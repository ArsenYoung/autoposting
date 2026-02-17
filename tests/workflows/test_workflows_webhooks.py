from __future__ import annotations

import json
import uuid
from typing import Any

import psycopg
import pytest
import requests

from conftest import TestSettings
from helpers import WaitConfig, post_webhook, require_webhook, sql_scalar, wait_until

pytestmark = [pytest.mark.integration]


def _assert_webhook_ok(response: requests.Response, allow_conflict: bool = False) -> None:
    allowed = {200, 201, 202, 204}
    if allow_conflict:
        allowed.add(409)
    assert response.status_code in allowed, (
        f"Unexpected webhook status={response.status_code}; body={response.text}"
    )


def _enqueue_for_dispatcher(
    db_conn: psycopg.Connection[Any],
    workspace_id: str,
    endpoint_id: str,
    content_hash: str,
    source_ref: str,
    text: str,
) -> None:
    payload = {
        "hash_version": 1,
        "content_hash": content_hash,
        "source_ref": source_ref,
        "payload": {"text": text},
        "rendered_text": text,
        "tags": ["pytest", "dispatcher"],
        "trace_id": f"trace-{uuid.uuid4().hex}",
        "ingest_run_id": f"run-{uuid.uuid4().hex}",
    }
    with db_conn.cursor() as cur:
        cur.execute(
            """
            SELECT public.enqueue_messages_and_deliveries(
              %s, %s, 'push', %s::jsonb, now()
            )
            """,
            (workspace_id, endpoint_id, json.dumps(payload)),
        )


def _pause_workspace_channel(
    db_conn: psycopg.Connection[Any],
    workspace_id: str,
    minutes: int = 30,
) -> int:
    with db_conn.cursor() as cur:
        cur.execute(
            """
            UPDATE public.channels c
            SET paused_until = now() + make_interval(mins => %s),
                updated_at = now()
            WHERE c.workspace_id = %s
              AND c.enabled = true
            RETURNING c.channel_id
            """,
            (minutes, workspace_id),
        )
        rows = cur.fetchall()
    assert rows, "precondition failed: no enabled channel found to pause"
    return len(rows)


def test_workflow_01_ingest_push_webhook(
    settings: TestSettings,
    db_conn: psycopg.Connection[Any],
    http_session: requests.Session,
    webhook_base_headers: dict[str, str],
    wait_config: WaitConfig,
    workspace_ctx: dict[str, str],
) -> None:
    url = require_webhook(settings.wf01_push_url, "WF01_PUSH_WEBHOOK_URL")
    source_ref = f"push-{uuid.uuid4().hex}"
    content_hash = f"hash-{uuid.uuid4().hex}"
    trace_id = f"trace-{uuid.uuid4().hex}"
    ingest_run_id = f"run-{uuid.uuid4().hex}"

    payload = {
        "source_ref": source_ref,
        "content_hash": content_hash,
        "hash_version": 1,
        "payload": {"text": f"E2E ingest push {source_ref}"},
        "rendered_text": f"E2E ingest push {source_ref}",
        "tags": ["pytest", "ingest", "push"],
        "trace_id": trace_id,
        "ingest_run_id": ingest_run_id,
    }

    response = post_webhook(
        session=http_session,
        url=url,
        payload=payload,
        timeout_sec=settings.request_timeout_sec,
        global_headers=webhook_base_headers,
        extra_headers={settings.ingest_secret_header: workspace_ctx["push_secret"]},
    )
    _assert_webhook_ok(response)

    def _deliveries_created() -> bool:
        return (
            sql_scalar(
                db_conn,
                """
                SELECT COUNT(*)
                FROM public.deliveries d
                JOIN public.messages m
                  ON m.workspace_id = d.workspace_id
                 AND m.message_id = d.message_id
                WHERE d.workspace_id = %s
                  AND m.source_ref = %s
                """,
                (workspace_ctx["workspace_id"], source_ref),
            )
            > 0
        )

    wait_until(_deliveries_created, wait_config, "ingest push deliveries were not created")


def test_workflow_01_ingest_pull_webhook(
    settings: TestSettings,
    db_conn: psycopg.Connection[Any],
    http_session: requests.Session,
    webhook_base_headers: dict[str, str],
    wait_config: WaitConfig,
    workspace_ctx: dict[str, str],
) -> None:
    url = require_webhook(settings.wf01_pull_url, "WF01_PULL_WEBHOOK_URL")
    source_ref = f"pull-{uuid.uuid4().hex}"
    base_item = {
        "source_ref": source_ref,
        "hash_version": 1,
        "content_hash": f"hash-{uuid.uuid4().hex}",
        "payload": {"text": f"E2E ingest pull {source_ref}"},
        "rendered_text": f"E2E ingest pull {source_ref}",
        "tags": ["pytest", "ingest", "pull"],
        "cursor_to": f"cursor-{uuid.uuid4().hex}",
    }
    payload = {
        "workspace_id": workspace_ctx["workspace_id"],
        "source_id": workspace_ctx["pull_source_id"],
        "items": [base_item, base_item],  # duplicate on purpose for receipt dedup
    }

    response = post_webhook(
        session=http_session,
        url=url,
        payload=payload,
        timeout_sec=settings.request_timeout_sec,
        global_headers=webhook_base_headers,
    )
    _assert_webhook_ok(response)

    def _receipts_inserted() -> bool:
        return (
            sql_scalar(
                db_conn,
                """
                SELECT COUNT(*)
                FROM public.pull_receipts
                WHERE workspace_id = %s
                  AND source_id = %s
                  AND source_ref = %s
                """,
                (workspace_ctx["workspace_id"], workspace_ctx["pull_source_id"], source_ref),
            )
            >= 1
        )

    wait_until(_receipts_inserted, wait_config, "pull receipts were not inserted")

    receipt_count = sql_scalar(
        db_conn,
        """
        SELECT COUNT(*)
        FROM public.pull_receipts
        WHERE workspace_id = %s
          AND source_id = %s
          AND source_ref = %s
        """,
        (workspace_ctx["workspace_id"], workspace_ctx["pull_source_id"], source_ref),
    )
    assert receipt_count == 1, "duplicate pull source_ref should be deduplicated"


