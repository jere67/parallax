---
title: get_run
description: One morning run - its status, summary, market backdrop, action log, and one row per covered ticker from screen to order.
api: { method: POST, path: /function/get_run, auth: none }
related:
  - { text: list_runs, link: /api/list-runs }
  - { text: get_decision_trail, link: /api/get-decision-trail }
  - { text: Reading the dashboard, link: /guide/dashboard#runs }
---

Returns one run with a row per covered ticker.
Each row carries the ticker's whole path in brief: why it was covered, the consensus, the decision, the risk gate's outcome, and the order.
The newest run is rebuilt every minute; other dates are built on first request and cached for 120 seconds.

<div class="api-grid">
<div class="api-main">

## Body

<Param name="run_date" type="string" default='""'>

A trading date, `YYYY-MM-DD`. Leave it empty for the newest run.

</Param>

## Response

Returns a [`RunView`](/api/types#runview), or `null` when there is no run on that date.

<Param name="run_date" type="string" required />
<Param name="status" type="string" required>

`normal`, `fallback`, `skipped`, `failed`, or `running`.

</Param>
<Param name="mode" type="string" required>

The portfolio's mode when the run was read: `insight` or `auto`.

</Param>
<Param name="reduced_mode" type="boolean">

`true` when the run was [reduced](/system/run-guard#how-many-requests-are-left) for a low request budget.

</Param>
<Param name="summary" type="string">

The Orchestrator's summary, or the Run Guard's when it wrote none.

</Param>
<Param name="started_at" type="string">

With `finished_at`, `executed_at`, and `reconciled_at`: when each step happened, in UTC. Empty until it happens.

</Param>
<Param name="execution_note" type="string">

The risk gate's summary, such as `"4 checks, 2 approved"`.

</Param>
<Param name="model_requests" type="integer">

Model requests spent, with `prompt_tokens` and `completion_tokens`.

</Param>
<Param name="macro" type="MacroView | null">

The macro agent's regime call (`RISK_ON`, `NEUTRAL`, or `RISK_OFF`), its confidence and summary, the risks it flagged, and SPY's close, 200-day average, and 20-day volatility.

</Param>
<Param name="action_log" type="string[]">

The trading tick's log for the day, as `HH:MM line`.

</Param>
<Param name="previous_day" type="string">

With `next_day`: the neighbouring runs, or empty.

</Param>
<Param name="rows" type="CoverageRow[]">

One per covered ticker, highest conviction first.

<Fields title="Show CoverageRow fields">

<Param name="ticker" type="string" required />
<Param name="sector" type="string" required />
<Param name="reason" type="string" required>Why it was covered: `screen`, `held`, `wildcard`, or `user_request`. `reason_note` explains it.</Param>
<Param name="screen_score" type="number | null">The composite screen score, for `screen` only.</Param>
<Param name="action" type="string">The final decision. `draft_action` is the consensus's draft.</Param>
<Param name="conviction" type="number | null">From 0 to 1.</Param>
<Param name="downgraded" type="boolean">`true` when the Arbiter downgraded the draft.</Param>
<Param name="forced_hold" type="boolean">`true` when the Run Guard or a flag forced a hold.</Param>
<Param name="score" type="number | null">The consensus score, -1 to +1, with its interval `ci_low` to `ci_high` and `agreement`.</Param>
<Param name="gate_outcome" type="string">`approved`, `resized`, or `rejected`, with `requested_qty`, `approved_qty`, and `rejected_by` (the last rule that failed).</Param>
<Param name="order_status" type="string">The order's status, with `order_side`, `order_qty`, `filled_qty`, and `filled_avg_price`.</Param>
<Param name="last_close" type="number | null" />

</Fields>

</Param>

</div>
<ApiExamples>

<p class="example-label">Request</p>

::: code-group

```bash [cURL]
curl -s -X POST http://localhost:8000/function/get_run \
  -H 'Content-Type: application/json' \
  -d '{"run_date": "2026-10-30"}'
```

```js [JavaScript]
const res = await fetch('http://localhost:8000/function/get_run', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({"run_date": "2026-10-30"})
})
const { data } = await res.json()
const result = data.result
```

```python [Python]
import httpx

res = httpx.post(
    'http://localhost:8000/function/get_run',
    json={'run_date': '2026-10-30'},
)
result = res.json()['data']['result']
```

:::

<p class="example-label">Response · 200, lists trimmed</p>

```json
{
  "ok": true,
  "type": "response",
  "data": {
    "result": {
      "action_log": [
        "09:45 execute: 4 checks, 2 approved",
        "09:45 execute: AMZN sold 6 @ 208.12 (trim)",
        "09:45 execute: HD buy 4 refused by earnings blackout"
      ],
      "completion_tokens": 35358,
      "demo": true,
      "executed_at": "2026-10-30T13:45:00+00:00",
      "execution_note": "4 checks, 2 approved",
      "finished_at": "2026-10-30T12:54:00+00:00",
      "macro": {
        "confidence": 0.66,
        "regime": "RISK_ON",
        "risks": [
          "A hotter inflation print could lift yields.",
          "Earnings season could widen single-stock dispersion."
        ],
        "spy_close": 613.31,
        "spy_sma_200": 573.44,
        "spy_vol_20": 0.1255,
        "summary": "SPY closed at 613.31, +2.5% over the past month and well above its 200-day average. Its 20-day realized volatility is 13%. Treasury funds were steady, and the leading sectors rotated without a clear defensive tilt. Conditions favor taking equity risk."
      },
      "mode": "auto",
      "model_requests": 71,
      "next_day": "",
      "previous_day": "2026-10-29",
      "prompt_tokens": 217189,
      "reconciled_at": "2026-10-30T20:30:00+00:00",
      "reduced_mode": false,
      "rows": [
        {
          "action": "ADD",
          "agreement": 1.0,
          "approved_qty": 0,
          "ci_high": 0.8533,
          "ci_low": 0.79,
          "conviction": 0.8193,
          "downgraded": false,
          "draft_action": "ADD",
          "filled_avg_price": null,
          "filled_qty": 0,
          "flag_reason": "",
          "forced_hold": false,
          "gate_outcome": "",
          "last_close": 196.06,
          "order_qty": 0,
          "order_side": "",
          "order_status": "",
          "reason": "held",
          "reason_note": "open position",
          "rejected_by": "",
          "requested_qty": 0,
          "score": 0.8193,
          "screen_score": null,
          "sector": "Information Technology",
          "ticker": "AAPL"
        }
      ],
      "run_date": "2026-10-30",
      "started_at": "2026-10-30T11:30:00+00:00",
      "status": "normal",
      "summary": "Covered 12 tickers (6 from the screen, 6 held). The panel was strongest on AAPL. 6 buys or adds and 1 sell or trim went to the risk gate; the rest hold."
    },
    "reports": []
  },
  "error": null
}
```

</ApiExamples>
</div>
