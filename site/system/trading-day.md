---
title: The trading day
description: The scheduled jobs, the morning run, and the minute-by-minute trading tick that executes, monitors, and reconciles each day's decisions.
related:
  - { text: Run Guard, link: /system/run-guard }
  - { text: Execution, link: /system/execution }
  - { text: Starting a run by hand, link: /guide/manual-run }
---

A trading day has two halves.
The **morning run** starts at 7:30 a.m. New York time and decides what to do: it screens, researches, votes, and records a decision for every covered ticker.
The **trading tick** runs every minute while the market is open and acts on those decisions: it executes orders at 9:45 a.m., watches fills and stops, cancels leftovers before the close, and checks the books after it.

<Figure name="daily_run" alt="The daily run" caption="The daily run, from the 7:30 a.m. screen to the post-close review." />

## Scheduled jobs

Five static jobs run inside the server process on Jac's built-in scheduler.
The scheduler reads cron in UTC, and counts day 0 as Monday, so `0-4` means Monday to Friday.

| Job | Cron (UTC) | What it does |
| --- | --- | --- |
| `morning_job` | `30 11,12 * * 0-4` | Starts the morning run at 7:30 a.m. New York time. |
| `trading_job` | `* 13-21 * * 0-4` | Runs the trading tick every minute through the trading day. |
| `manual_run_job` | `* * * * *` | Runs a morning run the admin [asked for by hand](/guide/manual-run). |
| `refresh_job` | `* * * * *` | Rebuilds the dashboard's cached views. See [Dashboard internals](/system/dashboard#read-cache). |
| `demo_job` | `* * * * *` | Seeds [demo history](/guide/demo-data), only when `TRADING_AGENT_DEMO=1`. |

### Daylight saving time

New York is UTC-4 in summer and UTC-5 in winter, but cron has no time zones.
So `morning_job` fires at both 11:30 and 12:30 UTC, and proceeds only when New York time is a weekday between 7:30 and 7:44 a.m.
Exactly one of the two firings passes, in either season.
The 15-minute window lets a slow scheduler still start the run.

`trading_job` fires every minute from 13:00 to 21:59 UTC, which covers 9:45 a.m. to 4:30 p.m. New York time in both seasons; the tick itself decides, from New York time, what is due.

## The morning run

`morning_job` calls the [Run Guard](/system/run-guard)'s `daily_run` for the team portfolio and today's New York date.
It is one continuous run, and it takes about 20 minutes:

<Steps>

1. **Preflight.**
   Check the market calendar and the day's model request budget.

2. **Claim the day.**
   Create the day's `Run` node, unless one exists; a second firing stops here.
   On a market holiday, the claimed run closes as SKIPPED.

3. **Collect and screen.**
   Screen the S&P 500 and collect each shortlisted ticker's data, plus the macro data.
   If collection fails, every open position is held and the run ends as FAILED.

4. **Orchestrate.**
   Write the macro report, then hand the run to the [Orchestrator](/system/agents#orchestrator), which dispatches research, asks follow-ups, convenes the panel, and submits the decisions.
   Whatever it leaves undone, the Run Guard finishes in a fixed order.

5. **Record.**
   Write the reports, votes, consensus, decisions, and insight cards to the graph, and close the run as NORMAL or FALLBACK.

</Steps>

The run never sends an order.
Execution is the trading tick's job.

## The trading tick

`trading_job` calls the trading tick once a minute.
Only one tick runs at a time: if the previous one is still working, the new one returns at once.
A demo portfolio and a weekend get no steps at all.

The tick reads the day's session from Alpaca's market calendar.
All of its times are measured from that session's close, so an early close (such as the day after Thanksgiving) moves them too.

| Constant | Value |
| --- | --- |
| Execution starts | 9:45 a.m. |
| Fast polling until | 10:00 a.m., every minute |
| Slow polling after | every 5 minutes |
| Cancel day orders | 10 minutes before the close |
| Reconcile and score | 30 minutes after the close |

### In auto mode

| When | What the tick does |
| --- | --- |
| 9:45 a.m. to the cancel time | If today's run has finished and not executed: [execute it](/system/execution) (size, gate, send orders), sync order status, and place stops. Otherwise, poll fills and stops: every minute until 10:00, then every 5 minutes. |
| The cancel time to 30 minutes after the close | Cancel the day's unfilled limit orders, once. |
| 30 minutes after the close | [Reconcile](/system/execution#reconciliation) the ledger with the broker and mark equity, once a day. |

A run that is still RUNNING, or was SKIPPED, is never executed.

### In both modes

30 minutes after the close, once per day:

- **Score votes.** Every vote whose horizon has passed is [scored](/system/scoring) against SPY.
- **Advance the baselines.** If the forward test has started, both [baselines](/system/insights-baselines) are simulated through the day.

In insight mode, these are the tick's only steps.

### Starting the forward test

On any tick, if `TRADING_AGENT_FORWARD_TEST_START` names today or an earlier day and the test has not started, the tick [starts the forward test](/guide/forward-test) first.
It does so only before today's run has executed and before the cancel time, so the team still trades that day.

### The action log

Each step writes a line to the run's action log, as `HH:MM line`, kept to the last 400 lines.
The Runs page shows it.
If a step raises an error, the tick logs it and records it on the run; the next tick tries again.

## A normal day, minute by minute

| New York time | What happens |
| --- | --- |
| 7:30 a.m. | `morning_job` starts the morning run. |
| about 7:50 a.m. | The run finishes as NORMAL. Decisions and insight cards are on the dashboard. |
| 9:45 a.m. | The tick executes the run: sells first, then buys, each through the risk gate. Stops follow fills. |
| 9:46 to 10:00 a.m. | The tick polls fills and stops every minute. |
| 10:00 a.m. to 3:50 p.m. | The tick polls every 5 minutes. |
| 3:50 p.m. | The tick cancels unfilled day orders. Stops stay. |
| 4:00 p.m. | The market closes. |
| 4:30 p.m. | The tick reconciles, marks equity, scores votes, and advances the baselines. |

::: info Where it differs from the TDD
The daily schedule in [TDD §4](/design/tdd#daily-schedule-eastern-time) times each stage separately (screening at 7:32, the Arbiter at 9:00, sizing at 9:15, insight cards at 10:00).
In the code, the morning run is one continuous run from 7:30, insight cards are published when it ends, and sizing and the risk gate run in the 9:45 trading tick.
Preflight checks the market calendar and the request budget, not the health of each API.
:::