def test_workflow_02_dispatcher_webhook(
    settings: TestSettings,
    db_conn: psycopg.Connection[Any],
    http_session: requests.Session,
    webhook_base_headers: dict[str, str],
    wait_config: WaitConfig,
    workspace_ctx: dict[str, str],
) -> None:
    url = require_webhook(settings.wf02_dispatcher_url, "WF02_DISPATCHER_WEBHOOK_URL")
    content_hash = f"dispatcher-{uuid.uuid4().hex}"
    source_ref = f"dispatcher-source-{uuid.uuid4().hex}"

    _enqueue_for_dispatcher(
        db_conn=db_conn,
        workspace_id=workspace_ctx["workspace_id"],
        endpoint_id=workspace_ctx["push_endpoint_id"],
        content_hash=content_hash,
        source_ref=source_ref,
        text=f"Dispatcher test {source_ref}",
    )

    queued_before = sql_scalar(
        db_conn,
        """
        SELECT COUNT(*)
        FROM public.deliveries d
        JOIN public.messages m
          ON m.workspace_id = d.workspace_id
         AND m.message_id = d.message_id
        WHERE d.workspace_id = %s
          AND m.content_hash = %s
          AND d.status = 'queued'
        """,
        (workspace_ctx["workspace_id"], content_hash),
    )
    assert queued_before > 0, "precondition failed: no queued deliveries before dispatcher run"

    response = post_webhook(
        session=http_session,
        url=url,
        payload={"workspace_id": workspace_ctx["workspace_id"], "test_run_id": uuid.uuid4().hex},
        timeout_sec=settings.request_timeout_sec,
        global_headers=webhook_base_headers,
    )
    _assert_webhook_ok(response)

    def _delivery_progressed() -> bool:
        progressed = sql_scalar(
            db_conn,
            """
            SELECT COUNT(*)
            FROM public.deliveries d
            JOIN public.messages m
              ON m.workspace_id = d.workspace_id
             AND m.message_id = d.message_id
            WHERE d.workspace_id = %s
              AND m.content_hash = %s
              AND d.status IN ('sending', 'sent', 'retry', 'failed_permanent', 'dead')
            """,
            (workspace_ctx["workspace_id"], content_hash),
        )
        return progressed >= 1

    wait_until(_delivery_progressed, wait_config, "dispatcher did not move queued delivery forward")


def test_workflow_03_monitor_webhook(
    settings: TestSettings,
    db_conn: psycopg.Connection[Any],
    http_session: requests.Session,
    webhook_base_headers: dict[str, str],
    wait_config: WaitConfig,
    workspace_ctx: dict[str, str],
) -> None:
    url = require_webhook(settings.wf03_monitor_url, "WF03_MONITOR_WEBHOOK_URL")
    content_hash = f"monitor-{uuid.uuid4().hex}"
    source_ref = f"monitor-source-{uuid.uuid4().hex}"

    _enqueue_for_dispatcher(
        db_conn=db_conn,
        workspace_id=workspace_ctx["workspace_id"],
        endpoint_id=workspace_ctx["push_endpoint_id"],
        content_hash=content_hash,
        source_ref=source_ref,
        text=f"Monitor test {source_ref}",
    )

    with db_conn.cursor() as cur:
        cur.execute(
            """
            SELECT delivery_id
            FROM public.claim_deliveries(%s, %s, 5, 300, now())
            LIMIT 1
            """,
            (workspace_ctx["workspace_id"], f"run-{uuid.uuid4().hex}"),
        )
        row = cur.fetchone()
        assert row is not None, "precondition failed: claim_deliveries returned no rows"
        delivery_id = row[0]

        cur.execute(
            """
            UPDATE public.deliveries
            SET sending_lease_until = now() - interval '10 minutes',
                lease_until = now() - interval '10 minutes'
            WHERE workspace_id = %s
              AND delivery_id = %s
            """,
            (workspace_ctx["workspace_id"], delivery_id),
        )

    response = post_webhook(
        session=http_session,
        url=url,
        payload={"workspace_id": workspace_ctx["workspace_id"], "test_run_id": uuid.uuid4().hex},
        timeout_sec=settings.request_timeout_sec,
        global_headers=webhook_base_headers,
    )
    _assert_webhook_ok(response)

    def _lease_recovered() -> bool:
        status = sql_scalar(
            db_conn,
            """
            SELECT status::text
            FROM public.deliveries
            WHERE workspace_id = %s
              AND delivery_id = %s
            """,
            (workspace_ctx["workspace_id"], delivery_id),
        )
        return status in {"retry", "dead"}

    wait_until(_lease_recovered, wait_config, "monitor did not recover expired sending lease")

    event_count = sql_scalar(
        db_conn,
        """
        SELECT COUNT(*)
        FROM public.events
        WHERE workspace_id = %s
          AND delivery_id = %s
          AND action IN ('sending_lease_expired', 'dead_letter')
        """,
        (workspace_ctx["workspace_id"], delivery_id),
    )
    assert event_count >= 1, "monitor recovery event was not written"


