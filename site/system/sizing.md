---
title: Position sizing
description: How a decision and its conviction become a whole number of shares, long only, before the risk gate sees it.
related:
  - { text: Stochastic consensus, link: /system/consensus }
  - { text: Risk gate, link: /system/risk-gate }
  - { text: Execution, link: /system/execution }
---

Sizing answers one question for every covered ticker and every open position: how many shares should the portfolio hold after today?
A stronger, calmer conviction gets a bigger position; a volatile stock gets a smaller one; no position may exceed 10% of equity.
Sizing is deterministic and long only, and it produces proposals, not orders: an order exists only once the [risk gate](/system/risk-gate) approves it.
The code is [`action/sizing.jac`](https://github.com/jere67/parallax/blob/main/action/sizing.jac), versioned by `SIZING_VERSION` (currently `2026-10-20.1`).

## The target weight

For a BUY or an ADD, the target weight of equity is:

```text
w = min(w_max, λ × conviction / (σ / σ_median))
```

| Symbol | Meaning | Value |
| --- | --- | --- |
| conviction | The consensus conviction, abs(C) × A, in [0, 1] | from the run |
| σ | The stock's 20-day realized volatility | from the research pass |
| σ_median | The median 20-day volatility of all candidates with a positive one | computed per run |
| λ | `scale` | 0.08 |
| w_max | `max_position_weight` | 0.10 |

Dividing by σ / σ_median makes the position smaller for a stock more volatile than the typical candidate and larger for a calmer one.

## What each action does

| Action | Shares after sizing |
| --- | --- |
| BUY, ADD | The current shares, plus the shares that close the gap to the target weight; never fewer than held, so an ADD only adds |
| HOLD, NO_ACTION | Exactly the shares held; recomputing from a weight would trade a share either way on rounding alone |
| TRIM | The shares held times (1 - `trim_fraction`), rounded down; `trim_fraction` is 0.5 |
| SELL | 0 |

A held stock the run did not cover is sized as HOLD.

A buy with no positive price, or no positive 20-day volatility, buys nothing and records a note such as `no positive 20-day volatility; nothing bought`.

## The gross exposure limit

The positions that are not buying keep their value.
The buys share the room left under the gross limit, `gross_exposure_limit` = 0.90 of equity.
If the buys ask for more than that room, every buy shrinks by the same factor, and positions that are not buying are never sold to make room.

All share counts are rounded down to whole shares.
Each entry carries a GTC protective stop, and Alpaca accepts fractional orders only with time in force DAY, so the system never trades fractions.

## A worked example

The account has $100,000 of equity and no positions.
The run decides BUY on a stock at $410.00 with conviction 0.332, a 20-day volatility of 22%, and a candidates' median volatility of 28%.

1. Volatility ratio: 0.22 / 0.28 = 0.786.
2. Raw weight: 0.08 × 0.332 / 0.786 = 0.0338, below the 0.10 cap.
3. Dollars: 0.0338 × $100,000 = $3,383.
4. Shares: floor($3,383 / $410.00) = **8 shares**, a weight of 3.3%.

A stock with conviction 0.9 and a volatility of 15% would get 0.08 × 0.9 / (0.15 / 0.28) = 0.134, so the 0.10 cap applies.

## Configuration

`SizingConfig` validates its values at construction:

| Setting | Value | Constraint |
| --- | --- | --- |
| `scale` | 0.08 | finite, at least 0 |
| `max_position_weight` | 0.10 | in (0, 1], at most the gross limit |
| `gross_exposure_limit` | 0.90 | in (0, 1] |
| `trim_fraction` | 0.5 | in (0, 1] |

`size_positions` also refuses non-positive equity, duplicate tickers, negative holdings, convictions outside [0, 1], and a held position with no positive price.

## Where it runs

The executor sizes the run's decisions at the first trading tick from 9:45 a.m. in auto mode, using the account's live equity, Alpaca's positions, and the latest IEX trade price ([Execution](/system/execution)).
The equal-weight baseline uses the same sizing with every shortlisted stock at conviction 1 ([Insights and baselines](/system/insights-baselines)).

::: info Where the code differs from the TDD
The code matches [TDD §8](/design/tdd#position-sizing).
The TDD leaves the trim size open; the code starts at half.
:::
