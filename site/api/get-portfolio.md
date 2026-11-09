---
title: get_portfolio
description: The caller's own portfolio now - equity, returns, drawdown, exposure, open positions, closed trades, and recent orders.
api: { method: POST, path: /function/get_portfolio, auth: Bearer token }
related:
  - { text: Data types, link: /api/types#portfolioview }
  - { text: Reading the dashboard, link: /guide/dashboard#portfolio }
---

Returns the caller's own agent portfolio as of its last mark.
It needs a bearer token; an anonymous call answers `401`.
The admin gets the team portfolio, and on a server in demo mode every account gets the demo portfolio.
The dashboard's header and Portfolio page are built from this one call.
The view is rebuilt every minute and cached for up to 120 seconds.

<div class="api-grid">
<div class="api-main">

## Body

This endpoint takes no parameters.

## Response

Returns a [`PortfolioView`](/api/types#portfolioview).
Money is in dollars, returns are fractions, and a missing figure is `null`, never 0.

### Before the forward test

When the caller has no portfolio yet, the response is a minimal view: `name` is `"agent"`, `mode` is `"insight"`, and `started` is `false`.
Every figure is `null` and every list is empty.

### Fields

<Param name="name" type="string" required>

The portfolio's name: `"agent"` for a user's own agent, `"team"` for the admin's.

</Param>
<Param name="mode" type="string" required>

`"insight"` (decisions are published, not traded) or `"auto"` (decisions are traded).

</Param>
<Param name="started" type="boolean" required>

`true` once the forward test has started and the portfolio has a starting balance.

</Param>
<Param name="demo" type="boolean">

`true` when the portfolio holds [demo history](/guide/demo-data).

</Param>
<Param name="starting_cash" type="number">

The balance the forward test started with.

</Param>
<Param name="as_of" type="string">

When the figures were marked, in UTC.

</Param>
<Param name="last_day" type="string">

The trading date of the last mark.

</Param>
<Param name="equity" type="number | null">

Cash plus the value of open positions.

</Param>
<Param name="cash" type="number | null">

Cash in the account.

</Param>
<Param name="positions_value" type="number | null">

The value of open positions at their last price.

</Param>
<Param name="day_pnl" type="number | null">

The change in equity since the previous mark (or the starting balance on the first day). `day_return` is the same as a fraction.

</Param>
<Param name="total_pnl" type="number | null">

Equity minus the starting balance. `total_return` is the same as a fraction.

</Param>
<Param name="peak_equity" type="number | null">

The highest equity marked so far.

</Param>
<Param name="drawdown" type="number | null">

The fall from `peak_equity`, as a fraction. New buys halt at 0.10.

</Param>
<Param name="gross_exposure" type="number | null">

The value of open positions as a fraction of equity. The cap is 0.90.

</Param>
<Param name="sessions" type="integer">

Trading sessions marked since the start.

</Param>
<Param name="bypasses" type="integer">

Broker orders found by reconciliation that the system did not place. Should be 0.

</Param>
<Param name="drift" type="integer">

Positions where the ledger and the broker disagree on quantity. Should be 0.

</Param>
<Param name="positions" type="PositionView[]">

Open positions, largest market value first.

<Fields title="Show PositionView fields">

<Param name="ticker" type="string" required />
<Param name="sector" type="string" required />
<Param name="qty" type="integer" required>Shares held. 0 for a closed position.</Param>
<Param name="avg_entry_price" type="number" required />
<Param name="opened_at" type="string" required />
<Param name="last_price" type="number | null">With `priced_at`, when it was read.</Param>
<Param name="market_value" type="number | null" />
<Param name="weight" type="number | null">Market value as a fraction of equity.</Param>
<Param name="pnl" type="number | null">Unrealized for an open position, realized for a closed one. `pnl_pct` is the same as a fraction of cost.</Param>
<Param name="stop_price" type="number | null">The protective stop. `stop_distance` is its distance below the last price, as a fraction.</Param>
<Param name="time_stop" type="string">The date the position is closed if its exit condition has not fired.</Param>
<Param name="closed_at" type="string">Empty while open. With `exit_price` once closed.</Param>
<Param name="entry_qty" type="integer">Shares bought in total.</Param>
<Param name="thesis" type="string">The Arbiter's thesis for the decision that opened it.</Param>
<Param name="decision_day" type="string">The run that opened it. Pass it with the ticker to <a href="./get-decision-trail">get_decision_trail</a>.</Param>

</Fields>

</Param>
<Param name="closed" type="PositionView[]">

The 40 most recently closed positions, with realized P&L.

</Param>
<Param name="orders" type="OrderView[]">

The 60 most recent orders, with their fills. See [OrderView](/api/types#orderview).

</Param>

</div>
<ApiExamples>

<p class="example-label">Request</p>

::: code-group

```bash [cURL]
curl -s -X POST http://localhost:8000/function/get_portfolio \
  -H 'Content-Type: application/json' \
  -d '{}'
```

```js [JavaScript]
const res = await fetch('http://localhost:8000/function/get_portfolio', {
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
    'http://localhost:8000/function/get_portfolio',
    json={},
)
result = res.json()['data']['result']
```

:::

<p class="example-label">Response · 200, lists trimmed to one item</p>

```json
{
  "ok": true,
  "type": "response",
  "data": {
    "result": {
      "as_of": "2026-10-30T20:30:00+00:00",
      "bypasses": 0,
      "cash": 72129.24,
      "closed": [
        {
          "avg_entry_price": 170.538,
          "closed_at": "2026-10-29T13:46:00+00:00",
          "decision_day": "2026-10-15",
          "entry_qty": 35,
          "exit_price": 174.31,
          "last_price": null,
          "market_value": null,
          "opened_at": "2026-10-15T13:46:00+00:00",
          "pnl": 132.02,
          "pnl_pct": 0.0221,
          "priced_at": "",
          "qty": 0,
          "sector": "Communication Services",
          "stop_distance": null,
          "stop_price": 165.27,
          "thesis": "GOOGL screens well and the panel leans positive: technical momentum and steady fundamentals point the same way over about two weeks.",
          "ticker": "GOOGL",
          "time_stop": "2026-10-29",
          "weight": null
        }
      ],
      "day_pnl": 968.46,
      "day_return": 0.0094,
      "demo": true,
      "drawdown": 0.0,
      "drift": 0,
      "equity": 103466.7,
      "gross_exposure": 0.3029,
      "last_day": "2026-10-30",
      "mode": "auto",
      "name": "team",
      "opened_at": "2026-09-30T13:00:00+00:00",
      "orders": [
        {
          "client_order_id": "NEE-20261028134600-stop3",
          "filled_avg_price": null,
          "filled_qty": 0,
          "fills": [],
          "limit_price": null,
          "order_type": "stop",
          "purpose": "stop",
          "qty": 55,
          "reject_reason": "",
          "run_day": "",
          "side": "sell",
          "status": "new",
          "stop_price": 71.74,
          "submitted_at": "2026-10-30T13:47:00+00:00",
          "ticker": "NEE",
          "time_in_force": "gtc",
          "updated_at": "2026-10-30T13:47:00+00:00"
        }
      ],
      "peak_equity": 103466.7,
      "positions": [
        {
          "avg_entry_price": 224.6006,
          "closed_at": "",
          "decision_day": "2026-10-27",
          "entry_qty": 31,
          "exit_price": null,
          "last_price": 243.42,
          "market_value": 7546.02,
          "opened_at": "2026-10-27T13:46:00+00:00",
          "pnl": 583.4,
          "pnl_pct": 0.0838,
          "priced_at": "2026-10-30T20:30:00+00:00",
          "qty": 31,
          "sector": "Financials",
          "stop_distance": 0.1147,
          "stop_price": 215.5,
          "thesis": "JPM screens well and the panel leans positive: technical momentum and steady fundamentals point the same way over about two weeks.",
          "ticker": "JPM",
          "time_stop": "2026-11-10",
          "weight": 0.0729
        }
      ],
      "positions_value": 31337.46,
      "sessions": 23,
      "started": true,
      "starting_cash": 100000.0,
      "total_pnl": 3466.7,
      "total_return": 0.0347
    },
    "reports": []
  },
  "error": null
}
```

</ApiExamples>
</div>