def test_workflow_03_monitor_no_alerts_no_notification(
    settings: TestSettings,
    http_session: requests.Session,
    webhook_base_headers: dict[str, str],
    workspace_ctx: dict[str, str],
) -> None:
    url = require_webhook(settings.wf03_monitor_url, "WF03_MONITOR_WEBHOOK_URL")
    response = post_webhook(
        session=http_session,
        url=url,
        payload={
            "workspace_id": workspace_ctx["workspace_id"],
            "test_run_id": uuid.uuid4().hex,
            "failed_permanent_threshold": 1000000,
            "paused_channels_threshold": 1000000,
            "alert_webhook_url": "http://127.0.0.1:1/should-not-be-used",
        },
        timeout_sec=settings.request_timeout_sec,
        global_headers=webhook_base_headers,
    )
    _assert_webhook_ok(response)

    data = _response_json(response)
    assert data.get("ok") is True
    alerts = data.get("alerts")
    assert isinstance(alerts, dict)
    assert alerts.get("has_alerts") is False

    notification = data.get("notification")
    assert isinstance(notification, dict), "expected notification object"
    assert notification.get("attempted") is False
    assert notification.get("delivered") is False
    assert notification.get("skipped") is True
    assert notification.get("reason") == "no_alerts"


def test_workflow_03_monitor_alerts_sent_with_cooldown(
    settings: TestSettings,
    db_conn: psycopg.Connection[Any],
    http_session: requests.Session,
    webhook_base_headers: dict[str, str],
    workspace_ctx: dict[str, str],
) -> None:
    url = require_webhook(settings.wf03_monitor_url, "WF03_MONITOR_WEBHOOK_URL")
    paused_count = _pause_workspace_channel(db_conn, workspace_ctx["workspace_id"], minutes=30)
    assert paused_count >= 2, "expected at least two enabled channels to trigger paused-channel alert"

    base_payload = {
        "workspace_id": workspace_ctx["workspace_id"],
        "paused_channels_threshold": 1,
        "failed_permanent_threshold": 1000000,
        "alert_cooldown_seconds": 300,
        "alert_webhook_url": url,
        "alert_webhook_headers": webhook_base_headers,
    }

    response_first = post_webhook(
        session=http_session,
        url=url,
        payload={**base_payload, "test_run_id": uuid.uuid4().hex},
        timeout_sec=settings.request_timeout_sec,
        global_headers=webhook_base_headers,
    )
    _assert_webhook_ok(response_first)
    data_first = _response_json(response_first)

    assert data_first.get("ok") is True
    assert data_first.get("alerts", {}).get("has_alerts") is True
    notification_first = data_first.get("notification")
    assert isinstance(notification_first, dict), "expected notification object on first alert run"
    assert notification_first.get("attempted") is True
    assert notification_first.get("delivered") is True
    assert notification_first.get("skipped") is False
    assert notification_first.get("reason") in {None, ""}

    alert_fingerprint = notification_first.get("alert_fingerprint")
    assert isinstance(alert_fingerprint, str) and alert_fingerprint, "missing alert fingerprint"

    response_second = post_webhook(
        session=http_session,
        url=url,
        payload={**base_payload, "test_run_id": uuid.uuid4().hex},
        timeout_sec=settings.request_timeout_sec,
        global_headers=webhook_base_headers,
    )
    _assert_webhook_ok(response_second)
    data_second = _response_json(response_second)

    assert data_second.get("ok") is True
    assert data_second.get("alerts", {}).get("has_alerts") is True
    notification_second = data_second.get("notification")
    assert isinstance(notification_second, dict), "expected notification object on cooldown run"
    assert notification_second.get("attempted") is False
    assert notification_second.get("delivered") is False
    assert notification_second.get("skipped") is True
    assert notification_second.get("reason") == "cooldown_active"
    assert notification_second.get("alert_fingerprint") == alert_fingerprint

    sent_count = sql_scalar(
        db_conn,
        """
        SELECT sent_count
        FROM public.monitor_alert_receipts
        WHERE workspace_key = %s
          AND alert_fingerprint = %s
        """,
        (workspace_ctx["workspace_id"], alert_fingerprint),
    )
    assert sent_count == 1, "cooldown dedup failed: expected sent_count to stay 1"


