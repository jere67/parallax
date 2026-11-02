---
title: Universe screen
description: How about 500 S&P 500 stocks become a shortlist of 15 each morning, with no model calls.
related:
  - { text: Data sources, link: /system/data-sources }
  - { text: Research pass, link: /system/research }
  - { text: Run Guard, link: /system/run-guard }
---

The screen decides where the agents spend their attention, not what to buy.
It is plain, deterministic code: the same inputs always give the same shortlist, and it makes no model calls.
Each morning it drops illiquid and untradable stocks, scores the rest on momentum, volume, news, and earnings, and takes the top 15 with at most three per sector.
Every open position is then added, so the system always reconsiders what it holds.

The screen lives in [`research/screener.jac`](https://github.com/jere67/parallax/blob/main/research/screener.jac) and is versioned by `SCREEN_VERSION` (currently `2026-10-08.1`), which every run records with its model versions.

## The steps

<Steps>

1. **Load the constituents.**
   The current S&P 500 members, with GICS sector and SEC company number (CIK), come from the Wikipedia constituents table.
   The table is cached for 7 days.

2. **Check tradability.**
   Alpaca's asset list marks each symbol tradable or not.
   An untradable symbol is excluded with the reason `not tradable on Alpaca`.

3. **Read one year of daily bars.**
   Bars run to the last session before the run date, so the screen uses only closed prices.
   The indicators below are computed from them in code.

4. **Filter for liquidity.**
   A stock needs at least 20 sessions of history and a 20-day average dollar volume of at least $50 million.

5. **Score.**
   Each remaining stock gets the composite score described below.

6. **Diversify.**
   The highest scores are taken in order, with at most 3 per GICS sector and one share class per company, until 15 are picked.

7. **Add open positions.**
   Every held stock not already picked is appended with the note `open position: exits are always evaluated`.

</Steps>

## The composite score

Each stock's score is a weighted sum of cross-sectional z-scores over the liquid universe:

```text
S = w1 z(mom20) + w2 z(mom60) + w3 z(rvol5) + w4 z(news3) + w5 [earnings within 5 sessions] - w6 z(vol20)
```

| Term | Meaning | Weight |
| --- | --- | --- |
| `momentum_20` | Return over the last 20 sessions: close / close 20 sessions ago - 1 | +1 |
| `momentum_60` | Return over the last 60 sessions | +1 |
| `rvol_5` | Mean volume of the last 5 sessions over the mean of the last 60 | +1 |
| `news_3` | Number of Benzinga articles over the 3 sessions before the run date | +1 |
| `earnings_soon` | 1 when Finnhub lists an earnings release in the 5 sessions from the run date, else 0 | +1 |
| `vol_20` | 20-day realized volatility: the sample standard deviation of daily log returns, times √252 | -1 |

The weights start equal, as the design proposed (GAP-03), and are meant to be tuned on history and frozen before the forward test.

### How z-scores are computed

A z-score says how many standard deviations a stock sits from the universe mean on one feature.
The screen uses the population standard deviation (`statistics.pstdev`).
A stock with a missing feature scores 0 on it, which is the universe mean.
A feature with fewer than 2 values, or no spread at all, scores 0 for every stock.

::: tip Why the score is unclipped
The z-scores are not clipped.
On the first live screen, on October 8, 2026, one name's news term reached 10.8 and another's relative-volume term 10.1, so the earnings flag (worth 1) never changed a pick.
The design document records this and proposes comparing clipping at ±3 or log-scaling counts when the weights are tuned.
:::

### A worked example

Suppose the liquid universe has a mean 20-day momentum of 2% with a population deviation of 4%.
A stock up 10% over 20 sessions has `z(mom20) = (0.10 - 0.02) / 0.04 = 2.0`, and contributes +2.0 to its score.
If its 20-day volatility is one deviation above the universe mean, that term subtracts 1.0.
With a release due in 3 sessions, the earnings flag adds 1.0.
Ties are broken by symbol, so the order is always total.

## Diversification rules

The picker walks the scored list from the top:

- A stock whose company already has a picked share class is skipped, with the reason `another share class of the same company, X, scored higher`.
  Share classes are matched by SEC company number, so GOOG and GOOGL are one company.
- A stock whose sector already has 3 picks is passed over.
- The walk stops at 15 picks.

Open positions are appended after the walk, outside the sector limit, so a held stock is always researched even when its sector is full.

## Configuration

`ScreenConfig` holds every setting:

| Setting | Value | Meaning |
| --- | --- | --- |
| `shortlist_size` | 15 | Picks from the score (10 in reduced mode) |
| `per_sector` | 3 | Picks per GICS sector |
| `min_dollar_volume` | $50,000,000 | 20-day average dollar volume floor (proposal GAP-02) |
| `max_wildcards` | 3 | Wildcard tickers a run may add |
| `earnings_sessions` | 5 | Sessions ahead for the earnings flag |
| `news_sessions` | 3 | Sessions back for the article count |

In reduced mode, when fewer than 500 model requests are left for the day, the [Run Guard](/system/run-guard) shrinks the shortlist to 10.

## Failure handling

The screen never fails because one optional source is down:

- If the news counts are unavailable, the news term is 0 for every name and the run records the gap.
- If the earnings calendar is unavailable, no name gets the earnings flag, and the gap is recorded.
- If the market calendar around the run date has too few sessions, the screen raises an error, since it cannot tell which bars are closed.

Every excluded stock keeps its reason in `Shortlist.excluded`, and every scored stock keeps each weighted term in `ScoreRow.terms`.

## Wildcards

`add_wildcards` appends up to 3 extra tickers, each with a required reason.
A wildcard already on the shortlist, or one without a reason, is refused with an explanation.

::: info Where the code differs from the TDD
The TDD's step 8 lets the Orchestrator add up to three wildcard tickers from the macro brief or breaking news.
`add_wildcards` exists and is tested, but nothing in the morning run calls it, and the Orchestrator has no wildcard tool, so a live run covers only the screen's picks and the open positions.
The TDD also plans to measure the screen's own hit rate (shortlisted names' next-10-day return against the rest of the index); no module computes it yet.
See [TDD §5](/design/tdd#_5-universe-selection-s-p-500-screen).
:::
