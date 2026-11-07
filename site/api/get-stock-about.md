---
title: get_stock_about
description: A stock's recent headlines and, from Wikipedia, a short description with a link to its article.
api: { method: POST, path: /function/get_stock_about, auth: none }
related:
  - { text: get_stock, link: /api/get-stock }
  - { text: Data types, link: /api/types#stockaboutview }
  - { text: Market data, link: /system/market-data#what-is-stored }
---

Returns a stock's headlines and description, read on demand and held for a while.
Each is fetched on its own, so one failing leaves the other.
`busy: true` means the shared allowance of source calls was spent, so ask again shortly.

<div class="api-grid">
<div class="api-main">

## Body

<Param name="symbol" type="string" required>

The ticker, in any case.

</Param>

## Response

Returns a [`StockAboutView`](/api/types#stockaboutview).
The description is empty when no article clearly matches the company, since a wrong one is worse than none.

</div>
<ApiExamples>

<p class="example-label">Request</p>

```bash
curl -s -X POST http://localhost:8000/function/get_stock_about \
  -H 'Content-Type: application/json' \
  -d '{"symbol": "AAPL"}'
```

</ApiExamples>
</div>
