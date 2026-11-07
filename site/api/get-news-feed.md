---
title: get_news_feed
description: One page of the research feed, newest first, filtered by words, ticker, desk, view, day, or holdings.
api: { method: POST, path: /function/get_news_feed, auth: token }
related:
  - { text: get_news_story, link: /api/get-news-story }
  - { text: Reading the dashboard, link: /guide/dashboard#news }
---

Returns one page of the caller's research feed, newest first: their own agent's notes and the reports they asked for.
All the filters are optional and combine.
The feed is cached for each reader, so filtering never waits on the graph.

<div class="api-grid">
<div class="api-main">

## Body

<Param name="q" type="string" default='""'>

Words that must all appear in a note or its sources, in any case.

</Param>
<Param name="ticker" type="string" default='""'>The ticker, in any case.</Param>
<Param name="desk" type="string" default='""'>`market`, `fundamentals`, `news`, or `macro`.</Param>
<Param name="lean" type="string" default='""'>`up`, `flat`, or `down`.</Param>
<Param name="day" type="string" default='""'>A trading date, `YYYY-MM-DD`.</Param>
<Param name="held" type="boolean" default="false">Keep only the tickers the caller's agent holds now.</Param>
<Param name="offset" type="integer" default="0">Notes to skip. Use the last page's `next_offset`.</Param>
<Param name="limit" type="integer" default="50">Notes on this page, at most 100.</Param>

## Response

Returns a [`NewsFeed`](/api/types#newsfeed).

</div>
<ApiExamples>

<p class="example-label">Request</p>

```bash
curl -s -X POST http://localhost:8000/function/get_news_feed \
  -H 'Content-Type: application/json' \
  -d '{"ticker": "AAPL", "desk": "news", "limit": 10}'
```

</ApiExamples>
</div>
