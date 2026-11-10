# Decision replay: why six more runs bought nothing

Run on November 10, 2026, by `tests/spikes/decision_replay.jac` on exports of the live runs (`tests/spikes/export_runs.py`).
It makes no model or network requests.

## What happened

After the [decision backtest](2026-11-04-decision-backtest.md) lowered the buy bar to C ≥ 0.2 and A ≥ 0.5, still with the 90% interval above zero, the live runs kept buying nothing.
Four team runs (November 4, 5, 6, and 9) and the first two runs of a user's own agent (November 9 and 10) decided 90 tickers, and none was a buy.
The panel now forms graded views, as the backtest hoped, but the best scores sit between 0.10 and 0.15, short of 0.2.

## Answer

**C ≥ 0.1 with an 80% interval above zero is the new default bar.**
Over the same six runs, it drafts six buys for the Arbiter to review instead of one.
A ≥ 0.5 is unchanged, and so is every risk gate rule.

An 80% interval whose low end is above zero still means the bootstrap puts C above zero with 90% confidence, since only the low tail counts.
The 90% interval asked for 95%.

## Method

Each run's stored votes go through `replay_picks` (`tests/spikes/decision_backtest.jac`), the consensus engine with no Arbiter.
A buy here is the draft the Arbiter would have reviewed.
The grid is every pair of interval coverage (90%, 80%, 68%, 50%) and score bar (0.2, 0.15, 0.1).
Agreement stays at 0.5: in the November 4 backtest it did not bind anywhere between 0.4 and 0.6.

## Results

Draft buys over the six runs:

| Interval | C ≥ 0.2 | C ≥ 0.15 | C ≥ 0.1 |
| --- | --- | --- | --- |
| 90% | 1 | 1 | 2 |
| 80% | 1 | 1 | 6 |
| 68% | 1 | 1 | 7 |
| 50% | 1 | 1 | 10 |

The score bar binds first: no ticker but PFE reached 0.15.
At C ≥ 0.1 the interval binds next, passing two tickers at 90% and six at 80%.
68% adds one more and 50% four more, all with an interval low end within 0.05 of zero.

The six draft buys at C ≥ 0.1 and 80%:

| Run | Ticker | C | A | 80% low | 90% low | The run decided |
| --- | --- | --- | --- | --- | --- | --- |
| Team, November 6 | PFE | +0.20 | 0.76 | +0.13 | +0.08 | NO_ACTION |
| Team, November 9 | BDX | +0.13 | 0.67 | +0.01 | −0.06 | NO_ACTION |
| Agent, November 9 | AMZN | +0.11 | 0.53 | +0.01 | below 0 | NO_ACTION |
| Agent, November 9 | KDP | +0.15 | 0.67 | +0.04 | below 0 | NO_ACTION |
| Agent, November 10 | AMZN | +0.14 | 0.60 | +0.01 | below 0 | NO_ACTION |
| Agent, November 10 | EW | +0.15 | 0.50 | +0.07 | +0.05 | NO_ACTION |

PFE was the one buy under the old bar, and the Arbiter downgraded it: "Consensus is only weakly positive (+0.204) and is contradicted by negative fundamentals".
The Arbiter will review every new draft the same way, so it can still turn any of these down.

## Limits

- **Few runs.**
  Six runs, two of them on one agent's first days, are enough to show the bar never fires, not to tune it.
  All thresholds are still retuned as the forward test adds history.
- **No P&L.**
  This replay counts drafts and trades nothing; the forward test, with its SPY and equal-weight baselines, is where returns show.
- **Small positions.**
  Conviction is |C| × A, about 0.06 to 0.15 for these drafts, so sizing (`sizing_scale` 0.08, volatility-adjusted) gives well under 1% of equity per position.
  A policy can raise `sizing_scale` to 0.15.
- **Held stocks change too.**
  A held stock with C between 0.1 and 0.2 used to hold, or trim when A was below 0.5.
  Now it adds when A ≥ 0.5 and the interval is above zero, and otherwise stays unchanged.

## Consequences for the design

- **BUY needs C ≥ 0.1 and A ≥ 0.5, with the 80% interval above zero** (`ConsensusConfig` and `Policy` defaults, `CONSENSUS_VERSION` 2026-11-10).
  A saved policy keeps its own score bar; no policy was saved on the live server, so both agents take the new default.
- **The Arbiter, decision trail, and docs say 80%.**
- **Rerun this replay** after any change to a prompt or the consensus rule:
  export with `tests/spikes/export_runs.py` (`EXPORT_PORTFOLIO=agent` for a user's agent), then run `TRADING_AGENT_RUN_REPLAY=1 REPLAY_RUNS=<exports> jac run --no-takeover tests/spikes/decision_replay.jac`.
