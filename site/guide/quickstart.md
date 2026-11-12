---
title: Quickstart
description: Install Jac, export the keys, and serve the app locally, with demo data or with your own keys.
related:
  - { text: Configuration, link: /guide/configuration }
  - { text: Demo data, link: /guide/demo-data }
---

This page gets the app running on your machine.
With demo data you need no provider API keys, and the dashboard fills with a few weeks of made-up history within a minute.
The dashboard needs an account, so you sign up once at `/signup`.

## Before you start

You need:

- macOS or Linux.
- [Jac 0.39.2](https://www.jaseci.org/), the version the project pins in `jac.toml`.
  Much of the Jac website still describes 0.34, so trust `jac guide` over the website.
- Node.js 22, only for the end-to-end browser tests.
- A clone of the [repository](https://github.com/jere67/parallax).

## Run it

<Steps>

1. **Install Jac 0.39.2.**

   ```bash
   curl -fsSL https://raw.githubusercontent.com/jaseci-labs/jaseci/main/scripts/install.sh \
     | bash -s -- --version 0.39.2
   jac --version
   ```

2. **Create your environment file.**
   Copy the example file and fill in the keys you have.
   `.env` is gitignored; never commit it.

   ```bash
   cp .env.example .env
   ```

   For demo data, you can leave the provider keys empty.
   [Configuration](/guide/configuration) lists every variable.

   Set `PARALLAX_KEYS_SECRET` on any server that lets users connect their own keys.
   It must be at least 32 characters; generate one with `openssl rand -base64 48`.
   Changing it later makes every stored key unreadable, and users must connect theirs again.
   `PARALLAX_MAX_AGENTS` caps how many agents the server keeps (10 by default).

3. **Export the variables.**
   `jac run` and `jac test` do not read `.env`, so export it into your shell.

   ```bash
   set -a && source .env && set +a
   ```

   With direnv, `echo dotenv > .envrc && direnv allow` does this whenever you enter the repo.

4. **Install the dependencies.**
   This installs the Python packages and the dashboard's npm packages.

   ```bash
   jac install
   ```

5. **Serve the app.**
   For a first look, use demo data and switch orders off:

   ```bash
   TRADING_AGENT_DEMO=1 TRADING_AGENT_DISABLE_ORDERS=1 jac run --dev main.jac
   ```

   The landing page is at `http://localhost:8000`.
   Sign up at `/signup` to reach the dashboard at `/app`.
   Within a minute, a scheduled job fills the empty team portfolio with simulated sessions, and every account sees them.

</Steps>

## Check that it is up

```bash
curl -s localhost:8000/healthz
curl -s -X POST localhost:8000/function/health -H 'Content-Type: application/json' -d '{}'
```

The second call answers with `"status": "ok"` and the server's UTC time.
`/docs` lists every endpoint the server serves.

## Run it for real

Without `TRADING_AGENT_DEMO`, the server starts with an empty team portfolio in insight mode, and every new account starts empty.
With `PARALLAX_KEYS_SECRET` exported, `jac run` serves the app with hot reload.
The admin's team agent runs on the keys in `.env`, and the scheduler starts its morning run at 7:30 a.m. New York time on each trading day.
Every other user connects their own keys in Settings; see [Your agent](/guide/your-agent).

::: warning Orders go to the paper account in the keys
In insight mode the server never sends an order.
A user's agent trades only after its owner turns on paper trading in Settings, and the team agent only after the [forward test](/guide/forward-test) switches its portfolio to auto mode.
Both trade only on an Alpaca paper account: the broker client refuses any other host and any account number that does not start with `PA`.
Set `TRADING_AGENT_DISABLE_ORDERS=1` to keep every order off while you experiment.
:::

A server that was down or asleep at 7:30 a.m. starts the run as soon as it is back, until 9:15; one that is down for that whole window has no team run that day.
The admin can [start it by hand](/guide/manual-run), and a user can press **Start today's run** in Settings.

## Next steps

<Cards :cols="2">
<Card title="Read the dashboard" icon="chart" link="/guide/dashboard">What each page and figure means.</Card>
<Card title="Checks and tests" icon="flask" link="/guide/testing">Type-check, test, build, and run the browser checks.</Card>
</Cards>
