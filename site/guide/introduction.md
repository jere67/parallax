---
title: Introduction
description: What Parallax is, what it does each trading day, and how these docs are organized.
related:
  - { text: Quickstart, link: /guide/quickstart }
  - { text: Architecture, link: /system/architecture }
---

Parallax is a multi-agent system written in [Jac](https://www.jaseci.org/).
Every user has their own agent, on their own API keys.
Every trading day it screens the S&P 500, researches a shortlist from free data sources, decides what to do through a stochastic consensus of specialist agents, and, if its owner turns paper trading on, trades the result on that user's Alpaca paper account.
Every report, vote, decision, risk check, and order is stored in a graph and shown on a dashboard to the user whose agent made it.
The landing page is the only public page; everything else needs an account, and accounts cannot see each other's data.

The Jac project is still named `trading-agent` internally, so file names such as `dist/trading-agent.jab` keep that name.

It is a student project for EECS 449 at the University of Michigan, Fall 2026.

::: warning Simulated money only
An educational student project trading simulated money.
Nothing here is investment advice, and past simulated performance does not predict future results.
:::

## What it does

The system acts like a small investment committee with a strict rulebook.
Language models do the reading and the arguing.
Deterministic code does the arithmetic and has the last word on risk.

<Steps>

1. **Screen the market.**
   In the morning, New York time, a ranking of the S&P 500 by momentum, volume, news, and earnings picks a shortlist of up to 15 stocks, plus every stock the portfolio already holds.

2. **Research each stock.**
   Research agents collect prices, SEC filings, news, insider trades, and macro data, and write a cited report for each stock.
   A claim without a source from the stock's evidence packet is rejected.

3. **Vote, three times.**
   Five specialist agents (fundamentals, technical, news, macro, and flow) each vote on a five-step scale from strong sell to strong buy, with a confidence, three times at a high temperature.
   The spread of those samples is a measure of how unsure the panel is.

4. **Draft and review the decision.**
   A bootstrap over the votes gives a consensus score, an agreement share, and an 80% confidence interval, and a fixed rule turns them into a draft action.
   An Arbiter agent may confirm the draft or downgrade it, but never upgrade it.

5. **Pass the risk gate and trade.**
   From 9:45 a.m., each decision is sized by conviction and volatility, checked by ten deterministic risk rules, and sent to Alpaca as a limit order with a protective stop.

6. **Check the books.**
   After the close, the ledger is reconciled with the broker, equity is marked, and every vote is scored against SPY over its own horizon.

</Steps>

## Two modes

Each agent's portfolio runs in one of two modes.

| Mode | What happens to a decision |
| --- | --- |
| `insight` | It is published as an insight card on the dashboard. No order is sent. This is the starting mode, and a new agent stays in it. |
| `auto` | It is sized, gated, and traded on the user's Alpaca paper account. |

A user switches their agent to auto mode by turning on paper trading in Settings.
See [Your agent](/guide/your-agent).
The admin's team agent is switched by the [forward test](/guide/forward-test), on a date the team picks.

## How these docs are organized

<Cards :cols="2">
<Card title="Guides" icon="terminal" link="/guide/quickstart">Run the app, set up your agent, configure it, and read the dashboard.</Card>
<Card title="System" icon="network" link="/system/architecture">How each layer works, with the exact numbers from the code.</Card>
<Card title="API Reference" icon="book" link="/api/overview">The HTTP endpoints the dashboard calls, with examples.</Card>
<Card title="Design Docs" icon="file" link="/design/tdd">The technical design, requirements, spikes, and exit runs, mirrored from the repo.</Card>
</Cards>

## The stack

| Part | Choice |
| --- | --- |
| Language and server | Jac 0.39.2 (`jac-scale` serves the app, runs the scheduler, and stores the graph) |
| Models | Free models on OpenRouter, called through byLLM |
| Market data and broker | Alpaca (market data and a paper trading account) |
| Other data | SEC EDGAR, Finnhub, Wikipedia |
| Dashboard | React 19 client components in Jac, Tailwind CSS 4, Lightweight Charts |
| Tests | `jac test`, Hypothesis property tests, Playwright end-to-end tests |

The source is on [GitHub](https://github.com/jere67/parallax).
