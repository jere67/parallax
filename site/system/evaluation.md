---
title: Evaluation
description: How the evening review turns the stored runs, votes, and marks into the forward test's scorecard, and how to read its intervals.
related:
  - { text: The forward test, link: /guide/forward-test }
  - { text: Vote scoring, link: /system/scoring }
  - { text: Insights and baselines, link: /system/insights-baselines }
---

The forward test asks one question: does the full system beat simpler portfolios, and how sure can the team be?
The evaluation answers it from what the graph already holds: the daily marks of the portfolio and its two baselines, the scored votes and decisions, and each run's scored screen.
It reads no prices and calls no model, so the evening review rebuilds it after every close.
The code lives in [`analysis/evaluation.jac`](https://github.com/jere67/parallax/blob/main/analysis/evaluation.jac), and the stored shape in [`models/evaluation.jac`](https://github.com/jere67/parallax/blob/main/models/evaluation.jac).

## When it runs

The trading tick's evening steps run 30 minutes after the close on a day with a run ([The trading day](/system/trading-day#the-trading-tick)).
After scoring votes, decisions, and screens and marking the baselines, it computes the evaluation and stores it as the portfolio's single `EvaluationRecord`, replacing the one before.
The Results page (`/app/results`) and the final report read that record, so neither recomputes anything.

## What it measures

The metrics follow [TDD §13](/design/tdd#metrics).

| Figure | How it is computed |
|---|---|
| Total return, Sharpe, max drawdown | From each portfolio's daily closing marks since the start, against its starting cash. Sharpe is annualized over 252 sessions with no risk-free rate. |
| Excess return against a baseline | The system's total return minus the baseline's, over the sessions both marked. |
| Sharpe difference | The system's Sharpe minus the baseline's, over the same sessions. |
| Screen spread | Each run's shortlisted names against every other S&P 500 member that day, both as ten-session excess returns over SPY, averaged over runs. |
| Specialist calibration | Each specialist's mean stated confidence against its hit rate on scored BUY and SELL votes. The target is a gap within 10 percentage points. |
| Arbiter value | The ten-session excess return of buys the Arbiter downgraded, had they been taken, beside the buys it confirmed. |
| Reliability | Sessions with a run that finished (normally or in fallback) with a decision for every covered ticker, out of all trading sessions since the start. |
| Operations | Risk-gate bypasses, each run's time from preflight to its decisions, and free-model requests per run and on the busiest day. |

Run time stops at the decisions, not the orders, because orders wait for 9:45 a.m. by design; time to orders would measure the clock rather than the run.

## How to read the intervals

Every figure with an interval shows a 95% range, and a verdict only when the range leaves out zero.

- **Comparisons** resample the paired daily returns in moving blocks of 5 sessions, 2,000 times, since good and bad days cluster. Resampling single days would make the range look narrower than it is.
- **The screen's spread** resamples runs in the same blocks, since neighboring runs' ten-session windows overlap.
- **The Arbiter's trades** resample one trade at a time.
- **Hit rates** use the Wilson interval, which stays inside 0 and 1 even for a handful of votes.

With fewer than 5 observations there is no interval, and the page says so.
Every resample uses the same seed, so the same data always gives the same ranges.

A verdict of **Not clear yet** is the expected result for weeks.
A month of daily returns rarely separates two portfolios that both hold large US stocks; the range narrows roughly with the square root of the number of sessions.

## The final report

[`analysis/final_report.jac`](https://github.com/jere67/parallax/blob/main/analysis/final_report.jac) builds `docs/evaluation/report.md` from three inputs: the stored evaluation and equity curves, read from a running server as the admin, the screen backtest (`docs/evaluation/backtest.json`), and the LLM replay (`docs/evaluation/llm-replay.json`).
It answers first, then shows each part with its intervals, and draws its figures as SVG files in `docs/evaluation/figures/`.

```sh
ADMIN_PASSWORD=... PARALLAX_FINAL_REPORT=1 jac run --no-takeover analysis/final_report.jac
```

`REPORT_URL` names the server (default `http://localhost:8100`).
The fetched data is saved as `docs/evaluation/forward-test.json`, so `REPORT_OFFLINE=1` rebuilds the report from the saved files without a server.
A missing input leaves its section saying so rather than failing.
