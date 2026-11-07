---
title: list_runs
description: Every morning run, newest first, with how many tickers it covered, how many orders filled, and its decisions by action.
api: { method: POST, path: /function/list_runs, auth: Bearer token }
related:
  - { text: get_run, link: /api/get-run }
---

Returns a one-line summary of every run of the caller's own agent, newest first, up to 250.
It needs a bearer token.
The Runs page lists them, and links each one to [`get_run`](/api/get-run).

<div class="api-grid">
<div class="api-main">

## Body

This endpoint takes no parameters.

## Response

Returns a list of [`RunSummary`](/api/types#runsummary).
Before any run, the list is empty.

<Param name="run_date" type="string" required>

The trading date, New York time.

</Param>
<Param name="status" type="string" required>

`normal`, `fallback`, `skipped`, `failed`, or `running`. See [Run status](/system/run-guard#run-status).

</Param>
<Param name="covered" type="integer">

Tickers covered.

</Param>
<Param name="trades" type="integer">

Orders with a filled quantity above zero.

</Param>
<Param name="actions" type="object">

Decisions by action, such as `{"BUY": 1, "NO_ACTION": 5}`. Actions with no decisions are left out.

</Param>

</div>
<ApiExamples>

<p class="example-label">Request</p>

::: code-group

```bash [cURL]
curl -s -X POST http://localhost:8000/function/list_runs \
  -H 'Content-Type: application/json' \
  -d '{}'
```

```js [JavaScript]
const res = await fetch('http://localhost:8000/function/list_runs', {
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
    'http://localhost:8000/function/list_runs',
    json={},
)
result = res.json()['data']['result']
```

:::

<p class="example-label">Response · 200, trimmed to two runs</p>

```json
{
  "ok": true,
  "type": "response",
  "data": {
    "result": [
      {
        "actions": {
          "NO_ACTION": 5,
          "BUY": 1,
          "ADD": 5,
          "TRIM": 1
        },
        "covered": 12,
        "run_date": "2026-10-30",
        "status": "normal",
        "trades": 2
      },
      {
        "actions": {
          "NO_ACTION": 5,
          "BUY": 1,
          "ADD": 3,
          "HOLD": 1,
          "SELL": 2,
          "TRIM": 1
        },
        "covered": 13,
        "run_date": "2026-10-29",
        "status": "normal",
        "trades": 5
      }
    ],
    "reports": []
  },
  "error": null
}
```

</ApiExamples>
</div>
