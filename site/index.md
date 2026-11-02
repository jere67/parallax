---
layout: home
title: Trading Agent docs
titleTemplate: false
description: How the Trading Agent screens the S&P 500, researches a shortlist, decides through a consensus of specialist agents, and trades on Alpaca paper accounts.
---

<section class="hero">
<div>
<p class="hero-overline">EECS 449 · Fall 2026</p>
<h1 class="hero-title display">A trading desk of agents, <em>with every decision on file.</em></h1>
<p class="hero-lede">The Trading Agent screens the S&amp;P 500 every trading day, researches a shortlist from free data sources, decides through a stochastic consensus of five specialist agents, and trades on an Alpaca paper account. Every report, vote, risk check, and order is recorded and shown on a public dashboard.</p>
<div class="hero-actions">
<a class="btn btn-primary" href="./guide/quickstart">Run it locally <Icon name="arrow-right" /></a>
<a class="btn" href="./system/architecture">How it works</a>
<a class="btn" href="./api/overview">API reference</a>
</div>
</div>
<div class="hero-code vp-doc">

```bash
# Jac 0.37.12, then from the repo root
set -a && source .env && set +a
jac install
TRADING_AGENT_DEMO=1 TRADING_AGENT_DISABLE_ORDERS=1 \
  jac run --dev main.jac
# the dashboard: http://localhost:8000
```

<p class="code-caption">Demo mode fills the dashboard with a few weeks of made-up sessions and sends no orders.</p>
</div>
</section>

<section class="home-section">
<div class="home-section-head">
<h2 class="display">One trading day</h2>
<p>A morning run decides; the trading ticks act on its decisions; the evening checks the books. All times are New York time.</p>
</div>
<div class="pipeline">
<div class="pipeline-step">
<div class="pipeline-time">7:30 a.m.</div>
<p class="pipeline-name">Research</p>
<p class="pipeline-body">Screen the S&amp;P 500 down to 15 names, then collect prices, filings, news, and macro data from free sources into cited briefs.</p>
<a class="pipeline-link" href="./system/research">Research pass <Icon name="arrow-right" /></a>
</div>
<div class="pipeline-step">
<div class="pipeline-time">about 7:40</div>
<p class="pipeline-name">Analysis</p>
<p class="pipeline-body">Five specialists vote three times each. A bootstrap consensus drafts the action, and an Arbiter may only confirm or downgrade it.</p>
<a class="pipeline-link" href="./system/consensus">Stochastic consensus <Icon name="arrow-right" /></a>
</div>
<div class="pipeline-step">
<div class="pipeline-time">9:45 a.m.</div>
<p class="pipeline-name">Action</p>
<p class="pipeline-body">Size each position by conviction and volatility, pass it through ten deterministic risk rules, and send limit orders with stops.</p>
<a class="pipeline-link" href="./system/risk-gate">Risk gate <Icon name="arrow-right" /></a>
</div>
<div class="pipeline-step">
<div class="pipeline-time">4:30 p.m.</div>
<p class="pipeline-name">Review</p>
<p class="pipeline-body">Reconcile the ledger with the broker, mark equity, score every vote against SPY, and advance the two baselines.</p>
<a class="pipeline-link" href="./system/trading-day">The trading day <Icon name="arrow-right" /></a>
</div>
</div>
</section>

<section class="home-section">
<div class="home-section-head">
<h2 class="display">Start where you are</h2>
<p>The docs cover the running system, its HTTP API, and the design documents it was built from.</p>
</div>

<Cards :cols="3">
<Card title="Run it locally" icon="terminal" link="/guide/quickstart">Install Jac, export the keys, and serve the app with demo data in a few minutes.</Card>
<Card title="Read the dashboard" icon="chart" link="/guide/dashboard">What the Portfolio, Runs, and Decision trail pages show, figure by figure.</Card>
<Card title="Follow a decision" icon="network" link="/system/architecture">From the universe screen to a filled order: every layer and what it writes.</Card>
<Card title="Check the risk controls" icon="shield" link="/system/risk-gate">The ten deterministic rules every order passes, in the order they run.</Card>
<Card title="Call the API" icon="book" link="/api/overview">The public endpoints the dashboard reads, with request and response examples.</Card>
<Card title="Read the design" icon="file" link="/design/tdd">The technical design, requirements, spikes, and the exit runs of each phase.</Card>
</Cards>
</section>

<section class="home-section">
<div class="home-section-head">
<h2 class="display">For your agent</h2>
<p>Every page is also published as plain Markdown, so a coding agent or an LLM can read the docs without a browser.</p>
</div>

<Cards :cols="2">
<Card title="llms.txt" icon="file" link="/llms.txt">An index of every page with a one-line summary.</Card>
<Card title="llms-full.txt" icon="book" link="/llms-full.txt">Every page's Markdown in one file.</Card>
</Cards>
</section>
