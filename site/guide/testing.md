---
title: Checks and tests
description: Type-check, test, and build the project, run the browser checks on every device, and record fixtures, the same way CI does.
related:
  - { text: Contributing, link: /guide/contributing }
  - { text: Repository layout, link: /guide/repository-layout }
---

Every pull request runs the same checks as your machine: type-check, test, build, boot the bundle, and load the dashboard in real browsers.
Tests never call a real model, broker, or data provider, so they are free and deterministic.

## The three commands

```bash
jac check .   # type-check and lint the whole project
jac test      # every test, colocated and in tests/
jac build     # the production bundle, dist/trading-agent.jab
```

Run `jac check .`, not `jac check main.jac`: checking one file does not check the modules it imports.

::: info Known false positives
`jac check .` prints "may be undefined" warnings for JSX tags and "never used" warnings for component state setters.
These come from checking client modules in isolation in Jac 0.37.12; a fresh `jac create` scaffold prints the same warnings.
:::

## How the tests are organized

Unit tests sit beside the module they test, as `module_tests.jac`.
Integration tests that need a real server are in `tests/`.

| Folder | Test files | What they cover |
| --- | --- | --- |
| `research/` | 13 | Collectors against recorded fixtures, the screener, indicators, briefs, rate limits |
| `action/` | 7 | Sizing, the risk gate (with property tests), the executor, reconciliation, baselines, insight cards |
| `run/` | 8 | The Run Guard, the Orchestrator loop, the trading day, scheduled jobs, the manual run |
| `tests/` | 10 | Endpoints served, private visibility, the dashboard endpoints through a real server |
| `agents/` | 6 | Model roles, research agents, specialists, the Arbiter |
| `dashboard/` | 5 | View building, the news feed, the read cache, demo history, number and time formatting |
| `analysis/` | 3 | The consensus engine and vote scoring |
| `models/` | 2 | The graph and the agents' output types |
| `policy/` | 4 | The assistant's edits, the figures rules read, replay, and saved versions |
| `accounts/` | 1 | Sealing a user's keys |
| `reports/` | 1 | How many requests a report may spend |

In all, 60 test files hold 482 tests.

### Property tests

The risk gate is checked with [Hypothesis](https://hypothesis.readthedocs.io/): 3,000 random books and proposals, and no approved order may ever break a cap.
See [Risk gate](/system/risk-gate).

### Fakes

| Fake | Stands in for |
| --- | --- |
| `MockLLM` | Every model call. Agents get scripted JSON. |
| `tests/fakes/broker_server.jac` (`FakeBroker`) | Alpaca's trading and data APIs, with the order rules measured in the [order rules spike](/design/spike-alpaca-order-rules): wash-trade and insufficient-quantity rejections, reused client order IDs, idempotent cancels. Tests can fill orders, move prices to trigger stops, and close the session. |
| `tests/fakes/openrouter.jac` (`FakeOpenRouter`) | OpenRouter's chat API, from a script of answers, with delays for timeout tests. |
| `tests/fakes/source_server.jac` (`FakeSource`) | Every data source, replaying recorded fixtures. |
| `run/stubs.jac` | The run layer's collectors, calendar, budget check, and agents, so a full run can be tested in one process. |

### Recording fixtures

Collector tests replay real responses recorded once from the live source.

<Steps>

1. **Export the source's key and a directory.**

   ```bash
   export COLLECTOR_RECORD_DIR=/some/dir
   ```

2. **Run the collector once.**
   Each live response is saved as `<dir>/<source>/<dataset>-<hash>.json`.
   API keys sent as query parameters are left out.

3. **Trim and commit.**
   Cut large bodies down to what the test needs, and commit them under `tests/fixtures/<source>/`.

4. **Replay them.**
   Serve them with `FakeSource` and point the source's base-URL variable (such as `FINNHUB_BASE_URL`) at it.

</Steps>

## Browser checks

The end-to-end check loads every dashboard page in a real browser on four devices, against a server with demo data and fake providers.
The fake, `e2e/fake-providers.js`, stands in for OpenRouter, Alpaca, and Finnhub on port 8399, so a test can sign up, connect keys, and use the policy assistant without a real key or network.
The server needs `OPENROUTER_API_BASE`, `ALPACA_BASE_URL`, and `FINNHUB_BASE_URL` all set to `http://127.0.0.1:8399`, `PARALLAX_KEYS_SECRET` set, and `PARALLAX_MAX_AGENTS=1000`, since each run connects new agents to the same database and the default limit is 10.

```bash
node e2e/fake-providers.js &   # in one terminal
OPENROUTER_API_BASE=http://127.0.0.1:8399 ALPACA_BASE_URL=http://127.0.0.1:8399 \
FINNHUB_BASE_URL=http://127.0.0.1:8399 PARALLAX_KEYS_SECRET=$(openssl rand -base64 48) PARALLAX_MAX_AGENTS=1000 \
TRADING_AGENT_DEMO=1 TRADING_AGENT_DISABLE_ORDERS=1 jac run --dev main.jac   # in another
cd e2e
npm ci
npx playwright install chromium webkit
npx playwright test   # E2E_BASE_URL defaults to http://localhost:8000
```

| Project | Device | Viewport |
| --- | --- | --- |
| `desktop` | Desktop Chrome | 1440 by 900 |
| `minimum` | Pixel 7 | 360 by 640 |
| `android-chrome` | Pixel 7 | the device's own |
| `ios-safari` | iPhone 15 (WebKit) | the device's own |

Before the tests start, a setup step signs up a throwaway account and waits up to 4 minutes for the demo history to appear.
Any console error or page error fails the test and attaches a full-page screenshot, and every page must fit the viewport's width with no sideways scroll.

The tests cover:

- The Portfolio page, a run leading to a ticker's decision trail with all six stages, and the not-found page.
- The landing page, and sign-up, connecting keys, logging out, and logging back in to the page the visitor was going to.
- A crafted link that cannot send someone elsewhere after logging in, and old addresses that redirect to `/app/...`.
- Changing a password, and a new agent's next step on the Portfolio page.
- Reports and the Policy page, including the assistant and a member's save being theirs alone.
- The theme, which starts dark and stays on a switch to light after a reload.
- The phone layout: bottom tabs, cards in place of tables, and installing and opening offline.

## Continuous integration

`.github/workflows/ci.yml` runs on every pull request and on every push to `main`.
One job does everything, in order:

<Steps>

1. **Install Jac 0.37.12** and verify the binary's SHA-256.

2. **`jac install`, `jac check .`, `jac test`, `jac build`.**
   Postgres binaries, the Jac runtime, and the virtualenv are cached between runs; the database's data directory never is.

3. **Boot the bundle.**
   Start `dist/trading-agent.jab` with demo data, orders off, and the fake providers, wait up to 2 minutes for `/healthz`, then check that `POST /function/health` answers ok and `/` has the app's title.

4. **Run the browser checks** in Chromium and WebKit.
   On failure, the Playwright report is uploaded for 7 days, and the server log is always printed.

</Steps>
