# Decision backtest: why three live runs bought nothing

Run on November 4, 2026, from 8:39 to 9:20 p.m. New York time, by `tests/spikes/decision_backtest.jac` on an export of the live runs (`tests/spikes/export_runs.py`).
It re-ran November 4's panel and Arbiter with 271 free-model requests, checking OpenRouter's count before each batch so that more than 620 stayed for the next morning run (729 did).

## What happened

The first three live runs on the paper account (November 2, 3, and 4) decided 45 tickers and bought none.
November 4 was a clean run: status `normal`, Nemotron 3.5 Super VL throughout, SEC filings collected.
Still, 211 of its 225 specialist samples were HOLD, Flow and Macro voted HOLD on every sample, and the best ticker reached C = 0.14 against a buy bar of 0.35.

Three things kept the panel at zero:

- **The prompt counted doubt twice.**
  It told specialists "with weak, stale, or mixed evidence, prefer HOLD and a lower confidence".
  A vote's score is already its stance times its confidence, so a weak lean was zeroed out instead of counting a little.
- **Missing data voted.**
  A Flow HOLD that cites only a data gap ("no insider data") scored 0 like any other HOLD and pulled C toward zero, though missing data is uncertainty, not a view.
- **The bar needed near-unanimity.**
  With Flow at 0, four BUY votes at confidence 0.7 give C = 0.28, short of 0.35.

## Answer

**With the new prompt and rule, November 4's panel forms graded views, and two tickers clear the bar: REGN and EL, both confirmed by the Arbiter.**
The specialist prompt now asks for a side whenever the evidence tilts, with confidence carrying the doubt, and HOLD only for balanced or directionless evidence.
A vote that cites only data gaps abstains from C, A, and the interval.
BUY needs C ≥ 0.2 and A ≥ 0.5 instead of 0.35 and 0.6, still with the 90% interval above zero, and every risk gate rule is unchanged.
The thresholds were chosen before the re-run, not fitted to it.

## Method

Three scenarios, each traded through the real sizing (`action/sizing.jac`) and risk gate (`action/gate.jac`) from $100,000 in cash:

- **live:** the decisions the runs made.
- **replay:** the runs' stored votes through the new rule, with no model requests and no Arbiter.
- **rerun:** the specialist panel and the Arbiter run again with the new prompt on November 4's stored research and macro brief, the same inputs the live run's panel read (`run/analysis.jac`, `analyze`).

A buy fills at the open of the first 5-minute bar at or after 9:45 a.m. New York on the run date, when the trading tick executes.
It takes the gate's protective stop (2 × ATR), exits at the stop if a 5-minute bar trades through it, and is otherwise marked at the latest close.
SPY over the same window is the benchmark.

## Results

| Scenario | Buys decided | Filled | P&L | Same dollars in SPY |
| --- | --- | --- | --- | --- |
| live (November 2 to 4) | 0 | 0 | $0 | $0 |
| replay, stored votes, new rule (November 2 to 4) | 1 (EL, November 2) | 0 (earnings blackout) | $0 | $0 |
| rerun, new prompt and rule (November 4) | 2 (REGN, EL) | 2 | −$27.13 | −$1.89 |

The new rule alone, on the stored votes, adds one buy, and the gate refuses it because EL reported earnings that day.
The prompt is what moves the panel.

### Stances on November 4, stored run → re-run

| Specialist | STRONG_BUY | BUY | HOLD | SELL | STRONG_SELL |
| --- | --- | --- | --- | --- | --- |
| Fundamentals | 2 → 2 | 4 → 14 | 39 → 11 | 0 → 23 | 0 → 1 |
| Technical | 0 → 0 | 6 → 29 | 39 → 13 | 0 → 9 | 0 → 0 |
| News | 0 → 0 | 0 → 32 | 43 → 7 | 2 → 12 | 0 → 0 |
| Macro | 0 → 0 | 0 → 20 | 45 → 9 | 0 → 22 | 0 → 0 |
| Flow | 0 → 0 | 0 → 14 | 45 → 11 | 0 → 26 | 0 → 0 |

HOLD fell from 94% to 20% of samples, and the panel leaned both ways: 111 buys against 93 sells.
The re-run drew 255 samples: 225, plus two more per specialist for the three tickers whose first result was ambiguous.

### Consensus on November 4, stored run → re-run

