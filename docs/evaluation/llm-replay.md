# LLM replay: ten past mornings with history-only data

Run on November 11, 2026, by `tests/spikes/llm_replay.jac`, with the team's free OpenRouter models.
The full output is [llm-replay.json](llm-replay.json).

## Question

Does the whole pipeline, from data collection to the Arbiter, run end to end on past mornings when every source serves only what was public at the time, and are its outputs sane?
This is layer 1 of the evaluation plan (TDD §13), in its smallest form: 10 consecutive trading days, 5 tickers, and one sample per specialist (K = 1).

## Answer

**In progress.**
The replay shares the team's free-model allowance, so it runs in the hours the live morning runs do not need, and this section is filled in when the last day is scored.
The first replayed day ran end to end: all 5 tickers reached the Arbiter, all 25 votes parsed, and no report cited anything dated after the decision.

## Method

The replayed days are the 10 sessions from October 15 to October 28, 2026.
The primary model, Nemotron 3.5 Super VL, was trained on data collected through December 2025, according to NVIDIA's model card, and was released on October 15, 2026, so none of these days can be in its training data.
The fallback, Dots3-Note Preview, was listed on August 14, 2026.
The last day's 10-session scoring window ends on November 10, so every window has closed.

The 5 tickers are the top 5 the real screen picked as of October 15, with the screen's own scoring and history-only data: MRNA, MDT, META, MSFT, and NVDA.
They stay fixed for all 10 days, so a day's results do not depend on which tickers the screen happened to pick that day.

Each day runs as a morning run would, with the decision time set to 7:30 a.m. New York.
A new as-of mode in `research/asof.jac`, off unless a replay turns it on, bounds every source to what was published before that time.
The collection pass, the research sub-agents, the specialist panel, the consensus rule, and the Arbiter are the production functions (`run/research.jac`, `run/analysis.jac`), with the default policy and no holdings.
Nothing is written to any graph, and no order is placed.

Each decision and each vote is scored on the ticker's 10-session excess return over SPY, with the window rule in `analysis/scoring.jac`.
A vote hits when its direction (buy or sell) matches the sign of the excess return; a hold has no direction and is not scored.
The hit rate's interval is Wilson's 95% interval.

The replay shares the team's free-model allowance with the live morning runs.
It reads OpenRouter's remaining free requests before every day and waits whenever spending the day's ceiling would leave fewer than 650 for the next weekday morning's runs, or fewer than 100 once that morning's runs are done.
It also slows Alpaca to 120 requests a minute and makes no data calls from 7:15 to 10:00 a.m. New York on weekdays.

## Look-ahead audit

Every source the collection pass reads, and what the replay does with it.
"Bounded" serves only what was published before the decision time, "stripped" keeps a record but removes the fields that were not known yet, and "dropped" does not read the source at all and records a gap.

| Source | Treatment | What the replay does |
| --- | --- | --- |
| Alpaca daily bars (stock, SPY, sector and bond ETFs) | bounded | The query ends at the last session before the replayed day, and a series stamped at or after the decision time is dropped. Bars are split- and dividend-adjusted with today's factors, so price levels can differ from what was shown then; returns and indicators do not. |
| Alpaca news (articles and the screen's counts) | bounded | Every query ends at the decision time, and an article published at or after it is dropped. |
| Finnhub company news | bounded | Ends on the replayed day; an article published at or after the decision time is dropped. |
| Finnhub key metrics | dropped | Finnhub serves only today's snapshot, so it is not read; the Fundamentals brief records a gap and relies on SEC figures. |
| Finnhub EPS surprises | stripped | Finnhub dates a quarter by its end, not by when it was reported, so a quarter is kept only when an Item 2.02 earnings release filed after it ended and before the replayed day covers it. |
| Finnhub recommendation trends | stripped | The decision's own month is left out, since its counts kept changing after the decision; earlier months are kept. |
| Finnhub earnings calendar (next release, and the screen's earnings flag) | stripped | A release on or after the replayed day keeps its date and estimates but loses its actual EPS and revenue. The date shown is the one the calendar holds today, which can differ from the schedule known then. |
| SEC submissions (8-K events, earnings release, Form 4) | bounded | Only filings dated before the replayed day are listed, so every event, release, and insider trade read from them was public. |
| SEC XBRL company facts | bounded | A fact filed on or after the replayed day is left out, so neither a new quarter nor a later restatement leaks in. |
| SEC 13F holdings | bounded | Only filing windows that closed before the replayed day are used. SEC's listing does not give when each archive was posted, which the brief already notes as a gap. |
| Wikipedia S&P 500 membership | bounded | The members on the replayed day are rebuilt from today's list by undoing every later change in the historical-components table. |
| Alpaca assets (the screen's tradability check) | dropped | Alpaca lists only today's assets, so every member counts as tradable rather than drop one delisted since. |
| Macro and regime inputs (SPY, sector and bond ETFs) | bounded | Computed from the bounded daily bars. |
| Market calendar | bounded | The exchange schedule is published in advance, so the sessions around the day were known then. |

The tests in `research/asof_tests.jac` check each treatment on recorded responses, and that a live run sends and keeps exactly what it did before.

## Results

Filled in when the last day is scored.

## Sanity checks

Filled in when the last day is scored.

## Limits

- Alpaca adjusts past prices for splits and dividends with today's factors, so a price level shown to a model can differ from the one shown then; returns and indicators do not change.
- The earnings calendar gives the release date it holds today, which can differ from the date announced at the time.
- SEC's 13F listing does not say when each archive was posted, so a filing window that had closed may not yet have been fully posted.
- The free router picks the model behind each answer, and the models it used are recorded per answer, but their training data is not always documented.
- Ten days and five tickers make a small sample: the interval on the hit rate is wide, and every day's window overlaps the next, so the days are not independent.
- The screen's top picks on October 15 were driven by news volume, so the five tickers lean toward heavily covered large caps and one news-driven biotech.
- With K = 1 each specialist answers once, so the consensus interval reflects disagreement between specialists only, not the spread of one specialist's answers.
