---
title: get_stock
description: One stock's page - its row of figures, profile, peers, period tables, filings, indicators, analyst history, and what the committee last did.
api: { method: POST, path: /function/get_stock, auth: none }
related:
  - { text: get_stock_history, link: /api/get-stock-history }
  - { text: get_stock_about, link: /api/get-stock-about }
  - { text: Data types, link: /api/types#stockview }
---

Returns everything on a stock's page that the sweeps have already stored, with no source calls.
An unknown symbol returns `found: false`, not an error.

<div class="api-grid">
<div class="api-main">

## Body

<Param name="symbol" type="string" required>

The ticker, in any case.

</Param>

## Response

Returns a [`StockView`](/api/types#stockview).

</div>
<ApiExamples>

<p class="example-label">Request</p>

```bash
curl -s -X POST http://localhost:8000/function/get_stock \
  -H 'Content-Type: application/json' \
  -d '{"symbol": "AAPL"}'
```

</ApiExamples>
</div>
