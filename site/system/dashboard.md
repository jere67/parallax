---
title: Dashboard internals
description: How the dashboard's views are built from the graph, cached, and refreshed, and how the client pages, formatting, and theme work.
related:
  - { text: Reading the dashboard, link: /guide/dashboard }
  - { text: API overview, link: /api/overview }
  - { text: Data model, link: /system/data-model }
---

The dashboard is a React client written in Jac, served by the same server as the agents.
Each page calls a public endpoint that returns one typed view, built from the graph and cached, so a page load never walks the whole graph.

## From graph to view

The endpoints in [`dashboard/api.jac`](https://github.com/jere67/parallax/blob/main/dashboard/api.jac) each return one view type from [`models/views.jac`](https://github.com/jere67/parallax/blob/main/models/views.jac).
The view types are the API's contract; see [Data types](/api/types).

| Endpoint | View | Built from |
| --- | --- | --- |
| [`get_portfolio`](/api/get-portfolio) | `PortfolioView` | The portfolio, its positions, its daily marks, recent orders, and closed positions. |
| [`get_performance`](/api/get-performance) | `PerformanceView` | The daily marks of the portfolio and both baselines. |
| [`list_runs`](/api/list-runs) | `list[RunSummary]` | Every run, newest first, at most 250. |
| [`get_run`](/api/get-run) | `RunView` | One run, its macro record, and a row per coverage. |
| [`get_decision_trail`](/api/get-decision-trail) | `TrailView` | One coverage and everything under it, plus the position it opened. |

### Conventions

- Money is in dollars, and returns are fractions (0.012 is 1.2%).
- Dates are New York `YYYY-MM-DD`, and timestamps are UTC ISO 8601.
- A missing figure is `null`, never 0, so the client can show a dash instead of a false zero.

### How the figures are computed

| Figure | Rule |
| --- | --- |
| Day P&L and return | Equity against the previous mark, or the starting balance on the first day. |
| Position value | An open position is valued at its last price. |
| Closed P&L | Realized from the fills of the position's sell orders between its open and close. |
| Drawdown | The fall from the running peak of equity. |
| Total return | Equity against the starting balance. |
| Volatility | Standard deviation of daily returns, times the square root of 252. |
| Sharpe ratio | Mean daily return over its standard deviation, times the square root of 252, with no risk-free rate, and only with at least two returns. |
| Trades in a run | Orders with a filled quantity above zero. |

Lists are capped: the portfolio view carries the 60 most recent orders and the 40 most recent closed positions.
A run's rows are sorted by conviction, highest first, then by ticker.
A trail's research is in domain order (market, fundamentals, news, macro), first reports before follow-ups, and each vote carries the sources it cited from its specialist's evidence packet.

## News feed

[`dashboard/news.jac`](https://github.com/jere67/parallax/blob/main/dashboard/news.jac) reads research records from the graph and turns each one into a feed line.
A note's address is `{day}/{ticker or "market"}/{desk}/{n}`, where `n` counts that desk's notes for the ticker that day, so a follow-up has `n` above 0.
A reader's report adds `/requested` to its address.

The records hold no headline, so the server cuts one from the summary.
The cut takes the first sentence, or its first clause when a colon, semicolon, or spaced dash leaves at least 24 characters, and it stops at about 200 characters.
Whatever the headline leaves out stays in the story's body, and a cut sentence keeps the whole summary as the body.

The whole feed is held as an in-memory index with each note's searchable text, so filtering and paging never touch the graph.
`get_news_feed` returns light lines, 50 to a page, and `get_news_story` returns one note in full.
A finished run's notes are read once and kept, since they never change, and a running one's are read at each rebuild.

## Read cache

The persistent graph loads about one node per query, so building a full view takes about 1,000 queries.
A small in-process cache keeps that off the page load.

| Setting | Value |
| --- | --- |
| Freshness | 120 seconds |
| Entries | 512 at most, oldest evicted first |
| Key | `<team portfolio id>:<kind>[:<arguments>]` |

A stale entry is rebuilt under one lock, after a second freshness check, so a burst of requests builds a view once.
The scheduled `refresh_job` rebuilds the portfolio, performance, the run list, and the newest run every minute, so those are always warm.
Runs for other dates and decision trails are built on first request and cached for 120 seconds.
The news index and each story follow the same rule, and `news_refresh_job` keeps the index warm.

## Client

The route table is in [`dashboard/App.jac`](https://github.com/jere67/parallax/blob/main/dashboard/App.jac).

| Path | Component |
| --- | --- |
| `/` | `PortfolioPage` |
| `/news`, `/news/:day/:ticker/:desk/:n` | `NewsPage` |
| `/runs`, `/runs/:day` | `RunPage` |
| `/runs/:day/:ticker` | `DecisionPage` |
| anything else | `NotFound` |

Every route sits inside `Layout`, which loads the portfolio once for the header's mark time, mode badge, and demo banner.

### Shared components

| Component | Use |
| --- | --- |
| `Panel`, `Overline`, `Stat`, `Delta`, `Field` | The ledger layout: hairline panels, small uppercase labels, figures. |
| `ActionBadge`, `StatusBadge` | Pills for decisions and statuses. Alpaca's working order states show as "working". |
| `Loading`, `Empty`, `ErrorBox` | The three non-data states every page handles. |
| `EquityChart` | Lightweight Charts, plotting each series as cumulative return: `(equity / starting cash - 1) x 100`. |
| `DotPlot`, `ScoreScale`, `IntervalBar` | Votes, the consensus score, and its interval, placed on a -1 to +1 scale. |

### Formatting

[`dashboard/ui/format.jac`](https://github.com/jere67/parallax/blob/main/dashboard/ui/format.jac) formats every number and date, and uses no browser APIs, so it is unit-tested.
A missing value shows as `-`.
New York time is computed without a time zone library, from the US daylight saving rules: from the second Sunday of March to the first Sunday of November.

### Theme

The look is a ledger: parchment and ink, brass for whatever is selected, verdigris for gains and cinnabar for losses, hairlines instead of shadows, and Instrument Serif for titles.
These docs use the same tokens.

- The light theme ("Newsprint") is the default; the dark theme ("Ink") follows the system unless the reader picks one.
- The choice is stored in `localStorage` and set as `data-theme` on `<html>` before the first paint, so the page never flashes the wrong theme.
- Switching turns transitions off for two frames and sends an event, so the chart repaints in the new colors.

## Testing

| Test | Checks |
| --- | --- |
| `dashboard/api_tests.jac` | Position valuation, realized P&L, run rows, trails, series statistics, the not-started state. |
| `dashboard/cache_tests.jac` | Freshness and eviction. |
| `dashboard/demo_tests.jac` | The demo history is consistent, every view builds from it, and the seed writes once. |
| `dashboard/ui/format_tests.jac` | Number formatting and New York time across daylight saving changes. |
| `dashboard/news_tests.jac` | News headlines, source lists, filters, paging, and feed order. |
| `tests/dashboard_tests.jac` | The read endpoints, called anonymously through a real server. |
| `e2e/dashboard.spec.js` | Every page in real browsers on four devices. See [Checks and tests](/guide/testing#browser-checks). |

::: info Where it differs from the TDD
[TDD §10](/design/tdd#_10-dashboard) plans six pages (Portfolio, Today, Decision detail, Specialists, Reports, Admin) and the endpoints `get_specialist_stats`, `request_report`, and `list_reports`.
The code has the Portfolio, News, Runs, Decision trail, Policy, and Reports pages, and no `get_specialist_stats`.
The "Today" page is the Runs page.
:::