def test_workflow_03_monitor_alert_delivery_failed(
    settings: TestSettings,
    db_conn: psycopg.Connection[Any],
    http_session: requests.Session,
    webhook_base_headers: dict[str, str],
    workspace_ctx: dict[str, str],
) -> None:
    url = require_webhook(settings.wf03_monitor_url, "WF03_MONITOR_WEBHOOK_URL")
    paused_count = _pause_workspace_channel(db_conn, workspace_ctx["workspace_id"], minutes=30)
    assert paused_count >= 2, "expected at least two enabled channels to trigger paused-channel alert"

    response = post_webhook(
        session=http_session,
        url=url,
        payload={
            "workspace_id": workspace_ctx["workspace_id"],
            "test_run_id": uuid.uuid4().hex,
            "paused_channels_threshold": 1,
            "failed_permanent_threshold": 1000000,
            "alert_cooldown_seconds": 1,
            "alert_webhook_url": "http://127.0.0.1:1/monitor-alert",
        },
        timeout_sec=settings.request_timeout_sec,
        global_headers=webhook_base_headers,
    )
    _assert_webhook_ok(response)

    data = _response_json(response)
    assert data.get("ok") is False, "monitor should report notification delivery failure"
    assert data.get("alerts", {}).get("has_alerts") is True

    notification = data.get("notification")
    assert isinstance(notification, dict), "expected notification details on failed delivery"
    assert notification.get("attempted") is True
    assert notification.get("delivered") is False
    assert notification.get("reason") == "delivery_failed"

    error = data.get("error")
    assert isinstance(error, dict), "expected normalized error payload"
    assert error.get("code") == "monitor_alert_delivery_failed"


def test_workflow_11_bot_ingest_webhook(
    settings: TestSettings,
    db_conn: psycopg.Connection[Any],
    http_session: requests.Session,
    webhook_base_headers: dict[str, str],
    wait_config: WaitConfig,
    workspace_ctx: dict[str, str],
) -> None:
    url = require_webhook(settings.wf11_bot_ingest_url, "WF11_BOT_INGEST_WEBHOOK_URL")
    chat_id = f"chat-{uuid.uuid4().hex[:10]}"
    provider_message_id = f"msg-{uuid.uuid4().hex}"
    payload = {
        "provider": "max",
        "chat_id": chat_id,
        "provider_message_id": provider_message_id,
        "text": "hello bot",
        "trace_id": f"trace-{uuid.uuid4().hex}",
    }

    response_first = post_webhook(
        session=http_session,
        url=url,
        payload=payload,
        timeout_sec=settings.request_timeout_sec,
        global_headers=webhook_base_headers,
        extra_headers={settings.bot_secret_header: workspace_ctx["bot_secret"]},
    )
    _assert_webhook_ok(response_first, allow_conflict=True)

    response_second = post_webhook(
        session=http_session,
        url=url,
        payload=payload,
        timeout_sec=settings.request_timeout_sec,
        global_headers=webhook_base_headers,
        extra_headers={settings.bot_secret_header: workspace_ctx["bot_secret"]},
    )
    _assert_webhook_ok(response_second, allow_conflict=True)

    def _inbox_written() -> bool:
        return (
            sql_scalar(
                db_conn,
                """
                SELECT COUNT(*)
                FROM public.bot_inbox
                WHERE workspace_id = %s
                  AND provider = 'max'
                  AND chat_id = %s
                  AND provider_message_id = %s
                """,
                (workspace_ctx["workspace_id"], chat_id, provider_message_id),
            )
            >= 1
        )

    wait_until(_inbox_written, wait_config, "bot inbox record was not written")

    inbox_count = sql_scalar(
        db_conn,
        """
        SELECT COUNT(*)
        FROM public.bot_inbox
        WHERE workspace_id = %s
          AND provider = 'max'
          AND chat_id = %s
          AND provider_message_id = %s
        """,
        (workspace_ctx["workspace_id"], chat_id, provider_message_id),
    )
    assert inbox_count == 1, "bot inbound dedup failed; duplicate webhook should not create second inbox row"


def test_workflow_12_bot_engine_webhook_smoke(
    settings: TestSettings,
    http_session: requests.Session,
    webhook_base_headers: dict[str, str],
    workspace_ctx: dict[str, str],
) -> None:
    url = require_webhook(settings.wf12_bot_engine_url, "WF12_BOT_ENGINE_WEBHOOK_URL")
    payload = {
        "workspace_id": workspace_ctx["workspace_id"],
        "provider": "max",
        "chat_id": f"chat-{uuid.uuid4().hex[:10]}",
        "provider_message_id": f"msg-{uuid.uuid4().hex}",
        "text": "hello from bot engine smoke test",
    }
    response = post_webhook(
        session=http_session,
        url=url,
        payload=payload,
        timeout_sec=settings.request_timeout_sec,
        global_headers=webhook_base_headers,
    )
    _assert_webhook_ok(response, allow_conflict=True)


