from __future__ import annotations

import os
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterator

import psycopg
import pytest
import requests
from dotenv import load_dotenv

from helpers import WaitConfig, sha256_hex

# Load local test env vars (ignored by git) if present.
_DOTENV_PATH = Path(__file__).with_name(".env")
if _DOTENV_PATH.exists():
    load_dotenv(dotenv_path=_DOTENV_PATH, override=False)


@dataclass(frozen=True)
class TestSettings:
    # Prevent pytest from trying to collect this dataclass as a test container.
    __test__ = False

    database_url: str | None
    wf01_push_url: str | None
    wf01_pull_url: str | None
    wf02_dispatcher_url: str | None
    wf03_monitor_url: str | None
    wf11_bot_ingest_url: str | None
    wf12_bot_engine_url: str | None
    wf13_bot_monitor_url: str | None
    wf_adapter_telegram_url: str | None
    wf_adapter_max_url: str | None
    webhook_auth_header: str | None
    webhook_auth_value: str | None
    adapter_tg_target_id: str | None
    adapter_tg_photo_url: str | None
    adapter_tg_video_url: str | None
    ingest_secret_header: str
    bot_secret_header: str
    request_timeout_sec: float
    poll_timeout_sec: float
    poll_interval_sec: float


def _env_str(name: str, default: str | None = None) -> str | None:
    value = os.getenv(name, default)
    if value is None:
        return None
    value = value.strip()
    return value or None


def _env_float(name: str, default: float) -> float:
    value = _env_str(name)
    if value is None:
        return default
    return float(value)


@pytest.fixture(scope="session")
def settings() -> TestSettings:
    return TestSettings(
        database_url=_env_str("DATABASE_URL"),
        wf01_push_url=_env_str("WF01_PUSH_WEBHOOK_URL"),
        wf01_pull_url=_env_str("WF01_PULL_WEBHOOK_URL"),
        wf02_dispatcher_url=_env_str("WF02_DISPATCHER_WEBHOOK_URL"),
        wf03_monitor_url=_env_str("WF03_MONITOR_WEBHOOK_URL"),
        wf11_bot_ingest_url=_env_str("WF11_BOT_INGEST_WEBHOOK_URL"),
        wf12_bot_engine_url=_env_str("WF12_BOT_ENGINE_WEBHOOK_URL"),
        wf13_bot_monitor_url=_env_str("WF13_BOT_MONITOR_WEBHOOK_URL"),
        wf_adapter_telegram_url=_env_str("WF_ADAPTER_TELEGRAM_WEBHOOK_URL"),
        wf_adapter_max_url=_env_str("WF_ADAPTER_MAX_WEBHOOK_URL"),
        webhook_auth_header=_env_str("N8N_WEBHOOK_AUTH_HEADER"),
        webhook_auth_value=_env_str("N8N_WEBHOOK_AUTH_VALUE"),
        adapter_tg_target_id=_env_str("ADAPTER_TG_TARGET_ID"),
        adapter_tg_photo_url=_env_str("ADAPTER_TG_PHOTO_URL"),
        adapter_tg_video_url=_env_str("ADAPTER_TG_VIDEO_URL"),
        ingest_secret_header=_env_str("INGEST_SECRET_HEADER", "X-Autoposting-Secret") or "X-Autoposting-Secret",
        bot_secret_header=_env_str("BOT_SECRET_HEADER", "X-Autoposting-Secret") or "X-Autoposting-Secret",
        request_timeout_sec=_env_float("REQUEST_TIMEOUT_SEC", 20.0),
        poll_timeout_sec=_env_float("POLL_TIMEOUT_SEC", 45.0),
        poll_interval_sec=_env_float("POLL_INTERVAL_SEC", 1.0),
    )


@pytest.fixture(scope="session")
def wait_config(settings: TestSettings) -> WaitConfig:
    return WaitConfig(
        timeout_sec=settings.poll_timeout_sec,
        poll_interval_sec=settings.poll_interval_sec,
    )


@pytest.fixture(scope="session")
def db_conn(settings: TestSettings) -> Iterator[psycopg.Connection[Any]]:
    if not settings.database_url:
        pytest.skip("DATABASE_URL is required for workflow e2e tests")
    with psycopg.connect(settings.database_url, autocommit=True) as conn:
        yield conn


