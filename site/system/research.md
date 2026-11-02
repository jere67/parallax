---
title: Research pass
description: How collected data becomes cited research reports, one per ticker and domain, plus one macro brief for the whole market.
related:
  - { text: Data sources, link: /system/data-sources }
  - { text: Agents and models, link: /system/agents }
  - { text: Stochastic consensus, link: /system/consensus }
---

The research pass has two halves.
First, code collects every input for every shortlisted ticker in parallel and turns it into compact, numbered briefs.
Then four research sub-agents read those briefs and write typed reports: Market, Fundamentals, and News for each ticker, and Macro once for the whole market.
Code, not the model, decides what counts as a citation, so every claim that reaches the panel points at a source the agent was actually shown.

The pass lives in [`run/research.jac`](https://github.com/jere67/parallax/blob/main/run/research.jac), the briefs in [`research/briefs.jac`](https://github.com/jere67/parallax/blob/main/research/briefs.jac), and the sub-agents in [`agents/research.jac`](https://github.com/jere67/parallax/blob/main/agents/research.jac).

## Collection

`collect_pass` makes no model calls and never touches the graph.
It runs in this order:

<Steps>

1. **Screen.**
   Load the constituents, gather the screen inputs, and pick the shortlist ([Universe screen](/system/screener)).

2. **Read the benchmark bars.**
   One year of daily bars for every shortlisted ticker, SPY, the 11 SPDR sector funds, and four Treasury funds, in one multi-symbol read.
   Stale bars are dropped with a gap.

3. **Read the market-wide calendars.**
   The earnings calendar for the next 30 days for the whole index, and each ticker's SEC company number.
   The quarter's 13F holdings archive is read once and shared by every ticker.

4. **Collect each ticker in parallel.**
   `collect_ticker` runs on the shared network pool, one task per ticker, and gathers the inputs for that ticker's three briefs.

</Steps>

A failed source never stops the pass.
Each source call runs inside `Attempts.run`, which turns any exception into a gap on the brief that needed the data and a fetch error on the ticker's coverage, shown on the [decision trail](/guide/dashboard).

### Look-back windows

`PassConfig` sets how far back each source looks, in calendar days:

| Setting | Days | Used for |
| --- | --- | --- |
| `news_days` | 7 | Alpaca and Finnhub articles |
| `events_days` | 60 | 8-K current reports |
| `release_days` | 100 | The latest 8-K earnings press release (Item 2.02, exhibit 99) |
| `insider_days` | 90 | Form 4 insider trades |
| `earnings_ahead_days` | 30 | The next scheduled earnings release |
| `articles_per_source` | 10 | Articles read from each news source (a count, not days) |

### Indicators

Agents never see raw bars.
[`research/indicators.jac`](https://github.com/jere67/parallax/blob/main/research/indicators.jac) computes a compact `Technicals` summary in plain, typed code, checked against hand-computed values in its tests.
A recent listing gets fewer indicators rather than wrong ones, since each function returns None when there is too little history.

| Indicator | Definition |
| --- | --- |
| SMA 20, 50, 200 | Mean of the last n closes |
| RSI(14) | Wilder's relative strength index, seeded with the simple mean of its first window |
| MACD 12/26/9 | EMA(12) - EMA(26), its 9-period signal line, and the histogram |
| Bollinger width | (upper - lower) / middle over 20 bars at 2 population standard deviations |
| ATR(14), ATR % | Wilder's average true range, and ATR over the close |
| 52-week position | Where the close sits in the 252-bar high-low range |
| Momentum 20, 60 | Return over n bars |
| Relative volume | Mean volume of the last 5 bars over the last 60 |
| Realized volatility | Sample standard deviation of 20 daily log returns, times √252 |
| Dollar volume, volume | 20-bar mean of close × volume, and of volume |
| Relative strength | (1 + stock return) / (1 + benchmark return) - 1 over 20 and 60 sessions, against SPY and the stock's sector fund |

The sector funds are XLC, XLY, XLP, XLE, XLF, XLV, XLI, XLK, XLB, XLRE, and XLU.
The Treasury funds are SHY (1-3 year), IEF (7-10 year), TLT (20+ year), and TIP (inflation-protected); TIP is measured against IEF, so the gap between them tracks inflation expectations rather than rates.

## Briefs

A brief is everything one sub-agent reads: numbered sources, each with the exact `source_url` and `published` time the agent must copy, and figures already written out in words.
Agents never do date math; every "sessions until" and "days ago" is computed in code.

| Brief | Sources, in priority order |
| --- | --- |
| Market | The stock's indicators in words; SPY's trend; the sector fund's trend |
| Fundamentals | SEC XBRL financial statements by filing; Finnhub valuation and quality metrics; EPS against consensus; analyst ratings by month (up to 4); insider trades (a summary and up to 5 of the largest open-market trades); 13F institutional holdings and the prior quarter |
| News | The next scheduled earnings release with sessions until it; up to 5 8-K current reports; the latest earnings press release; up to 8 articles, newest first, with repeats of one story across sources removed |
| Macro | SPY's trend; each Treasury fund; the sector funds ranked by 60-day strength against SPY |

### Caps

| Cap | Value |
| --- | --- |
| Whole brief | 24,000 characters (about 6,000 tokens) |
| Articles | 8, each capped at 1,200 characters |
| 8-K events | 5 |
| Insider trades listed | 5 |

Sources are added most important first, and the length cap drops the last ones.
When the cap drops sources, the brief adds a gap such as `2 lower-priority sources were left out to fit the length cap`.
Article and filing text is wrapped in an untrusted-data block, so the agent treats it as material to analyze, never as instructions.

## The sub-agents

Each sub-agent is one typed byLLM call at temperature 0.2 through the `research_llm` role instance.
It has no tools.

| Sub-agent | Domain | Runs | Judges |
| --- | --- | --- | --- |
| Market and Technical | `market` | per ticker | Whether price action supports owning the stock over the next few weeks |
| Fundamentals and Filings | `fundamentals` | per ticker | The business and its price, including insider activity and delayed institutional holdings |
| News and Events | `news` | per ticker | How material the news is, which way it points, and whether it is priced in |
| Macro | `macro` | once per run | Whether conditions favor taking equity risk: `RISK_ON`, `NEUTRAL`, or `RISK_OFF` |

A ticker report is a `ResearchReport`: a 3-5 sentence summary, a view from `STRONG_SELL` to `STRONG_BUY`, a confidence in [0, 1], evidence items, risks, and data gaps.
The macro report is a `MacroReport` with a regime instead of a view.
The prompt asks for HOLD and a lower confidence when evidence is weak or mixed, and for a regime call only when several sources agree.

### Citation check

After the call, `check_citations` keeps only evidence whose `source_url` matches a source in the brief.
A match ignores case, surrounding brackets, and a trailing slash or punctuation; the kept item's URL becomes the brief's own, and its `published` time is replaced with the brief's value, so a model cannot misdate a source.
Every other claim is dropped and counted in `dropped_citations`, and the count is added to the report's data gaps.

A report is **complete** when the call succeeded and at least one claim survived the check.
The panel convenes only on a ticker with a complete market, fundamentals, and news report.

### When a call fails

<Steps>

1. **Parse retry.**
   byLLM retries a response that does not fit the type once (`max_output_retries=1`).

2. **Retry role.**
   A parse that still fails is tried once more through the separate `retry_llm` instance at temperature 0.2.

3. **Safe default.**
   Any other error, or a second failure, gives a report with view HOLD at confidence 0 and the error in its data gaps.
   A failed macro call gives a `NEUTRAL` brief at confidence 0; the risk gate still reads the regime figures computed in code.

</Steps>

## How the run uses it

In the morning run, the Orchestrator dispatches the sub-agents through its `dispatch_research` tool, in batches, and may ask up to two follow-up questions per ticker before the panel convenes.
A follow-up reruns one domain's sub-agent with the question; the answer goes in the new report's summary.
See [Agents and models](/system/agents) for the tools and [Run Guard](/system/run-guard) for the limits.

The results are written to the graph only afterwards, on the caller's thread: a `MacroRecord` on the run, a `Coverage` per ticker with its fetch errors and the figures the gate needs (last close, ATR(14), 20-day volatility and volume, sessions to earnings), and a `ResearchRecord` per report.
Each node is granted public read access, which is how the [dashboard](/guide/dashboard) shows them to anonymous readers.

::: info Where the code differs from the TDD
The TDD's schedule runs collection at 7:32 and research until about 8:10 as separate steps.
In code the morning run is one continuous run from 7:30, and the Orchestrator decides when to dispatch research.
See [TDD §6](/design/tdd#research-sub-agents).
:::
