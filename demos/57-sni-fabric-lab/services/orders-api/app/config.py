"""Settings, read once from the environment. Every address points at Envoy, never at a peer."""

import os
from dataclasses import dataclass, field


def _env(name: str, default: str = "") -> str:
    return os.environ.get(name, default).strip()


def _read_secret(path: str) -> str:
    with open(path, encoding="utf-8") as handle:
        return handle.read().strip()


@dataclass(frozen=True)
class Settings:
    # Public TLS server (reached through Envoy's edge_sni) and internal plain server (mesh_http).
    tls_dir: str = field(default_factory=lambda: _env("TLS_DIR", "/tls/orders-api"))
    ca_file: str = field(default_factory=lambda: _env("CA_FILE", "/tls/ca/ca.crt"))
    public_port: int = field(default_factory=lambda: int(_env("PUBLIC_PORT", "8443")))
    internal_port: int = field(default_factory=lambda: int(_env("INTERNAL_PORT", "8080")))
    cors_origins: tuple[str, ...] = field(default_factory=lambda: tuple(
        o for o in _env("CORS_ORIGINS", "https://web.fabric.localtest.me:8443").split(",") if o))

    # Postgres, through Envoy's mesh_pg listener.
    db_host: str = field(default_factory=lambda: _env("DB_HOST", "postgres.mesh"))
    db_port: int = field(default_factory=lambda: int(_env("DB_PORT", "15432")))
    db_name: str = field(default_factory=lambda: _env("DB_NAME", "fabric"))
    db_user: str = field(default_factory=lambda: _env("DB_USER", "fabric"))
    db_password_file: str = field(default_factory=lambda: _env("DB_PASSWORD_FILE", "/secrets/orders-api/postgres-password"))

    # tcp-svc, through Envoy's edge_sni listener (the same port browsers use).
    tcp_host: str = field(default_factory=lambda: _env("TCP_SVC_HOST", "tcp.fabric.localtest.me"))
    tcp_port: int = field(default_factory=lambda: int(_env("TCP_SVC_PORT", "10443")))

    # IBM MQ REST API, through Envoy's mesh_http listener. Empty disables publishing.
    mq_rest_url: str = field(default_factory=lambda: _env("MQ_REST_URL"))
    mq_qmgr: str = field(default_factory=lambda: _env("MQ_QMGR", "QM1"))
    mq_queue: str = field(default_factory=lambda: _env("MQ_QUEUE", "DEV.QUEUE.1"))
    mq_user: str = field(default_factory=lambda: _env("MQ_APP_USER", "app"))
    mq_password_file: str = field(default_factory=lambda: _env("MQ_APP_PASSWORD_FILE", "/secrets/orders-api/mq-app-password"))

    # Health and dashboard sources, through mesh_http. Empty disables each one.
    web_health_url: str = field(default_factory=lambda: _env("WEB_HEALTH_URL", "https://web.fabric.localtest.me:10443/healthz"))
    envoy_ready_url: str = field(default_factory=lambda: _env("ENVOY_READY_URL"))
    worker_metrics_url: str = field(default_factory=lambda: _env("WORKER_METRICS_URL"))
    prometheus_url: str = field(default_factory=lambda: _env("PROMETHEUS_URL"))

    admin_token_file: str = field(default_factory=lambda: _env("ADMIN_TOKEN_FILE", "/secrets/orders-api/admin-token"))
    # The worker's bearer token for PUT /orders/{id}/status on the internal server.
    worker_token_file: str = field(default_factory=lambda: _env("WORKER_TOKEN_FILE", "/secrets/orders-api/worker-token"))

    # Orders still "created" this long after their last event get their event sent again.
    sweep_after_s: float = field(default_factory=lambda: float(_env("SWEEP_AFTER_S", "60")))
    sweep_every_s: float = field(default_factory=lambda: float(_env("SWEEP_EVERY_S", "15")))

    @property
    def db_password(self) -> str:
        return _read_secret(self.db_password_file)

    @property
    def mq_password(self) -> str:
        return _read_secret(self.mq_password_file)

    @property
    def admin_token(self) -> str:
        return _read_secret(self.admin_token_file)

    @property
    def worker_token(self) -> str:
        return _read_secret(self.worker_token_file)


settings = Settings()
