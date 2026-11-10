---
title: get_performance
description: Daily equity of the caller's portfolio and both baselines, with total return, Sharpe ratio, maximum drawdown, and volatility.
api: { method: POST, path: /function/get_performance, auth: Bearer token }
related:
  - { text: Insights and baselines, link: /system/insights-baselines }
  - { text: Data types, link: /api/types#performanceview }
---

Returns three series of daily marks for the caller's own agent (the team portfolio for the admin), needing a bearer token: the agent's portfolio, the equal-weight shortlist baseline, and SPY buy-and-hold.
The Portfolio page's chart and performance table are built from it.

<div class="api-grid">
<div class="api-main">

## Body

This endpoint takes no parameters.

## Response

Returns a [`PerformanceView`](/api/types#performanceview).
Before the forward test starts, `started` is `false` and `series` is empty.

<Param name="started" type="boolean" required>

`true` once the forward test has started.

</Param>
<Param name="start_day" type="string">

The forward test's first trading date.

</Param>
<Param name="starting_cash" type="number">

The starting balance shared by all three series.

</Param>
<Param name="series" type="Series[]">

One entry per portfolio, in this order: `team`, `equal_weight`, `spy`.

<Fields title="Show Series fields" open>

<Param name="key" type="string" required>`team`, `equal_weight`, or `spy`.</Param>
<Param name="label" type="string" required>`Your agent`, `Equal-weight shortlist`, or `SPY buy-and-hold`.</Param>
<Param name="points" type="MarkPoint[]" required>One per trading day: `day`, `equity`, and `drawdown` from the running peak.</Param>
<Param name="total_return" type="number | null">Last equity against the starting balance.</Param>
<Param name="sharpe" type="number | null">Mean daily return over its standard deviation, times the square root of 252, with no risk-free rate. `null` with fewer than two returns.</Param>
<Param name="max_drawdown" type="number | null">The largest fall from a peak.</Param>
<Param name="volatility" type="number | null">Standard deviation of daily returns, times the square root of 252.</Param>

</Fields>

</Param>

</div>
<ApiExamples>

<p class="example-label">Request</p>

::: code-group

```bash [cURL]
curl -s -X POST http://localhost:8000/function/get_performance \
  -H 'Content-Type: application/json' \
  -d '{}'
```

```js [JavaScript]
const res = await fetch('http://localhost:8000/function/get_performance', {
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
    'http://localhost:8000/function/get_performance',
    json={},
)
result = res.json()['data']['result']
```

:::

<p class="example-label">Response · 200, points trimmed to two</p>

```json
{
  "ok": true,
  "type": "response",
  "data": {
    "result": {
      "series": [
        {
          "key": "team",
          "label": "Your agent",
          "max_drawdown": 0.0038,
          "points": [
            {
              "day": "2026-09-30",
              "drawdown": 0.0011,
              "equity": 99888.48
            },
            {
              "day": "2026-10-01",
              "drawdown": 0.0006,
              "equity": 99937.6
            }
          ],
          "sharpe": 9.0283,
          "total_return": 0.0347,
          "volatility": 0.0415
        },
        {
          "key": "equal_weight",
          "label": "Equal-weight shortlist",
          "max_drawdown": 0.0431,
          "points": [
            {
              "day": "2026-09-30",
              "drawdown": 0.0029,
              "equity": 99709.22
            },
            {
              "day": "2026-10-01",
              "drawdown": 0.0026,
              "equity": 99738.31
            }
          ],
          "sharpe": 1.0803,
          "total_return": 0.0105,
          "volatility": 0.1115
        },
        {
          "key": "spy",
          "label": "SPY buy-and-hold",
          "max_drawdown": 0.0247,
          "points": [
            {
              "day": "2026-09-30",
              "drawdown": 0.0,
              "equity": 100013.44
            },
            {
              "day": "2026-10-01",
              "drawdown": 0.0,
              "equity": 100646.8
            }
          ],
          "sharpe": 4.0163,
          "total_return": 0.0458,
          "volatility": 0.1241
        }
      ],
      "start_day": "2026-09-30",
      "started": true,
      "starting_cash": 100000.0
    },
    "reports": []
  },
  "error": null
}
```

</ApiExamples>
</div>
