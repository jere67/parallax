---
title: The forward test
description: How the team portfolio moves from publishing insight cards to trading on paper, and what has to be true on the start date.
related:
  - { text: Insights and baselines, link: /system/insights-baselines }
  - { text: The trading day, link: /system/trading-day }
  - { text: Execution, link: /system/execution }
---

This page covers the admin's team agent.
A user's own agent starts its test when its owner turns on paper trading in Settings; see [Your agent](/guide/your-agent#turn-on-paper-trading).

The forward test is the live evaluation of the system: from its start date, the team portfolio trades the Alpaca paper account every trading day, next to two baselines that get the same starting balance.
Until it starts, the team portfolio is in insight mode and only publishes its decisions.

## Start it

The forward test starts on a date the team picks, through one environment variable:

```bash
TRADING_AGENT_FORWARD_TEST_START=2026-11-09   # a trading date, YYYY-MM-DD
```

Set it only with the team's go-ahead, and restart the server so it reads the new value.

On the start date, the next [trading tick](/system/trading-day#the-trading-tick) starts the test, as long as all of these are true:

- The date is today or earlier.
- The forward test has not started yet (no baselines exist).
- Today's run has not executed its orders yet.
- Today is a trading session, and it is before the cancel time (10 minutes before the close, so 3:50 p.m. on a normal day).

A server started after that window starts the test on the next trading day instead.

## What happens at the start

<Steps>

1. **The paper account is checked.**
   It must be flat: no positions and no open orders.
   If it is not, the start fails with a message listing what is held, and the next tick tries again.

2. **The starting balance is set.**
   The account's equity becomes the starting balance of the team portfolio and of both baselines, so all three start alike, all in cash.

3. **The baselines are created.**
   An equal-weight shortlist and SPY buy-and-hold.
   See [Insights and baselines](/system/insights-baselines).

4. **The team portfolio switches to auto mode.**
   From now on, each morning's decisions are sized, gated, and traded.
   If today's run has finished but not executed, the same tick executes it.

</Steps>

The tick writes a line like this to the run's action log:

```text
start: forward test started on 2026-11-09: starting balance 100,000.00, team portfolio in auto mode, baselines equal_weight and spy created
```

## Before the start date

Check these before setting the variable:

- The server has run at least one morning in insight mode, and the [Runs page](/guide/dashboard#runs) shows a NORMAL run.
- The paper account is flat.
- `TRADING_AGENT_DISABLE_ORDERS` is not set, unless the team wants a dry run that records the checks without trading.
- `TRADING_AGENT_DEMO` is not set.
  A demo portfolio is never traded, and it already has baselines, so the test could not start on it.

## After the start

The dashboard's Portfolio page shows the team portfolio against both baselines from the start date: equity, return against SPY, drawdown, Sharpe ratio, and volatility.
The test is measured against SPY (requirement GAP-14 in the [requirements](/design/requirements)).

The Results page (`/app/results`) is the test's scorecard, rebuilt after each close: whether the agent is ahead of each baseline with a 95% interval, how the screen's picks did against the rest of the index, how well each specialist's confidence matched its hit rate, what the Arbiter's downgrades were worth, and how reliably the runs completed.
See [Evaluation](/system/evaluation) for how each figure is computed.

::: info The start is one-way
Nothing in the code switches the team portfolio back to insight mode.
To stop trading without stopping the server, set `TRADING_AGENT_DISABLE_ORDERS=1`: the executor still sizes and gates each decision and records why nothing was sent.
:::