def test_workflow_12_bot_engine_state_outbox_idempotent(
    settings: TestSettings,
    db_conn: psycopg.Connection[Any],
    http_session: requests.Session,
    webhook_base_headers: dict[str, str],
    workspace_ctx: dict[str, str],
) -> None:
    url = require_webhook(settings.wf12_bot_engine_url, "WF12_BOT_ENGINE_WEBHOOK_URL")
    chat_id = f"chat-{uuid.uuid4().hex[:10]}"
    inbound_provider_message_id = f"msg-{uuid.uuid4().hex}"
    payload = {
        "workspace_id": workspace_ctx["workspace_id"],
        "provider": "max",
        "chat_id": chat_id,
        "provider_message_id": inbound_provider_message_id,
        "text": "hello from bot engine idempotency test",
    }

    response_first = post_webhook(
        session=http_session,
        url=url,
        payload=payload,
        timeout_sec=settings.request_timeout_sec,
        global_headers=webhook_base_headers,
    )
    _assert_webhook_ok(response_first, allow_conflict=True)
    data_first = _response_json(response_first)
    assert data_first.get("ok") is True
    assert data_first.get("duplicate") is False
    first_provider_message_id = data_first.get("provider_message_id")
    assert isinstance(first_provider_message_id, str) and first_provider_message_id

    response_second = post_webhook(
        session=http_session,
        url=url,
        payload=payload,
        timeout_sec=settings.request_timeout_sec,
        global_headers=webhook_base_headers,
    )
    _assert_webhook_ok(response_second, allow_conflict=True)
    data_second = _response_json(response_second)
    assert data_second.get("ok") is True
    assert data_second.get("duplicate") is True

    outbox_count = sql_scalar(
        db_conn,
        """
        SELECT COUNT(*)
        FROM public.bot_outbox
        WHERE workspace_id = %s
          AND chat_id = %s
          AND inbound_provider_message_id = %s
        """,
        (workspace_ctx["workspace_id"], chat_id, inbound_provider_message_id),
    )
    assert outbox_count == 1, "bot_outbox idempotency failed: duplicate input created additional row"

    stored_provider_message_id = sql_scalar(
        db_conn,
        """
        SELECT provider_message_id
        FROM public.bot_outbox
        WHERE workspace_id = %s
          AND chat_id = %s
          AND inbound_provider_message_id = %s
        """,
        (workspace_ctx["workspace_id"], chat_id, inbound_provider_message_id),
    )
    assert stored_provider_message_id == first_provider_message_id

    state_turns = sql_scalar(
        db_conn,
        """
        SELECT turns
        FROM public.bot_state
        WHERE workspace_id = %s
          AND chat_id = %s
        """,
        (workspace_ctx["workspace_id"], chat_id),
    )
    assert int(state_turns) >= 1, "bot_state was not persisted on first bot_engine pass"

    processed_log_count = sql_scalar(
        db_conn,
        """
        SELECT COUNT(*)
        FROM public.bot_logs
        WHERE workspace_id = %s
          AND chat_id = %s
          AND inbound_provider_message_id = %s
          AND action = 'bot_engine_processed'
        """,
        (workspace_ctx["workspace_id"], chat_id, inbound_provider_message_id),
    )
    assert processed_log_count == 1, "duplicate bot_engine call should not create second processed log row"


def test_workflow_13_bot_monitor_webhook_smoke(
    settings: TestSettings,
    http_session: requests.Session,
    webhook_base_headers: dict[str, str],
    workspace_ctx: dict[str, str],
) -> None:
    url = require_webhook(settings.wf13_bot_monitor_url, "WF13_BOT_MONITOR_WEBHOOK_URL")
    payload = {"workspace_id": workspace_ctx["workspace_id"], "test_run_id": uuid.uuid4().hex}
    response = post_webhook(
        session=http_session,
        url=url,
        payload=payload,
        timeout_sec=settings.request_timeout_sec,
        global_headers=webhook_base_headers,
    )
    _assert_webhook_ok(response, allow_conflict=True)