@pytest.fixture(scope="session")
def http_session() -> Iterator[requests.Session]:
    with requests.Session() as session:
        yield session


@pytest.fixture(scope="session")
def webhook_base_headers(settings: TestSettings) -> dict[str, str]:
    headers: dict[str, str] = {}
    if settings.webhook_auth_header and settings.webhook_auth_value:
        headers[settings.webhook_auth_header] = settings.webhook_auth_value
    return headers


@pytest.fixture()
def workspace_ctx(db_conn: psycopg.Connection[Any]) -> Iterator[dict[str, str]]:
    workspace_id = str(uuid.uuid4())
    push_endpoint_id = str(uuid.uuid4())
    pull_endpoint_id = str(uuid.uuid4())
    bot_endpoint_id = str(uuid.uuid4())
    pull_source_id = f"src-{uuid.uuid4().hex[:12]}"
    push_secret = f"push-{uuid.uuid4().hex}"
    pull_secret = f"pull-{uuid.uuid4().hex}"
    bot_secret = f"bot-{uuid.uuid4().hex}"
    rate_group = f"rg-{uuid.uuid4().hex[:8]}"

    with db_conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO public.workspaces (workspace_id, name, status)
            VALUES (%s, %s, 'active')
            """,
            (workspace_id, f"autotest-{workspace_id[:8]}"),
        )

        cur.execute(
            """
            INSERT INTO public.workspace_endpoints
              (workspace_id, endpoint_id, kind, secret_hash, enabled, source_id)
            VALUES
              (%s, %s, 'webhook_push', %s, true, NULL),
              (%s, %s, 'pull_source', %s, true, %s),
              (%s, %s, 'bot_webhook', %s, true, NULL)
            """,
            (
                workspace_id,
                push_endpoint_id,
                sha256_hex(push_secret),
                workspace_id,
                pull_endpoint_id,
                sha256_hex(pull_secret),
                pull_source_id,
                workspace_id,
                bot_endpoint_id,
                sha256_hex(bot_secret),
            ),
        )

        cur.execute(
            """
            INSERT INTO public.pull_sources
              (workspace_id, source_id, endpoint_id, kind, config_json, enabled)
            VALUES (%s, %s, %s, 'api', '{}'::jsonb, true)
            """,
            (workspace_id, pull_source_id, pull_endpoint_id),
        )

        cur.execute(
            """
            INSERT INTO public.pull_cursors (workspace_id, source_id, cursor_json)
            VALUES (%s, %s, '{}'::jsonb)
            """,
            (workspace_id, pull_source_id),
        )

        cur.execute(
            """
            INSERT INTO public.channels
              (workspace_id, channel_id, platform, target_id, auth_ref, rate_group, enabled, rate_rps, max_parallel, route_filter)
            VALUES
              (%s, 'ch_tg', 'telegram', %s, 'autotest-auth', %s, true, 1, 1, '{}'::jsonb),
              (%s, 'ch_max', 'max', %s, 'autotest-auth', %s, true, 1, 1, '{}'::jsonb)
            """,
            (
                workspace_id,
                f"-100{uuid.uuid4().int % 10_000_000}",
                rate_group,
                workspace_id,
                f"chat-{uuid.uuid4().hex[:10]}",
                rate_group,
            ),
        )

        cur.execute(
            """
            INSERT INTO public.platform_limits
              (workspace_id, platform, rate_group, rate_rps, burst)
            VALUES
              (%s, 'telegram', %s, 5, 1),
              (%s, 'max', %s, 5, 1)
            """,
            (workspace_id, rate_group, workspace_id, rate_group),
        )

    context = {
        "workspace_id": workspace_id,
        "push_endpoint_id": push_endpoint_id,
        "pull_endpoint_id": pull_endpoint_id,
        "bot_endpoint_id": bot_endpoint_id,
        "pull_source_id": pull_source_id,
        "push_secret": push_secret,
        "pull_secret": pull_secret,
        "bot_secret": bot_secret,
    }

    try:
        yield context
    finally:
        with db_conn.cursor() as cur:
            cur.execute("DELETE FROM public.workspaces WHERE workspace_id = %s", (workspace_id,))
