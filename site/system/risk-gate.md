---
title: Risk gate
description: The ten deterministic rules every proposed buy passes, the one rule a sell passes, and the order they run in.
related:
  - { text: Position sizing, link: /system/sizing }
  - { text: Execution, link: /system/execution }
  - { text: get_decision_trail, link: /api/get-decision-trail }
---

The risk gate is the last word before the broker.
It takes the sized proposals, a snapshot of the portfolio, each stock's latest facts, and the market regime, and approves, resizes, or rejects each order.
No model reads or changes anything here, and every rule it evaluates is recorded with the quantity before and after, so each decision's trail shows exactly why an order was cut.
The gate is [`action/gate.jac`](https://github.com/jere67/parallax/blob/main/action/gate.jac), versioned by `GATE_VERSION` (currently `2026-10-20.1`).

## Exits first

Sells are checked first, and a sell is never cut short, so risk can always come off.
A sell passes two checks only:

| Rule | On failure |
| --- | --- |
| Instrument checks | Rejected when the broker cannot trade the stock today (inactive or untradable); the exit waits for the next run |
| Shares held | Capped at the shares actually held |

The gate then computes the book as it will be after the sells, and the buys are judged against that.

## The rules for buys

Buys pass ten rules in this order.
Rules 1 to 4 reject an order outright; rules 5 to 10 resize it, and a resize to zero is a rejection.

| # | Rule | Limit | On breach |
| --- | --- | --- | --- |
| 1 | Instrument checks | Active and tradable on Alpaca, price above $5, and a trade in the last 15 minutes | Reject; no recent trade may mean the stock is halted |
| 2 | Earnings blackout | No earnings release within 2 trading sessions (0 means today) | Reject; logged as insight only |
| 3 | Drawdown breaker | Equity more than 10% below its peak | Reject every new buy; exits and stops still run |
| 4 | Protective stop | A usable ATR(14), with the price minus 2 × ATR above 0 | Reject; no stop could be set |
| 5 | Per-position cap | At most 10% of equity in the stock after the buy | Resize down |
| 6 | Liquidity | At most 1% of the 20-day average daily volume, in shares | Resize down |
| 7 | New positions per day | At most 3 new entries a day, counting earlier entries today | Keep the highest conviction; reject the rest |
| 8 | Sector cap | At most 30% of equity in one GICS sector | Fill in conviction order; resize or reject the lowest |
| 9 | Gross exposure | At most 90% of equity invested, or 50% under the regime filter | Scale every buy down together |
| 10 | Daily turnover | At most 25% of equity traded a day, counting exits first | Scale every buy down together |

Every resize and every scaling rounds down to whole shares, so no cap is crossed by rounding.
Rule 7 applies only to entries; an ADD to a held stock does not use a slot.
Rule 4 also sets the order's `stop_distance`, 2 × ATR(14), which the executor uses for the protective stop once the buy fills.

### The regime filter

The regime filter lowers the gross limit from 90% to 50% when SPY closed below its 200-day average and its 20-day realized volatility, annualized, is above 30%.
If either figure is missing, the filter is on, so the gate fails safe.
The figures come from the research pass's SPY bars, computed in code, not from the Macro sub-agent's opinion.

## Configuration

`GateConfig` holds every limit:

| Setting | Value |
| --- | --- |
| `max_position_weight` | 0.10 |
| `sector_cap` | 0.30 |
| `gross_limit` | 0.90 |
| `regime_gross_limit` | 0.50 |
| `regime_vol` | 0.30 |
| `new_positions_per_day` | 3 |
| `turnover_limit` | 0.25 |
| `drawdown_halt` | 0.10 |
| `earnings_blackout_sessions` | 2 |
| `adv_fraction` | 0.01 |
| `min_price` | $5.00 |
| `stop_atr_multiple` | 2.0 |
| `max_trade_age_minutes` | 15 |

## A worked example

The book has $100,000 of equity, a peak of $102,000, and $70,000 invested, of which $27,000 is in Information Technology.
The run proposes buying 30 shares of a new Information Technology stock at $200.00, with ATR(14) of $4.00, 1,500,000 shares of 20-day average volume, and no earnings in the next 2 sessions.

| Rule | Shares before | Shares after | Detail |
| --- | --- | --- | --- |
| Instrument checks | 30 | 30 | active, tradable, last trade 200.00 |
| Earnings blackout | 30 | 30 | no earnings within 2 sessions |
| Drawdown breaker | 30 | 30 | 2.0% below the peak |
| Protective stop | 30 | 30 | stop 8.00 below the fill |
| Per-position cap | 30 | 30 | at most 50 shares |
| Liquidity | 30 | 30 | at most 15,000 shares |
| New positions per day | 30 | 30 | a slot is free |
| Sector cap | 30 | **15** | the sector has $3,000 of room |
| Gross exposure | 15 | 15 | $20,000 of room |
| Daily turnover | 15 | 15 | $25,000 of room |

The outcome is **resized** to 15 shares, and `rejected_by` names the last rule that cut it, the sector cap.

## What is recorded

For every proposal the executor stores a `RiskCheck` node, linked to its decision: the outcome (`approved`, `resized`, or `rejected`), the requested and approved quantities, the side and purpose, the checked price, the stop distance, the gate version, and one `RuleResult` per rule with its detail and quantities.
A rule that cut the quantity or failed is recorded as not passed.
A held stock the run did not cover still gets its check on record, attached to the portfolio.
The [decision trail](/api/get-decision-trail) returns all of it.

## Proven by a property test

A [Hypothesis](https://hypothesis.readthedocs.io/) property test in [`action/gate_tests.jac`](https://github.com/jere67/parallax/blob/main/action/gate_tests.jac) generates 3,000 random books, proposals, and market facts, and checks every approved set of orders:

- no approved quantity exceeds the request, and no exit of a tradable stock is cut;
- every approved buy passes the instrument, earnings, drawdown, stop, and liquidity rules;
- no position exceeds 10%, no sector 30%, and gross exposure stays under its limit, regime included;
- new entries stay within the day's slots, and buys within the day's turnover after exits.

::: info Where the code differs from the TDD
The TDD's instrument check says "not halted"; the code approximates it by requiring a trade in the last 15 minutes, since a stock with no recent trade may be halted.
The TDD says the sector cap rejects the "newest" order; the code fills the sector in conviction order, so the lowest-conviction order is the one resized or rejected.
The code also adds a "shares held" check for sells, which the TDD does not list.
See [TDD §8](/design/tdd#risk-gate).
:::
