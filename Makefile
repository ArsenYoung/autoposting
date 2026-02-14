SHELL := /bin/bash

.DEFAULT_GOAL := help

# Absolute paths so targets work regardless of where `make` is invoked from.
ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

WF_TEST_DIR := $(ROOT)/tests/workflows
WF_VENV := $(WF_TEST_DIR)/.venv
WF_PY := $(WF_VENV)/bin/python
WF_REQ := $(WF_TEST_DIR)/requirements.txt
WF_STAMP := $(WF_VENV)/.installed

PYTEST_ARGS ?= -q

.PHONY: help
help:
	@echo "Targets:"
	@echo "  make wf-tests            Run all n8n workflow webhook tests ($(WF_TEST_DIR))"
	@echo "  make wf-stage1           Run all adapter (stage 1) tests"
	@echo "  make wf01-push           Run 01_ingest push webhook test only"
	@echo "  make wf01-pull           Run 01_ingest pull webhook test only"
	@echo "  make wf02-dispatcher     Run 02_dispatcher webhook test only"
	@echo "  make wf03-monitor        Run 03_monitor webhook test only"
	@echo "  make wf11-bot-ingest     Run 11_bot_ingest webhook test only"
	@echo "  make wf12-bot-engine     Run 12_bot_engine smoke test only"
	@echo "  make wf13-bot-monitor    Run 13_bot_monitor smoke test only"
	@echo "  make wf-adapter-telegram Run adapter_telegram_send tests only"
	@echo "  make wf-adapter-max      Run adapter_max_send tests only"
	@echo "  make wf-test K='expr'    Run tests matching pytest -k expression"
	@echo
	@echo "Notes:"
	@echo "  - Tests read settings from $(WF_TEST_DIR)/.env (loaded automatically)."
	@echo "  - First run may create a venv at $(WF_VENV) and install $(WF_REQ)."

$(WF_STAMP): $(WF_REQ)
	@if [ ! -x "$(WF_PY)" ]; then \
		echo "Creating venv: $(WF_VENV)"; \
		python3 -m venv "$(WF_VENV)"; \
	fi
	@"$(WF_PY)" -m pip install -r "$(WF_REQ)"
	@touch "$(WF_STAMP)"

.PHONY: wf-venv
wf-venv: $(WF_STAMP)
	@echo "OK: $(WF_PY)"

.PHONY: wf-tests
wf-tests: $(WF_STAMP)
	cd "$(WF_TEST_DIR)" && "$(WF_PY)" -m pytest $(PYTEST_ARGS)

.PHONY: wf-test
wf-test: $(WF_STAMP)
	@if [ -z "$(K)" ]; then \
		echo "Usage: make wf-test K='...'" >&2; \
		exit 2; \
	fi
	cd "$(WF_TEST_DIR)" && "$(WF_PY)" -m pytest $(PYTEST_ARGS) -k "$(K)"

.PHONY: wf-stage1
wf-stage1: $(WF_STAMP)
	cd "$(WF_TEST_DIR)" && "$(WF_PY)" -m pytest $(PYTEST_ARGS) -k "subworkflow_adapter_"

.PHONY: wf01-push
wf01-push: $(WF_STAMP)
	cd "$(WF_TEST_DIR)" && "$(WF_PY)" -m pytest $(PYTEST_ARGS) \
		test_workflows_webhooks.py::test_workflow_01_ingest_push_webhook

.PHONY: wf01-pull
wf01-pull: $(WF_STAMP)
	cd "$(WF_TEST_DIR)" && "$(WF_PY)" -m pytest $(PYTEST_ARGS) \
		test_workflows_webhooks.py::test_workflow_01_ingest_pull_webhook

.PHONY: wf02-dispatcher
wf02-dispatcher: $(WF_STAMP)
	cd "$(WF_TEST_DIR)" && "$(WF_PY)" -m pytest $(PYTEST_ARGS) \
		test_workflows_webhooks.py::test_workflow_02_dispatcher_webhook

.PHONY: wf03-monitor
wf03-monitor: $(WF_STAMP)
	cd "$(WF_TEST_DIR)" && "$(WF_PY)" -m pytest $(PYTEST_ARGS) \
		test_workflows_webhooks.py::test_workflow_03_monitor_webhook

.PHONY: wf11-bot-ingest
wf11-bot-ingest: $(WF_STAMP)
	cd "$(WF_TEST_DIR)" && "$(WF_PY)" -m pytest $(PYTEST_ARGS) \
		test_workflows_webhooks.py::test_workflow_11_bot_ingest_webhook

.PHONY: wf12-bot-engine
wf12-bot-engine: $(WF_STAMP)
	cd "$(WF_TEST_DIR)" && "$(WF_PY)" -m pytest $(PYTEST_ARGS) \
		test_workflows_webhooks.py::test_workflow_12_bot_engine_webhook_smoke

.PHONY: wf13-bot-monitor
wf13-bot-monitor: $(WF_STAMP)
	cd "$(WF_TEST_DIR)" && "$(WF_PY)" -m pytest $(PYTEST_ARGS) \
		test_workflows_webhooks.py::test_workflow_13_bot_monitor_webhook_smoke

.PHONY: wf-adapter-telegram
wf-adapter-telegram: $(WF_STAMP)
	cd "$(WF_TEST_DIR)" && "$(WF_PY)" -m pytest $(PYTEST_ARGS) -k "subworkflow_adapter_telegram_"

.PHONY: wf-adapter-max
wf-adapter-max: $(WF_STAMP)
	cd "$(WF_TEST_DIR)" && "$(WF_PY)" -m pytest $(PYTEST_ARGS) -k "subworkflow_adapter_max_"
