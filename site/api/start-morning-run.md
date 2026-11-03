---
title: start_morning_run
description: Ask for today's morning run on the team portfolio, as the admin. The run starts within a minute.
api: { method: POST, path: /function/start_morning_run, auth: Admin token }
related:
  - { text: Starting a run by hand, link: /guide/manual-run }
  - { text: user/login, link: /api/login }
---

Requests today's morning run, for a day the scheduled run missed.
The endpoint only records the request; a scheduled job starts the run within a minute, and it takes about 20 minutes.
Only the admin may call it.
See [Starting a run by hand](/guide/manual-run) for the whole procedure.

<div class="api-grid">
<div class="api-main">

## Headers

<Param name="Authorization" type="string" required location="header">

`Bearer <token>`, from [`user/login`](/api/login) as the admin.

</Param>

## Body

This endpoint takes no parameters.
The day is always today in New York.

## Response

Returns a `ManualRun` in `data.result`.

<Param name="started" type="boolean" required>

`true` when the request was recorded.

</Param>
<Param name="run_day" type="string" required>

Today's trading date in New York.

</Param>
<Param name="message" type="string" required>

What happens next, or why the request was refused.

</Param>

## Refusals

A refusal answers `200` with `started: false`:

| `message` | When |
| --- | --- |
| `Only the admin can start a run.` | The token is not the admin's. |
| `<day> is a weekend; the market is closed.` | It is Saturday or Sunday in New York. |
| `The team portfolio holds the demo history, which never runs.` | The server holds [demo data](/guide/demo-data). |
| `The run for <day> has already started (status: <status>).` | The day already has a run, in any status. |

A request with no token, or an expired one, answers `401` with `error.code` `UNAUTHORIZED`.

</div>
<ApiExamples>

<p class="example-label">Request</p>

::: code-group

```bash [cURL]
curl -s -X POST http://localhost:8000/function/start_morning_run \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  -d '{}'
```

```js [JavaScript]
const res = await fetch('http://localhost:8000/function/start_morning_run', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
  body: JSON.stringify({})
})
const { data } = await res.json()
const result = data.result
```

```python [Python]
import httpx

res = httpx.post(
    'http://localhost:8000/function/start_morning_run',
    json={}, headers={'Authorization': f'Bearer {token}'},
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
      "started": true,
      "run_day": "2026-11-02",
      "message": "The morning run for 2026-11-02 starts within a minute and takes about 20 minutes. The trading tick executes it once it finishes, if the team portfolio is in auto mode."
    },
    "reports": []
  },
  "error": null
}
```

</ApiExamples>
</div>
