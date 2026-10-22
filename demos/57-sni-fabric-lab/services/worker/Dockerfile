FROM docker.io/library/python:3.12.14-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
# requirements.lock pins every package with its hash (generated from requirements.txt).
COPY requirements.lock .
RUN pip install --no-cache-dir --require-hashes -r requirements.lock
COPY worker.py .

# Fixed non-root UID; the init container gives this UID its MQ password.
RUN useradd --uid 10003 --no-create-home --shell /usr/sbin/nologin app
USER 10003
EXPOSE 9100
# opentelemetry-instrument (R1.4) configures OpenTelemetry from the OTEL_* variables compose.yaml
# sets, instruments httpx, then execs the same command: no code change.
CMD ["opentelemetry-instrument", "python", "worker.py"]
