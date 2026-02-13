# n8n workflow exports

Store exported workflow JSON files in this folder.

Recommended file names:
- `01_ingest.json`
- `02_dispatcher.json`
- `03_monitor.json`
- `11_bot_ingest.json`
- `12_bot_engine.json`
- `13_bot_monitor.json`
- `adapter_telegram_send.json`
- `adapter_max_send.json`

Rules:
- Export after each meaningful change in n8n UI.
- Keep filenames stable; do not add timestamps.
- Commit only JSON exports that match active workflow logic.
