---
title: Execution
description: How approved orders reach Alpaca's paper account, how every position keeps a protective stop, and how the books are reconciled each evening.
related:
  - { text: Risk gate, link: /system/risk-gate }
  - { text: The trading day, link: /system/trading-day }
  - { text: The forward test, link: /guide/forward-test }
---

The executor turns the morning's decisions into paper orders, keeps a protective stop under every position, and lets the evening reconciliation check the record against the broker.
It trades only Alpaca's paper environment, and only when the team portfolio is in auto mode.
Every function is safe to call again: a retried job finds the order it already placed instead of placing a second one.
The code is in [`action/executor.jac`](https://github.com/jere67/parallax/blob/main/action/executor.jac), [`action/broker.jac`](https://github.com/jere67/parallax/blob/main/action/broker.jac), and [`action/reconcile.jac`](https://github.com/jere67/parallax/blob/main/action/reconcile.jac).

## Paper only

The broker client refuses to trade anything but a paper account, in two places:

- **The host.** The base URL must be `paper-api.alpaca.markets`, or `localhost` or `127.0.0.1` for a test's fake broker; anything else raises an error at construction.
- **The account.** `account()` refuses an account whose number does not start with `PA`, the prefix Alpaca gives paper accounts.

Keys go in request headers, which nothing logs or stores.
Prices are rounded to the tick Alpaca accepts: a cent at $1 and above, a hundredth of a cent below.

## Modes and switches

| Condition | What the executor does |
| --- | --- |
| Portfolio in insight mode | Nothing; the run's decisions are published as [insight cards](/system/insights-baselines) |
| Portfolio in auto mode | Sizes, gates, records, and submits |
| `TRADING_AGENT_DISABLE_ORDERS=1` | Sizes and gates, records every `RiskCheck`, and sends nothing; no stops are placed |

The team portfolio starts in insight mode and switches to auto mode when the [forward test](/guide/forward-test) starts.

## Executing the run

At the first trading tick from 9:45 a.m. New York time, while it is still before 10 minutes to the close, `execute_run` runs once for the day's run:

<Steps>

1. **Read the account.**
   Live equity, Alpaca's positions, the latest IEX trade for every covered or held stock, and the asset list.
   A failed read becomes a gap in the execution note, and the gate refuses the buys it cannot judge.

2. **Size.**
   Every covered ticker and every held stock is sized ([Position sizing](/system/sizing)); a held stock the run did not cover is sized as HOLD.

3. **Gate.**
   Every non-zero change becomes a proposal for the [risk gate](/system/risk-gate), and every result is stored as a `RiskCheck` linked to its decision.

4. **Submit, sells first.**
   Exits free their cash and turnover before any buy is placed.

</Steps>

A run that is still running, or was skipped, is not executed, and a run already executed is not executed again (`run.executed_at`).
A run that finishes after 3:50 p.m. only publishes its decisions; it is never executed on a later day.

### Order type

Every run order is a **marketable limit, time in force DAY**, at the latest trade price plus 0.3% for a buy or minus 0.3% for a sell.
A limit protects against a bad fill in a thin moment, and the 0.3% offset makes it fill at once in normal markets; in the order-rule spike, marketable limits filled in under a second.

### Idempotent IDs

| Order | `client_order_id` | Example |
| --- | --- | --- |
| A run's order | run date, ticker, purpose | `2026-10-21-MSFT-entry` |
| A protective stop | ticker, the position's opening time, stop number | `MSFT-20261021134512-stop1` |

Purposes are `entry`, `add`, `exit`, `trim`, and `stop`.
Before posting, the client looks the ID up with `GET /v2/orders:by_client_order_id`; if the order exists, it is returned instead of placed again.
A failed POST is retried only for a transient error (no response, 429, or 5xx), and only after a lookup shows the order was not created.
A re-placed stop gets the next stop number, so it never reuses an ID.

### Wash-trade rules

Alpaca refuses an order whose opposite side is already open, and a sell of shares an open stop reserves.
So before any run order, `submit` cancels the position's working stop and waits until Alpaca reports it closed.
If the stop filled first, the order is not sent, and the log says `its stop filled (n shares) before the order`.
A sell is also capped at the shares Alpaca says are available.

## Fills and positions

`sync_orders` refreshes every working order and records each new fill as a `Fill` node:

- A buy fill with no open position opens one, with its stop at the fill price minus the gate's stop distance (2 × ATR(14)).
- A buy fill on an open position averages the entry price; an add never loosens the stop.
- A sell fill reduces the position, and closes it at zero shares with its exit price.

## Protective stops

`keep_stops` makes sure every open position has exactly one working stop for all its shares:

- A **GTC stop sell** at the position's stop price, placed after the entry fills.
- It waits while a buy or a non-stop sell on the stock is working, since Alpaca would refuse it.
- A stop with the wrong quantity or price is canceled and re-placed.
  This covers a partial fill once its buy is canceled at 3:50 p.m., an add, a trim, and a GTC stop Alpaca expired after 90 days.
- If the price is already at or below the stop, a stop sell would be refused, so the position is sold at once with a marketable DAY limit instead.

The trading tick runs `sync_orders` and `keep_stops` every minute until 10:00 a.m. and every 5 minutes after, until 10 minutes before the close.

## The close

At 10 minutes before the close (3:50 p.m. on a normal day, earlier on an early close), `close_day_orders` runs once: it records the last fills, cancels every DAY order still working, and logs how much of each filled.
Unfilled orders are not carried over; the next morning's run decides again.

## Reconciliation

Thirty minutes after the close, `reconcile` brings the record in line with Alpaca, which holds the truth about shares and cash:

| Check | What happens |
| --- | --- |
| A position on record that Alpaca no longer holds | Closed on the record; listed as drift |
| A share count that differs | Corrected to Alpaca's; listed as drift |
| A position at Alpaca not on record | Adopted with a stop at entry minus 2 × the newest recorded ATR(14), or 10% below entry with no ATR; listed as drift |
| Every held position | Priced at Alpaca's current price |
| Every order the executor sent | Must trace to an approving `RiskCheck` for at least its quantity, or, for a stop, to its position |
| Every order Alpaca saw since the last mark | Must be one the executor sent; anything else is a **bypass** |

The day is then marked as one `DailyMark`: equity, cash, positions value, peak equity, drawdown from the peak, open positions, and the drift and bypass lists.
The peak only moves up, and the [drawdown breaker](/system/risk-gate#the-rules-for-buys) measures from it.
Drift and bypasses must stay empty; the action exit run counted zero of each over three simulated days ([Action exit run](/design/run-action)).

::: info Where the code differs from the TDD
The TDD says time stops and thesis invalidations are checked each morning and become SELL decisions.
In code, a passed time stop makes the consensus draft a SELL; an event-based exit stays the Arbiter's text, for the next run's research to test.
Adopting an unknown position with a 10% fallback stop when no ATR is on record is not in the TDD.
Otherwise the code follows [TDD §8](/design/tdd#execution-on-alpaca) and the [order-rule spike](/design/spike-alpaca-order-rules).
:::
