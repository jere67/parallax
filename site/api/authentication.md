---
title: Authentication
description: Which endpoints are public, how to sign up and get a token, and how the admin check works.
related:
  - { text: user/login, link: /api/login }
  - { text: start_morning_run, link: /api/start-morning-run }
---

Almost the whole API is private.
Every data endpoint answers `401` to an anonymous caller, and an account can see only its own agent's data.

## Public endpoints

Only [`health`](/api/health), [`healthz`](/api/healthz), the landing page, and static assets answer anyone, with no token.

## Private endpoints

Functions marked `def:protect` need a signed-in user's token.
That covers the dashboard endpoints, the [policy endpoints](/api/policy), and the [account endpoints](/api/accounts).

<Steps>

1. **Sign up, once.**
   Sign-up is open.
   The pages at `/signup` and `/login` take an email and a password, and offer no Google, passkey, SSO, or forgot-password.
   Over the API, call `POST /user/register` with the email as a `username` identity and a password credential (see [`user/login`](/api/login)).

2. **Sign in.**
   Call [`user/login`](/api/login) with the same email and password.

3. **Read the token** from `data.token`.

4. **Send it** as a bearer token on each private call:

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

## Changing a password

A signed-in user changes their password in Settings, which calls `PUT /user/password` with a bearer token and a JSON body of `current_password` and `new_password`.
There is no forgot-password flow; the admin can reset a password by hand.

## The admin

The server creates one admin account, `admin`, with the password in `ADMIN_PASSWORD` (from `[scale.admin]` in `jac.toml`).
The password is read once, when the account is created; changing the variable later does not change it.

The admin's agent is the existing team agent, with its history and policy, and it keeps using the server's `.env` keys and its existing jobs.
Every other account starts empty.

`start_morning_run` checks more than a valid token: it looks up the caller's user and refuses unless the user's role is `admin`.
Any other signed-in user gets `started: false` and the message `Only the admin can start a run.`

::: warning Set ADMIN_PASSWORD
Without it, the server makes a one-time admin password and prints it in its log once.
Set it before the server first starts on any machine others can reach.
A new server refuses to start when the password is shorter than 8 characters, is a common password, or contains `admin`.
:::