def test_workflow_13_bot_monitor_alert_logic(
    settings: TestSettings,
    db_conn: psycopg.Connection[Any],
    http_session: requests.Session,
    webhook_base_headers: dict[str, str],
    workspace_ctx: dict[str, str],
) -> None:
    url = require_webhook(settings.wf13_bot_monitor_url, "WF13_BOT_MONITOR_WEBHOOK_URL")
    chat_id = f"chat-{uuid.uuid4().hex[:10]}"

    with db_conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO public.bot_logs
              (workspace_id, chat_id, inbound_provider_message_id, matched_rule_id, matched_rule_version, action, result, meta, created_at)
            VALUES
              (%s, %s, %s, NULL, NULL, 'bot_engine_processed', 'ok'::public.event_result, '{}'::jsonb, now()),
              (%s, %s, %s, NULL, NULL, 'bot_engine_processed', 'error'::public.event_result, '{}'::jsonb, now()),
              (%s, %s, %s, 'rule-1', 1, 'bot_engine_processed', 'ok'::public.event_result, '{}'::jsonb, now()),
              (%s, %s, %s, 'rule-2', 1, 'bot_engine_processed', 'error'::public.event_result, '{}'::jsonb, now())
            """,
            (
                workspace_ctx["workspace_id"],
                chat_id,
                f"in-{uuid.uuid4().hex}",
                workspace_ctx["workspace_id"],
                chat_id,
                f"in-{uuid.uuid4().hex}",
                workspace_ctx["workspace_id"],
                chat_id,
                f"in-{uuid.uuid4().hex}",
                workspace_ctx["workspace_id"],
                chat_id,
                f"in-{uuid.uuid4().hex}",
            ),
        )

    response = post_webhook(
        session=http_session,
        url=url,
        payload={
            "workspace_id": workspace_ctx["workspace_id"],
            "test_run_id": uuid.uuid4().hex,
            "window_minutes": 60,
            "error_threshold": 1,
            "fallback_rate_threshold_pct": 49,
        },
        timeout_sec=settings.request_timeout_sec,
        global_headers=webhook_base_headers,
    )
    _assert_webhook_ok(response, allow_conflict=True)

    data = _response_json(response)
    assert data.get("ok") is True

    alerts = data.get("alerts")
    assert isinstance(alerts, dict), "expected alerts object from 13_bot_monitor"
    assert alerts.get("has_alerts") is True
    reasons = set(alerts.get("reasons") or [])
    assert "bot_error_spike" in reasons
    assert "fallback_rate_high" in reasons

    snapshot = data.get("snapshot")
    assert isinstance(snapshot, dict), "expected snapshot object from 13_bot_monitor"
    assert int(snapshot.get("total_logs", 0)) >= 4
    assert int(snapshot.get("error_logs", 0)) >= 2
    assert int(snapshot.get("fallback_logs", 0)) >= 2


def _response_json(response: requests.Response) -> dict[str, Any]:
    try:
        data = response.json()
    except Exception as exc:  # pragma: no cover - defensive diagnostics
        raise AssertionError(
            f"Expected JSON response; status={response.status_code}; body={response.text}"
        ) from exc
    assert isinstance(data, dict), f"Expected JSON object, got: {type(data)}"
    return data


def _assert_adapter_result_shape(data: dict[str, Any]) -> None:
    assert isinstance(data.get("ok"), bool), f"Expected boolean 'ok', got: {data.get('ok')!r}"
    if data["ok"] is True:
        assert isinstance(data.get("provider_message_id"), str) and data["provider_message_id"], (
            "Expected non-empty provider_message_id on success"
        )
        return

    err = data.get("error")
    assert isinstance(err, dict), f"Expected error object, got: {type(err)}"
    assert err.get("category") in {"TRANSIENT", "PERMANENT"}, f"Unexpected error.category={err.get('category')!r}"
    assert err.get("scope") in {"platform", "channel", "delivery"}, f"Unexpected error.scope={err.get('scope')!r}"
    assert isinstance(err.get("code"), str) and err["code"], "Expected non-empty error.code"
    assert isinstance(err.get("message"), str) and err["message"], "Expected non-empty error.message"


def test_subworkflow_adapter_telegram_missing_target_id(
    settings: TestSettings,
    http_session: requests.Session,
    webhook_base_headers: dict[str, str],
    workspace_ctx: dict[str, str],
) -> None:
    url = require_webhook(settings.wf_adapter_telegram_url, "WF_ADAPTER_TELEGRAM_WEBHOOK_URL")
    payload = {
        "workspace_id": workspace_ctx["workspace_id"],
        "delivery": {
            "delivery_id": str(uuid.uuid4()),
            "channel_id": "ch_tg",
            "rendered_text": "adapter telegram missing target",
            "payload": {"media": []},
            "meta": {"parse_mode": "None"},
        },
        "channel": {
            "platform": "telegram",
            "auth_ref": "autotest-auth",
        },
    }
    response = post_webhook(
        session=http_session,
        url=url,
        payload=payload,
        timeout_sec=settings.request_timeout_sec,
        global_headers=webhook_base_headers,
    )
    _assert_webhook_ok(response, allow_conflict=True)

    data = _response_json(response)
    _assert_adapter_result_shape(data)
    assert data["ok"] is False
    assert data["error"]["code"] == "missing_target_id"


def test_subworkflow_adapter_telegram_text_invalid_target_normalizes_error(
    settings: TestSettings,
    http_session: requests.Session,
    webhook_base_headers: dict[str, str],
    workspace_ctx: dict[str, str],
) -> None:
    url = require_webhook(settings.wf_adapter_telegram_url, "WF_ADAPTER_TELEGRAM_WEBHOOK_URL")
    payload = {
        "workspace_id": workspace_ctx["workspace_id"],
        "delivery": {
            "delivery_id": str(uuid.uuid4()),
            "channel_id": "ch_tg",
            "rendered_text": "adapter telegram text invalid target",
            "payload": {"media": []},
            "meta": {"parse_mode": "None"},
        },
        "channel": {
            "platform": "telegram",
            # Intentionally invalid; should exercise Telegram error normalization.
            "target_id": "autotest-chat",
            "auth_ref": "autotest-auth",
        },
    }
    response = post_webhook(
        session=http_session,
        url=url,
        payload=payload,
        timeout_sec=settings.request_timeout_sec,
        global_headers=webhook_base_headers,
    )
    _assert_webhook_ok(response, allow_conflict=True)

    data = _response_json(response)
    _assert_adapter_result_shape(data)
    assert data["ok"] is False


def test_subworkflow_adapter_telegram_photo_no_blob_ref_invalid_target(
    settings: TestSettings,
    http_session: requests.Session,
    webhook_base_headers: dict[str, str],
    workspace_ctx: dict[str, str],
) -> None:
    url = require_webhook(settings.wf_adapter_telegram_url, "WF_ADAPTER_TELEGRAM_WEBHOOK_URL")
    photo_url = settings.adapter_tg_photo_url or "https://httpbin.org/image/png"
    payload = {
        "workspace_id": workspace_ctx["workspace_id"],
        "delivery": {
            "delivery_id": str(uuid.uuid4()),
            "channel_id": "ch_tg",
            "rendered_text": "adapter telegram photo no blob_ref invalid target",
            "payload": {
                "media": [
                    {
                        "type": "photo",
                        "origin_url": photo_url,
                    }
                ]
            },
            "meta": {"parse_mode": "None"},
        },
        "channel": {
            "platform": "telegram",
            "target_id": "autotest-chat",
            "auth_ref": "autotest-auth",
        },
    }
    response = post_webhook(
        session=http_session,
        url=url,
        payload=payload,
        timeout_sec=settings.request_timeout_sec,
        global_headers=webhook_base_headers,
    )
    _assert_webhook_ok(response, allow_conflict=True)

    data = _response_json(response)
    _assert_adapter_result_shape(data)
    assert data["ok"] is False


def test_subworkflow_adapter_telegram_photo_with_blob_ref_invalid_target(
    settings: TestSettings,
    http_session: requests.Session,
    webhook_base_headers: dict[str, str],
    workspace_ctx: dict[str, str],
) -> None:
    url = require_webhook(settings.wf_adapter_telegram_url, "WF_ADAPTER_TELEGRAM_WEBHOOK_URL")
    photo_url = settings.adapter_tg_photo_url or "https://httpbin.org/image/png"
    payload = {
        "workspace_id": workspace_ctx["workspace_id"],
        "delivery": {
            "delivery_id": str(uuid.uuid4()),
            "channel_id": "ch_tg",
            "rendered_text": "adapter telegram photo blob_ref invalid target",
            "payload": {
                "media": [
                    {
                        "type": "photo",
                        "blob_ref": f"pytest-blob-{uuid.uuid4().hex}",
                        "origin_url": photo_url,
                    }
                ]
            },
            "meta": {"parse_mode": "None"},
        },
        "channel": {
            "platform": "telegram",
            "target_id": "autotest-chat",
            "auth_ref": "autotest-auth",
        },
    }
    response = post_webhook(
        session=http_session,
        url=url,
        payload=payload,
        timeout_sec=settings.request_timeout_sec,
        global_headers=webhook_base_headers,
    )
    _assert_webhook_ok(response, allow_conflict=True)

    data = _response_json(response)
    _assert_adapter_result_shape(data)
    assert data["ok"] is False


def test_subworkflow_adapter_telegram_video_invalid_target_normalizes_error(
    settings: TestSettings,
    http_session: requests.Session,
    webhook_base_headers: dict[str, str],
    workspace_ctx: dict[str, str],
) -> None:
    url = require_webhook(settings.wf_adapter_telegram_url, "WF_ADAPTER_TELEGRAM_WEBHOOK_URL")
    video_url = settings.adapter_tg_video_url or (settings.adapter_tg_photo_url or "https://httpbin.org/image/png")
    payload = {
        "workspace_id": workspace_ctx["workspace_id"],
        "delivery": {
            "delivery_id": str(uuid.uuid4()),
            "channel_id": "ch_tg",
            "rendered_text": "adapter telegram video invalid target",
            "payload": {
                "media": [
                    {
                        "type": "video",
                        "blob_ref": f"pytest-blob-{uuid.uuid4().hex}",
                        "origin_url": video_url,
                    }
                ]
            },
            "meta": {"parse_mode": "None"},
        },
        "channel": {
            "platform": "telegram",
            "target_id": "autotest-chat",
            "auth_ref": "autotest-auth",
        },
    }
    response = post_webhook(
        session=http_session,
        url=url,
        payload=payload,
        timeout_sec=settings.request_timeout_sec,
        global_headers=webhook_base_headers,
    )
    _assert_webhook_ok(response, allow_conflict=True)

    data = _response_json(response)
    _assert_adapter_result_shape(data)
    assert data["ok"] is False


def test_subworkflow_adapter_telegram_cache_upsert_on_success(
    settings: TestSettings,
    db_conn: psycopg.Connection[Any],
    http_session: requests.Session,
    webhook_base_headers: dict[str, str],
    workspace_ctx: dict[str, str],
) -> None:
    url = require_webhook(settings.wf_adapter_telegram_url, "WF_ADAPTER_TELEGRAM_WEBHOOK_URL")
    if not settings.adapter_tg_target_id:
        pytest.skip("ADAPTER_TG_TARGET_ID is not set (required for telegram adapter success + cache upsert test)")

    photo_url = settings.adapter_tg_photo_url or "https://httpbin.org/image/png"
    blob_ref = f"pytest-blob-{uuid.uuid4().hex}"

    with db_conn.cursor() as cur:
        cur.execute(
            """
            DELETE FROM public.media_blobs
            WHERE workspace_id = %s
              AND blob_ref = %s
              AND provider = 'telegram'
            """,
            (workspace_ctx["workspace_id"], blob_ref),
        )
        cur.execute(
            """
            INSERT INTO public.media_origin (workspace_id, blob_ref, origin_url, last_seen_at, ref_count)
            VALUES (%s, %s, %s, now(), 0)
            ON CONFLICT (workspace_id, blob_ref) DO UPDATE
            SET origin_url = EXCLUDED.origin_url,
                last_seen_at = now()
            """,
            (workspace_ctx["workspace_id"], blob_ref, photo_url),
        )

    payload = {
        "workspace_id": workspace_ctx["workspace_id"],
        "delivery": {
            "delivery_id": str(uuid.uuid4()),
            "channel_id": "ch_tg",
            "rendered_text": "adapter telegram cache upsert success",
            "payload": {
                "media": [
                    {
                        "type": "photo",
                        "blob_ref": blob_ref,
                        "origin_url": photo_url,
                    }
                ]
            },
            "meta": {"parse_mode": "None"},
        },
        "channel": {
            "platform": "telegram",
            "target_id": settings.adapter_tg_target_id,
            "auth_ref": "autotest-auth",
            "simulate": True,
        },
    }

    response = post_webhook(
        session=http_session,
        url=url,
        payload=payload,
        timeout_sec=settings.request_timeout_sec,
        global_headers=webhook_base_headers,
    )
    _assert_webhook_ok(response, allow_conflict=True)

    data = _response_json(response)
    _assert_adapter_result_shape(data)
    assert data["ok"] is True, f"Expected ok=true; got: {data}"

    file_id = sql_scalar(
        db_conn,
        """
        SELECT mb.file_id
        FROM public.media_blobs mb
        WHERE mb.workspace_id = %s
          AND mb.blob_ref = %s
          AND mb.provider = 'telegram'
        """,
        (workspace_ctx["workspace_id"], blob_ref),
    )
    assert isinstance(file_id, str) and file_id, "expected telegram file_id cached into media_blobs"


def test_subworkflow_adapter_max_missing_target_rejected_without_simulate(
    settings: TestSettings,
    http_session: requests.Session,
    webhook_base_headers: dict[str, str],
    workspace_ctx: dict[str, str],
) -> None:
    url = require_webhook(settings.wf_adapter_max_url, "WF_ADAPTER_MAX_WEBHOOK_URL")
    payload = {
        "workspace_id": workspace_ctx["workspace_id"],
        "delivery": {
            "delivery_id": str(uuid.uuid4()),
            "channel_id": "ch_max",
            "rendered_text": "adapter max simulate success",
            "payload": {"media": []},
            "meta": {"parse_mode": "None"},
        },
        "channel": {
            "platform": "max",
            "auth_ref": "autotest-auth",
            "simulate": False,
        },
    }
    response = post_webhook(
        session=http_session,
        url=url,
        payload=payload,
        timeout_sec=settings.request_timeout_sec,
        global_headers=webhook_base_headers,
    )
    _assert_webhook_ok(response, allow_conflict=True)

    data = _response_json(response)
    _assert_adapter_result_shape(data)
    assert data["ok"] is False
    assert data["error"]["code"] == "missing_adapter_inputs"


def test_subworkflow_adapter_max_long_text_rejected_before_network(
    settings: TestSettings,
    http_session: requests.Session,
    webhook_base_headers: dict[str, str],
    workspace_ctx: dict[str, str],
) -> None:
    url = require_webhook(settings.wf_adapter_max_url, "WF_ADAPTER_MAX_WEBHOOK_URL")
    payload = {
        "workspace_id": workspace_ctx["workspace_id"],
        "delivery": {
            "delivery_id": str(uuid.uuid4()),
            "channel_id": "ch_max",
            "rendered_text": "x" * 5001,
            "payload": {"media": []},
            "meta": {"parse_mode": "None"},
        },
        "channel": {
            "platform": "max",
            "target_id": "autotest-chat",
            # Satisfy "Can Call MAX API?" without relying on n8n env vars.
            "auth_token": "pytest-dummy-token",
        },
    }
    response = post_webhook(
        session=http_session,
        url=url,
        payload=payload,
        timeout_sec=settings.request_timeout_sec,
        global_headers=webhook_base_headers,
    )
    _assert_webhook_ok(response, allow_conflict=True)

    data = _response_json(response)
    _assert_adapter_result_shape(data)
    assert data["ok"] is False
    assert data["error"]["code"] == "message_too_long"


def test_subworkflow_adapter_max_media_missing_origin_rejected(
    settings: TestSettings,
    http_session: requests.Session,
    webhook_base_headers: dict[str, str],
    workspace_ctx: dict[str, str],
) -> None:
    url = require_webhook(settings.wf_adapter_max_url, "WF_ADAPTER_MAX_WEBHOOK_URL")
    payload = {
        "workspace_id": workspace_ctx["workspace_id"],
        "delivery": {
            "delivery_id": str(uuid.uuid4()),
            "channel_id": "ch_max",
            "rendered_text": "adapter max media missing origin",
            "payload": {"media": [{}]},
            "meta": {"parse_mode": "None"},
        },
        "channel": {
            "platform": "max",
            "target_id": "autotest-chat",
            "auth_token": "pytest-dummy-token",
        },
    }
    response = post_webhook(
        session=http_session,
        url=url,
        payload=payload,
        timeout_sec=settings.request_timeout_sec,
        global_headers=webhook_base_headers,
    )
    _assert_webhook_ok(response, allow_conflict=True)

    data = _response_json(response)
    _assert_adapter_result_shape(data)
    assert data["ok"] is False
    assert data["error"]["code"] == "media_missing_origin"
