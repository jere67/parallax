# Screen backtest: the screen, sizing, and risk gate on 2016 to 2026

Run on November 11, 2026, by `tests/backtest/evaluate.jac` on history cached by `tests/backtest/fetch.jac`.
It makes no model requests, and the run itself makes no network requests.
The figures are in [backtest.json](backtest.json).

## Question

Does the morning screen pick stocks that beat the rest of the S&P 500, and would a different screen or protective stop do better?
This is the first layer of the evaluation in [TDD §13](../TDD.md#layer-1-historical-harness-october): the deterministic parts on full history, at no model cost.
The tuning was fixed in issue #195 before any result was seen.

## Answer

**Nothing is adopted: today's screen and the 2 ATR stop stay.**
V2 (log-scaled news and volume, every z-score clipped to ±3) had the best train spread, but on validation it did worse than today's screen.
A 3 ATR stop passed the rule's literal test, but under today's screen with the drawdown breaker off it did no better than 2 ATR.

**The screen shows no reliable edge.**
Over 10 sessions, today's picks trailed the rest of the index by 0.17% on train and led it by 0.19% on validation.
Both 95% intervals include zero, and every variant's do too.

**The drawdown breaker latched, so it now measures from a rolling peak.**
Measured from the all-time peak, once a portfolio is 10% down and has sold out, it can never buy again.
Under today's settings, the equal-weight shortlist was halted for 79% of validation: from late October 2023 on, and wholly in cash from November 24, 2023.
Measured from the highest close of the last 63 sessions instead (issue #215), it was halted for 0.1% of validation, and its validation Sharpe rose from 0.43 to 1.09, so the rolling peak is adopted in the live gate.

## Method

**Universe.**
Each morning's members come from Wikipedia's current S&P 500 list with its dated changes undone, so companies that left the index stay in the history.
Sectors come from yearly revisions of the same page, and CIKs from SEC's ticker list and those revisions.
726 symbols were members on some day; WLTW is the only one with no bars on Alpaca.

**Mornings.**
For each of 2,703 sessions from January 2016 to October 2026, the harness rebuilds what the screen would have seen at 7:30 a.m. New York time:

- the year of daily bars through the last session, through `summarize`, as the live screen computes them;
- Alpaca news from the third session before through 7:30 a.m. on the day;
- an earnings release in the five sessions from the day, read from 8-K Item 2.02 filing dates on SEC EDGAR;
- untradable when the stock has no bar on the last session.

`tests/backtest/harness_tests.jac` checks that a morning never reads a bar from its own day or later.

**Hit rate.**
A day's spread is the picks' mean 10-session excess return over SPY minus the other liquid scored members' mean.
It uses the votes' scoring window: from the last close before the day to the close of the tenth session counting the day.
The mean daily spread gets a moving-block bootstrap 95% interval (blocks of 10 sessions, 2,000 resamples, fixed seed).

**Portfolio.**
Each morning's picks go through `simulate_equal_weight` (`action/baselines.jac`), the forward test's equal-weight shortlist baseline: today's sizing, the full risk gate, fills at the open, stops, and the ten-session time stop.
Sharpe is computed as the dashboard does: mean daily return over its sample standard deviation, times √252.
Its interval is a block bootstrap of the daily Sharpe gap to SPY buy-and-hold.

**Tuning (pre-registered).**

- Train on 2016-01-04 to 2022-12-30, validate on 2023-01-03 to 2026-10-30.
- Screens: V0 today's; V1 every z clipped to ±3; V2 log(1 + x) of `news_3` and `rvol_5` before z, every z clipped; V3 V2 without news; V4 V2 without the volatility penalty.
- Stops: 1.5, 2, or 3 ATRs.
- The best train spread picks the screen; with it, the best train Sharpe picks the stop.
- Each is adopted only if, on validation, it is at least as good as today's setting by point estimate.

**One check added after the first run.**
The first full run showed the breaker latch, so a Sharpe gap between two stops mostly said when each portfolio latched.
Before running anything more, the stop rule gained a second condition: a new stop must also be at least as good as 2 ATR under today's screen on validation, both with the breaker as it is and with it off.
Today's screen is what would ship, since the screen was not adopted.
These runs are under `diagnostics` in the JSON.

**The breaker's release (pre-registered).**
Every run above measures the breaker from the all-time peak, as when the tuning was fixed.
Then, before any rolling run was seen, issue #215 registered a release: measure from the highest close of the last 63 sessions (about three months), with the same 10% halt.
It is adopted if, under the settings that ship (today's screen and stop, since neither change was adopted), its validation Sharpe is at least the all-time breaker's.
These runs are under `breaker` in the JSON, beside the same settings with the breaker off.

## Results

SPY buy-and-hold: Sharpe 0.68, 11.5% a year, and a 33.8% maximum drawdown on train; Sharpe 1.35, 20.8% a year, and an 18.7% drawdown on validation.

Hit-rate spread, mean per day over 10 sessions, with 95% intervals (V0 is today's screen):

| Screen | Train | Validation |
| --- | --- | --- |
| V0 | −0.17% (−0.40% to +0.07%) | +0.19% (−0.21% to +0.61%) |
| V1 | −0.13% (−0.37% to +0.13%) | +0.06% (−0.31% to +0.47%) |
| V2 | −0.10% (−0.35% to +0.16%) | +0.10% (−0.27% to +0.52%) |
| V3 | −0.16% (−0.42% to +0.10%) | −0.01% (−0.39% to +0.39%) |
| V4 | −0.12% (−0.36% to +0.15%) | +0.21% (−0.23% to +0.68%) |

V2 won train by 0.07 percentage points over V0 and lost validation by 0.09, both well inside the noise.

Equal-weight shortlist at a 2 ATR stop, with the share of sessions that ended at or below the breaker's line:

| Screen | Train Sharpe | Train halted | Validation Sharpe | Validation halted |
| --- | --- | --- | --- | --- |
| V0 | 0.64 | 41% | 0.43 | 79% |
| V1 | 0.77 | 8% | 0.75 | 4% |
| V2 | 0.72 | 5% | 0.12 | 81% |
| V3 | 0.54 | 0% | 0.73 | 0% |
| V4 | 0.41 | 58% | 0.02 | 79% |

No maximum drawdown exceeds 11.8%: a portfolio 10% down stops buying, its positions close out on their stops and time stops, and its equity then stays put.
On validation, the Sharpe ranking follows the halted share, not the spread: the three portfolios halted about 80% of the time have the three lowest Sharpes.

The stop, under V2 (the rule) and under today's screen (the added check):

| Setting | Validation Sharpe, breaker on | Validation Sharpe, breaker off |
| --- | --- | --- |
| V2, 1.5 ATR | 0.44 | 0.46 |
| V2, 2 ATR | 0.12 | 0.71 |
| V2, 3 ATR | 0.57 | 0.84 |
| V0, 2 ATR | 0.43 | 1.09 |
| V0, 3 ATR | 0.90 | 1.08 |

On train, V2 at 3 ATR had the best Sharpe (0.80 against 0.72 at 2 ATR and 0.74 at 1.5), and it beat 2 ATR on validation, so it passed the rule.
Under today's screen it beat 2 ATR only with the breaker on (0.90 against 0.43), because it latched later; with the breaker off it scored 1.08 against 1.09.
So the stop stays at 2 ATR.

With the breaker off, today's screen and stop returned 12.9% a year on validation at a Sharpe of 1.09, against SPY's 20.8% and 1.35.
No setting's Sharpe beat SPY's on validation; every interval of the gap is mostly or wholly below zero.

Today's screen at a 2 ATR stop, by how the breaker measures its peak (halted is the share of sessions that ended at or below the breaker's line):

| Breaker | Train Sharpe | Train a year | Train max drawdown | Train halted | Validation Sharpe | Validation a year | Validation max drawdown | Validation halted |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| All-time peak | 0.64 | 3.7% | 11.8% | 41% | 0.43 | 2.7% | 11.3% | 79% |
| Last 63 sessions | 0.67 | 5.9% | 17.4% | 6% | 1.09 | 12.9% | 11.7% | 0.1% |
| Off | 0.71 | 6.5% | 14.7% | 6% | 1.09 | 12.9% | 11.7% | 0.6% |

On validation the rolling breaker never bound long enough to change a trade, so it matched the breaker off.
On train it halted 6% of sessions, and its maximum drawdown was deeper than with the breaker off: it paused buying near lows, missed part of the rebounds, and later losses started from lower equity.
In this history the breaker, rolling or not, never cut risk beyond what the stops already do; the rolling peak keeps it from ending a portfolio's trading for good.

## What this means

- The screen narrows 500 names to 15 with no measurable edge over the rest at a 10-session horizon.
  The agents' job is to add the edge; the screen keeps them to liquid, active names.
  The forward test's equal-weight baseline will show the same.
- Measured from the all-time peak, the breaker turned any 10% drawdown into a permanent halt, in the live portfolios as well as the baselines.
  The gate now measures from the highest close of the last 63 sessions (`GateConfig.drawdown_window`, `breaker_peak` in `action/gate.jac`), so a bad stretch ages out after about three months.
  The breaker earned no risk reduction in this history, so it stays a backstop, not a source of return.
- The screen gained two options, `z_clip` and `log_terms` (`research/screener.jac`), off by default, so today's screen and `SCREEN_VERSION` are unchanged.

## Limits

- **Membership gaps.**
  Four dated changes could not be undone exactly (FLT, RE, SATS, UA.C), so those names miss some member days.
  0.23% of member-days had no sector and 0.17% no CIK.
- **Earnings proxy.**
  8-K Item 2.02 filings stand in for the earnings calendar; a filing usually comes the same day as the release, but not always.
- **A thinner news archive.**
  Alpaca's archive holds about 40,000 articles a year on these names for 2016 to 2019 and about 85,000 from 2022.
  The news term is a z-score across each morning's members, so this shifts every name together, but early mornings separate fewer names on news.
- **Fills.**
  Every fill is at the open with no slippage or commissions, and a delisted position is held at its last close until the time stop sells it.
- **Early 2016.**
  Alpaca's bars start on January 4, 2016, so the 60-session momentum term is missing until April 2016.
- **One path per setting.**
  The portfolio figures are a single path, which the breaker makes fragile; the spread is the steadier measure.

## Reproducing it

```sh
set -a && source .env && set +a
TRADING_AGENT_RUN_BACKTEST_FETCH=1 BACKTEST_CACHE=/path/to/cache jac run tests/backtest/fetch.jac
TRADING_AGENT_RUN_BACKTEST=1 BACKTEST_OFFLINE=1 BACKTEST_CACHE=/path/to/cache jac run --no-takeover tests/backtest/evaluate.jac
```

The fetch needs Alpaca keys and `SEC_USER_AGENT`, holds Alpaca to 120 requests a minute and SEC to 8 a second, and pauses from 7:15 to 10:00 a.m. New York time on weekdays, so it never competes with a morning run.
It took about two hours, most of it the news archive (716,558 articles).
The evaluation then takes 15 to 45 minutes and about 2.2 GB of memory from the cache.
