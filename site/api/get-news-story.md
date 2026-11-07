---
title: get_news_story
description: One research note in full - its body, sources, risks, data gaps, and the decision it fed.
api: { method: POST, path: /function/get_news_story, auth: token }
related:
  - { text: get_news_feed, link: /api/get-news-feed }
  - { text: Reading the dashboard, link: /guide/dashboard#news }
---

Returns one research note in full, by the parts of its address, or `null` when no such note is in the caller's feed.
A story is built on first request and cached for 120 seconds.

<div class="api-grid">
<div class="api-main">

## Body

<Param name="day" type="string" required>The run's trading date, `YYYY-MM-DD`.</Param>
<Param name="ticker" type="string" required>The ticker, or `market` for a macro brief.</Param>
<Param name="desk" type="string" required>`market`, `fundamentals`, `news`, or `macro`.</Param>
<Param name="n" type="integer" default="0">Which of that desk's notes that day. Follow-ups come after the first report.</Param>
<Param name="requested" type="boolean" default="false">`true` for a report a reader asked for.</Param>

## Response

Returns a [`NewsStory`](/api/types#newsstory), or `null` when there is no such note.

</div>
<ApiExamples>

<p class="example-label">Request</p>

```bash
curl -s -X POST http://localhost:8000/function/get_news_story \
  -H 'Content-Type: application/json' \
  -d '{"day": "2026-11-06", "ticker": "AAPL", "desk": "news"}'
```

</ApiExamples>
</div>
