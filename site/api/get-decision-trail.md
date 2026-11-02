---
title: get_decision_trail
description: Everything behind one decision - research, every specialist sample, the consensus, the Arbiter, the risk gate, and the orders.
api: { method: POST, path: /function/get_decision_trail, auth: none }
related:
  - { text: Reading the dashboard, link: /guide/dashboard#decision-trail }
  - { text: Stochastic consensus, link: /system/consensus }
  - { text: Risk gate, link: /system/risk-gate }
---

Returns the full trail of one ticker's decision on one day, in the order the system made it.
This is the audit record: every claim a research agent made with its source, every vote with its rationale, and every risk rule with its result.

<div class="api-grid">
<div class="api-main">

## Body

<Param name="run_date" type="string" required>

The run's trading date, `YYYY-MM-DD`.

</Param>
<Param name="ticker" type="string" required>

The ticker. Case does not matter: `amzn` and `AMZN` are the same.

</Param>

A missing parameter answers `422` with the field that is missing.

## Response

Returns a [`TrailView`](/api/types#trailview), or `null` when the ticker was not covered on that date.

<Param name="run_date" type="string" required>

With `ticker`, `sector`, `reason`, `run_status`, and `mode`: what was covered and why.

</Param>
<Param name="last_close" type="number | null">

The ticker's facts at the run: `atr_14`, `realized_vol_20`, `volume_20`, `sessions_to_earnings`, and `screen_score`.

</Param>
<Param name="fetch_errors" type="string[]">

Data that could not be collected.

</Param>
<Param name="research" type="ResearchView[]">

One report per domain (market, fundamentals, news, macro), first reports before follow-ups.

<Fields title="Show ResearchView fields">

<Param name="domain" type="string" required />
<Param name="view" type="string" required>The report's stance.</Param>
<Param name="confidence" type="number" required />
<Param name="summary" type="string" required />
<Param name="evidence" type="EvidenceView[]">Each claim with its `source_url`, `published` date, and `host`.</Param>
<Param name="risks" type="string[]" />
<Param name="data_gaps" type="string[]" />
<Param name="followup_question" type="string">The Orchestrator's question, for a follow-up report.</Param>

</Fields>

</Param>
<Param name="specialists" type="SpecialistView[]">

One per specialist, with its mean `score`, `weight`, and every sample.

<Fields title="Show SampleView fields">

<Param name="sample" type="integer" required>The sample's index.</Param>
<Param name="stance" type="string" required>`STRONG_SELL`, `SELL`, `HOLD`, `BUY`, or `STRONG_BUY`.</Param>
<Param name="confidence" type="number" required />
<Param name="signed" type="number" required>The vote's score: the stance's score (-2 to +2) halved, times confidence, so -1 to +1.</Param>
<Param name="horizon_days" type="integer" required />
<Param name="rationale" type="string" required />
<Param name="cited" type="integer[]">Indexes into the specialist's evidence packet. `sources` holds those sources.</Param>
<Param name="excess_return" type="number | null">Once scored: return over the horizon minus SPY's. `hit` is whether the stance's sign matched.</Param>

</Fields>

</Param>
<Param name="consensus" type="ConsensusView | null">

`score`, `agreement`, `ci_low`, `ci_high`, `draft_action`, `samples_used`, and `samples_dropped`.

</Param>
<Param name="decision" type="DecisionView | null">

The final `action` and `conviction`, the `thesis`, `risks`, `exit_condition`, `time_stop`, the `arbiter_verdict` (`CONFIRM` or `DOWNGRADE`), and any `downgrade_reason` or `forced_hold_reason`.

</Param>
<Param name="gate" type="GateView | null">

The risk check: `outcome`, `side`, `purpose`, `requested_qty`, `approved_qty`, `price`, `stop_distance`, `gate_version`, and each rule with `passed`, `detail`, `qty_before`, and `qty_after`.

</Param>
<Param name="orders" type="OrderView[]">

The orders placed for the decision, and the position's stop orders, with fills.

</Param>
<Param name="position" type="PositionView | null">

The position the decision opened or changed, if any.

</Param>
<Param name="tickers" type="string[]">

Every ticker covered by the same run, for previous and next links.

</Param>
<Param name="disclaimer" type="string">

The project's disclaimer, to show with the trail.

</Param>

</div>
<ApiExamples>

<p class="example-label">Request</p>

::: code-group

```bash [cURL]
curl -s -X POST http://localhost:8000/function/get_decision_trail \
  -H 'Content-Type: application/json' \
  -d '{"run_date": "2026-10-30", "ticker": "AMZN"}'
```

```js [JavaScript]
const res = await fetch('http://localhost:8000/function/get_decision_trail', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({"run_date": "2026-10-30", "ticker": "AMZN"})
})
const { data } = await res.json()
const result = data.result
```

```python [Python]
import httpx

res = httpx.post(
    'http://localhost:8000/function/get_decision_trail',
    json={'run_date': '2026-10-30', 'ticker': 'AMZN'},
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
      "atr_14": 4.8029,
      "consensus": {
        "agreement": 0.2667,
        "ci_high": 0.1793,
        "ci_low": -0.0453,
        "draft_action": "TRIM",
        "samples_dropped": 0,
        "samples_used": 15,
        "score": 0.045
      },
      "decision": {
        "action": "TRIM",
        "arbiter_verdict": "CONFIRM",
        "conviction": 0.012,
        "downgrade_reason": "",
        "exit_condition": "A close below 197.99 (two ATRs under the last close), or the panel turning negative.",
        "forced_hold_reason": "",
        "model": "openrouter/nvidia/nemotron-3-super-120b-a12b:free",
        "risks": [
          "Rising yields could rotate money out of the sector.",
          "Valuation leaves little room for a miss."
        ],
        "thesis": "The panel's case on AMZN is not strong enough to act on: score +0.04 with agreement 27%.",
        "time_stop": "2026-11-11"
      },
      "demo": true,
      "disclaimer": "An educational student project trading simulated money. Nothing here is investment advice, and past simulated performance does not predict future results.",
      "fetch_errors": [],
      "flag_reason": "",
      "gate": {
        "approved_qty": 6,
        "checked_at": "2026-10-30T13:45:00+00:00",
        "gate_version": "2026-10-20.1",
        "outcome": "approved",
        "price": 208.2,
        "purpose": "trim",
        "requested_qty": 6,
        "rules": [
          {
            "detail": "12 shares held",
            "passed": true,
            "qty_after": 6,
            "qty_before": 6,
            "rule": "shares held"
          }
        ],
        "side": "sell",
        "stop_distance": null
      },
      "last_close": 207.6,
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
      "orders": [
        {
          "client_order_id": "2026-10-30-AMZN-trim",
          "filled_avg_price": 208.12,
          "filled_qty": 6,
          "fills": [
            {
              "filled_at": "2026-10-30T13:46:00+00:00",
              "price": 208.12,
              "qty": 6
            }
          ],
          "limit_price": 207.58,
          "order_type": "limit",
          "purpose": "trim",
          "qty": 6,
          "reject_reason": "",
          "run_day": "2026-10-30",
          "side": "sell",
          "status": "filled",
          "stop_price": null,
          "submitted_at": "2026-10-30T13:45:00+00:00",
          "ticker": "AMZN",
          "time_in_force": "day",
          "updated_at": "2026-10-30T13:46:00+00:00"
        }
      ],
      "position": null,
      "realized_vol_20": 0.236,
      "reason": "held",
      "reason_note": "open position",
      "research": [
        {
          "as_of": "2026-10-30T11:50:00+00:00",
          "confidence": 0.69,
          "data_gaps": [
            "No intraday data."
          ],
          "domain": "market",
          "evidence": [
            {
              "claim": "Closed at 207.60 on 2026-10-29, +0.0% over 20 sessions.",
              "host": "data.alpaca.markets",
              "published": "2026-10-29",
              "source_url": "https://data.alpaca.markets/v2/stocks/bars?symbols=AMZN&timeframe=1Day&start=2026-10-01"
            }
          ],
          "followup_question": "",
          "model": "openrouter/nvidia/nemotron-3-super-120b-a12b:free",
          "risks": [
            "A guidance cut at the next report."
          ],
          "summary": "AMZN closed at 207.60, +0.0% over 20 sessions and +1.4% against its 30-day average. ATR(14) is 4.80 and 20-day realized volatility 24%. Volume is near its 20-day average of 34.9M shares.",
          "view": "SELL"
        }
      ],
      "run_date": "2026-10-30",
      "run_status": "normal",
      "screen_score": null,
      "sector": "Consumer Discretionary",
      "sessions_to_earnings": 17,
      "specialists": [
        {
          "samples": [
            {
              "cited": [
                1
              ],
              "confidence": 0.62,
              "excess_return": null,
              "hit": null,
              "horizon_days": 10,
              "rationale": "Growth is steady but already priced in at this multiple; nothing in the filings moves the case either way.",
              "sample": 0,
              "signed": 0.0,
              "sources": [
                {
                  "claim": "Reported financial facts from XBRL company facts.",
                  "host": "data.sec.gov",
                  "published": "2026-09-25",
                  "source_url": "https://data.sec.gov/api/xbrl/companyfacts/CIK0001018724.json"
                }
              ],
              "stance": "HOLD"
            }
          ],
          "score": 0.0,
          "specialist": "fundamentals",
          "weight": 1.0
        }
      ],
      "ticker": "AMZN",
      "tickers": [
        "AAPL",
        "MSFT",
        "HD"
      ],
      "volume_20": 34886427.3511
    },
    "reports": []
  },
  "error": null
}
```

</ApiExamples>
</div>
