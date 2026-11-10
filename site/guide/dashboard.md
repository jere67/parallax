---
title: Reading the dashboard
description: What the Portfolio, News, Runs, Decision trail, Screener, and stock pages show, and how to follow one decision from research to order.
related:
  - { text: Dashboard internals, link: /system/dashboard }
  - { text: get_decision_trail, link: /api/get-decision-trail }
  - { text: Market data, link: /system/market-data }
---

The dashboard needs an account and shows the signed-in user's own agent.
A visitor who is not signed in is sent to `/login?next=<path>` and comes back to that page after logging in.
The landing page at `/` is the only public page.

The pages below show the portfolio, the research, runs, and decision trails, and every ticker on them links to the decision trail that explains it.
The Screener and stock pages cover the whole market, whether or not your agent has looked at a stock.
The Policy and Reports pages have their own guides, and Settings is described in [Your agent](/guide/your-agent).
The admin account sees the team agent's portfolio instead of its own.
On a server in demo mode, every account sees the same demo history.

| Path | Page |
| --- | --- |
| `/app` | Portfolio |
| `/app/news` | News, the research feed |
| `/app/news/:day/:ticker/:desk/:n` | News, with one note open |
| `/app/runs` | Runs, showing the newest run |
| `/app/runs/:day` | Runs, showing the run on a trading date |
| `/app/runs/:day/:ticker` | Decision trail for one ticker on one day |
| `/app/screener` | Screener |
| `/app/stocks/:symbol` | A stock's page |
| `/app/stocks/:symbol/:tab` | One section of a stock's page |
| `/app/policy` | [Your policy](/guide/policies) |
| `/app/reports` | On-demand reports |
| `/app/settings` | [Your agent](/guide/your-agent): keys, paper trading, and the password |

The old addresses `/news...`, `/runs...`, `/policy`, `/reports`, `/screener`, and `/stocks...` redirect to `/app/...` once you are signed in.

The header shows when the portfolio was last marked, a **Paper** badge, the portfolio's mode (insight or auto), and the theme switch.
The dark theme is the default until you pick light.
The footer repeats the disclaimer: the project trades simulated money, and nothing on it is investment advice.

## Portfolio

The Portfolio page answers one question: how is the agent doing against the market?
Until the agent's paper trading starts (the [forward test](/guide/forward-test) for the team agent), it says so and shows what the agent's next step is.

### Return since start

The large figure is the portfolio's equity, with the day's change beside it.
The chart plots the cumulative return of three series from the start date:

| Series | What it is |
| --- | --- |
| Your agent | The real paper account. |
| Equal-weight shortlist | The same daily shortlist, sized and gated the same way, without the agents' votes. |
| SPY buy-and-hold | The whole starting balance in SPY on day one. |

Below the chart, six figures:

| Figure | Meaning |
| --- | --- |
| Total return | Equity against the starting balance. |
| Against SPY | Total return minus SPY buy-and-hold's. |
| Drawdown | The fall from the highest equity so far. New buys halt at 10%. |
| Gross exposure | The value of all positions as a share of equity. The cap is 90%. |
| Open P&L | Unrealized profit and loss of open positions. |
| Cash | Cash in the account. |

### Performance

A table compares the three series by total return, Sharpe ratio, maximum drawdown, and annualized volatility.
Sharpe here is the mean daily return over its standard deviation, times the square root of 252, with no risk-free rate.

