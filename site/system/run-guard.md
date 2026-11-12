---
title: Run Guard
description: The deterministic code around the Orchestrator that enforces budgets and deadlines, refuses what breaks a rule, and always finishes the run.
related:
  - { text: Agents and models, link: /system/agents }
  - { text: The trading day, link: /system/trading-day }
  - { text: Retry audit, link: /design/run-retry-audit }
---

The Orchestrator is a language model, so it can loop, stall, overspend, or stop early.
The Run Guard is the deterministic code around it that makes those failures harmless.
Every tool the Orchestrator calls is a Run Guard method that checks its limits first, and when the Orchestrator is done (or fails), the Run Guard finishes whatever is left in a fixed order.
A claimed run never raises: every failure is recorded on the run.

The code is in [`run/guard.jac`](https://github.com/jere67/parallax/blob/main/run/guard.jac) and [`run/orchestration.jac`](https://github.com/jere67/parallax/blob/main/run/orchestration.jac).

## Budgets

`RunLimits` holds every limit a run must respect.

| Limit | Value | Meaning |
| --- | --- | --- |
| `run_requests` | 600 | Model requests one run may spend. |
| `reduced_below` | 500 | Below this many requests left today, the run is reduced. |
| `followups_per_ticker` | 2 | Follow-up research requests per ticker. |
| `react_iterations` | 12 | Turns of the Orchestrator's tool loop. |
| `deadline_s` | 5400 | The run's deadline: 90 minutes. |
| `shortlist` / `reduced_shortlist` | 15 / 10 | Tickers screened in a normal and a reduced run. |
| `samples` / `reduced_samples` | 3 / 1 | Samples per specialist in a normal and a reduced run. |

Text the Orchestrator writes is clipped too: a follow-up question to 500 characters, a flag reason to 300, and the run summary to 2,000.

### How many requests are left

Preflight works out the day's budget before the run is claimed:

```text
own_used       = max(requests counted in the graph for today (UTC), requests the limiter sent today)
requests_left  = min(1000 - own_used, the free requests OpenRouter reports as left)
reduced        = requests_left < 500
run_requests   = min(600, requests_left)
```

1,000 is the account's free-model allowance per UTC day.
A **reduced** run screens 10 tickers instead of 15 and takes one sample per specialist, with no extra samples near a decision boundary.
The Runs page shows a **Reduced mode** badge.

## What it prevents

`daily_run` checks these in order.

| Case | What happens |
| --- | --- |
| A demo portfolio | Never run. Returns SKIPPED, with no `Run` node. |
| A second firing for the same day | `claim_run` takes a lock and creates the day's `Run` only if none exists. The second caller gets SKIPPED, "already claimed". |
| A market holiday | The claimed run closes as SKIPPED with the calendar's note. If the calendar cannot be read, weekdays count as trading days and a note is recorded. |
| Data collection fails | Every open position gets a forced HOLD decision and an insight card, and the run closes as FAILED. |
| A low budget | The run is reduced. |

## The Orchestrator's tools

Each tool checks its limits and, if the call breaks one, refuses with a reason the Orchestrator can read and act on.

| Tool | What it does, and what it refuses |
| --- | --- |
| `get_run_context` | Returns the date, the mode (standard or reduced), the requests left, the macro brief, and each ticker with why it is covered and how far it has got. |
| `dispatch_research` | Runs the named research agents (market, fundamentals, news) for a batch of tickers in parallel. Each ticker and domain runs at most once. |
| `request_followup` | Asks one research agent a follow-up question. Refused after 2 per ticker. |
| `flag_ticker` | Marks a ticker as unreliable today, with a reason. It is decided HOLD, and the dashboard shows the reason. Refused without a reason or after submission. |
| `convene_panel` | Runs the specialist panel, the consensus, and the Arbiter for a ticker. Refused until research is dispatched. A ticker whose panel no longer fits the budget is forced to HOLD. |
| `submit_decisions` | Submits the run's decisions, with a note. Refused until every ticker has a decision. |
| `write_run_summary` | Writes the run summary, once. |

A panel costs `5 x K + 1` requests: five specialists, K samples each, and one Arbiter call.
With K = 3, that is 16 requests per ticker.

## The tool loop

The Orchestrator runs as a ReAct loop of at most 12 iterations.
Before each iteration, a hook stops the loop with a summary when 2 or fewer requests are left in the run's budget, or when the run is past its deadline.
The last two requests are kept back so the Orchestrator can always write its summary.

## Finishing in fixed order

When the Orchestrator returns, raises, or runs out of time, `complete_in_order` takes over.
It never raises.

<Steps>

1. **Research what is missing.**
   Every ticker that lacks a market, fundamentals, or news report gets it, with no follow-ups.

2. **Convene the missing panels.**
   Every ticker without a decision gets its panel, as far as the budget allows.

3. **Hold the rest.**
   A ticker it still cannot decide gets HOLD with the reason "the run could not finish its research or panel".

4. **Submit.**
   The decisions are submitted, with the note "submitted by the Run Guard".

</Steps>

## Run status

| Status | When |
| --- | --- |
| `normal` | The Orchestrator itself submitted the decisions, before the deadline. |
| `fallback` | Anything else: the Orchestrator raised, stopped early, or ran late, and the Run Guard finished the run. Also any run where no specialist voted on any ticker, whatever the Orchestrator submitted. |
| `skipped` | Not a trading day, or the day was already claimed. |
| `failed` | Data collection failed. |
| `running` | The run is in progress. |

If no summary was written, the Run Guard writes one, such as "15 tickers decided by the Orchestrator: 2 BUY, 13 NO_ACTION. 241 model requests."

A run where no specialist voted on any ticker holds everything, and a hold with no vote behind it is not the panel's verdict.
So the Run Guard marks that run `fallback` and replaces its summary with the cause, which the Runs page shows:

- **Models unavailable**, when the run still had requests left: every model was down or the kill switch was set. For example: "Models unavailable: no specialist answered for any of the 15 tickers (insufficient data: no complete market, fundamentals, news research), so every ticker holds and no new position was opened."
- **Request budget spent**, when the run had used its requests before the panel.

The evaluation counts such a run as incomplete ([Evaluation](/system/evaluation)).

## Recording the run

Model calls run on a shared pool of 32 worker threads, and workers never touch the graph.
When the session ends, `record_run` writes everything from the run's own thread: the macro record, one `Coverage` per ticker with its research, votes, consensus, and decision, and the insight cards.
Each node is granted read access as it is written, so the dashboard can show it to the account whose agent wrote it.
It also records the model versions used, the requests spent by role, and the tokens, and adds the requests to the day's count.

::: info Where it differs from the TDD
[TDD §4](/design/tdd#orchestrator-tools) lists `submit_decisions(decisions)`.
In the code, `submit_decisions` takes only a note; the decisions come from the session's state.
The TDD also says a ticker without reports defaults to HOLD with the reason "insufficient data".
In the code, `convene_panel` refuses until research is dispatched, an incomplete report gives "insufficient data: no complete ... research", and a ticker the run never reached gets "the run could not finish its research or panel".
:::
