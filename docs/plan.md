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
- Для dispatcher обязательно DB advisory lock (workflow concurrency=1 только как дополнительная защита).
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
- ~~Перед claim ставить advisory lock для run scope.~~
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

## Этап 4. Workflow `03_monitor`
- Реализовать cron monitor + test webhook ветку.
- Lease recovery через `recover_sending_leases(...)`.
- SQL-проверки алертов:
  - `dead > threshold`
  - `failed_permanent` за окно
  - количество paused channels
- Канал уведомлений (Telegram/admin endpoint), health snapshot в компактном формате.

Критерий готовности:
- Тест `test_workflow_03_monitor_webhook` проходит.

## Этап 5. Bot workflows (P1)
- `11_bot_ingest`: endpoint resolve + inbound dedup в `bot_inbox`.
- `12_bot_engine`: rules/state/outbox idempotency + отправка через `adapter_max_send`.
- `13_bot_monitor`: алерты по ошибкам и fallback rate.

Критерий готовности:
- Тесты `test_workflow_11_bot_ingest_webhook` и smoke тесты `12/13` проходят.

## Этап 6. E2E, стабилизация и запуск
- Прогон полного набора `pytest -q` в `tests/workflows`.
- Проверка наблюдаемости:
  - события в `events`
  - корректные статусы `deliveries`
  - отсутствие stuck `sending/claimed` после monitor.
- Экспорт всех workflow JSON и фиксация в git.
- Freeze изменений и подготовка short runbook:
  - как деплоить
  - как запускать тесты
  - как делать rollback/export.

Критерий готовности:
- Все обязательные тесты зелёные, workflow экспортированы, runbook оформлен.

## 5. Последовательность выполнения
1. ~~Этап 0~~
2. ~~Этап 1~~
3. ~~Этап 2~~
4. ~~Этап 3~~
5. Этап 4
6. Этап 6
7. Этап 5 (можно параллелить после стабилизации P0)

## 6. Артефакты, которые должны остаться в репозитории
- `docs/plan.md` (этот документ)
- `n8n/workflows/*.json` (экспорт workflow)
- `n8n/env/.env.example`
- `n8n/docs/runbook.md`

## 7. Definition of Done (общий)
- Реализованы P0 workflow в n8n согласно контрактам из `docs/workflows.md`.
- SQL boundary используется как единственный источник бизнес-гарантий.
- Автотесты `tests/workflows` для P0 проходят.
- Все workflow и конфигурация воспроизводимы из репозитория.
