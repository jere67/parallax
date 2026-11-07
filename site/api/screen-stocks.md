---
title: screen_stocks
description: One page of the market screener - filter, search, and sort every U.S.-listed stock, and pick which fields each row carries.
api: { method: POST, path: /function/screen_stocks, auth: none }
related:
  - { text: Data types, link: /api/types#screenerview }
  - { text: Market data, link: /system/market-data }
  - { text: Reading the dashboard, link: /guide/dashboard#screener }
---

Returns one page of the stocks that pass the filters, from memory, with no source calls.
An unknown field or an unusable bound is left out rather than refused, so an old link still opens.

<div class="api-grid">
<div class="api-main">

## Body

<Param name="filters" type="array" default="[]">

Conditions that must all hold, at most 40.
`{"field": "pe", "min": 5, "max": 20}` keeps rows within the bounds, and `{"field": "sector", "one_of": ["Energy"]}` keeps rows with one of the words.
A row missing the figure does not match.

</Param>
<Param name="search" type="string" default='""'>

The start of a symbol, or any part of a company's name.

</Param>
<Param name="symbols" type="array" default="[]">

Limits the rows to these symbols, at most 500.

</Param>
<Param name="sort" type="string" default='"market_cap"'>

The field to sort by. A missing figure sorts last in either direction, and ties fall to the symbol.

</Param>
<Param name="descending" type="boolean" default="true">

The sort's direction.

</Param>
<Param name="columns" type="array" default="[]">

The fields each row carries, beside `symbol`, `name`, `kind`, and `sp500`. Empty means every field.

</Param>
<Param name="offset" type="integer" default="0">

How many rows to skip.

</Param>
<Param name="limit" type="integer" default="100">

How many rows to return, at most 200.

</Param>

## Response

Returns a [`ScreenerView`](/api/types#screenerview).
Returns and ratios are fractions, and a missing figure is `null`.

</div>
<ApiExamples>

<p class="example-label">Request</p>

```bash
curl -s -X POST http://localhost:8000/function/screen_stocks \
  -H 'Content-Type: application/json' \
  -d '{"filters": [{"field": "sector", "one_of": ["Energy"]}],
       "columns": ["price", "pe"], "limit": 2}'
```

</ApiExamples>
</div>
