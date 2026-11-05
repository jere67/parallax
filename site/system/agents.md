---
title: Agents and models
description: The model roles, the shared request limiter and fallback, and what each agent may and may not do.
related:
  - { text: Research pass, link: /system/research }
  - { text: Stochastic consensus, link: /system/consensus }
  - { text: Run Guard, link: /system/run-guard }
---

The system uses language models in four places: the research sub-agents, the five specialists on the analysis panel, the Arbiter, and the Orchestrator that runs the morning.
Everything else, including the screen, the consensus, sizing, the risk gate, and execution, is plain code.
Every model call goes through one shared limiter, backs off on rate limits, and falls back to a second free model when the first fails.
Each agent returns a typed object that byLLM validates, and code checks what the type cannot, such as citations and the Arbiter's authority.

## Models

| Setting | Value |
| --- | --- |
| Primary model | `openrouter/nvidia/nemotron-3-super-120b-a12b:free` |
| Fallback model | `openrouter/dots-studio/dots-3-note-preview:free` |
| Requests per minute | 18, paced evenly across every thread |
| Free requests per UTC day | 1,000 |
| Request timeout | 180 seconds |
| Reasoning effort | `low` |

Both models are free OpenRouter models, chosen by the [free-models spike](/design/spike-free-models): the primary was the only free model with every typed output valid on the first request and no provider errors, and the fallback was the runner-up.
The settings live in [`agents/models.jac`](https://github.com/jere67/parallax/blob/main/agents/models.jac).

### One instance per role

byLLM's `by m(temperature=...)` overwrites the call parameters on the model instance, so two roles sharing one instance would leak settings into each other's concurrent calls.
Each role therefore has its own `LimitedModel` instance:

| Instance | Used by | Temperature |
| --- | --- | --- |
| `research_llm` | Market, Fundamentals, News, and Macro sub-agents | 0.2 |
| `specialist_llm` | The five specialists | 0.8 |
| `arbiter_llm` | The Arbiter | 0.2 |
| `orchestrator_llm` | The Orchestrator's ReAct loop | 0.2 |
| `retry_llm` | A second try after a parse failure, for any role | 0.2 |

A test fails if any module calls the builtin `llm`, which would skip the limiter.

### The request limiter

`RequestLimiter` spaces requests at least 60 / 18 = 3.3 seconds apart, process-wide, and counts them per UTC day, per role, and per kind: `first_attempt`, `parse_retry`, `transient_retry`, or `fallback`.
The [Run Guard](/system/run-guard#budgets) reads these counts to decide how many requests a run may spend.

### Retries and fallback

`LimitedModel.model_call_no_stream` handles every provider request, including byLLM's parse retries, ReAct iterations, and summaries:

<Steps>

1. **Kill switch.**
   With `TRADING_AGENT_DISABLE_MODELS` set to `1`, `true`, or `yes`, no request is sent; the call raises `ModelsDisabledError`, and each agent falls back to its safe default.

2. **Primary model.**
   A 429 is retried up to 3 times, waiting 2, 4, then 8 seconds.

3. **Fallback model.**
   A 429 that persists, a 5xx, an overloaded provider, a dropped connection, or a timeout sends the request once to the fallback model.
   An authentication or configuration error is raised at once, since another model would fail the same way.

</Steps>

Agents never stream, since streaming would bypass the limiter.

## Typed outputs

Every enum a model returns is a string enum, because a plain enum becomes an integer schema and rejects `"BUY"`.
Confidences must lie in [0, 1]; a value outside raises a validation error, and byLLM retries the parse with that message.

| Type | Fields | Returned by |
| --- | --- | --- |
| `ResearchReport` | summary, view (`Stance`), confidence, evidence, risks, data_gaps | Research sub-agents |
| `MacroReport` | summary, regime (`RiskRegime`), confidence, evidence, risks, data_gaps | Macro sub-agent |
| `Vote` | stance, confidence, horizon_days (at least 1), rationale, cited_evidence, cited_gaps | Specialists |
| `Review` | verdict (`CONFIRM` or `DOWNGRADE`), reason, thesis, risks (at least 2), exit_condition | Arbiter |

`Stance` runs `STRONG_SELL`, `SELL`, `HOLD`, `BUY`, `STRONG_BUY`, which code maps to scores -2 to +2.
Each `Evidence` item is a claim, a `source_url` that must be http or https, and a `published` time.
The types are in [`models/agents.jac`](https://github.com/jere67/parallax/blob/main/models/agents.jac).

Every call site follows the same failure rule: a parse that still fails after one retry is tried once more through `retry_llm`, and any other error, or a second failure, gives that agent's safe default.

## Research sub-agents

The Market, Fundamentals, and News sub-agents each read one brief per ticker, and Macro reads one brief per run.
They have no tools, and code drops any claim that does not cite a source in the brief.
The safe default is a HOLD at confidence 0 (or a `NEUTRAL` macro brief) with the error in the data gaps.
See [Research pass](/system/research).

## Specialists

Five specialists vote on each ticker, independently, from their own specialty:

| Specialist | Reads | Judges |
| --- | --- | --- |
| Fundamentals | The fundamentals report | Valuation, growth, margins, cash flow, balance sheet, guidance, and earnings quality |
| Technical | The market report | Trend, momentum, support and resistance, volatility, and relative strength |
| News and Events | The news report | How material the news is, whether it is priced in, and the catalysts ahead |
| Macro and Sector | The macro report and the market report | The regime, rates, inflation, sector rotation, and how this stock's sector sits in it |
| Flow and Positioning | The fundamentals report | Insider trades, quarterly institutional holdings, and analyst positioning |

### The packet

A specialist reads a packet built in code ([`agents/specialists.jac`](https://github.com/jere67/parallax/blob/main/agents/specialists.jac)): each report's summary, risks, and data gaps, and all the reports' evidence as one numbered list.
It never sees another specialist's votes, nor the research sub-agents' own views and confidences, so the panel's errors stay independent.

| Packet cap | Value |
| --- | --- |
| Evidence items per report | 25 |
| Characters per claim, risk, or gap | 400 |
| Characters per summary | 1,200 |
| Risks or gaps per report | 6 |

### Sampling

Each specialist is called K times at temperature 0.8 (K = 3, or 1 in reduced mode).
Each sample shows the evidence in a different order, to reduce position bias.
The order is a shuffle seeded by the CRC-32 of `run_day:ticker:specialist:sample`, so a rerun reproduces it.

### Citations

A vote's `cited_evidence` lists the 1-based numbers the sample was shown.
Code maps them back to the packet's own order and drops numbers out of range.
A vote that cites nothing in range is discarded, and the consensus counts it as a dropped sample.

The one exception is a Flow HOLD.
When missing insider or holdings data prevents a directional view, Flow may copy supplied data-gap statements verbatim into `cited_gaps` instead.
Code accepts gaps only on a Flow HOLD, only when they match a supplied gap exactly, and never on a directional vote.
Such a vote abstains in the [consensus](/system/consensus#consensus-score-c): it is shown on the decision trail but adds nothing to C.

### Taking a side

The prompt asks a specialist to take a side whenever its evidence tilts either way, and to let confidence say how sure it is: a weak lean is a BUY or SELL at low confidence, not a HOLD.
HOLD is for evidence that is balanced or says nothing about direction, and STRONG_BUY or STRONG_SELL for a clear, well-supported call.
A vote's score is already its stance times its confidence, so asking for HOLD on weak evidence, as the prompt did until November 4, 2026, counted doubt twice; in the first three live runs about 90% of samples were HOLD.

## Arbiter

The Arbiter reviews each ticker's draft action once, at temperature 0.2, and writes the decision's text.
It reads the consensus statistics, the three strongest rationales on each side by signed score, and the research summaries and risks.

Its authority is one-sided, and code enforces it ([`agents/arbiter.jac`](https://github.com/jere67/parallax/blob/main/agents/arbiter.jac)):

| Draft | CONFIRM | DOWNGRADE |
| --- | --- | --- |
| BUY | BUY | NO_ACTION |
| ADD | ADD | HOLD |
| HOLD, TRIM, SELL, NO_ACTION | unchanged | unchanged, recorded as `DOWNGRADE (not applied to ...)` |

So one model can never talk the ensemble into a trade or into more risk.
The `Review` type requires at least two risks and a non-empty exit condition, a price level or an event; the first two risks are stored.
The time stop is a trading date computed in code from the votes' horizons and given to the Arbiter, never one it works out.

If the Arbiter cannot rule, the safe ruling turns a BUY into NO_ACTION and an ADD into HOLD, since no reviewed trade beats an unreviewed one, and leaves any other draft as it is.
The decision then records the verdict `unavailable` and the error.

## Orchestrator

The Orchestrator runs the morning as one bounded ReAct loop at temperature 0.2 ([`agents/orchestrator.jac`](https://github.com/jere67/parallax/blob/main/agents/orchestrator.jac)).
It acts only through seven tools, which are methods of the run's session in [`run/guard.jac`](https://github.com/jere67/parallax/blob/main/run/guard.jac); every limit is enforced in the tool, since the free-models spike found that models ignore counts stated in a prompt.

| Tool | What it does | Refuses when |
| --- | --- | --- |
| `get_run_context` | Returns the run date, mode, requests left, the macro brief, and each ticker's status | never |
| `dispatch_research(tickers, domains)` | Runs the named sub-agents for a batch of tickers in parallel | the ticker is not covered, the domain was already researched, or the budget is spent |
| `request_followup(ticker, domain, question)` | Reruns one sub-agent with a question of up to 500 characters | before the first report, after the panel, past 2 per ticker, or with no budget |
| `flag_ticker(ticker, reason)` | Marks a ticker unreliable today; it is decided HOLD with the reason | after submission, or with no reason |
| `convene_panel(tickers)` | Runs the specialists, the consensus, and the Arbiter for a batch | research is missing, or a ticker was already decided |
| `submit_decisions(note)` | Sends the decision set to the Action layer, once | any covered ticker has no decision |
| `write_run_summary(text)` | Stores the run's 3-5 sentence summary, once (up to 2,000 characters) | already written, or empty |

A panel costs 5 × K + 1 requests: K samples from each of five specialists, and one Arbiter call.
A ticker whose panel no longer fits the budget is decided HOLD with the reason `the run's request budget was spent before the panel`.

The loop stops after 12 iterations, and its `on_iteration` hook ends it with a summary when 2 or fewer requests are left or the 90-minute deadline has passed.
Whatever the loop leaves undone, the Run Guard finishes in code, so every covered ticker still ends with a decision.
See [Run Guard](/system/run-guard).

::: info Where the code differs from the TDD
The TDD lists `submit_decisions(decisions)`; in code the tool takes only a note, and the decisions come from the session's own state, so the model cannot alter them.
The TDD's Orchestrator may also add up to three wildcard tickers; there is no tool for it yet ([Universe screen](/system/screener#wildcards)).
See [TDD §4](/design/tdd#orchestrator-tools) and [TDD §7](/design/tdd#specialists).
:::
