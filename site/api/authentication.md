---
title: Authentication
description: Which endpoints are public, how to get a token for the private one, and how the admin check works.
related:
  - { text: user/login, link: /api/login }
  - { text: start_morning_run, link: /api/start-morning-run }
---

Almost the whole API is public and read-only.
Only one endpoint changes anything, [`start_morning_run`](/api/start-morning-run), and only the admin may call it.

## Public endpoints

Functions marked `def:pub` answer anyone, with no token.
The dashboard calls them anonymously.

They can read the team graph because every node the dashboard shows is granted public read access when it is written.
A node that is not granted (such as a private user's data) stays invisible to them.
See [Making nodes public](/system/data-model#making-nodes-public).

## Private endpoints

Functions marked `def:priv` need a signed-in user's token.

<Steps>

1. **Sign in.**
   Call [`user/login`](/api/login) with a username and password.

2. **Read the token** from `data.token`.

3. **Send it** as a bearer token on each private call:

   ```text
   Authorization: Bearer <token>
   ```

</Steps>

A call with no token, or an expired one, answers `401`:

```json
{
  "ok": false,
  "type": "error",
  "data": null,
  "error": { "code": "UNAUTHORIZED", "message": "Unauthorized" }
}
```

## The admin

The server creates one admin account, `admin`, with the password in `ADMIN_PASSWORD` (from `[scale.admin]` in `jac.toml`).
The password is read once, when the account is created; changing the variable later does not change it.

`start_morning_run` checks more than a valid token: it looks up the caller's user and refuses unless the user's role is `admin`.
Any other signed-in user gets `started: false` and the message `Only the admin can start a run.`

::: warning Set ADMIN_PASSWORD
Without it, the admin password is `changeme`.
Set it before the server first starts on any machine others can reach.
:::
