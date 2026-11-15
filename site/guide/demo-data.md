---
title: Demo data
description: Fill the dashboard with a few weeks of simulated sessions, made by the project's own consensus, sizing, risk gate, and scoring code.
related:
  - { text: Reading the dashboard, link: /guide/dashboard }
  - { text: Dashboard internals, link: /system/dashboard }
---

Before the forward test stores real runs, the dashboard has nothing to show.
Demo mode fills an empty team portfolio with a few weeks of simulated trading, so you can build and check every page against realistic history.

```bash
TRADING_AGENT_DEMO=1 TRADING_AGENT_DISABLE_ORDERS=1 jac run --dev main.jac
```

Within a minute, every page shows a "Demo data" banner.

## What is real and what is made up

The inputs are invented; the machinery is not.

Made up:

- A 14-stock universe and SPY, with prices from a seeded random walk (SPY starts at 575).
- The research reports and the specialists' votes, from templates.
- Fills: orders fill at each session's open, stops fire on its low, and the portfolio is marked at its close.

The project's own code:

- The [stochastic consensus](/system/consensus) and the decision rule turn the votes into draft actions.
- [Position sizing](/system/sizing) and the [risk gate](/system/risk-gate) turn decisions into orders.
- The two [baselines](/system/insights-baselines) are simulated by the same code as in the forward test.
- [Vote scoring](/system/scoring) scores every vote against SPY.

So the numbers on a demo dashboard behave like real ones: positions respect the caps, stops sit at twice the ATR, and the baselines move with SPY.

The screener and stock pages show an invented market of about 70 well-known names.
Their prices, figures, ratings, and dates are all made up, are never written to disk, and cost no source calls.

## What the job writes

A scheduled job, `demo_job`, runs every minute and does nothing unless `TRADING_AGENT_DEMO` is `1`.
When it is set, the job:

<Steps>

1. **Checks that the portfolio is empty.**
   If the team portfolio already has demo history, or any run, mark, or baseline, it writes nothing.

2. **Simulates the history.**
   A seeded random generator (seed 449, so every server gets the same history) plays 30 warm-up sessions and then 23 recorded sessions, ending on the weekday before today.
   The portfolio starts with $100,000, a shortlist of 6, and 3 samples per specialist.

3. **Includes one bad day.**
   Session 9 is a FALLBACK run, so the dashboard's fallback styling has something to show.

4. **Marks the portfolio as a demo.**
   It sets `demo` on the team portfolio, switches it to auto mode, and creates both baselines.
   Votes are scored at the end.

</Steps>

## What never touches a demo portfolio

The Run Guard, the trading tick, and the manual run all skip a portfolio with `demo` set.
So a demo portfolio is never run, traded, reconciled, or scored by the scheduled jobs.

## The demo account

Every server, deployed or not, also has a shared account named `demo`, with no password, for visitors who have no API keys.
Press **Browse the demo** on the front page, open `/demo`, or log in as `demo` with the password left empty.

It shows the same simulated history, written into a portfolio of its own named `demo`, so the team's portfolio and every other agent are never touched.
On a server in demo mode it shows the team's demo history instead, since that is already made up.

It can look at every page but change nothing: its keys, paper trading, runs, asset classes, policy saves, the policy assistant, and reports are all refused.
On the Policy page it can still try a draft and see what it would have done.
Everyone who browses shares the one account, so nothing it did would stay its own.

Two scheduled jobs set it up, a minute at a time:

- `demo_account_job` writes a record of the demo account on `root.shared`, then makes the `demo` user with a random password no one is told, and records its ids.
  The `open_demo` endpoint hands out a sign-in token for that user instead of a password.
  If someone signed up as `demo` before the record was written, that account is left alone and the demo sign-in stays off; the server log says so.
- `demo_history_job` simulates the history once, outside demo mode, ending on the weekday before the day it runs.

::: danger Never on a deployed server
Never set `TRADING_AGENT_DEMO` on a deployed server.
It would fill the team portfolio with made-up history, and the scheduled jobs never run or trade a demo portfolio, so the real forward test could not use it.
:::
