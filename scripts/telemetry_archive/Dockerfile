FROM python:3.12-slim
WORKDIR /app
COPY requirements.lock ./requirements.lock
RUN pip install --no-cache-dir --require-hashes -r requirements.lock
COPY src ./src
ENV PYTHONPATH=/app/src PYTHONUNBUFFERED=1
USER 65532:65532
ENTRYPOINT ["python", "-m", "telemetry_archive.cli"]