A ledger check under the table counts **bypasses** (broker orders the system did not place) and **drift** (quantity differences between the ledger and the broker) found by the nightly [reconciliation](/system/execution#reconciliation).
Both should be zero.

### Sector exposure

Bars show each sector's share of equity, with a marker at the 30% sector cap.

### Positions and activity

The open positions table lists each holding with its quantity, entry price, last price, weight, profit and loss, and stop.
Open a row to read the thesis the position was opened on, with a link to its decision trail.

The Activity panel has two tabs: recent **Orders** with their fills, and **Closed trades** with realized profit and loss.

## News

The News page answers: what did the research desks find?
It lists every note from your agent's morning runs and the reports you asked for, newest first, one line per note.

| Column | Shows |
| --- | --- |
| Time | When the note was written, in New York time |
| Ticker | The stock, or **Market** for the macro desk's brief |
| Headline | The note's first clause, or the Orchestrator's question for a follow-up |
| View | The desk's stance and confidence |
| Desk | Market, fundamentals, news, or macro, and how many sources it read |

Headlines are cut from what the desk wrote, with no model rewriting them.
The note's first sentence or clause becomes the headline, and the story continues from there.

### Filtering

The bar above the feed filters by desk, ticker, view, and date, and searches the words of each note and its sources.
**Holdings** keeps only the tickers your agent holds now.
Filters live in the page's address, so a filtered feed can be bookmarked or shared.

### Reading a story

Pick a line to read its note, with its sources, the risks the desk named, and any data it could not get.
Each source shows its publication date and the claims the desk took from it.
Sources that are API addresses needing the project's keys are named but not linked.

A callout shows the panel's decision on that ticker that morning and links to its [decision trail](#decision-trail).
A note a signed-in reader asked for is marked **Requested**, and has no decision behind it.

On a wide screen the story sits beside the feed, and the newest one opens by itself.
On a phone it opens over the feed, and going back returns to the same place.

## Runs

The Runs page is one morning run.
The header shows the date, the run's status, a **Reduced mode** badge when the request budget was low, the Orchestrator's summary, and links to the previous and next runs.

| Status | Meaning |
| --- | --- |
| <Pill tone="up">normal</Pill> | The Orchestrator finished and submitted every decision in time. |
| <Pill tone="warn">fallback</Pill> | The Run Guard finished the run: some tickers were forced to HOLD. |
| <Pill>skipped</Pill> | Not a trading day. |
| <Pill tone="down">failed</Pill> | Data collection failed; every open position was held. |
| <Pill tone="accent">running</Pill> | The run is in progress. |

### Facts

A strip of facts: how many tickers were covered and how many came from the screen, the risk gate's note, when analysis ran, when orders were executed and the books reconciled, and how many model calls and tokens the run used.

### Shortlist

The main table has one row per covered ticker, sorted by conviction.
Filter it by All, Buys, Sells, or Holds.

| Column | Meaning |
| --- | --- |
| Decision | The final action, with a note when the Arbiter cut it or the Run Guard forced a hold. |
| Conviction | How strong the decision is, from 0 to 1. |
| Consensus | The consensus score on a scale from -1 to +1, with its 80% interval drawn as a bar. |
| Agreement | The share of specialists that agree with the consensus's direction. |
| Risk gate | Approved, resized, or rejected, and by which rule. |
| Order | The order's side, quantity, and status. |

Click a row to open its decision trail.

### Market

The market panel shows the macro agent's regime call, SPY's close, its 200-day average, its 20-day volatility, the summary, and the risks it flagged.

The page also lists every run and the run's action log, the trading tick's line-by-line record of what it did.

## Decision trail

The decision trail answers: why did the system do this, for this stock, on this day?
It follows the decision through six stages, and a strip at the top links to each one.

<Steps>

1. **Research.**
   One row per research report (market, fundamentals, news, macro), with its view, confidence, follow-up question, risks, data gaps, and the sources it cited.
   Fetch errors are called out at the top.

2. **Panel.**
   One dot plot per specialist, showing each sample's signed score and their mean.
   Expand a specialist to read each sample's stance, confidence, horizon, rationale, cited sources, and, once scored, whether it beat SPY.

3. **Consensus.**
   The consensus score with its interval, agreement, samples used and dropped, and the draft action.

4. **Arbiter.**
   The Arbiter's verdict, the reason for a downgrade or a forced hold, the key risks, the exit condition, and the time stop.

5. **Risk gate.**
   The order the gate was asked for, the shares it approved, the price, the stop distance, and every rule with pass or fail and the quantity before and after.

6. **Orders.**
   The orders sent, with their fills.
   In insight mode: "this decision was published as a card, not traded."

</Steps>

A side column shows the ticker's facts (last close, ATR, volatility, volume, days to earnings, why it was covered, its screen score), the position if one is open, and the market backdrop.
Arrows step to the previous or next ticker of the same run.

## Screener

The screener lists every U.S.-listed stock, biggest first.

- **Filters.** Each pill opens a card with presets, typed bounds, or a list of words, and **Filter** adds any other field. Filters all have to hold, and a stock missing a figure does not match it.
- **Tabs.** Each tab is a set of columns: Overview, Performance, Technicals, Extended hours, Forecasts, Valuation, Dividends, Profitability, Income statement, Balance sheet, Cash flow, and Per share. The column button changes them.
- **Sorting.** A column head sorts by it, and again the other way. A missing figure stays last.
- **The address holds the screen.** A screen survives a reload and can be sent to someone, and the browser's back and forward buttons undo and redo a change.
- **Watchlist and saved screens.** The star and **Save screen** keep your choices in this browser.

Prices are delayed about 15 minutes during a session.
The note under the table says how much of the market each sweep has reached so far, since a new server takes hours to read every company.

## Stock page

A stock's page opens from any ticker in the screener.
Its header shows the price, the day's change, the market's phase, any extended-hours price, and, when your agent has looked at the stock, its last decision with a link to the trail.

| Tab | Shows |
| --- | --- |
| Overview | The price chart, peers, key figures, the day's trading, earnings, ratings, the company, its financials, headlines, and filings |
| Financials | Revenue and profit by year or quarter, revenue down to profit, debt and cash, and returns and ratios |
| Technicals | The rating, each indicator's value and vote, and performance over six periods |
| Forecasts | The analyst consensus now and by month, and earnings against the consensus |
| Seasonals | Returns by month and year since 2016 |
| News | Recent headlines, linking to their sources |
| Filings | Recent SEC filings, linking to EDGAR |

Each button under the chart is a range, with that range's change on it.
**Add** on a peer draws it on the chart, up to three, which turns the chart into percent change from the range's start so stocks at different prices share one axis.

The market pages are not advice, and your agent's decisions rest on its own research, not on these ratings.
