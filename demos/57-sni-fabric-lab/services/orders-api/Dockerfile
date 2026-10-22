FROM docker.io/library/python:3.12.14-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /srv
# requirements.lock pins every transitive package (generated from requirements.txt).
COPY requirements.lock .
RUN pip install --no-cache-dir --require-hashes -r requirements.lock
COPY app ./app

# Fixed non-root UID; the init container gives this UID its key and secrets.
RUN useradd --uid 10002 --no-create-home --shell /usr/sbin/nologin app
USER 10002
EXPOSE 8443 8080
CMD ["python", "-m", "app.main"]
