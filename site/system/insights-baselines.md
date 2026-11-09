---
title: Insights and baselines
description: The insight card every decision publishes, and the two simulated portfolios the team portfolio is measured against.
related:
  - { text: The forward test, link: /guide/forward-test }
  - { text: get_performance, link: /api/get-performance }
  - { text: Execution, link: /system/execution }
---

Every decision is published twice over: as orders when the portfolio trades, and always as an insight card a reader can follow.
To tell whether the agents add anything, the team portfolio is measured against two portfolios simulated from daily bars: one that buys whatever the screen picks, and one that simply holds SPY.
Neither the cards nor the baselines make a model request.

## Insight cards

An insight card is a decision as a reader sees it, rendered from what the run stored ([`action/insights.jac`](https://github.com/jere67/parallax/blob/main/action/insights.jac)).
The morning run publishes one card for each covered ticker when it finishes, in both modes: in auto mode the card sits beside the orders, and in insight mode it is the run's only output.
Publishing is idempotent; a second call returns the card already published.

| Field | Content |
| --- | --- |
| `ticker`, `action`, `conviction` | The final decision |
| `run_date`, `mode`, `published_at` | When and in which mode it was published |
| `thesis`, `risks`, `exit_condition`, `time_stop` | The Arbiter's text (the first two risks) and the time stop computed in code |
| `score`, `agreement`, `ci_low`, `ci_high` | The consensus C, A, and its 90% interval, when the panel ran |
| `specialists` | Each specialist's stances and confidences in sample order, and its mean signed score |
| `sources` | Up to 8 distinct sources the research cited: market first, then fundamentals, news, and macro, each with a label of up to 160 characters, URL, publish time, and host |
| `note` | Why the decision was forced to HOLD, or why the Arbiter downgraded it |
| `disclaimer` | The project's disclaimer, below |

The disclaimer on every card reads:

> An educational student project trading simulated money. Nothing here is investment advice, and past simulated performance does not predict future results.

## The forward test

The forward test runs three portfolios from the same day with the same starting balance:

| Portfolio | What it isolates | Where it trades |
| --- | --- | --- |
| Your agent (the team portfolio for the admin) | The full system | The user's Alpaca paper account |
| Equal-weight shortlist | Whether the agents add value beyond the screen | Simulated from daily bars |
| SPY buy-and-hold | The market | Simulated from daily bars |

For the admin's team agent, the test starts when `TRADING_AGENT_FORWARD_TEST_START` is set to a trading date, at the first trading tick on or after that date before the day's run executes.
The paper account must be flat, with no positions and no open orders.
Its equity becomes the starting balance of all three portfolios, the team portfolio switches to auto mode, and both baselines are created in cash.
See [The forward test](/guide/forward-test) for how to start it and [`action/baselines.jac`](https://github.com/jere67/parallax/blob/main/action/baselines.jac) for the code.

## Equal-weight shortlist

Every stock the morning screen shortlisted (not the open positions it carried) is a BUY at conviction 1, or an ADD when already held.
The orders go through the team's own [sizing](/system/sizing) and [risk gate](/system/risk-gate), so the only difference from the team portfolio is the agents' judgment.

| Rule | Simulation |
| --- | --- |
| Fills | At the session's open |
| Gate inputs | The open as price, a fresh trade, and the screen's ATR(14), 20-day volume, and sessions to earnings |
| Protective stop | The gate's stop distance below the fill; it fires when a session's low reaches it, filling at the stop or at a lower open |
| Time stop | 10 sessions after the buy, the default horizon; sold at that session's open |
| Renewal | A stock the screen picks again that morning has its time stop renewed instead of being sold |
| Mark | At each session's close |

## SPY buy-and-hold

The whole starting balance buys SPY, in whole shares, at the first session's open, and holds.
It stays outside the gate: a fully invested index is the benchmark, not a strategy.
It marks at each session's close.

## When the baselines move

A session is simulated only once its bars are final, after 8:15 p.m. New York time.
The evening trading tick, 30 minutes after the close, therefore simulates through the previous session, so the baselines run one session behind the team portfolio.
A missed evening is caught up at the next one.
Each simulated session appends lines to the baseline's trade log, which keeps the newest 2,000.

## How they are compared

[`get_performance`](/api/get-performance) returns one series per portfolio: the team portfolio, the equal-weight shortlist, and SPY buy-and-hold.
Each carries its daily marks and four statistics: total return against the starting balance, Sharpe (mean daily return over its standard deviation, times √252, with a risk-free rate of zero), maximum drawdown from the running peak, and annualized volatility.
The dashboard's Portfolio page charts all three as cumulative return.

::: info Where the code differs from the TDD
The code follows [TDD §8](/design/tdd#insight-mode) and [TDD §13](/design/tdd#layer-2-forward-paper-test-late-october-to-december-11).
The TDD's other metrics, such as Arbiter downgrade value and screen hit rate, are not computed by any module yet.
:::
