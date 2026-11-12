---
title: Your agent
description: Sign up, connect your own API keys, start a run, and turn on paper trading for your own agent.
related:
  - { text: Account endpoints, link: /api/accounts }
  - { text: Reading the dashboard, link: /guide/dashboard }
  - { text: Policies and the assistant, link: /guide/policies }
  - { text: Configuration, link: /guide/configuration }
---

Every user has one agent of their own.
It has its own Alpaca paper account, its own morning run, and its own policy, and it runs on API keys you enter in Settings, never on keys from the server's `.env`.
Accounts cannot see each other's data.

A new agent only researches.
It places no order until you turn on paper trading.

## Set it up

<Steps>

1. **Create an account.**
   Open `/signup` and enter an email and a password of at least 8 characters.
   Sign-up is open, and email and password are the only way in: there is no Google, passkey, or SSO sign-in, and no forgot-password link.
   A signed-in user changes their password in Settings, and the admin can reset one by hand.

2. **Connect your keys.**
   Sign-up takes you to Settings (`/app/settings`).
   Enter the keys below and save.
   Each key is checked with its provider before anything is stored, and nothing is saved unless every key you sent passes.

3. **Start a run, or wait for the morning.**
   Press **Start today's run** in Settings, or let the agent run by itself.

4. **Read the result** on the Portfolio and Runs pages.
   See [Reading the dashboard](/guide/dashboard).

</Steps>

## The keys

| Key | Required | What it does |
| --- | --- | --- |
| Alpaca paper key ID and secret | Yes | Gives the agent market data, and its paper account for orders. Enter both: Alpaca issues them as a pair. |
| OpenRouter API key | Yes | Pays for every model request: the research agents, the five specialists, and the Arbiter, plus the policy assistant. |
| Finnhub API key | No | Supplies fundamentals, earnings dates, and analyst views. Without it, those show as data gaps, and the specialists that depend on them abstain. |

Settings lists the steps to make each key, with a button that opens the provider's page in a new tab.
Once a key is connected, the steps fold under "Need a new key?".

- Alpaca: sign up at `app.alpaca.markets/signup`, check that the account menu says Paper, then choose Generate New Keys on the paper dashboard, at `app.alpaca.markets/paper/dashboard/overview`. Alpaca shows the secret only once.
- OpenRouter: choose Create Key at `openrouter.ai/settings/keys`. OpenRouter shows the key only once.
- Finnhub: sign up at `finnhub.io/register`; the key is at the top of `finnhub.io/dashboard`.

### The OpenRouter allowance

A full run uses about 460 model requests.
A free OpenRouter key allows 50 free-model requests a day, so its runs cover fewer stocks.
OpenRouter raises the limit to 1,000 a day after a one-time $10 credit purchase, which a full run needs.
When you save the key, Settings tells you the allowance it found.

### How keys are handled

- A live Alpaca account is refused.
  Parallax only trades on paper, so use the keys from Alpaca's paper trading dashboard.
- Keys are stored encrypted with AES-256-GCM, under a key derived from the server's `PARALLAX_KEYS_SECRET`.
- A key is never shown again except its last few characters.
- If the server's secret changes, stored keys become unreadable and show as not connected, and you connect them again.
- Disconnecting Alpaca or OpenRouter stops the agent from running and trading.
  Positions stay open on Alpaca, where you can close them.
- Keys cannot be changed or disconnected while the day's run is working.

A server that has no `PARALLAX_KEYS_SECRET` refuses to store keys, and says so in Settings.
A server at its limit of agents (`PARALLAX_MAX_AGENTS`, 10 by default) refuses a new agent until room opens.
See [Configuration](/guide/configuration).

## When the agent runs

An agent runs by itself on a weekday between 7:30 and 9:15 a.m. New York time.
Up to three agents run at a time, the oldest account first.
A run takes about half an hour.

You can also press **Start today's run** in Settings.
It starts within a minute or two, uses your own keys, and is refused on a weekend, while a run is working, or when the day already has a run.
A run needs your Alpaca and OpenRouter keys.

## Turn on paper trading

Paper trading is off for a new agent, and you turn it on in Settings with a confirmation.
It trades only on an Alpaca paper account.

Turning it on for the first time starts your forward test.
Your paper account must hold nothing then, with no positions and no open orders, so your agent and its two baselines (the equal-weight shortlist and SPY buy-and-hold) start alike.
If it holds anything, Settings says how many positions and orders, and you close them or reset the account on Alpaca and try again.

Once on, the agent places paper orders from its next morning run, after 9:45 a.m. New York time.
Turning it off stops new orders; the agent keeps researching, and open positions stay on Alpaca with their stops.

## Your policy and reports

Your account has one [policy](/guide/policies), and it drives your agent from its next morning run.
The policy assistant and any new on-demand report run on your own OpenRouter key.
Without keys, the Reports page shows a message that points to Settings, and you can still read cached reports.

## The admin and demo servers

The `admin` account inherits the original team agent, with its history and policy.
It keeps using the server's `.env` keys and its existing jobs, including the manual [`start_morning_run`](/guide/manual-run), so Settings only describes it.
Every other account starts empty.

On a server in demo mode (`TRADING_AGENT_DEMO=1`), every account sees the same demo history, and runs and trading are refused.
See [Demo data](/guide/demo-data).
