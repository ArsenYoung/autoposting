# План реализации workflows в n8n

## 1. Цель и рамки
- Реализовать в n8n production-ready контур из `docs/workflows.md` и `docs/arch.md`.
- База данных и SQL boundary уже настроены, поэтому фокус только на оркестрации и интеграциях в n8n.
- Работать от тестов в `tests/workflows` как от минимального контракта приемки.

## 2. Объем (что внедряем)
- Обязательный контур (P0):
  - ~~`01_ingest` (push + pull)~~
  - ~~`02_dispatcher`~~
  - `03_monitor`
  - ~~`adapter_telegram_send`~~
  - ~~`adapter_max_send`~~
- Дополнительный контур (P1):
  - `11_bot_ingest`
  - `12_bot_engine`
  - `13_bot_monitor`

## 3. Нефункциональные правила (фиксируем до старта)
- Не дублировать SQL-логику в n8n: dedup, claim, retry/backoff, lease recovery только через DB-функции.
- Для cron workflow добавить test-webhook входы, ведущие в тот же execution path.
- Для dispatcher обязательно DB lease lock в данных (`workflow_locks` + TTL + owner); advisory lock в n8n не использовать.
- Никаких `Wait`-узлов для retry/schedule.
- Хранить и версионировать экспорт workflow JSON в репозитории.

## 4. Этапы работ

## Этап 0. Подготовка n8n-проекта
- ~~Создать структуру в репозитории для артефактов n8n:~~
  - ~~`n8n/workflows/`~~
  - ~~`n8n/env/.env.example`~~
  - ~~`n8n/docs/` (короткие runbook-инструкции)~~
- ~~Согласовать naming:~~
  - ~~`01_ingest`, `02_dispatcher`, `03_monitor`~~
  - ~~`11_bot_ingest`, `12_bot_engine`, `13_bot_monitor`~~
  - ~~`adapter_telegram_send`, `adapter_max_send`~~
- ~~Зафиксировать переменные окружения для webhook/auth и runtime-порогов (из `docs/workflows.md`).~~

~~Критерий готовности:~~
- ~~Есть шаблон структуры и список env-переменных для всех workflow.~~

Статус на 2026-02-13:
- Выполнено.
- Добавлены:
  - `n8n/workflows/README.md`
  - `n8n/env/.env.example`
  - `n8n/docs/runbook.md`

## Этап 1. Адаптеры отправки (сначала sub-workflows)
- ~~Реализовать `adapter_telegram_send`:~~
  - ~~normalized input/output контракт~~
  - ~~media materialization cache через `media_blobs`~~
  - ~~нормализация ошибок (`TRANSIENT|PERMANENT`, `scope`, `code`, `retry_after_ms`)~~
- ~~Реализовать `adapter_max_send`:~~
  - ~~upload flow (`/uploads` -> upload -> `/messages`)~~
  - ~~parse mode mapping (`HTML|Markdown|None`)~~
  - ~~поддержка media series с `series_progress_delta`~~
  - ~~нормализация ошибок и обработка `attachment.not.ready` как transient~~
- ~~Добавить webhook smoke входы для обоих адаптеров (для `WF_ADAPTER_*_WEBHOOK_URL`).~~

~~Критерий готовности:~~
- ~~Smoke тесты адаптеров из `tests/workflows/test_workflows_webhooks.py` проходят.~~

## ~~Этап 2. Workflow `01_ingest` (push + pull)~~
- ~~Push path:~~
  - ~~webhook trigger + secret resolution через `workspace_endpoints`~~
  - ~~ingress guard (размер, rate, dedup через receipts)~~
  - ~~enqueue через `enqueue_messages_and_deliveries(...)`~~
  - ~~finalize `ingest_runs`~~
- ~~Pull path:~~
  - ~~cron + test webhook для тестового `items[]`~~
  - ~~pull chunk processing через `ingest_pull_chunk(...)`~~
  - ~~корректное обновление `pull_cursors` только после успешного commit~~
  - ~~finalize `ingest_runs`~~
- ~~Проверить единый deterministic normalization contract для push/pull.~~

~~Критерий готовности:~~
- ~~Тесты `test_workflow_01_ingest_push_webhook` и `test_workflow_01_ingest_pull_webhook` проходят.~~

Статус на 2026-02-16:
- Выполнено.
- Пройдены `make wf01-push` и `make wf01-pull`.
- Закрыты риски: dedup bypass по `source_ref`, пустой secret hash fallback.

## ~~Этап 3. Workflow `02_dispatcher`~~
- ~~Реализовать cron dispatcher + test webhook ветку.~~
- ~~Перед claim ставить DB lease lock для run scope (`workflow_locks`).~~
- ~~По workspace:~~
  - ~~claim через `claim_deliveries(...)`~~
  - ~~отправка через нужный адаптер по `platform`~~
  - ~~commit через `mark_sent(...)` / `schedule_retry(...)` / `fail_permanent(...)` с `claim_token`~~
- ~~Убедиться, что `attempt` не изменяется вне `claim_deliveries`.~~

~~Критерий готовности:~~
- ~~Тест `test_workflow_02_dispatcher_webhook` проходит.~~

Статус на 2026-02-16:
- Выполнено.
- Пройден `make wf02-dispatcher`.
- Workflow задеплоен в n8n как `02_dispatcher` (active).

Статус на 2026-02-17:
- Критичный риск advisory lock закрыт.
- `public.dispatcher_tick` переведен на lease lock через `public.workflow_locks` (миграция `db/migrations/20260217_dispatcher_lease_lock.sql`).
- Связка lock/unlock больше не зависит от session-level поведения Postgres node в n8n.

