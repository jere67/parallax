---
title: health
description: Check that the server is up and answering function calls.
api: { method: POST, path: /function/health, auth: none }
related:
  - { text: healthz, link: /api/healthz }
  - { text: API overview, link: /api/overview }
---

Answers `ok` with the server's current UTC time, and the switches that decide whether the server can trade.
Unlike [`healthz`](/api/healthz), it goes through the same function route as every other endpoint, so it also proves that `main.jac` loaded and its endpoints are served.
CI calls it after booting the production bundle, and checks that its server is a demo with orders off.
After a deploy, call it to check that the server trades on Alpaca's paper API: `demo` is `false`, `orders` is `"on"`, and `broker` is `"paper"`.
It names no key and no account, so it needs no login.

<div class="api-grid">
<div class="api-main">

## Body

This endpoint takes no parameters.
Send an empty JSON object.

## Response

Returns a `Health` object in `data.result`.

<Param name="status" type="string" required>

Always `"ok"` when the server answers.

</Param>
<Param name="checked_at" type="string" required>

The server's time when it answered, in UTC ISO 8601 with a `+00:00` offset.

</Param>
<Param name="demo" type="boolean" required>

`true` when the server runs with `TRADING_AGENT_DEMO=1`: it shows the seeded demo history, and no agent runs or trades.

</Param>
<Param name="orders" type="string" required>

`"on"` when the executor may send orders, or `"off"` when `TRADING_AGENT_DISABLE_ORDERS=1` stops every order.

</Param>
<Param name="broker" type="string" required>

Where orders would go: `"paper"` for Alpaca's paper API, `"test"` for a local test server named by `ALPACA_BASE_URL`, or `"refused"` for any other host, which the broker never calls.

</Param>

</div>
<ApiExamples>

<p class="example-label">Request</p>

::: code-group

```bash [cURL]
curl -s -X POST http://localhost:8000/function/health \
  -H 'Content-Type: application/json' \
  -d '{}'
```

```js [JavaScript]
const res = await fetch('http://localhost:8000/function/health', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({})
})
const { data } = await res.json()
const result = data.result
```

```python [Python]
import httpx

res = httpx.post(
    'http://localhost:8000/function/health',
    json={},
)
result = res.json()['data']['result']
```

:::

<p class="example-label">Response · 200</p>

```json
{
  "ok": true,
  "type": "response",
  "data": {
    "result": {
      "broker": "paper",
      "checked_at": "2026-11-02T20:13:19.946974+00:00",
      "demo": false,
      "orders": "on",
      "status": "ok"
    },
    "reports": []
  },
  "error": null
}
```

</ApiExamples>
</div>
