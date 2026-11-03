---
title: healthz
description: The server's built-in liveness check, answered before any app code runs.
api: { method: GET, path: /healthz, auth: none }
related:
  - { text: health, link: /api/health }
---

A liveness check built into the Jac server.
It answers as soon as the server accepts connections, without calling any of the app's code, so it is the right check for a process supervisor or a boot script.
CI waits up to 2 minutes for it before running anything else.

<div class="api-grid">
<div class="api-main">

## Request

A plain `GET` with no body and no parameters.

## Response

<Param name="status" type="string" required>

`"ok"`.

</Param>

Note that this response is not wrapped in the `ok`/`data`/`error` envelope that function calls use.

</div>
<ApiExamples>

<p class="example-label">Request</p>

::: code-group

```bash [cURL]
curl -s http://localhost:8000/healthz
```

```js [JavaScript]
const res = await fetch('http://localhost:8000/healthz')
const body = await res.json()
```

```python [Python]
import httpx

res = httpx.get('http://localhost:8000/healthz')
body = res.json()
```

:::

<p class="example-label">Response · 200</p>

```json
{
  "status": "ok"
}
```

</ApiExamples>
</div>
