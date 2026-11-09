---
title: get_stock_history
description: A stock's price history for the chart - daily bars back to 2016, five sessions of intraday bars, and its returns by month.
api: { method: POST, path: /function/get_stock_history, auth: token }
related:
  - { text: get_stock, link: /api/get-stock }
  - { text: Data types, link: /api/types#historyview }
  - { text: Market data, link: /system/market-data#what-is-stored }
---

Returns a stock's bars, read on demand and held for a while.
Only covered symbols are accepted.
`busy: true` means the shared allowance of source calls was spent, so ask again shortly.

<div class="api-grid">
<div class="api-main">

## Body

<Param name="symbol" type="string" required>

The ticker, in any case.

</Param>

## Response

Returns a [`HistoryView`](/api/types#historyview).

</div>
<ApiExamples>

<p class="example-label">Request</p>

```bash
curl -s -X POST http://localhost:8000/function/get_stock_history \
  -H 'Content-Type: application/json' \
  -d '{"symbol": "AAPL"}'
```

</ApiExamples>
</div>
