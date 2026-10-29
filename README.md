# Trading Agent

A Jac multi-agent system that screens the S&P 500 every trading day, researches a shortlist from free data sources, decides through a stochastic consensus of specialist agents, and trades on Alpaca paper accounts.
Every report, vote, decision, risk check, and order is logged and shown on a public dashboard.

EECS 449, Fall 2026.
An educational project using simulated money; nothing here is investment advice.

## Documents

- [Technical design document](docs/TDD.md): architecture, data sources, agents, risk controls, and the build plan.
- [Requirements](docs/requirements.md): what the system must do, and the open knowledge gaps.
- [Contributing](CONTRIBUTING.md): how we branch, commit, review, and write Jac.

Work is tracked in [issues](https://github.com/jere67/eecs449-project/issues), grouped into one milestone per build phase.

## Quickstart

Install Jac 0.37.12, the version this project pins:

```bash
curl -fsSL https://raw.githubusercontent.com/jaseci-labs/jaseci/main/scripts/install.sh | bash -s -- --version 0.37.12
jac --version
```

Then, from the repo root:

```bash
cp .env.example .env       # fill in keys
set -a && source .env && set +a   # export them; jac run does not read .env
jac install                # Python and npm dependencies
jac run                    # serves the app with hot reload at http://localhost:8000
```

`GET /healthz` and `POST /function/health` answer once the server is up, and `/docs` lists every endpoint.

## Trading switches

The server trades only the team's Alpaca paper account, and only when the team portfolio is in auto mode.
Two environment variables control it:

- `TRADING_AGENT_FORWARD_TEST_START=YYYY-MM-DD` starts the forward test on that trading date, before 9:45 a.m. New York time.
  The paper account must be flat.
  Its equity becomes the starting balance of the team portfolio and both baselines (equal-weight shortlist and SPY buy-and-hold), and the team portfolio switches to auto mode.
  Set it only with the team's go-ahead.
- `TRADING_AGENT_DISABLE_ORDERS=1` stops every order.
  The executor still sizes and gates each morning's decisions and records the checks, but sends nothing.

## Demo data

Before the forward test stores real runs, the dashboard can be built and checked against made-up history:

```bash
TRADING_AGENT_DEMO=1 TRADING_AGENT_DISABLE_ORDERS=1 jac run --dev main.jac
```

Within a minute, a scheduled job fills an empty team portfolio with a few weeks of simulated sessions, and every page shows a "Demo data" banner.
The prices, research, and votes are invented; the consensus, sizing, risk gate, baselines, and scoring that turn them into orders are the project's own.
The scheduled jobs never run, trade, reconcile, or score a demo portfolio, and the job writes nothing once the team portfolio has any run.
Never set `TRADING_AGENT_DEMO` on a deployed server.

## Checks

```bash
jac check .   # type-check and lint the whole project
jac test      # every test, colocated and in tests/
jac build     # the production bundle, dist/trading-agent.jab
```

`jac check .` prints "may be undefined" warnings for JSX tags and "never used" warnings for component state setters.
These are false positives from checking client modules in isolation in Jac 0.37.12; the same warnings appear in a fresh `jac create` scaffold.

The dashboard's end-to-end check loads every page in a real browser on each device in the matrix (TDD §10): desktop Chrome, a 360-pixel phone, Android Chrome, and iOS Safari.
It needs a server with the demo data running (above), and Node.js:

```bash
cd e2e
npm ci
npx playwright install chromium webkit
npx playwright test   # E2E_BASE_URL defaults to http://localhost:8000
```

## Layout

The layout follows [TDD §3](docs/TDD.md#repository-layout).
Module paths that declare node types are frozen once data is stored, because moving them strands stored rows.

```
main.jac        server entry; imports every endpoint by name
models/         node, edge, obj, and enum definitions; no server-only imports
agents/         role model instances, Orchestrator, research sub-agents, specialists, Arbiter
research/       data collectors and the S&P 500 screener
analysis/       indicators, the consensus engine, and vote scoring
action/         broker client, sizing, risk gate, executor, reconciliation, insight cards, baselines
run/            daily run walker, Run Guard, trading day, scheduled jobs, health
dashboard/      client pages and components
assets/         static files served at /static/assets/
tests/          integration and smoke tests, fixtures, fakes
e2e/            the dashboard's browser checks on each device (Playwright)
docs/           design documents and spike findings
```

Folders appear as their first module lands.