| Ticker | C | A | Interval low | Decision |
| --- | --- | --- | --- | --- |
| REGN | +0.07 → +0.25 | 0.20 → 0.84 | +0.14 | BUY |
| EL | 0.00 → +0.20 | 0.00 → 0.72 | +0.10 | BUY |
| MSFT | 0.00 → +0.14 | 0.00 → 0.67 | −0.04 | NO_ACTION |
| WST | +0.07 → +0.14 | 0.20 → 0.68 | −0.04 | NO_ACTION |
| GPN | 0.00 → +0.09 | 0.00 → 0.40 | +0.05 | NO_ACTION |
| AMZN | 0.00 → +0.04 | 0.00 → 0.40 | −0.13 | NO_ACTION |
| EG | +0.07 → +0.02 | 0.20 → 0.20 | −0.11 | NO_ACTION |
| NVDA | +0.14 → +0.02 | 0.20 → 0.33 | −0.26 | NO_ACTION |
| KDP | 0.00 → +0.02 | 0.00 → 0.40 | −0.17 | NO_ACTION |
| VLTO | 0.00 → −0.06 | 0.00 → 0.53 | −0.22 | NO_ACTION |
| MAR | 0.00 → −0.06 | 0.00 → 0.53 | −0.21 | NO_ACTION |
| MRNA | 0.00 → −0.08 | 0.00 → 0.47 | −0.23 | NO_ACTION |
| AAPL | 0.00 → −0.10 | 0.00 → 0.60 | −0.19 | NO_ACTION |
| GOOG | 0.00 → −0.16 | 0.00 → 0.73 | −0.30 | NO_ACTION |
| TSLA | −0.04 → −0.18 | 0.13 → 0.67 | −0.38 | NO_ACTION |

No ticker reached the old bar of C ≥ 0.35 even with graded votes; the highest was 0.25.
The agreement threshold did not bind anywhere between 0.4 and 0.6: the buy count was 1 at C ≥ 0.25 and 2 from C ≥ 0.2 down to 0.1, where the interval check held the rest back.

### The two trades, to the close of November 4

| Ticker | Shares | Fill at 9:45 | Stop | Close | Return | SPY |
| --- | --- | --- | --- | --- | --- | --- |
| EL | 9 | $110.89 | $103.18 | $112.20 | +1.18% | −0.14% |
| REGN | 1 | $975.91 | $919.73 | $936.99 | −3.99% | −0.05% |

One afternoon of two trades says nothing about edge, and this backtest is not evidence that the rule makes money.
It shows that the panel can now act, with the gate and the Arbiter still between a vote and an order.
P&L will come from the forward test, with the SPY and equal-weight baselines beside it.

## Limits

- **One re-run day.**
  November 2 and 3 were cast largely by the fallback model while the primary was gone, so November 4 is the only day whose stored votes and re-run share a model.
  A re-run of every day would cost about 270 requests each.
- **No point-in-time history.**
  The research is what the live runs collected; the collectors cannot rebuild an older day's inputs (TDD §7, 13F note), so there is no longer backtest to run.
- **Small positions.**
  Conviction is now 0.14 to 0.21 for a buy, so sizing (`scale` 0.08, volatility-adjusted) gives about 1% of equity per position.
  Whether to size up is a separate decision for TDD §8.
- **More sells to come.**
  The panel now leans both ways, so a held position meets its sell bar (C ≤ −0.25) or a trim (A below 0.5 under C 0.2) more often than before.
  The forward test should watch turnover against the gate's 25% daily limit.

## Consequences for the design

- **The specialist prompt asks for a side** (`agents/specialists.jac`), and **gap-only votes abstain** (`analysis/consensus.jac`, `abstains`).
- **BUY needs C ≥ 0.2 and A ≥ 0.5** (`ConsensusConfig`, `CONSENSUS_VERSION` 2026-11-04), retuned as the forward test adds history.
- **The decision trail marks an abstaining sample**, and a specialist whose samples all abstain shows "abstained" instead of a weight.
- **Rerun this backtest** after any change to a prompt, the consensus rule, or sizing:
  export with `tests/spikes/export_runs.py`, then run `TRADING_AGENT_RUN_SPIKE=1 BACKTEST_RUNS=<export> BACKTEST_RERUN=<days> BACKTEST_OUT=<file> jac run --no-takeover tests/spikes/decision_backtest.jac` with the keys exported.
