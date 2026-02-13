from __future__ import annotations

import hashlib
import time
from dataclasses import dataclass
from typing import Any, Callable, Mapping

import psycopg
import pytest
import requests


@dataclass(frozen=True)
class WaitConfig:
    timeout_sec: float
    poll_interval_sec: float


def sha256_hex(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def require_webhook(url: str | None, env_name: str) -> str:
    if not url:
        pytest.skip(f"{env_name} is not set")
    return url


def post_webhook(
    session: requests.Session,
    url: str,
    payload: dict[str, Any],
    timeout_sec: float,
    global_headers: Mapping[str, str] | None = None,
    extra_headers: Mapping[str, str] | None = None,
) -> requests.Response:
    headers: dict[str, str] = {}
    if global_headers:
        headers.update(global_headers)
    if extra_headers:
        headers.update(extra_headers)
    return session.post(url, json=payload, headers=headers, timeout=timeout_sec)


def wait_until(
    predicate: Callable[[], bool],
    wait: WaitConfig,
    description: str,
) -> None:
    deadline = time.monotonic() + wait.timeout_sec
    last_error: Exception | None = None
    while time.monotonic() < deadline:
        try:
            if predicate():
                return
        except Exception as exc:  # pragma: no cover - defensive diagnostics
            last_error = exc
        time.sleep(wait.poll_interval_sec)
    if last_error is not None:
        raise AssertionError(f"Timed out: {description}; last error: {last_error}") from last_error
    raise AssertionError(f"Timed out: {description}")


def sql_scalar(conn: psycopg.Connection[Any], sql: str, params: tuple[Any, ...] = ()) -> Any:
    with conn.cursor() as cur:
        cur.execute(sql, params)
        row = cur.fetchone()
    return None if row is None else row[0]

