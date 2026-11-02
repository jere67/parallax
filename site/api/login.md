---
title: user/login
description: Sign in with a username and password and get a bearer token for private endpoints.
api: { method: POST, path: /user/login, auth: none }
related:
  - { text: Authentication, link: /api/authentication }
  - { text: start_morning_run, link: /api/start-morning-run }
---

Signs a user in and returns a JWT.
The token goes in the `Authorization` header of a private endpoint such as [`start_morning_run`](/api/start-morning-run).
This endpoint is built into the Jac server.

<div class="api-grid">
<div class="api-main">

## Body

<Param name="identity" type="object" required>

Who is signing in.

<Fields title="Show identity fields" open>

<Param name="type" type="string" required>`"username"` or `"email"`.</Param>
<Param name="value" type="string" required>The username or email address. The admin account's username is `admin`.</Param>

</Fields>

</Param>
<Param name="credential" type="object" required>

The password.

<Fields title="Show credential fields" open>

<Param name="type" type="string" required>`"password"`.</Param>
<Param name="password" type="string" required>The admin's password is the `ADMIN_PASSWORD` the server read when it created the account.</Param>

</Fields>

</Param>

## Response

The user record in `data`, with the session token added.

<Param name="token" type="string" required>

A JWT. Send it as `Authorization: Bearer <token>`.

</Param>
<Param name="user_id" type="string">

The user's ID.

</Param>
<Param name="root_id" type="string">

The ID of the user's graph root.

</Param>

## Errors

| Status | `error.code` | When |
| --- | --- | --- |
| `401` | `UNAUTHORIZED` | The username or password is wrong. The message is `Invalid credentials` in both cases. |
| `422` | | A field is missing. |

</div>
<ApiExamples>

<p class="example-label">Request</p>

::: code-group

```bash [cURL]
curl -s -X POST http://localhost:8000/user/login \
  -H 'Content-Type: application/json' \
  -d "{\"identity\":{\"type\":\"username\",\"value\":\"admin\"},\"credential\":{\"type\":\"password\",\"password\":\"$ADMIN_PASSWORD\"}}"
```

```js [JavaScript]
const res = await fetch('http://localhost:8000/user/login', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({
    identity: { type: 'username', value: 'admin' },
    credential: { type: 'password', password: process.env.ADMIN_PASSWORD }
  })
})
const { data } = await res.json()
const token = data.token
```

```python [Python]
import os
import httpx

res = httpx.post(
    'http://localhost:8000/user/login',
    json={
        'identity': {'type': 'username', 'value': 'admin'},
        'credential': {'type': 'password', 'password': os.environ['ADMIN_PASSWORD']},
    },
)
token = res.json()['data']['token']
```

:::

<p class="example-label">Response · 200</p>

```json
{
  "ok": true,
  "type": "response",
  "data": {
    "user_id": "\u2026",
    "root_id": "\u2026",
    "token": "eyJhbGciOiJIUzI1NiIs\u2026"
  },
  "error": null
}
```

</ApiExamples>
</div>
