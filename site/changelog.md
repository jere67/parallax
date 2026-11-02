---
title: Changelog
description: What changed, phase by phase, from the design document to the dashboard. Each entry links to its pull request.
outline: 2
---

The project is built in seven phases, one GitHub milestone each, following the [build plan](/design/tdd#_15-build-plan-and-milestones).
Each phase has an exit criterion that is checked by an exit run before the next phase is called done.

<Figure caption="The build plan: seven phases from foundations to the final evaluation.">

![Build plan](../docs/figures/build_plan.png)

</Figure>

| Phase | Due | Exit criterion | Status |
| --- | --- | --- | --- |
| 1. Foundations | Oct 7 | `jac run` serves a health endpoint, a model call reaches the free model, and CI is green. | <Pill tone="up">done</Pill> |
| 2. Research | Oct 16 | A 20-ticker research pass finishes in under 30 minutes with at least 90% of reports complete and every claim cited. | <Pill tone="up">done</Pill> |
| 3. Analysis | Oct 25 | A full dry run decides every covered ticker within the request budget, and fallback mode passes its drill. | <Pill tone="up">done</Pill> |
| 4. Action | Oct 30 | The team portfolio trades on Alpaca paper for three consecutive days with zero gate bypasses. | <Pill tone="accent">in progress</Pill> |
| 5. Dashboard MVP | Nov 1 | Classmates can open the public link and follow a trade from order back to evidence. | <Pill tone="accent">in progress</Pill> |
| 6. Launch | Nov 15 | A new user can sign up and get a report in under 5 minutes on the deployed app. | <Pill>planned</Pill> |
| 7. Hardening and evaluation | Dec 9 | The final evaluation report and the Reflection Week presentation. | <Pill>planned</Pill> |

## November 2, 2026

**Dashboard MVP.**
The dashboard was redrawn as a ledger, and the admin can start a missed run.

- Let the admin start the morning run by hand. [#144](https://github.com/jere67/parallax/pull/144)
- The decision trail laid out as an entity page. [#136](https://github.com/jere67/parallax/pull/136)
- The run laid out as a screener. [#135](https://github.com/jere67/parallax/pull/135)
- The Portfolio page set as a quote. [#134](https://github.com/jere67/parallax/pull/134)
- A brass team curve over dashed baselines. [#133](https://github.com/jere67/parallax/pull/133)
- The shell: committee mark, brass tabs, and a 1200-pixel frame. [#132](https://github.com/jere67/parallax/pull/132)
- Ledger theme tokens, fonts, and shared parts. [#131](https://github.com/jere67/parallax/pull/131)
- A responsive dashboard shell. [#115](https://github.com/jere67/parallax/pull/115)

## October 29, 2026

**Dashboard MVP.**
The first public dashboard: read-only endpoints, three pages, demo history, and browser tests on four devices.

- Device matrix and an end-to-end check in CI; live jobs kept off the demo history. [#121](https://github.com/jere67/parallax/pull/121)
- The Decision page, from evidence to order. [#120](https://github.com/jere67/parallax/pull/120)
- The Today page and the list of past runs. [#119](https://github.com/jere67/parallax/pull/119)
- The Portfolio page, and a read cache for every page. [#118](https://github.com/jere67/parallax/pull/118)
- The shell: theme, routes, top bar, and disclaimer. [#117](https://github.com/jere67/parallax/pull/117)
- Demo history for local development. [#116](https://github.com/jere67/parallax/pull/116)
- Public read-only endpoints for the portfolio, performance, runs, and decision trails. [#113](https://github.com/jere67/parallax/pull/113)
- CI caches only the embedded Postgres binaries, never its data directory. [#112](https://github.com/jere67/parallax/pull/112)

## October 26, 2026

**Research and analysis follow-ups.**

- Track model retries by role, and fix the Flow specialist's gap citations. [#124](https://github.com/jere67/parallax/pull/124)
  See the [retry audit](/design/run-retry-audit).
- Quarterly SEC 13F holdings. [#123](https://github.com/jere67/parallax/pull/123)

## October 21, 2026

**Action.**
Everything between a decision and a filled order, checked by the [Action exit run](/design/run-action): three simulated days with zero bypasses and zero drift.

- Action exit run. [#101](https://github.com/jere67/parallax/pull/101)
- Equal-weight and SPY baselines, and the forward-test start. [#100](https://github.com/jere67/parallax/pull/100)
- Post-close vote scoring against SPY. [#99](https://github.com/jere67/parallax/pull/99)
- Insight cards rendered from each stored decision. [#98](https://github.com/jere67/parallax/pull/98)
- A trading tick every minute: execute, poll, cancel, and reconcile. [#97](https://github.com/jere67/parallax/pull/97)
- Executor with gated marketable limit orders, fill tracking, and a stop keeper. [#96](https://github.com/jere67/parallax/pull/96)
- Risk gate with every TDD rule, and a Hypothesis property test. [#95](https://github.com/jere67/parallax/pull/95)
- Sizing moved to `action/`, held shares kept exact, and trims sized. [#94](https://github.com/jere67/parallax/pull/94)
- Order-rule spike script, and its closed-market findings. [#93](https://github.com/jere67/parallax/pull/93)
  See the [order rules spike](/design/spike-alpaca-order-rules).
- Paper-only broker client for Alpaca's trading API, and a stateful fake broker. [#92](https://github.com/jere67/parallax/pull/92)

## October 19, 2026

- Long-only position sizing. [#82](https://github.com/jere67/parallax/pull/82)

## October 18, 2026

**Analysis.**
The specialist panel, the consensus, the Arbiter, and the Orchestrator, checked by the [Analysis exit run](/design/run-analysis).

- Analysis exit run. [#80](https://github.com/jere67/parallax/pull/80)
- Scheduled morning job. [#79](https://github.com/jere67/parallax/pull/79)
- Orchestrator tool loop. [#78](https://github.com/jere67/parallax/pull/78)
- Run Guard. [#77](https://github.com/jere67/parallax/pull/77)
- Analysis pass. [#76](https://github.com/jere67/parallax/pull/76)
- Arbiter that confirms or downgrades, never upgrades. [#75](https://github.com/jere67/parallax/pull/75)
- Specialist panel. [#74](https://github.com/jere67/parallax/pull/74)
- Consensus engine. [#73](https://github.com/jere67/parallax/pull/73)

## October 16, 2026

**Research.**
Research agents and the research pass, checked by the [Research exit run](/design/run-research): 20 tickers, every report complete and cited.

- SEC EDGAR collector. [#61](https://github.com/jere67/parallax/pull/61)
- Research pass and exit run. [#59](https://github.com/jere67/parallax/pull/59)
- Macro research sub-agent. [#58](https://github.com/jere67/parallax/pull/58)
- Market, Fundamentals, and News research sub-agents. [#57](https://github.com/jere67/parallax/pull/57)
- Fall back when the primary model is down or hangs. [#56](https://github.com/jere67/parallax/pull/56)

## October 12, 2026

**Research.**
The collectors and the screen.

- Spike: free models on OpenRouter; switch to Nemotron 3 Super. [#49](https://github.com/jere67/parallax/pull/49)
  See the [free models spike](/design/spike-free-models).
- Deterministic S&P 500 screener. [#48](https://github.com/jere67/parallax/pull/48)
- Finnhub news, earnings calendar, ratings, EPS surprises, and metrics. [#47](https://github.com/jere67/parallax/pull/47)
- Alpaca news counts and delimited article text. [#46](https://github.com/jere67/parallax/pull/46)
- Technical indicators computed in code. [#45](https://github.com/jere67/parallax/pull/45)
- Alpaca daily bars, latest trades, assets, and market calendar. [#44](https://github.com/jere67/parallax/pull/44)
- S&P 500 constituents and point-in-time membership from Wikipedia. [#43](https://github.com/jere67/parallax/pull/43)
- Keep local keys in one `.env` file. [#42](https://github.com/jere67/parallax/pull/42)
- Collector framework with cache, rate limits, retries, budgets, and freshness. [#41](https://github.com/jere67/parallax/pull/41)

## October 7, 2026

**Foundations.**
The project skeleton, the model layer, the graph schema, and CI.

- A weekly-update skill for the progress slide. [#40](https://github.com/jere67/parallax/pull/40)
- Rate-limited model layer and per-role model instances. [#37](https://github.com/jere67/parallax/pull/37)
- Typed agent outputs, graph schema, and the publish helper. [#36](https://github.com/jere67/parallax/pull/36)
- Check, test, build, and boot on every pull request. [#35](https://github.com/jere67/parallax/pull/35)
- The project skeleton, replacing the `jac create` template. [#34](https://github.com/jere67/parallax/pull/34)
- Pull request and issue templates, and the contributing guide. [#33](https://github.com/jere67/parallax/pull/33)

## October 6, 2026

**Design.**

- The [requirements](/design/requirements). [#5](https://github.com/jere67/parallax/pull/5)
- The [technical design document](/design/tdd). [#4](https://github.com/jere67/parallax/pull/4)
