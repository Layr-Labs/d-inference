"""Continuous-batching STT server for DGInf providers.

Keeps the model loaded on GPU, accepts concurrent transcription requests,
and batches them together for efficient GPU utilization — same pattern
as vllm-mlx for LLM inference.

Usage:
    python stt_server.py --model CohereLabs/cohere-transcribe-03-2026 --port 8101

The server exposes:
    GET  /health                    Health check
    GET  /v1/models                 List loaded model
    POST /v1/audio/transcriptions   OpenAI-compatible transcription endpoint
"""

import argparse
import asyncio
import io
import os
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

import numpy as np
import uvicorn
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import JSONResponse

# ---------------------------------------------------------------------------
# Batching scheduler
# ---------------------------------------------------------------------------

@dataclass
class TranscriptionJob:
    """A single transcription request waiting to be batched."""
    audio_path: str
    language: str
    result_future: asyncio.Future = field(default_factory=lambda: asyncio.get_event_loop().create_future())
    submitted_at: float = field(default_factory=time.time)


class BatchScheduler:
    """Collects incoming transcription jobs and runs them in GPU batches.

    Jobs accumulate in a queue. The scheduler fires a batch when either:
      - max_batch_size jobs are waiting, OR
      - max_wait_ms has elapsed since the first job in the current batch

    This is continuous batching: new requests arriving while a batch is
    running are queued for the next batch, not blocked.
    """

    def __init__(
        self,
        model,
        max_batch_size: int = 16,
        max_wait_ms: float = 50.0,
    ):
        self.model = model
        self.max_batch_size = max_batch_size
        self.max_wait_ms = max_wait_ms
        self._queue: asyncio.Queue[TranscriptionJob] = asyncio.Queue()
        self._running = False

        # Stats
        self.total_requests = 0
        self.total_batches = 0
        self.total_audio_seconds = 0.0
        self.total_processing_seconds = 0.0

    async def submit(self, job: TranscriptionJob) -> dict:
        """Submit a job and wait for its result."""
        await self._queue.put(job)
        return await job.result_future

    async def run(self):
        """Main batch processing loop. Call this as a background task."""
        self._running = True
        print(f"[BatchScheduler] Started (max_batch={self.max_batch_size}, max_wait={self.max_wait_ms}ms)")

        while self._running:
            # Wait for at least one job
            try:
                first_job = await asyncio.wait_for(self._queue.get(), timeout=1.0)
            except asyncio.TimeoutError:
                continue

            # Collect more jobs up to batch size or timeout
            batch = [first_job]
            deadline = time.time() + (self.max_wait_ms / 1000.0)

            while len(batch) < self.max_batch_size:
                remaining = deadline - time.time()
                if remaining <= 0:
                    break
                try:
                    job = await asyncio.wait_for(self._queue.get(), timeout=remaining)
                    batch.append(job)
                except asyncio.TimeoutError:
                    break

            # Run the batch on GPU
            await self._process_batch(batch)

    async def _process_batch(self, batch: list[TranscriptionJob]):
        """Process a batch of jobs through the model."""
        batch_size = len(batch)
        self.total_batches += 1
        self.total_requests += batch_size

        t0 = time.time()

        # Group by language for efficient batching (model requires same language per batch)
        by_language: dict[str, list[tuple[int, TranscriptionJob]]] = {}
        for idx, job in enumerate(batch):
            by_language.setdefault(job.language, []).append((idx, job))

        results = [None] * batch_size

        for language, group in by_language.items():
            indices = [i for i, _ in group]
            audio_files = [job.audio_path for _, job in group]

            try:
                # Run transcription on the thread pool to avoid blocking the event loop
                # (MLX ops release the GIL during compute)
                loop = asyncio.get_event_loop()
                texts = await loop.run_in_executor(
                    None,
                    lambda: self.model.transcribe(
                        language=language,
                        audio_files=audio_files,
                        batch_size=self.max_batch_size,
                    ),
                )

                for idx, text in zip(indices, texts):
                    results[idx] = {"text": text, "language": language, "error": None}

            except Exception as e:
                for idx, _ in group:
                    results[idx] = {"text": "", "language": language, "error": str(e)}

        elapsed = time.time() - t0

        # Resolve all futures
        for job, result in zip(batch, results):
            if not job.result_future.done():
                if result and result.get("error"):
                    job.result_future.set_exception(
                        RuntimeError(result["error"])
                    )
                else:
                    job.result_future.set_result(result)

            # Clean up temp file
            try:
                os.remove(job.audio_path)
            except OSError:
                pass

        # Update stats
        self.total_processing_seconds += elapsed

        if batch_size > 1:
            print(
                f"[BatchScheduler] Batch of {batch_size} completed in {elapsed:.2f}s "
                f"({elapsed/batch_size:.2f}s/request, {batch_size/elapsed:.1f} req/s)"
            )
        else:
            print(f"[BatchScheduler] Single request completed in {elapsed:.2f}s")

    def stop(self):
        self._running = False


