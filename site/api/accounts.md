---
title: Account endpoints
description: Read your agent's settings, connect or disconnect your keys, turn paper trading on or off, and start your own run.
related:
  - { text: Your agent, link: /guide/your-agent }
  - { text: Authentication, link: /api/authentication }
  - { text: Policy endpoints, link: /api/policy }
---

These endpoints are what the Settings page calls.
Every one is a `POST` to `/function/<name>` with a JSON body, as described in the [overview](/api/overview), and every one is private: it needs a bearer token and answers `401` to an anonymous caller.
Each acts on the caller's own account, which no parameter names, so a request can only reach its caller's agent.

| Function | Parameters | Returns |
| --- | --- | --- |
| `get_agent_settings` | None | An `AgentSettings`: the keys, the paper trading choice, and today's run |
| `save_agent_keys` | `alpaca_key`, `alpaca_secret`, `openrouter_key`, `finnhub_key` (all optional, default empty) | A `KeysReply` |
| `remove_agent_keys` | `provider`: `alpaca`, `openrouter`, or `finnhub` | An `AgentReply` |
| `set_paper_trading` | `on`: boolean | An `AgentReply` |
| `start_my_run` | None | An `AgentReply` |
| `get_transfer_status` | None | A `TransferStatus`; admins only |
| `start_transfer` | `data`: base64 of an export file | A `TransferStatus`; admins only |

## AgentSettings

<Param name="managed" type="boolean" required>

`true` for the admin, whose agent runs on the server's own keys and is only described here.

</Param>
<Param name="demo" type="boolean" required>

`true` on a server in demo mode, which runs and trades nothing.

</Param>
<Param name="can_store" type="boolean" required>

`false` when the server has no usable `PARALLAX_KEYS_SECRET`, so it cannot store keys.

</Param>
<Param name="full" type="boolean" required>

`true` when the server is at its `PARALLAX_MAX_AGENTS` limit and the caller has no agent yet.

</Param>
<Param name="ready" type="boolean" required>

`true` when every required key is connected, or for the admin.

</Param>
<Param name="paper_trading" type="boolean" required>

Whether the agent places paper orders.

</Param>
<Param name="keys" type="list" required>

One row per key: `name`, `label`, `required`, `connected`, `hint` (the last few characters, or the paper account for the Alpaca secret), and `checked_at` (when its provider last accepted it).
The rows are the Alpaca key ID, the Alpaca secret key, the OpenRouter key, and the optional Finnhub key.
A key's value is never returned.

</Param>
<Param name="run" type="object" required>

Today's run: `day`, `status` (empty, `queued`, `running`, or the finished run's status), `can_start`, and a `note` that says why it cannot start, or what is happening.

</Param>
<Param name="requests_note" type="string">

What the OpenRouter key allows each day, when it is below what a full run needs.

</Param>
<Param name="trading_started" type="boolean">

Whether the agent's forward test has started.

</Param>

## save_agent_keys

Send only the keys you want to connect; a blank field keeps what is stored.
Alpaca's key and secret must be sent together.
Each key is checked with its provider first, a live Alpaca account is refused, and nothing is stored unless every key sent passes.

A `KeysReply` carries `saved`, the new `settings`, a `message`, and `problems`, a map from `alpaca`, `openrouter`, or `finnhub` to why that provider refused.
A refusal answers `200` with `saved: false`.
It happens when:

- The server has no `PARALLAX_KEYS_SECRET`, or is at its limit of agents.
- The caller is the admin, whose agent runs on the server's own keys.
- Today's run is working.
- A value contains spaces or is longer than 256 characters.

```bash
curl -s -X POST http://localhost:8000/function/save_agent_keys \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"alpaca_key":"PK...","alpaca_secret":"...","openrouter_key":"sk-or-..."}'
```

## remove_agent_keys

Disconnects one provider's keys.
Without Alpaca or OpenRouter the agent stops running and trading, and paper trading is switched off.
It is refused while today's run is working.
An `AgentReply` carries `ok`, a `message`, and the new `settings`.

## set_paper_trading

`on: true` turns paper orders on from the agent's next morning run.
The first time, the paper account must hold no positions and no open orders, and the call is refused with the counts if it does.
`on: false` stops new orders; open positions stay on Alpaca.
It is refused for the admin, on a demo server, and when the Alpaca or OpenRouter key is not connected.

## start_my_run

Asks for today's run on the caller's own keys.
It starts within a minute or two and takes about half an hour.
It is refused when keys are missing, on a weekend, while a run is working, when the run was already asked for, when the day already has a run, and on a demo server.
For the admin, it does what [`start_morning_run`](/api/start-morning-run) does.

## get_transfer_status and start_transfer

These move another server's records here, as [Bring your records along](/guide/deploy#bring-your-records-along) describes.
A non-admin caller gets an empty status, and `start_transfer` refuses them.

`start_transfer` takes `data`, the base64 of a file from `scripts/export-data.sh`, gzipped or not.
It checks the file, then moves it in the background and returns at once; `get_transfer_status` reports how the move went.
It refuses a server with runs of its own, a file that is not a whole server's records, and a file with classes this server does not have.

A `TransferStatus` has:

- `state`: empty before any move, then `running`, `done`, or `failed`; `refused` answers an upload that was not taken.
- `message`: what happened, in words.
- `ready`: `true` for an admin of a server that can take a move now.
- `runs`: how many runs this server has.

Once a move is `done`, the accounts are the old server's, so the caller's session no longer names an account.

## Changing a password

This is the server's built-in `PUT /user/password`, not a function.
Send a bearer token and `{"current_password": "...", "new_password": "..."}`.
See [`user/login`](/api/login).
