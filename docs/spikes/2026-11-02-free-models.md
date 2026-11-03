# Free models, rerun: after Nemotron 3 Super left the free list

Run on November 2, 2026, with the team's OpenRouter key, by `tests/spikes/model_spike.jac` with `SPIKE_SAMPLES=6`.
It used about 98 requests of the 1,000-a-day free allowance and spent $0.
It reran spike #12 ([October 8](2026-10-08-free-models.md)) after the first live run lost its primary model (#150).

## What happened

During the manual run of November 2, OpenRouter took `nvidia/nemotron-3-super-120b-a12b:free` off its free list.
From 2:54 p.m. ET every request to it failed with "This model is unavailable for free. The paid version is available now", and its free endpoint listing is now empty.
`LimitedModel` fell back to dots.3 Note preview on every call, but each call first spent a request on the dead model.
The run took 49 minutes, used 692 requests against its 600 budget, ended in `fallback` mode, and decided all 15 tickers `NO_ACTION`.

## Answer

**The primary model is now Nemotron 3.5 Super VL, the fallback stays dots.3 Note preview, and the chain is chosen from OpenRouter's live list at every run.**
Behind those two come any other usable free model and, last, OpenRouter's Free Models Router (`openrouter/free`), which passed every typed call in this spike.
A model that answers it is gone is retired for the rest of the run, so it never costs more than one request.

| Model | Valid typed outputs | First-try parse failures | Provider errors | Median / 90th pct / max latency | Notes |
| --- | --- | --- | --- | --- | --- |
| **nvidia/nemotron-3.5-super-vl:free** | **12 / 12** | **1** | **0** | 9 s / 25 s / 37 s | Primary |
| dots-studio/dots-3-note-preview:free | 12 / 12 | 8 | 0 | 19 s / 41 s / 50 s | Fallback; free until 2026-12-31 |
| xingchen-agi/xing4.0-29b-a4b:free | 4 / 12 | 0 | 11 | 18 s / 31 s / 31 s | "Temporarily rate-limited upstream" on 11 of 15 requests |
| openrouter/free | 12 / 12 | 3 | 0 | 11 s / 43 s / 103 s | Last link; answered by 8 different models |

Every model accepted `reasoning.effort`, and every model that answered ran the Orchestrator's tool loop to completion within 2 to 4 requests.
As in October, the capped loop's summary listed 12 follow-ups after being told at most two, so the Orchestrator's clamp in code still matters.

## The free list on November 2

OpenRouter listed 14 `:free` models.
Only four take a JSON schema (`structured_outputs`), which byLLM's typed calls send: Nemotron 3.5 Super VL, dots.3 Note preview, Xing 4.0, and Liquid LFM 2.5 (2.6B parameters).
The rest were ruled out without spending requests:

- **Nemotron 3 Ultra and Nemotron 3.5 Lightning** list tools but not `structured_outputs`; Ultra also had 43% uptime in spike #12.
- **Gemma 4 (31B and 26B)** and **Flint** list a response format but no JSON schema, and the endpoint listing showed Gemma 4 31B and Flint at 0% uptime.
- **Inkling and Inkling Small** answer only "agentic harnesses", and expire on November 4.
- **Nemotron 3.5 Content Safety** is the classifier spike #12 saw the router pick for a plain prompt.

## The Free Models Router, reconsidered

Spike #12 ruled the router out because it sent a plain prompt to the content-safety classifier.
With byLLM's typed calls, which send a JSON schema, it never did: its 25 requests went to Nemotron 3.5 Super VL, Nemotron 3 Ultra, Nemotron 3.5 Lightning, Nemotron 3 Nano Omni, dots.3 Note preview, Xing 4.0, Liquid LFM 2.5, and Cohere North Mini Code.
All 12 typed outputs were valid, 3 after a parse retry.
A wrong pick would fail validation rather than pass as a vote, so the router is safe as the last link, though not as the primary: one ticker's votes could come from several models, and some of them are small.
`LimitedModel` logs and records which model the router picked (the run's `model_versions["routed"]`).

## Consequences for the design

- **The chain is chosen at preflight** (`agents/catalog.jac`), from OpenRouter's public `/api/v1/models` list, which costs no requests: the vetted models still free, in order, then other free models that take a JSON schema and tools and have not expired, at most three, then the router.
- **A gone model is retired on its first "gone" answer**, so a model that leaves mid-run costs one request, not one per call.
- **The run records its chain**, any model retired mid-run with OpenRouter's reason, and which models answered through the router.
- **Rerun this spike** (`TRADING_AGENT_RUN_SPIKE=1 SPIKE_MODELS=<ids> SPIKE_SAMPLES=<n> SPIKE_OUT=<file> jac run --no-takeover tests/spikes/model_spike.jac`, with the keys exported) whenever a vetted model leaves the list, and before Launch Week.