# ---------------------------------------------------------------------------
# FastAPI app
# ---------------------------------------------------------------------------

app = FastAPI(title="DGInf STT Server")

# Global state — set during startup
_model = None
_scheduler: Optional[BatchScheduler] = None
_model_id: str = ""
_start_time: float = 0.0


@app.get("/health")
async def health():
    if _model is None:
        raise HTTPException(status_code=503, detail="model not loaded")
    return {"status": "ok", "model": _model_id}


@app.get("/v1/models")
async def list_models():
    return {
        "object": "list",
        "data": [
            {
                "id": _model_id,
                "object": "model",
                "created": int(_start_time),
                "owned_by": "dginf",
                "type": "stt",
            }
        ],
    }


@app.post("/v1/audio/transcriptions")
async def transcribe(
    file: UploadFile = File(...),
    model: str = Form(...),
    language: str = Form("en"),
):
    """OpenAI-compatible transcription endpoint with continuous batching."""
    if _scheduler is None:
        raise HTTPException(status_code=503, detail="server not ready")

    # Read uploaded audio to temp file
    data = await file.read()
    ext = Path(file.filename or "audio.wav").suffix or ".wav"
    raw_path = f"/tmp/dginf-stt-raw-{id(data)}-{time.monotonic_ns()}{ext}"
    tmp_path = f"/tmp/dginf-stt-{id(data)}-{time.monotonic_ns()}.wav"

    # Write raw upload, then convert to wav via ffmpeg for format compatibility.
    # Browser MediaRecorder produces webm/opus which soundfile can't read.
    with open(raw_path, "wb") as f:
        f.write(data)

    import subprocess
    try:
        subprocess.run(
            ["ffmpeg", "-y", "-i", raw_path, "-ar", "16000", "-ac", "1", tmp_path],
            capture_output=True, timeout=60,
        )
    except FileNotFoundError:
        # No ffmpeg — try soundfile directly
        pass
    finally:
        try:
            os.remove(raw_path)
        except OSError:
            pass

    if not os.path.exists(tmp_path):
        # ffmpeg failed or not installed — try soundfile as fallback
        try:
            from mlx_audio.audio_io import read as audio_read, write as audio_write
            buf = io.BytesIO(data)
            audio, sr = audio_read(buf, always_2d=False)
            audio_write(tmp_path, audio, sr)
        except Exception:
            raise HTTPException(status_code=400, detail="could not decode audio file — install ffmpeg for webm/opus support")

    # Estimate audio duration from the wav file
    try:
        import soundfile as sf
        info = sf.info(tmp_path)
        audio_seconds = info.duration
    except Exception:
        audio_seconds = 0.0

    # Submit to batch scheduler
    job = TranscriptionJob(
        audio_path=tmp_path,
        language=language,
    )

    t0 = time.time()
    try:
        result = await _scheduler.submit(job)
    except Exception as e:
        # Clean up temp file on error
        try:
            os.remove(tmp_path)
        except OSError:
            pass
        raise HTTPException(status_code=500, detail=str(e))

    elapsed = time.time() - t0

    return JSONResponse({
        "text": result["text"],
        "language": result.get("language", language),
        "duration": audio_seconds,
        "processing_time": elapsed,
        "model": model,
    })


