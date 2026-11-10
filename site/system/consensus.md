---
title: Stochastic consensus
description: How fifteen noisy votes become one score, an agreement, a confidence interval, and a draft action, in plain code.
related:
  - { text: Agents and models, link: /system/agents }
  - { text: Vote scoring, link: /system/scoring }
  - { text: Position sizing, link: /system/sizing }
---

One model call is noisy: ask the same question twice and the answer can change.
So the panel asks each of five specialists the same question three times, at a high temperature and with the evidence shuffled, and treats the spread of answers as information.
The consensus engine then turns the votes into a score C, an agreement A, an 80% interval for C, and a draft action.
It is plain code with no model calls, in [`analysis/consensus.jac`](https://github.com/jere67/parallax/blob/main/analysis/consensus.jac), versioned by `CONSENSUS_VERSION` (currently `2026-11-10`).

<Figure name="stochastic_consensus" alt="The stochastic consensus" caption="The stochastic consensus: five specialists, K samples each, aggregated by code and reviewed by the Arbiter." />

## Where the randomness comes from

1. **Temperature.**
   Each specialist is sampled K times at temperature 0.8.
2. **Evidence order.**
   Each sample sees the evidence in a different seeded order, so no claim always sits first.

K is 3 in a standard run and 1 in reduced mode.

## From votes to a score

### Signed score of one vote

Each vote becomes a signed score in [-1, 1]:

```text
x = stance / 2 × confidence
```

where the stance maps `STRONG_SELL` to -2, `SELL` to -1, `HOLD` to 0, `BUY` to +1, and `STRONG_BUY` to +2.
A `BUY` at confidence 0.8 scores 0.4; a `STRONG_BUY` at 0.8 scores 0.8; every HOLD scores 0.

### Consensus score C

Each specialist's score is the mean of its samples.
C is the weighted mean of the specialists' scores.
In the current build every weight is 1, so C is the plain mean of five specialist means.
A specialist with no valid vote is left out.

A vote that cites only data gaps abstains.
Only a Flow HOLD can do that, when missing insider or holdings data leaves it no view; see [Agents](/system/agents#citations).
An abstaining vote is left out of the specialist's mean, of A, and of the interval, and a specialist whose samples all abstain is left out entirely, so missing data never pulls C toward zero.

### Agreement A

For each specialist, take the share of its samples whose sign matches the sign of C.
A is the weighted mean of those shares.
A HOLD vote points neither way, so it never agrees.

### Interval for C

A 1,000-draw bootstrap gives an 80% interval for C.
Each draw picks specialists with replacement, each with all of its samples, and recomputes the weighted mean; the interval is the 10th and 90th percentiles, interpolated linearly.
So a low end above zero means the bootstrap puts C above zero with 90% confidence.
The engine resamples whole specialists rather than single votes because one specialist's samples share a prompt and an evidence set, so treating them as independent would make the interval too narrow.
The draws are seeded by the CRC-32 of `ticker:run_day`, so the same votes always give the same interval.

### Conviction

Conviction is `|C| × A`, in [0, 1].
It measures how strongly the panel backs its direction, and it drives [position sizing](/system/sizing).

## The decision rule

The draft action follows these rules, in order:

| Step | Condition | Draft action |
| --- | --- | --- |
| 1 | Held, and the exit fired or C ≤ -0.25 | SELL |
| 2 | C ≥ 0.1, A ≥ 0.5, and the interval's low end is above 0 | ADD if held, else BUY |
| 3 | Held, and C below 0.1 | TRIM if A is below 0.5, else HOLD |
| 4 | Anything else | NO_ACTION |

A held position's exit fires when its time stop has passed, that is, when the run date reaches the stored date.
Price exits are the protective stop orders the Action layer places; see [Execution](/system/execution).
NO_ACTION on a held stock keeps the position exactly as it is.

### Configuration

`ConsensusConfig` holds every threshold.
They are the design's starting values, except the buy bar.
That started at C ≥ 0.35 and A ≥ 0.6, and no ticker reached it in the first three live runs, so on November 4, 2026 it became 0.2 and 0.5 ([decision backtest](https://github.com/jere67/parallax/blob/main/docs/spikes/2026-11-04-decision-backtest.md)).
At that bar the votes of the next six runs drafted one buy between them, so on November 10 the score bar became 0.1 and the interval 80% instead of 90% ([decision replay](https://github.com/jere67/parallax/blob/main/docs/spikes/2026-11-10-decision-replay.md)).
All of them are retuned as the forward test adds history.

| Setting | Value | Meaning |
| --- | --- | --- |
| `samples` | 3 | K, samples per specialist |
| `extra_samples` | 2 | More samples per specialist for an ambiguous result |
| `buy_score` | 0.1 | C needed for BUY or ADD |
| `buy_agreement` | 0.5 | A needed for BUY or ADD |
| `sell_score` | -0.25 | C at or below which a held stock is sold |
| `trim_agreement` | 0.5 | A below which a weak hold is trimmed |
| `min_success` | 0.6 | Share of samples that must be valid |
| `interval` | 0.8 | Bootstrap interval coverage |
| `draws` | 1,000 | Bootstrap draws |
| `ambiguity_band` | 0.05 | How close to a threshold counts as ambiguous (proposal GAP-04) |

## Sequential sampling

A result is ambiguous when moving C and the interval's low end together by up to ±0.05, or A by up to ±0.05, would change the draft action.
An ambiguous ticker gets 2 more samples from each specialist, and the consensus is computed again from all of its samples.
So model requests scale with how close a call is.
An exit that has already fired is never ambiguous, and reduced mode draws no extra samples.

## Too few valid samples

A sample is dropped when its call fails twice or when it cites no evidence in range.
If fewer than 60% of the samples asked for come back valid, the ticker is decided HOLD with a reason such as `only 8 of 15 specialist samples were valid`, and the Arbiter is not called.
A ticker without complete market, fundamentals, and news research never reaches the panel and is decided HOLD with `insufficient data: no complete ... research`.

## A worked example

Here are 15 made-up votes on MSFT, not held, in a run on 2026-10-16:

| Specialist | Samples (stance, confidence) | Signed scores | Mean | Agreeing |
| --- | --- | --- | --- | --- |
| Flow | BUY 0.60, HOLD 0.50, BUY 0.55 | 0.300, 0, 0.275 | 0.192 | 2 of 3 |
| Fundamentals | BUY 0.80, BUY 0.75, STRONG_BUY 0.60 | 0.400, 0.375, 0.600 | 0.458 | 3 of 3 |
| Macro | BUY 0.60, HOLD 0.60, BUY 0.65 | 0.300, 0, 0.325 | 0.208 | 2 of 3 |
| News | BUY 0.70, STRONG_BUY 0.55, BUY 0.80 | 0.350, 0.550, 0.400 | 0.433 | 3 of 3 |
| Technical | STRONG_BUY 0.80, BUY 0.75, STRONG_BUY 0.70 | 0.800, 0.375, 0.700 | 0.625 | 3 of 3 |

- C = (0.192 + 0.458 + 0.208 + 0.433 + 0.625) / 5 = **0.383**.
- A = (0.667 + 1 + 0.667 + 1 + 1) / 5 = **0.867**.
- The bootstrap with seed `MSFT:2026-10-16` gives an 80% interval of **[0.288, 0.475]**.
- C ≥ 0.1, A ≥ 0.5, and 0.288 > 0, so the draft is **BUY**, with conviction 0.383 × 0.867 = **0.332**.

Every figure is well clear of its threshold, so moving any of them by 0.05 leaves the draft a BUY, and the result is not ambiguous.
Had C been 0.13, moving it down by 0.05 would make the draft NO_ACTION, so each specialist would be sampled twice more before the draft is final.
The Arbiter then confirms the BUY or downgrades it to NO_ACTION.

## Time stops

Every decision gets a time stop: the trading date by which the position is reviewed if no other exit fires.
It is computed in code, never by a model ([`run/analysis.jac`](https://github.com/jere67/parallax/blob/main/run/analysis.jac)):

1. Take the valid votes that point the way of the draft (positive for BUY or ADD, negative for SELL or TRIM), or all valid votes when the draft has no direction or none point that way.
2. Take the lower median of their `horizon_days`, at least 1.
   With no votes, use 10.
3. Count that many trading sessions after the run date on the market calendar, continuing on weekdays past the calendar's end.

## What is stored

Each ticker's valid votes are stored as `VoteRecord` nodes, its consensus as a `ConsensusResult` (C, A, the interval, the draft, each specialist's mean and weight, and samples used and dropped), and its final `Decision`.
Dropped samples are listed in the coverage's `analysis_errors`.
All of them appear on the [decision trail](/api/get-decision-trail).

::: info Where the code differs from the TDD
The TDD describes weights based on each specialist's track record; the core build uses equal weights, and track-record weights remain a stretch goal, as the TDD itself notes.
The TDD's decision table lists the held-stock HOLD band as -0.25 < C < 0.2; the code reaches the same result by checking SELL first.
See [TDD §7](/design/tdd#aggregation).
:::
