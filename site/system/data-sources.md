---
title: Data sources
description: The six free providers the agents read, and the shared client that caches, rate limits, retries, and budgets every request.
related:
  - { text: Universe screen, link: /system/screener }
  - { text: Research pass, link: /system/research }
  - { text: Configuration, link: /guide/configuration }
---

Every fact an agent sees comes from one of six free sources, fetched by plain code called a collector.
Collectors never call a model and never touch the graph; they return values with the URL and publish time of every datum.
All of them fetch through one client, `SourceClient`, which answers from a cache when it can and otherwise spends from the run's call budget, waits for a rate-limit token, and retries transient failures.
The limits, budgets, cache lifetimes, and freshness rules are versioned together in [`research/sources.jac`](https://github.com/jere67/parallax/blob/main/research/sources.jac) as `SOURCES_VERSION` (currently `2026-10-23.1`).

## The sources

| Source | What it provides | Module | Key |
| --- | --- | --- | --- |
| Alpaca Market Data | Daily bars (SIP feed, split- and dividend-adjusted), latest trades (IEX feed), Benzinga news | [`research/alpaca.jac`](https://github.com/jere67/parallax/blob/main/research/alpaca.jac), [`research/alpaca_news.jac`](https://github.com/jere67/parallax/blob/main/research/alpaca_news.jac) | `ALPACA_API_KEY`, `ALPACA_SECRET_KEY` |
| Alpaca Trading API (paper) | Tradable assets and the market calendar, including early closes | [`research/alpaca.jac`](https://github.com/jere67/parallax/blob/main/research/alpaca.jac) | Same keys |
| SEC EDGAR | Ticker-to-CIK map, filing index, XBRL company facts, 8-K events and earnings releases, Form 4 insider trades, quarterly bulk 13F holdings | [`research/sec.jac`](https://github.com/jere67/parallax/blob/main/research/sec.jac), [`research/holdings.jac`](https://github.com/jere67/parallax/blob/main/research/holdings.jac) | No key; `SEC_USER_AGENT` is required |
| Finnhub (free) | Company news, earnings calendar, recommendation trends, EPS surprises, key metrics | [`research/finnhub.jac`](https://github.com/jere67/parallax/blob/main/research/finnhub.jac) | `FINNHUB_API_KEY` |
| Wikipedia | S&P 500 constituents with GICS sectors, and dated index changes | [`research/wikipedia.jac`](https://github.com/jere67/parallax/blob/main/research/wikipedia.jac) | None |

Keys travel in request headers, never in URLs, so the cache and recorded fixtures never hold them.
A missing key raises `MissingKey`, which the collector reports as a data gap rather than a crash.
SEC asks every client to name itself and a contact in its User-Agent, so the SEC collector refuses to run without `SEC_USER_AGENT` and refuses the placeholder value from the example environment file.

::: tip Why raw REST and not an SDK
The collectors call each provider's REST API directly rather than through an SDK such as alpaca-py.
An SDK makes its own HTTP calls, which would bypass the cache, the shared rate limit, the run budget, and fixture recording.
:::

## Rate limits and run budgets

Each source has a token bucket, shared by every client of that source in the process.
A bucket holds up to `burst` tokens and refills at `per_minute` tokens a minute; a request waits until a token is free.
Sources that share one provider-wide limit share one bucket through `limit_group`.

Each run also gets a call budget per source, `run_budget`.
A cache hit spends nothing; every network attempt, including each retry, spends one call.
When a budget is spent, the request raises `BudgetExceeded`, and the collector records a gap.

| Source | Base URL | Per minute | Burst | Run budget | Limit group |
| --- | --- | --- | --- | --- | --- |
| `alpaca_data` | `https://data.alpaca.markets` | 180 | 10 | 500 | own |
| `alpaca_trading` | `https://paper-api.alpaca.markets` | 180 | 10 | 50 | own |
| `sec_data` | `https://data.sec.gov` | 480 | 5 | 600 | `sec` |
| `sec_archives` | `https://www.sec.gov` | 480 | 5 | 600 | `sec` |
| `finnhub` | `https://finnhub.io/api/v1` | 50 | 5 | 150 | own |
| `wikipedia` | `https://en.wikipedia.org` | 30 | 2 | 10 | own |

The limits sit below each provider's published allowance: Alpaca's free plan allows 200 historical calls a minute, Finnhub's 60, and SEC asks for under 10 requests a second across all of sec.gov, which is why both SEC hosts share one bucket of 480 a minute (8 a second).
No current source has a daily cap, so each run budget guards against a runaway loop.
A source that declares a daily limit may spend at most half of it in one run; `Source` raises an error at startup otherwise.

Every base URL can be overridden by an environment variable (`ALPACA_DATA_URL`, `ALPACA_BASE_URL`, `SEC_DATA_URL`, `SEC_ARCHIVES_URL`, `FINNHUB_BASE_URL`, `WIKIPEDIA_BASE_URL`).
Tests use this to replay recorded fixtures from a local server.

## Datasets, cache lifetimes, and freshness

Each kind of data is a `Dataset` with two separate rules:

- **Cache lifetime** (`cache_ttl_hours`) says how long a stored response may answer a new request.
  None means forever, for data that can never change, such as a closed bar or a filed document.
- **Freshness limit** (`max_age_hours`) says how old a datum may be, measured from its publish time, before it is dropped and named in the report's data gaps.

| Dataset | Cache lifetime | Freshness limit | Why |
| --- | --- | --- | --- |
| `alpaca.bars` | forever | 4 days | Decisions use prior-day bars; 4 days covers a three-day weekend |
| `alpaca.latest_trade` | 1 minute | 4 days | The executor prices orders from it; after hours it is the last session's |
| `alpaca.news` | 24 hours | 7 days | Also the limit applied to Finnhub articles |
| `alpaca.assets` | 24 hours | 2 days | |
| `alpaca.calendar` | 24 hours | 2 days | |
| `sec.submissions` | 24 hours | 2 days | The filing index changes with each filing |
| `sec.companyfacts` | 24 hours | 150 days | A 10-Q can be about 135 days old |
| `sec.filing` | forever | 150 days | A filed document never changes |
| `sec.13f_index` | 24 hours | 2 days | |
| `sec.13f` | forever | 180 days | Closed filing windows never change |
| `sec.tickers` | 7 days | 8 days | |
| `finnhub.news` | 24 hours | 7 days | |
| `finnhub.earnings_calendar` | 24 hours | 2 days | |
| `finnhub.recommendations` | 24 hours | 45 days | Recommendation trends are monthly |
| `finnhub.eps_surprises` | 24 hours | 150 days | |
| `finnhub.metrics` | 24 hours | 7 days | |
| `wikipedia.constituents` | 7 days | 8 days | Refreshed weekly |
| `wikipedia.history` | 7 days | 8 days | |

The freshness limits are proposals (GAP-15), to be checked against each provider's real update cadence.

## How one request works

<Steps>

1. **Look in the cache.**
   The cache key is `raw/<source>/<dataset>/<symbol>/<day>/<hash>.json`, where the hash is the first 20 hex digits of the SHA-256 of the path and sorted query.
   `day` is the as-of date that makes the response final, such as a bar range's end date, so a response that can no longer change is never fetched twice.
   A hit younger than the dataset's cache lifetime returns at once, with no request and no budget spent.

2. **Spend and wait.**
   Each attempt spends one call of the run budget, then takes a token from the source's bucket.

3. **Send, with a 30-second timeout.**
   A 2xx answer is kept.
   A timeout, a dropped connection, a 429, or a 5xx is retried up to 3 times, waiting 1, 2, then 4 seconds, or the `Retry-After` header's value when the provider sends one, capped at 60 seconds.
   Any other status fails at once.

4. **Check the body.**
   A collector may pass a check that rejects an error page sent with status 200; a rejected body is never cached.

5. **Cache and record.**
   The raw body is cached with its fetch time.
   When `COLLECTOR_RECORD_DIR` is set, the response is also saved as a replayable fixture under `<dir>/<source>/<dataset>-<hash>.json`.

</Steps>

After the fetch, the collector parses the body into stamped values, each carrying its source URL, publish time, and fetch time.
`split_fresh` then drops anything older than the freshness limit and writes one line per dropped datum, such as `alpaca.news: <url> was published ..., older than the 168-hour limit, so it was excluded`.

## Untrusted text

Article and filing text is reduced to plain text, capped, and wrapped in an untrusted-data block before any agent reads it.
The block's delimiters are defused inside the text, so an article cannot close the block early.
The research prompts say that text inside such a block is material to analyze, never instructions to follow.
See [Research pass](/system/research) for how briefs are built from it.

::: info Where the code differs from the TDD
The TDD lists Finnhub at 60 calls a minute and SEC at 10 requests a second; the code deliberately runs below both, at 50 a minute and 8 a second.
Otherwise the collector rules match [TDD §6](/design/tdd#collector-rules).
:::
