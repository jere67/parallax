---
title: Architecture
description: The layers of the system, which parts are language models and which are deterministic code, and how a decision travels from the screen to an order.
related:
  - { text: The trading day, link: /system/trading-day }
  - { text: Run Guard, link: /system/run-guard }
  - { text: Data model, link: /system/data-model }
---

The Trading Agent is a centralized multi-agent system.
One language-model Orchestrator directs three layers of work (Research, Analysis, and Action) through tools.
Deterministic Jac code enforces every rule the Orchestrator must not break: the Orchestrator decides what to investigate and when the evidence is good enough, and code decides what is allowed.

<Figure name="system_architecture" alt="System architecture" caption="Dashed boxes are deterministic code and solid boxes are language-model agents. The Orchestrator reaches Alpaca only through the risk gate." />

## Design principles

These six rules shape every layer.
They come from [TDD §2](/design/tdd#design-principles).

1. **Agents advise; code enforces.**
   No model output reaches Alpaca without passing the risk gate, and the Orchestrator has no tool that places orders.
2. **Parallel where independent, single where sequential.**
   Research and specialist samples run in parallel; each ticker still gets exactly one final decision.
3. **Typed handoffs.**
   Every agent returns a typed Jac `obj` that byLLM validates, so a malformed output fails loudly instead of flowing on.
4. **Everything is replayable.**
   Inputs, outputs, and model versions are stored per run, so any decision can be audited on the dashboard.
5. **Asset-agnostic core.**
   New markets plug in as new collectors and specialists; the Orchestrator, consensus, risk gate, and dashboard stay the same.
6. **Every model call fails safe.**
   Each model call catches provider errors and bad outputs and records a safe default, such as HOLD, so one bad answer never stops a run.

## Components

| Layer | Component | Kind | What it does |
| --- | --- | --- | --- |
| Trigger | [Scheduled jobs](/system/trading-day#scheduled-jobs) | Code | Start the morning run, the trading ticks, and the evening work, in New York time. |
| Control | [Orchestrator](/system/agents#orchestrator) | Model with tools | Plans the run, dispatches research, asks follow-ups, convenes the panel, submits decisions, writes the summary. |
| Control | [Run Guard](/system/run-guard) | Code | Enforces budgets and deadlines, and finishes the run with a fixed plan if the Orchestrator fails. |
| Universe | [Screener](/system/screener) | Code | Narrows the S&P 500 to a shortlist of up to 15, plus every open position. |
| Research | [Collectors](/system/data-sources) | Code | Fetch, cache, rate-limit, and count every request to the free data sources. |
| Research | [Research agents](/system/research) | Models | Turn raw data into structured, cited reports, one per domain. |
| Analysis | [Specialist panel](/system/agents#specialists) | Models | Five roles, three samples each, vote with a confidence and a rationale. |
| Analysis | [Consensus engine](/system/consensus) | Code | Turns votes into a score, an agreement share, an interval, and a draft action. |
| Analysis | [Arbiter](/system/agents#arbiter) | Model | Confirms or downgrades the draft, and writes the thesis and exit condition. |
| Action | [Sizing](/system/sizing) | Code | Turns decisions into target weights and share counts. |
| Action | [Risk gate](/system/risk-gate) | Code | Rejects or resizes anything that breaks a limit. |
| Action | [Executor](/system/execution) | Code | Places, monitors, and reconciles orders on the Alpaca paper account. |
| Action | [Insight publisher](/system/insights-baselines) | Code | Publishes each decision as a plain-English card with its sources. |
| Product | [API](/api/overview) and [dashboard](/guide/dashboard) | Endpoints and React client | Serve the public, read-only dashboard. |
| State | [Graph](/system/data-model) | Jac persistent graph on Postgres | Holds runs, reports, votes, decisions, risk checks, orders, and marks. |

## How a decision travels

Follow one stock through one day.

<Steps>

1. **It makes the shortlist.**
   The [screener](/system/screener) ranks every S&P 500 stock by a composite of momentum, volume, news, and earnings, and keeps up to three per sector.
   A stock the portfolio holds is always covered.

2. **It is researched.**
   The Orchestrator dispatches research.
   The [collectors](/system/data-sources) fetch prices, filings, news, and insider trades into a brief, and three research agents (market, fundamentals, news) each write a report that must cite the brief.
   A macro agent writes one report for the whole market.

3. **The panel votes.**
   Five [specialists](/system/agents#specialists) each read the reports and vote three times.
   Each vote is a stance, a confidence, a horizon, and the sources it relies on.

4. **The consensus drafts an action.**
   The [consensus engine](/system/consensus) bootstraps the 15 votes into a score with a 90% interval, and a fixed rule drafts BUY, ADD, HOLD, TRIM, SELL, or NO_ACTION.

5. **The Arbiter reviews it.**
   The [Arbiter](/system/agents#arbiter) may confirm the draft or downgrade it, never upgrade it.
   It writes the thesis, at least two risks, and the exit condition.

6. **It is sized and gated.**
   At 9:45 a.m., [sizing](/system/sizing) turns conviction and volatility into a target weight, and the [risk gate](/system/risk-gate) checks ten rules in order and may resize or reject.

7. **It is traded, or published.**
   In auto mode, the [executor](/system/execution) sends a limit order and a protective stop.
   In insight mode, the decision is published as an insight card and nothing is sent.

8. **It is checked and scored.**
   After the close, the ledger is reconciled with the broker, and once its horizon has passed, each vote is [scored](/system/scoring) against SPY.

</Steps>

Every step writes to the graph, and the [decision trail](/guide/dashboard#decision-trail) shows all of it.

## Where the code runs

The whole system is one Jac server (`jac-scale`).

- **Endpoints.** `main.jac` imports every public function by name; the dashboard calls them over HTTP. See [API overview](/api/overview).
- **Scheduled jobs.** Five static jobs run inside the server process on Jac's built-in scheduler.
- **Model calls and network fetches** run on a shared pool of 32 worker threads.
  Workers never touch the graph; the run writes every result from its own thread when the workers finish.
- **The graph** is stored in Postgres (embedded when run locally).
  The team portfolio lives on the server's shared root, and each node the dashboard shows is granted public read access.

## The request budget

All models are free models on OpenRouter, with an allowance of 1,000 requests per UTC day.
A standard run may spend up to 600 of them, and the [Run Guard](/system/run-guard#budgets) switches to a reduced mode (10 tickers, one sample per specialist) when fewer than 500 are left.
Every request is rate limited to 18 per minute and counted by role.
