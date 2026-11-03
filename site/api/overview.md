---
title: API overview
description: How to call the server's endpoints, what every response looks like, and which endpoints exist.
related:
  - { text: Authentication, link: /api/authentication }
  - { text: Data types, link: /api/types }
---

The dashboard reads everything it shows through a small HTTP API, and anyone can call it.
Every endpoint is a Jac function exposed by the server: you send a `POST` with a JSON body of its parameters and read the result from the response's `data.result`.
The read endpoints are public; only [`start_morning_run`](/api/start-morning-run) needs a token.

## Base URL

A local server answers at:

```text
http://localhost:8000
```

The examples on these pages use that address.
`/docs` on a running server lists every endpoint with its schema.

## Calling a function

```bash
curl -s -X POST http://localhost:8000/function/get_run \
  -H 'Content-Type: application/json' \
  -d '{"run_date": "2026-10-30"}'
```

- The method is always `POST`, even for reads.
- The path is `/function/<name>`.
- The body is a JSON object of the function's parameters.
  Send `{}` for a function without parameters.
- A missing required parameter answers `422`.

## The response envelope

Every function call answers with the same envelope:

```json
{
  "ok": true,
  "type": "response",
  "data": {
    "result": { "run_date": "2026-10-30", "status": "normal" },
    "reports": []
  },
  "error": null
}
```

<Param name="ok" type="boolean" required>

`true` when the call succeeded.

</Param>
<Param name="data.result" type="any">

The function's return value. `null` when the function returned nothing, such as `get_run` for a date with no run.

</Param>
<Param name="error" type="object | null">

On failure, `{"code": "...", "message": "..."}`, with `ok` set to `false` and `data` set to `null`.

</Param>

Each object in `result` also carries a few `_jac_` fields (`_jac_type`, `_jac_id`, and others) that name its type on the server.
These docs leave them out of the examples; ignore them.

## Endpoints

<Cards :cols="2">
<Card title="get_portfolio" icon="chart" link="/api/get-portfolio">The team portfolio now: equity, returns, positions, orders.</Card>
<Card title="get_performance" icon="chart" link="/api/get-performance">Daily equity of the portfolio and both baselines.</Card>
<Card title="list_runs" icon="clock" link="/api/list-runs">Every morning run, newest first.</Card>
<Card title="get_run" icon="clock" link="/api/get-run">One run, with a row per covered ticker.</Card>
<Card title="get_decision_trail" icon="search" link="/api/get-decision-trail">Everything behind one decision.</Card>
<Card title="start_morning_run" icon="terminal" link="/api/start-morning-run">Start today's run by hand. Admin only.</Card>
</Cards>

| Endpoint | Method and path | Auth |
| --- | --- | --- |
| [`health`](/api/health) | `POST /function/health` | none |
| [`healthz`](/api/healthz) | `GET /healthz` | none |
| [`get_portfolio`](/api/get-portfolio) | `POST /function/get_portfolio` | none |
| [`get_performance`](/api/get-performance) | `POST /function/get_performance` | none |
| [`list_runs`](/api/list-runs) | `POST /function/list_runs` | none |
| [`get_run`](/api/get-run) | `POST /function/get_run` | none |
| [`get_decision_trail`](/api/get-decision-trail) | `POST /function/get_decision_trail` | none |
| [`user/login`](/api/login) | `POST /user/login` | none |
| [`start_morning_run`](/api/start-morning-run) | `POST /function/start_morning_run` | admin token |

`GET /functions` lists every function the server serves.
It also lists four formatting helpers (`money`, `percent`, `ratio`, and `chart_points`) that are public but unused: the dashboard formats numbers in the client.

## Freshness

The dashboard endpoints read from a cache that is at most 120 seconds old.
The portfolio, performance, run list, and newest run are rebuilt every minute; other runs and decision trails are built on first request.
See [Dashboard internals](/system/dashboard#read-cache).

## Conventions

- Money is in dollars, and returns and weights are fractions: `0.012` is 1.2%.
- Trading dates are `YYYY-MM-DD` in New York time; timestamps are ISO 8601 in UTC.
- A missing figure is `null`, never 0.
- Tickers are upper case. `get_decision_trail` accepts any case.

## Adding an endpoint

An endpoint is a `def:pub` (public) or `def:priv` (signed-in) function, imported by name in `main.jac`.
A function that is not imported answers 404 or 405, and `tests/endpoints_tests.jac` fails for any marked function the server does not serve.
Return a typed object from `models/views.jac`, so the API stays a contract.