## Этап 4. Workflow `03_monitor`
- ~~Реализовать cron monitor + test webhook ветку.~~
- ~~Lease recovery через `recover_sending_leases(...)`.~~
- ~~SQL-проверки алертов:~~
  - ~~`dead > threshold`~~
  - ~~`failed_permanent` за окно~~
  - ~~количество paused channels~~
- ~~Канал уведомлений (Telegram/admin endpoint), health snapshot в компактном формате.~~

Статус на 2026-02-17:
- Выполнено.
- Добавлены: ветка `IF alerts.has_alerts = true`, HTTP уведомление в admin webhook, DB dedup/cooldown через `monitor_alert_receipts`.
- Добавлены тестовые сценарии: `no alerts`, `alerts sent + cooldown`, `delivery failed`.

Критерий готовности:
- Тест `test_workflow_03_monitor_webhook` проходит.

## Этап 5. Bot workflows (P1)
- ~~`11_bot_ingest`: endpoint resolve + inbound dedup в `bot_inbox`.~~
- ~~`12_bot_engine`: rules/state/outbox idempotency + отправка через `adapter_max_send`.~~
- ~~`13_bot_monitor`: алерты по ошибкам и fallback rate.~~

Статус на 2026-02-17:
- Выполнено.
- Workflow задеплоены и активированы в n8n:
  - `11_bot_ingest` (`wfPSzX6YlQFfyPXj`)
  - `12_bot_engine` (`x6SbMsgRue9eQP39`)
  - `13_bot_monitor` (`2gAJWYZjbvlXdFUW`)
- Пройдены тесты:
  - `make wf11-bot-ingest`
  - `make wf12-bot-engine`
  - `make wf13-bot-monitor`
- Усилены тесты P1 (не только smoke):
  - `test_workflow_12_bot_engine_state_outbox_idempotent`
  - `test_workflow_13_bot_monitor_alert_logic`

Критерий готовности:
- Тесты `test_workflow_11_bot_ingest_webhook` и smoke тесты `12/13` проходят.

## Этап 6. E2E, стабилизация и запуск
- ~~Прогон полного набора `pytest -q` в `tests/workflows`.~~
- ~~Проверка наблюдаемости:~~
  - события в `events`
  - корректные статусы `deliveries`
  - отсутствие stuck `sending/claimed` после monitor.
- ~~Экспорт всех workflow JSON и фиксация в git.~~
- ~~Freeze изменений и подготовка short runbook:~~
  - как деплоить
  - как запускать тесты
  - как делать rollback/export.

Статус на 2026-02-17:
- Выполнено.
- Полный прогон `make wf-tests` (без фильтра):
  - `21 passed` (без skip, `ADAPTER_TG_TARGET_ID` задан).
- Runtime-fix `executeWorkflow`:
  - sub-workflow вызовы в `02_dispatcher`, `11_bot_ingest`, `12_bot_engine` переведены на `workflowId` resource locator (`__rl`, `mode=id`, `value=<workflow_id>`), fallback-ошибка `No information about the workflow to execute` устранена.
- Инварианты БД:
  - `stuck_sending = 0`, `stuck_claimed = 0`;
  - `sent_without_sent_at = 0`, `retry_without_next_retry_at = 0`, `queued_retry_with_claim_token = 0`, `sending_without_claim_token = 0`;
  - `events_last_60m = 0` после тестового teardown (ожидаемо), при этом в самих monitor-сценариях запись событий проверяется и тесты проходят.
- Экспортированы актуальные JSON:
  - `01_ingest`, `02_dispatcher`, `03_monitor`, `adapter_telegram_send`, `adapter_max_send`, `11_bot_ingest`, `12_bot_engine`, `13_bot_monitor`
  - в `n8n/workflows/` и зеркально в `workflows/`.
- CI gate включен:
  - `.github/workflows/wf-tests.yml` запускает `make wf-tests` на `pull_request` и `push` (`main/master`).
- Pre-prod rollback rehearsal выполнен:
  - на `12_bot_engine` введена контролируемая деградация (`workflowId=NON_EXISTENT_WORKFLOW_ID`) -> строгий P1 тест падает;
  - rollback на рабочий `workflowId` выполнен -> строгий P1 тест и полный suite снова зелёные.
- Runbook обновлен до deploy/test/rollback процедуры и включает сценарий pre-prod rehearsal.

Критерий готовности:
- Все обязательные тесты зелёные, workflow экспортированы, runbook оформлен.

## 5. Последовательность выполнения
1. ~~Этап 0~~
2. ~~Этап 1~~
3. ~~Этап 2~~
4. ~~Этап 3~~
5. ~~Этап 4~~
6. ~~Этап 6~~
7. ~~Этап 5~~

## 6. Артефакты, которые должны остаться в репозитории
- `docs/plan.md` (этот документ)
- `n8n/workflows/*.json` (экспорт workflow)
- `n8n/env/.env.example`
- `n8n/docs/runbook.md`

## 7. Definition of Done (общий)
- Реализованы P0 workflow в n8n согласно контрактам из `docs/workflows.md`.
- SQL boundary используется как единственный источник бизнес-гарантий.
- Автотесты `tests/workflows` для P0 проходят.
- Для `03_monitor` алерты не только рассчитываются, но и отправляются во внешний канал уведомлений.
- Реализованы P1 bot workflow (`11/12/13`), smoke-тесты проходят.
- Все workflow и конфигурация воспроизводимы из репозитория.
