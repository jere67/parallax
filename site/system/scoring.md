---
title: Vote scoring
description: How every specialist vote is graded after the fact against SPY, so the panel's track record can be inspected.
related:
  - { text: Stochastic consensus, link: /system/consensus }
  - { text: The trading day, link: /system/trading-day }
  - { text: get_decision_trail, link: /api/get-decision-trail }
---

Every vote states a direction, a confidence, and a horizon in trading days.
After that horizon has passed, code checks whether the stock beat or trailed the market over exactly that window, and records the answer on the vote.
This makes each specialist's record inspectable: whether its calls point the right way, and whether its confidence means anything.
Scoring lives in [`analysis/scoring.jac`](https://github.com/jere67/parallax/blob/main/analysis/scoring.jac), versioned by `SCORING_VERSION` (currently `2026-10-20.1`).

## The scoring window

A vote made on run date D with a horizon of H trading days is scored from:

- **start:** the close of the last session before D, the last price the panel could have known, to
- **end:** the close of the H-th session counting D itself.

The design fixed this definition on October 20, 2026 (GAP-14).
The sessions come from Alpaca's market calendar, so holidays are skipped.

## Excess return and hits

The excess return is the stock's return over the window minus SPY's over the same sessions:

```text
excess = (stock_end / stock_start - 1) - (spy_end / spy_start - 1)
```

| Vote | Excess return | Result |
| --- | --- | --- |
| BUY or STRONG_BUY | positive | hit |
| BUY or STRONG_BUY | zero or negative | miss |
| SELL or STRONG_SELL | negative | hit |
| SELL or STRONG_SELL | zero or positive | miss |
| HOLD | any | neither; the excess return is still stored |

Direction is the sign of the vote's signed score, so a directional vote at confidence 0 also counts as neither.

## A worked example

A Technical sample on run date Friday, 2026-10-16, votes BUY with a horizon of 5 sessions.

- The start is the close of Thursday, 2026-10-15.
- Counting the 16th as session 1, the 5th session is Thursday, 2026-10-22, so the end is that day's close.
- If the stock went from $100.00 to $104.00 (+4.0%) and SPY from $600.00 to $606.00 (+1.0%), the excess return is +3.0%, and the vote is a hit.

## When scoring runs

The trading tick runs `score_votes` once per trading day that has a run, 30 minutes after the close, in both auto and insight mode ([The trading day](/system/trading-day#the-trading-tick)).
It looks at every unscored vote on every run of the portfolio except skipped runs.

A daily bar is final only after 8:15 p.m. New York time, so at 4:30 p.m. today's bar is not yet usable.
A window that ends today is therefore scored at the next trading day's evening tick.
Until then the vote counts as waiting.

Each vote is scored exactly once.
When either close is missing for the stock or SPY, the vote is marked scored with no excess return, so it is never retried.
The tick logs a line such as `score: 42 votes scored, 0 without prices, 118 still open`.

## Where the results appear

Each `VoteRecord` stores `excess_return` and `scored_at`.
The [decision trail](/api/get-decision-trail) returns them on every sample, with `hit` computed on read, and the dashboard's panel section shows hit or miss against SPY for each sample.

`records()` also aggregates a specialist's scored directional votes into a hit rate and a mean confidence, the inputs for calibration (does 0.8 confidence win about 80% of the time).

::: info Where the code differs from the TDD
The TDD says the dashboard shows each specialist's hit rate and calibration.
The per-specialist aggregate (`records()`) exists and is tested, but no endpoint or page uses it yet; the dashboard shows hits only per sample, on the decision trail.
The TDD's specialist-calibration metric (within 10 percentage points) and track-record weights in the consensus both depend on it.
See [TDD §7](/design/tdd#scoring-and-calibration) and [TDD §13](/design/tdd#metrics).
:::
