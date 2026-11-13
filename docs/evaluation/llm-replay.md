# LLM replay: ten past mornings with history-only data

Run on November 11, 2026, by `tests/spikes/llm_replay.jac`, with the team's free OpenRouter models.
The full output is [llm-replay.json](llm-replay.json).

## Question

Does the whole pipeline, from data collection to the Arbiter, run end to end on past mornings when every source serves only what was public at the time, and are its outputs sane?
This is layer 1 of the evaluation plan (TDD §13), in its smallest form: 10 consecutive trading days, 5 tickers, and one sample per specialist (K = 1).

## Answer

**Partly: the pipeline runs on history-only data, but not every check passed (see the sanity checks), and its votes beat a coin flip, though 10 overlapping days are a small sample.**
49 of 50 day and ticker pairs reached the Arbiter, and 245 of 245 votes parsed.
Votes that took a side were right 64% of the time (118 of 184), with a 95% interval of 57% to 71%: better than a coin flip.
The pipeline bought 9 times, with a mean 10-session excess return over SPY of +5.56%.
No report cited anything dated after its decision.

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

Each cell is the action, the consensus score C, and the ticker's 10-session excess return over SPY from that day.
"Vetoed" means the consensus rule drafted a buy and the Arbiter downgraded it; "none" means no action.

| Day | MRNA | MDT | META | MSFT | NVDA |
| --- | --- | --- | --- | --- | --- |
| 10-15 | vetoed, C +0.18, -5.7% | **buy**, C +0.30, +0.2% | none, C -0.06, -17.3% | **buy**, C +0.28, -0.9% | none, C +0.13, -3.0% |
| 10-16 | none, C -0.00, -5.5% | **buy**, C +0.22, +2.1% | vetoed, C +0.14, -14.9% | vetoed, C +0.16, -1.4% | none, C -0.06, -1.3% |
| 10-19 | none, C +0.06, +2.7% | **buy**, C +0.17, +2.9% | none, C -0.01, -12.3% | none, C -0.07, -0.4% | none, C -0.06, -3.4% |
| 10-20 | none, C -0.01, -0.8% | vetoed, C +0.14, +8.9% | none, C -0.17, -12.1% | none, C +0.09, -3.1% | none, C -0.10, -5.0% |
| 10-21 | none, C -0.08, -3.7% | **buy**, C +0.20, +6.4% | none, C -0.17, -8.6% | none, C n/a, -0.1% | none, C -0.12, -2.6% |
| 10-22 | none, C +0.06, +5.9% | **buy**, C +0.20, +13.6% | none, C -0.06, -8.9% | **buy**, C +0.23, +5.1% | none, C -0.11, -9.0% |
| 10-23 | none, C -0.15, +23.2% | vetoed, C +0.16, +12.6% | none, C -0.10, -2.7% | none, C +0.07, +6.9% | none, C -0.12, -10.4% |
| 10-26 | none, C +0.07, +30.3% | **buy**, C +0.19, +9.9% | none, C -0.11, -1.8% | vetoed, C +0.16, +4.4% | none, C -0.22, -8.3% |
| 10-27 | none, C -0.08, +36.9% | vetoed, C +0.15, +10.1% | none, C -0.03, +3.4% | none, C +0.12, +4.0% | none, C -0.17, -15.6% |
| 10-28 | none, C -0.13, +23.2% | **buy**, C +0.19, +10.7% | none, C -0.16, +6.0% | vetoed, C +0.15, +2.9% | none, C -0.17, -19.9% |

The consensus rule drafted 17 buys, and the Arbiter confirmed 9 and vetoed 8.
The confirmed buys were MDT on 10-15 (+0.2%), MSFT on 10-15 (-0.9%), MDT on 10-16 (+2.1%), MDT on 10-19 (+2.9%), MDT on 10-21 (+6.4%), MDT on 10-22 (+13.6%), MSFT on 10-22 (+5.1%), MDT on 10-26 (+9.9%), MDT on 10-28 (+10.7%).
The vetoed drafts were MRNA on 10-15 (-5.7%), META on 10-16 (-14.9%), MSFT on 10-16 (-1.4%), MDT on 10-20 (+8.9%), MDT on 10-23 (+12.6%), MSFT on 10-26 (+4.4%), MDT on 10-27 (+10.1%), MSFT on 10-28 (+2.9%).

How often each specialist's votes that took a side matched the sign of the excess return:

| Specialist | Votes that took a side | Right | Hit rate |
| --- | --- | --- | --- |
| flow | 43 | 21 | 49% |
| fundamentals | 31 | 17 | 55% |
| macro | 42 | 32 | 76% |
| news | 31 | 22 | 71% |
| technical | 37 | 26 | 70% |

A vote's horizon can be longer than 10 sessions, so this scores every vote on the same short window.

### Repeatability

A first pass of October 15 was discarded because of the dated snapshot, but its votes show how much one sample per specialist moves between two runs on the same data.
8 of its 25 votes took a different stance in the rerun.
The draft changed for 3 of the 5 tickers: MRNA and MSFT went from no action to a draft buy, and NVDA went from a draft buy to no action with almost the same score (0.136 and 0.133), because the low end of its interval sat right at zero.
The final action changed for one: the Arbiter confirmed MSFT in the rerun, so that morning bought MDT and MSFT instead of MDT alone.
That is the noise K = 1 accepts; more samples per specialist would average some of it out, at that many times the requests.

## Sanity checks

- **Completion:** 49 of 50 pairs reached a consensus and the Arbiter; 1 were held for missing research, and 0 had any error.
- **Parsed votes:** 245 of 245.
- **Stances:** 97 buy, 87 sell, 61 hold.
- **Confidence:** from 0.30 to 0.80.
- **Late evidence:** 0 items dated at or after the decision. A first pass of three days found 10, all of them the next-earnings snapshot dated when it was read rather than as of the decision; that was fixed and the days rerun.
- **Requests:** 595 free requests, about 12 per pair.
- **Wall time:** 116 minutes of running, spread over the hours the allowance allowed.
- **Models:** nvidia/nemotron-3.5-super-vl:free answered 395.

## Limits

- Alpaca adjusts past prices for splits and dividends with today's factors, so a price level shown to a model can differ from the one shown then; returns and indicators do not change.
- The earnings calendar gives the release date it holds today, which can differ from the date announced at the time.
- SEC's 13F listing does not say when each archive was posted, so a filing window that had closed may not yet have been fully posted.
- The free router picks the model behind each answer, and the models it used are recorded per answer, but their training data is not always documented.
- Ten days and five tickers make a small sample: the interval on the hit rate is wide, and every day's window overlaps the next, so the days are not independent.
- The screen's top picks on October 15 were driven by news volume, so the five tickers lean toward heavily covered large caps and one news-driven biotech.
- With K = 1 each specialist answers once, so the consensus interval reflects disagreement between specialists only, not the spread of one specialist's answers.
