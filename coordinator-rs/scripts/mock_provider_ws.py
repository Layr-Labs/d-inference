#!/usr/bin/env python3
"""Minimal Protocol-V2 mock provider for warm-plane smoke."""
import asyncio
import json
import sys
import websockets

URL = sys.argv[1] if len(sys.argv) > 1 else "ws://127.0.0.1:18083/ws/provider"
MODEL = "pilot-text-model"

async def main():
    async with websockets.connect(URL) as ws:
        await ws.send(json.dumps({
            "type": "register",
            "public_key": "smoke-provider-pk",
            "encrypted_response_chunks": True,
            "models": [{"id": MODEL}],
            "protocol_capabilities": {"v2": True, "binary_payload_frames": True},
        }))
        ack = json.loads(await asyncio.wait_for(ws.recv(), timeout=5))
        print("REGISTER_ACK", json.dumps(ack), flush=True)
        await ws.send(json.dumps({
            "type": "heartbeat",
            "warm_models": [MODEL],
            "active_model": MODEL,
        }))
        await ws.send(json.dumps({
            "type": "model_ready",
            "model": MODEL,
            "state_revision": 1,
        }))
        print("READY", flush=True)
        while True:
            raw = await ws.recv()
            msg = json.loads(raw)
            t = msg.get("type")
            print("IN", t, flush=True)
            if t == "prepare":
                await ws.send(json.dumps({
                    "type": "prepared",
                    "job_id": msg.get("job_id"),
                    "attempt_id": msg.get("attempt_id"),
                    "lease_id": msg.get("lease_id"),
                    "session_epoch": msg.get("session_epoch", 0),
                    "lease_ttl_ms": 15000,
                    "prompt_tokens": 4,
                    "max_output_tokens": 64,
                    "engine_queue_depth": 0,
                    "prefill_can_begin": True,
                    "predicted_first_content_ms": 50,
                }))
            elif t == "start":
                await ws.send(json.dumps({
                    "type": "started",
                    "job_id": msg.get("job_id"),
                    "attempt_id": msg.get("attempt_id"),
                    "lease_id": msg.get("lease_id"),
                    "session_epoch": msg.get("session_epoch", 0),
                }))
            elif t == "terminal_ack":
                print("TERMINAL_ACK", json.dumps(msg), flush=True)
            elif t in ("abort", "cancel"):
                await ws.send(json.dumps({
                    "type": "aborted" if t == "abort" else "cancelled",
                    "job_id": msg.get("job_id"),
                    "attempt_id": msg.get("attempt_id"),
                    "lease_id": msg.get("lease_id"),
                }))

asyncio.run(main())
