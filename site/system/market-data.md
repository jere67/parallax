---
title: Market data
description: How the screener and stock pages cover the whole U.S. market on free data - the universe, the two background sweeps, what is stored, and what each number is worked out from.
related:
  - { text: Reading the dashboard, link: /guide/dashboard#screener }
  - { text: screen_stocks, link: /api/screen-stocks }
  - { text: Data sources, link: /system/data-sources }
---

The screener and the stock pages cover every U.S.-listed stock, about 5,600 of them, on the same free sources as the research pipeline.
They are separate from the [universe screen](/system/screener), which picks the morning run's shortlist from the S&P 500, and nothing here reaches an agent.

The code is in [`market/`](https://github.com/jere67/parallax/tree/main/market), and the pages are in [`dashboard/market/`](https://github.com/jere67/parallax/tree/main/dashboard/market).

## The universe

A stock is covered when SEC's ticker file lists it, Alpaca can trade it on a U.S. exchange, and its name or Nasdaq symbol does not mark it as a warrant, unit, right, preferred share, note, or exchange-traded product.
Funds that SEC's file does list drop out once the company sweep has read their industry code: commodity pools by code 6221, and closed-end trusts by having no code.
S&P 500 members take their name and GICS sector from the Wikipedia list.
Every other stock takes its sector from its SEC industry code, through the table in [`market/sectors.jac`](https://github.com/jere67/parallax/blob/main/market/sectors.jac).

## The sweeps

A scheduled job fires every minute and starts two background passes.
Each pass holds a lock, so a slow one is skipped rather than stacked, and neither touches the graph, so they never compete with the morning run for the database.

| Pass | What it refreshes | How often |
| --- | --- | --- |
| Main | The list of stocks | Daily |
| Main | Quotes for every stock | Every 5 minutes in a session, every 6 hours otherwise |
| Main | Earnings dates | Every 12 hours |
| Main | A year of daily bars, reduced to stats and technicals | Once a session is final, resuming where the last pass stopped |
| Main | Each company's filings and, when a new report is out, its figures | Rolling, most-traded first, for at most 50 seconds a pass |
| Analyst | Six stocks' Finnhub records | Each minute, on a three-day cycle |

The SEC and Finnhub sweeps stand aside from 7:15 to 9:45 ET on weekdays, so the morning run has those allowances to itself.
A first sweep of a new server takes about two hours for company figures and about fifteen hours for analyst records, and the pages fill in as it goes.

## What is stored

Each domain is a JSON file under `.jac/market/`, or under `MARKET_DATA_DIR` when it is set, replaced atomically on each write.
Each company has its own file, `company/<cik>.json`, since its period tables and filings are only needed on its own page.
A broken file reads as empty and is rebuilt by the next pass.

The endpoints answer from memory: the rows are rebuilt only when a pass has changed something.
Price history, headlines, and descriptions are read on demand when a stock page opens, held in memory for a while, and limited to 40 source calls a minute across all readers.
Past that limit the endpoint answers `busy` and the page tries again shortly.

## What each number is

| Figure | Worked out from |
| --- | --- |
| Market cap | Shares times price. Shares are Finnhub's market cap over the price when Finnhub reports in dollars, which is right for share classes and ADRs, and otherwise SEC's latest count. An ADR with neither has none. |
| P/E, P/S, P/B | Market cap over the trailing twelve months, so they hold for ADRs and share classes alike. A loss has no P/E. |
| Margins, returns, debt ratios | SEC company facts, from U.S. GAAP filings. |
| Technical rating | The mean vote of six indicators worked out here from daily bars. |
| Beta | The slope of the stock's daily returns on SPY's over the last year, with at least 60 shared sessions. |
| Analyst rating | A -1 to 1 score from Finnhub's latest monthly recommendation counts. |
| Earnings surprise | Finnhub's reported against estimated EPS, in percent. |

Filers that report in IFRS, which is most foreign companies, have a price and technicals but no SEC figures.
A figure with no source is a dash, never a zero.

## When a number is doubted

Filings carry scale errors and stray tags, and one of them would otherwise top every sort, so `market/rows.jac` shows a dash rather than a figure it cannot believe.

| Figure | Unknown when |
| --- | --- |
| Filed share count | Under 50,000, or under half the average daily volume, which is how a pre-IPO cover page or a count in thousands looks |
| Dividend per share | Negative, or over 30% of the price, which is a preferred share's or a mis-scaled filing's |
| EPS | Over 20 times the price, which is a figure from before a reverse split |
| Margins, returns, P/E, P/S, P/B, and other ratios | Outside the range listed in `PLAUSIBLE` |

Today's change starts from the adjusted close when the snapshot's previous close is more than 25% away from it, because a snapshot's close predates a split or spin-off made that morning.
Revenue takes the largest of the reported revenue concepts for the newest period, because contract revenue alone leaves out a landlord's rent and a bank's interest.

## Licensing

Company figures come from SEC filings, which are public.
From Finnhub, the pages show only derived scores and percentages and public facts such as a website and an IPO date.
Technical ratings and betas are worked out here.

Prices and bars are shown as they come from Alpaca, on a public page, which goes beyond the [no raw redistribution rule](/design/tdd#design-notes) the rest of the dashboard follows.
Check Alpaca's terms before this runs anywhere public beyond the course.

## Demo mode

A server with `TRADING_AGENT_DEMO=1` answers from an invented market of about 70 well-known names, seeded so it repeats, and makes no source calls.
Nothing about it is written to disk.
See [Demo data](/guide/demo-data).
