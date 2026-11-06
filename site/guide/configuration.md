---
title: Configuration
description: Every environment variable the server reads, the switches that control trading, and the settings in jac.toml.
related:
  - { text: Quickstart, link: /guide/quickstart }
  - { text: The forward test, link: /guide/forward-test }
  - { text: Data sources, link: /system/data-sources }
---

The server is configured by environment variables and by `jac.toml`.
Keys and passwords come only from the environment, never from a file in the repo.

::: warning Secrets stay out of the repo
Never commit keys, tokens, or account IDs.
Copy `.env.example` to `.env`, fill it in, and export it with `set -a && source .env && set +a`.
Share keys through a password manager, not in chat.
:::

## Keys

A collector that needs a key and does not find it raises a `MissingKey` error that names the variable.
The run records the error and carries on with the data it has.

| Variable | Used by | Notes |
| --- | --- | --- |
| `ALPACA_API_KEY` | Market data, the broker | The paper account's key ID. |
| `ALPACA_SECRET_KEY` | Market data, the broker | The paper account's secret. |
| `FINNHUB_API_KEY` | Earnings calendar, company news | Free plan. |
| `SEC_USER_AGENT` | SEC EDGAR | No key, but SEC fair access requires a User-Agent with a contact email. A value without `@`, or the template's `example.com` placeholder, is refused. |
| `OPENROUTER_API_KEY` | Every model call | Free models only. |
| `ADMIN_PASSWORD` | The admin account | Read once, when the admin user is created. Defaults to `changeme`, so always set it on a shared server. |

## Trading switches

These decide whether the server trades.
Leave them unset unless you mean to change that.

| Variable | Effect |
| --- | --- |
| `TRADING_AGENT_FORWARD_TEST_START` | A trading date, `YYYY-MM-DD`. On that date, the first trading tick before the day's run executes starts the [forward test](/guide/forward-test) and switches the team portfolio to auto mode. Set it only with the team's go-ahead. |
| `TRADING_AGENT_DISABLE_ORDERS` | `1` stops every order. The executor still sizes and gates each decision and records the checks, but sends nothing and places no stop. |
| `TRADING_AGENT_DISABLE_MODELS` | `1`, `true`, or `yes` stops every model request. Each call raises `ModelsDisabledError`, so the Run Guard falls back to HOLD for every ticker. |
| `POLICY_CHAT_PER_USER_DAY` | Messages each user may send the [policy assistant](/guide/policies) in a UTC day. Defaults to 20. |
| `TRADING_AGENT_DEMO` | `1` fills an empty team portfolio with simulated history. See [Demo data](/guide/demo-data). Never set it on a deployed server. |

## Base URLs

Each data source reads its base URL from an environment variable, so tests can point it at a local fake server.
In normal use, leave them unset.

| Variable | Default |
| --- | --- |
| `ALPACA_DATA_URL` | `https://data.alpaca.markets` |
| `ALPACA_BASE_URL` | `https://paper-api.alpaca.markets` |
| `SEC_DATA_URL` | `https://data.sec.gov` |
| `SEC_ARCHIVES_URL` | `https://www.sec.gov` |
| `FINNHUB_BASE_URL` | `https://finnhub.io/api/v1` |
| `WIKIPEDIA_BASE_URL` | `https://en.wikipedia.org` |
| `OPENROUTER_API_BASE` | `https://openrouter.ai/api/v1` |

::: info The broker refuses anything but paper
Even with a changed `ALPACA_BASE_URL`, the broker client refuses to send an order unless the host is `paper-api.alpaca.markets` (or a local test server) and the account number starts with `PA`.
See [Execution](/system/execution).
:::

## Development and testing

| Variable | Effect |
| --- | --- |
| `COLLECTOR_RECORD_DIR` | Saves each live response as a fixture under this directory. See [Checks and tests](/guide/testing#recording-fixtures). |
| `E2E_BASE_URL` | The server the Playwright tests visit. Defaults to `http://localhost:8000`. |
| `TRADING_AGENT_RUN_SPIKE`, `TRADING_AGENT_RUN_ORDER_SPIKE` | Opt in to the spike scripts under `tests/spikes/`, which call real services. |
| `TRADING_AGENT_RUN_EXIT`, `TRADING_AGENT_RUN_ANALYSIS_EXIT`, `TRADING_AGENT_RUN_ACTION_EXIT` | Opt in to the exit-run scripts under `tests/runs/`, which wrote the [exit run reports](/design/run-research). |

## jac.toml

The project file pins the compiler and sets the server's defaults.

| Setting | Value | Why |
| --- | --- | --- |
| `[project] jac-version` | `==0.37.12` | The compiler the code and its guides were written against. |
| `[byllm.model] default_model` | `openrouter/nvidia/nemotron-3-super-120b-a12b:free` | The primary free model, chosen by the [free-models spike](/design/spike-free-models). Each role overrides its own temperature. |
| `[byllm.call_params]` | `temperature = 0.2`, `max_output_retries = 1` | Low temperature for research and review; the specialists use 0.8. |
| `[scale.scheduler] enabled` | `true` | Runs the [scheduled jobs](/system/trading-day#scheduled-jobs) inside the server process. Run `jac install` after changing it. |
| `[scale.admin] default_password` | `${ADMIN_PASSWORD:-changeme}` | The admin account's password at creation. |
| `[test] directory` | `.` | `jac test` runs every test in the project, colocated or under `tests/`. |
| `[check.lint] select` | `["all"]` | Every lint rule is on. |
