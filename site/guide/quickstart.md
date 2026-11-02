---
title: Quickstart
description: Install Jac, export the keys, and serve the app locally, with demo data or with your own keys.
related:
  - { text: Configuration, link: /guide/configuration }
  - { text: Demo data, link: /guide/demo-data }
---

This page gets the app running on your machine.
With demo data you need no API keys at all, and the dashboard fills with a few weeks of made-up history within a minute.

## Before you start

You need:

- macOS or Linux.
- [Jac 0.37.12](https://www.jaseci.org/), the version the project pins in `jac.toml`.
  Much of the Jac website still describes 0.34, so trust `jac guide` over the website.
- Node.js 22, only for the end-to-end browser tests.
- A clone of the [repository](https://github.com/jere67/parallax).

## Run it

<Steps>

1. **Install Jac 0.37.12.**

   ```bash
   curl -fsSL https://raw.githubusercontent.com/jaseci-labs/jaseci/main/scripts/install.sh \
     | bash -s -- --version 0.37.12
   jac --version
   ```

2. **Create your environment file.**
   Copy the example file and fill in the keys you have.
   `.env` is gitignored; never commit it.

   ```bash
   cp .env.example .env
   ```

   For demo data, you can leave the keys empty.
   [Configuration](/guide/configuration) lists every variable.

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

   The dashboard is at `http://localhost:8000`.
   Within a minute, a scheduled job fills the empty team portfolio with simulated sessions.

</Steps>

## Check that it is up

```bash
curl -s localhost:8000/healthz
curl -s -X POST localhost:8000/function/health -H 'Content-Type: application/json' -d '{}'
```

The second call answers with `"status": "ok"` and the server's UTC time.
`/docs` lists every endpoint the server serves.

## Run it for real

Without `TRADING_AGENT_DEMO`, the server starts with an empty team portfolio in insight mode.
With your keys exported, `jac run` serves the app with hot reload, and the scheduler starts the morning run at 7:30 a.m. New York time on each trading day.

::: warning Orders go to the paper account in the keys
In insight mode the server never sends an order.
It trades only after the [forward test](/guide/forward-test) switches the team portfolio to auto mode, and only on an Alpaca paper account: the broker client refuses any other host and any account number that does not start with `PA`.
Set `TRADING_AGENT_DISABLE_ORDERS=1` to keep every order off while you experiment.
:::

A server that was down at 7:30 a.m. has no run that day.
The admin can [start it by hand](/guide/manual-run).

## Next steps

<Cards :cols="2">
<Card title="Read the dashboard" icon="chart" link="/guide/dashboard">What each page and figure means.</Card>
<Card title="Checks and tests" icon="flask" link="/guide/testing">Type-check, test, build, and run the browser checks.</Card>
</Cards>
