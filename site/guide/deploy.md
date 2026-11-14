---
title: Deploying to JacHammer
description: Host Parallax on JacHammer with its own Postgres, one pod running the scheduler, keys kept on the server, and a check that it trades on paper.
related:
  - { text: Configuration, link: /guide/configuration }
  - { text: Your agent, link: /guide/your-agent }
  - { text: The forward test, link: /guide/forward-test }
---

[JacHammer](https://jachammer.ai) is Jaseci Labs' hosting for Jac apps.
A production deploy runs the app with `jac scale deploy` on Kubernetes, so Parallax gets the same server it runs on a laptop: one process that serves the dashboard and runs the scheduled jobs.
This page takes a deploy from nothing to a checked, public URL.

## What a deploy runs

| Part | Where it lives | Kept across restarts and redeploys |
| --- | --- | --- |
| The server and its scheduler | One pod. `jac.toml` pins `min_replicas` and `max_replicas` to 1, since the model rate limiter, the run guards, and the view caches live in the process. | Restarted with each deploy |
| The graph: accounts, runs, votes, decisions, orders, evaluations | A Postgres of the app's own on a persistent volume (`database_mode = "provision"`) | Yes |
| Server keys and passwords | JacHammer project environment variables, passed to the pod as a Kubernetes Secret | Yes |
| Each user's own keys | The graph, sealed under `PARALLAX_KEYS_SECRET` | Yes |
| The raw provider cache (`storage/`) and the market pages' files (`.jac/market/`) | The pod's disk | No. Both rebuild: the next provider calls refill the cache, and the market refresh jobs refill the market pages. |

::: warning Confirm on the first deploy
JacHammer's documentation does not describe its database.
The settings above follow `jac scale deploy`, which provisions a Postgres on a persistent volume by default.
Step 6 below checks that the volume exists and that data survives a redeploy.
:::

## Before you start

**A plan.** A permanent deploy needs the Builder plan ($15 a month), which allows one.
The free plan's sandbox deploy expires after 30 days.

**An Alpaca account of the host's own.** Give the hosted server its own Alpaca paper account, not the one the team's laptop server uses.
Two servers with the same Alpaca keys would each trade the same paper account.
Alpaca lets one login hold several paper accounts, each with its own keys; a second login works too.

**An OpenRouter account of the host's own.** OpenRouter limits free-model requests per account, not per key: "Making additional accounts or API keys will not affect your rate limits" ([its limits page](https://openrouter.ai/docs/api/reference/limits)).
Every key on one account shares its 20 free-model requests a minute, and buying credits raises only the daily cap, not that one.
Both servers run a team morning run at 7:30 a.m., so with keys on one account the two runs split those 20 requests, and most of each panel's requests come back refused (HTTP 429).
That happened on November 12, when something else used the account's requests from 8:06 a.m., and the laptop server's run was refused for two hours ([#240](https://github.com/jere67/parallax/issues/240)).
So give the hosted server a key from another teammate's OpenRouter account.
OpenRouter's note is aimed at one person opening more accounts to raise their own limits; how it treats two people's accounts is not documented.
If the hosted server's first morning run still shows refused requests (its run summary says so), keep only one of the two servers up on weekday mornings.
The team's forward test keeps running on the laptop server, where its history since November 2 is stored.
A new deploy starts with an empty graph, and its team portfolio stays out of auto mode, so it places no orders of its own until someone sets `TRADING_AGENT_FORWARD_TEST_START`.

To move the team's trading to the host instead, stop the laptop server for good and give the host the team's Alpaca keys.
When the host's forward test starts, it takes over the account: it cancels the laptop's open orders and puts the stocks the account holds on its own record with their stops (see [The forward test](/guide/forward-test#what-happens-at-the-start)).
The laptop's history stays on the laptop, and the host's evaluation starts from its own start date.
To keep one record instead, bring the laptop's records to the host before its first morning (see [Bring your records along](#bring-your-records-along)).

## Deploy

1. Install the CLI and log in.

   ```sh
   curl -fsSL https://jachammer.ai/static/assets/cli/install.sh | bash
   jachammer login
   ```

2. From a clean checkout of `main`, create the project with a first deploy.
   The CLI uploads tracked files only: it skips what `.gitignore` and `.jacignore` match, so no `.env`, database, or cache leaves your machine.

   ```sh
   git clone https://github.com/jere67/parallax.git && cd parallax
   jachammer deploy --prod
   ```

   The first deploy writes a `[jachammer]` project ID into `jac.toml`.
   Commit that change, so later deploys reach the same project.

3. Add the server's environment variables as **project** variables (Settings > Environment, or `jachammer env add NAME=value`).
   Account-wide global variables do not reach a production deploy.

   | Variable | Required | Value |
   | --- | --- | --- |
   | `ADMIN_PASSWORD` | Yes | A long random password, read once when the admin account is created. Without it the admin password is `changeme`, and anyone could take the admin account. |
   | `PARALLAX_KEYS_SECRET` | Yes | `openssl rand -base64 48`. Seals each user's keys. Keep a copy: changing it makes every stored key unreadable. |
   | `JAC_SERVE_AUTH_SECRET` | Yes | `openssl rand -base64 48`. Signs sign-in tokens. Without it each deploy makes a new one, which signs everyone out. |
   | `ALPACA_API_KEY`, `ALPACA_SECRET_KEY` | Yes | The host's own paper account. The market pages read prices with them, and the admin's team agent trades with them. |
   | `OPENROUTER_API_KEY` | Yes | A key from a teammate's OpenRouter account that the laptop server does not use (see [Before you start](#before-you-start)). The admin's team agent and the admin's policy assistant use it; every other account uses its own key. |
   | `SEC_USER_AGENT` | Yes | A name and a contact email, such as `Parallax team@example.edu`. SEC EDGAR refuses requests without one. |
   | `FINNHUB_API_KEY` | No | Earnings dates and company news. Without it those sections stay empty. |
   | `PARALLAX_MAX_AGENTS` | No | How many accounts may have an agent. Defaults to 10. |

   Never set these on a deploy: `TRADING_AGENT_DEMO` (fills the app with invented history and stops all trading), `ALPACA_BASE_URL` or any other `*_BASE_URL` (for local fakes only), and `TRADING_AGENT_DISABLE_ORDERS` unless you mean to stop every order.
   Set `TRADING_AGENT_FORWARD_TEST_START` only with the team's go-ahead (see [The forward test](/guide/forward-test)).

4. Deploy again, so the pod starts with the variables, and keep it to one pod.

   ```sh
   jachammer deploy --prod
   jachammer scale 1 --prod
   ```

5. Claim the address.

   ```sh
   jachammer domains add parallax
   ```

   The app is then at `https://parallax.jaseci.app`, if that name is free.

6. Check the deploy from outside, as a visitor reaches it.

   ```sh
   scripts/check-deploy.sh https://parallax.jaseci.app
   ```

   ```txt
   Checking https://parallax.jaseci.app
     ok    the server answers /healthz
     ok    the app's page is served
     ok    health reports ok
     ok    it is not a demo server
     ok    orders are on
     ok    orders go to Alpaca's paper API
     ok    the admin's fallback password is refused
   Every check passed.
   ```

   The script reads the public [health endpoint](/api/health), which names no key or account.
   Its `broker` field is `paper` only when orders go to `paper-api.alpaca.markets`; the broker refuses any other host, and refuses an account whose number does not start with `PA`.

   Then confirm that the graph persists:

   - `jachammer volume` lists the Postgres volume.
   - Create an account, run `jachammer deploy --prod` again, and log in with it once the new pod is up.

7. Optional: turn on auto-deploy on push in the project's Ship room, so each merge to `main` deploys.
   A commit message containing `[skip deploy]` skips one.

## After a deploy

- `jachammer logs --follow --prod` shows the server's log, including each scheduled job.
- `jachammer doctor` diagnoses a deploy that does not start.
- Each user connects their own keys in Settings, and their agent runs on them (see [Your agent](/guide/your-agent)).
- The admin logs in as `admin` with `ADMIN_PASSWORD`.

## Bring your records along

A new server starts empty.
It can take another server's whole record instead: every run, vote, decision, order, mark, evaluation, and agent, and the accounts that sign in to them.
Do it before the new server's first morning run, since a server that has run keeps its own records and refuses a move.

1. Stop the old server for good, so the two do not trade the same Alpaca account.
2. In a clone of this repository, export the old server's database:

   ```sh
   scripts/export-data.sh ~/path/to/old-server-folder
   ```

   It reads the folder's database in one snapshot, changes nothing, and writes `parallax-data-<date>.json.gz`.
   The file holds password hashes and sealed keys: keep it private, and delete it once the move is done.
3. Sign in to the new server as an admin, open Settings, choose the file under "Bring records from another server", and confirm.
   The move takes a minute or two.
4. When it lands, the page signs you out.
   Everyone signs in with their account from the old server, with its role there.
   The `admin` account keeps the new server's `ADMIN_PASSWORD`, since the old one may still have the laptop's fallback password.

What a move does:

- It replaces the new server's graph and accounts in one transaction, so it lands whole or changes nothing.
- It holds every scheduled job's lease while it writes, so no job starts on the graph it replaces.
- It renames each stored class to the new server's module names.
  A built app stores `models.graph` under a prefix made from its folder, so the same class has a different name on each server.
- The team's forward test carries on where it was: its baselines come along, so the new server starts no new one, and `TRADING_AGENT_FORWARD_TEST_START` changes nothing.
  Give the new server the team's Alpaca keys, since the record's positions and stop orders are on that account.
- Users' own keys stay sealed under the old server's `PARALLAX_KEYS_SECRET`.
  Give the new server the same secret to keep them working; otherwise Settings shows them as not connected, and each user connects them again.
- The provider cache and the market pages do not move; the new server rebuilds them.

The move lives in `accounts/transfer.jac`, and the export query in `scripts/export-data.sql`.

## Without JacHammer

Any small Linux VM runs the same server.
Install Jac 0.37.12, clone the repo, and put the variables above in a file that only root reads.
Build once with `jac build`, then run `jac run dist/trading-agent.jab` as a systemd service with `Restart=always` and that file as its `EnvironmentFile`.
The embedded Postgres and the caches stay on the VM's disk.
Put a reverse proxy such as Caddy in front for HTTPS, and run `scripts/check-deploy.sh` against its address.