@app.get("/v1/stats")
async def stats():
    """Server statistics for monitoring."""
    if _scheduler is None:
        return {"status": "not ready"}

    uptime = time.time() - _start_time
    return {
        "uptime_seconds": uptime,
        "total_requests": _scheduler.total_requests,
        "total_batches": _scheduler.total_batches,
        "avg_batch_size": (
            _scheduler.total_requests / _scheduler.total_batches
            if _scheduler.total_batches > 0
            else 0
        ),
        "total_processing_seconds": _scheduler.total_processing_seconds,
        "requests_per_second": (
            _scheduler.total_requests / uptime if uptime > 0 else 0
        ),
        "model": _model_id,
        "queue_size": _scheduler._queue.qsize(),
    }


# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------

def load_model(model_path: str):
    """Load the STT model and return it."""
    print(f"[STT Server] Loading model: {model_path}")
    t0 = time.time()

    # Patch the audio frontend loader for MLX-native models (no torch needed)
    from mlx_audio.stt.models.cohere_asr import audio as audio_mod
    from safetensors import safe_open
    import mlx.core as mx

    orig_load = audio_mod.CohereAudioFrontend.load_buffers_from_checkpoint

    def patched_load(self, mp):
        safetensor_path = Path(mp) / "model.safetensors"
        if not safetensor_path.exists():
            return
        try:
            # Try numpy first (works for MLX-converted models)
            with safe_open(str(safetensor_path), framework="np") as f:
                keys = set(f.keys())
                if "preprocessor.featurizer.fb" in keys:
                    fb = f.get_tensor("preprocessor.featurizer.fb").astype(np.float32)
                    self.fb = mx.array(fb.squeeze(0) if fb.ndim > 2 else fb).astype(mx.float32)
                if "preprocessor.featurizer.window" in keys:
                    window = f.get_tensor("preprocessor.featurizer.window").astype(np.float32)
                    self.window = mx.array(window).astype(mx.float32)
        except Exception:
            # Fall back to original (requires torch)
            orig_load(self, mp)

    audio_mod.CohereAudioFrontend.load_buffers_from_checkpoint = patched_load

    from mlx_audio.stt.utils import load_model as mlx_load_model
    model = mlx_load_model(model_path)

    elapsed = time.time() - t0
    print(f"[STT Server] Model loaded in {elapsed:.1f}s")
    return model


def main():
    global _model, _scheduler, _model_id, _start_time

    parser = argparse.ArgumentParser(description="DGInf STT Server with continuous batching")
    parser.add_argument("--model", required=True, help="Model path or HuggingFace repo ID")
    parser.add_argument("--port", type=int, default=8101, help="Port to listen on")
    parser.add_argument("--host", default="127.0.0.1", help="Host to bind to")
    parser.add_argument("--max-batch-size", type=int, default=16, help="Maximum batch size for GPU inference")
    parser.add_argument("--max-wait-ms", type=float, default=50.0, help="Max ms to wait for batch to fill")
    args = parser.parse_args()

    _model_id = args.model
    _start_time = time.time()

    # Load model
    _model = load_model(args.model)

    # Create scheduler
    _scheduler = BatchScheduler(
        model=_model,
        max_batch_size=args.max_batch_size,
        max_wait_ms=args.max_wait_ms,
    )

    # Start scheduler as background task
    @app.on_event("startup")
    async def start_scheduler():
        asyncio.create_task(_scheduler.run())

    @app.on_event("shutdown")
    async def stop_scheduler():
        _scheduler.stop()

    print(f"[STT Server] Starting on {args.host}:{args.port}")
    print(f"[STT Server] Batch config: max_batch_size={args.max_batch_size}, max_wait_ms={args.max_wait_ms}")

    uvicorn.run(
        app,
        host=args.host,
        port=args.port,
        log_level="info",
        # Single worker — model is in this process, no need for multiprocessing
        workers=1,
    )


if __name__ == "__main__":
    main()
