# Issue #71: request accounting and Flow abstention audit

The implementation now records provider requests by role and kind on each Run, retains full failed validation messages on the decision trail, and allows Flow to explain HOLD with verified missing-input statements.
The largest historical overhead was in the panel: 451 provider requests for 304 base calls in the October 16 Analysis exit run.
Those legacy results cannot identify the largest validation failure, so no reduction is claimed without another live measurement.

## What changed

- `Run.model_requests_by_role` contains each role's `first_attempt`, `parse_retry`, `transient_retry`, and `fallback` request counts.
- A provider request occupies exactly one cell; the cells sum to `Run.model_requests`.
- The low-temperature retry model has its own `retry` role; its first attempts are additional requests too.
- `Coverage.analysis_errors` retains complete dropped-sample errors, and `Decision.arbiter_error` retains complete failed-review errors.
- Flow HOLD may cite exact supplied missing-input statements in `Vote.cited_gaps`; these remain separate from factual evidence and cannot support a BUY or SELL.
- Citation numbers, confidence bounds, and horizon bounds are explicit in the initial prompt.
- `max_output_retries` remains one; reducing it without the requested live counts would be speculative.

## Offline validation

Tests use MockLLM or local fake OpenRouter responses, with no real provider requests.
They cover typed parse retries, 429s, fallback during a parse retry, async and concurrent dispatch, detached counter snapshots, stored run totals, full error tails, and Flow gap-citation acceptance and rejection.
One regression test reproduces the known Flow contract failure through the real parser and a local fake HTTP provider: four uncited HOLD responses spend four counted requests and drop the sample, while a HOLD citing an exact supplied gap succeeds in one counted request.
This proves the targeted failure path is fixed offline; it does not measure a live model's retry rate or establish which live validation failure is most frequent.

## Live measurement still required

No OpenRouter key or project `.env` was available during implementation.
Use the existing team credentials locally; never commit them or paste them into an issue or chat.
The existing live Analysis exit run also needs the team's data-provider credentials.
Run this only when the team account has allowance for a full run:

```bash
set -a && source .env && set +a
TRADING_AGENT_RUN_ANALYSIS_EXIT=1 EXIT_PARTS=main \
  EXIT_OUT=/tmp/issue-71-analysis.json \
  jac run --no-takeover tests/runs/analysis_exit_run.jac \
  > /tmp/issue-71-analysis.log 2>&1
```

The script uses a separate insight-only test portfolio and does not place broker orders.
Set `EXIT_RUN_DAY` to the trading day being measured when the default New York date is unsuitable.
The JSON includes `model_requests_by_role` for the run and every instrumented tool, full `dropped` and `arbiter_error` strings per ticker, and `cited_gaps` on valid votes.
The companion log preserves byLLM's validation feedback for parse failures that recover.

For the follow-up, verify that matrix cells sum to the scalar count, then compare `convene_panel` with the other tools.
Include the `retry` role's first attempts when calculating retry overhead.
Group full validation messages to identify the largest cause, check Flow HOLD gap citations, and change only the dominant prompt/schema or retry setting indicated by that evidence.
Record the model version, date, ticker count, K, request matrix, dropped counts, and before/after result in this document and update TDD §12.
Issue #71's empirical retry-reduction acceptance remains open until that evidence is recorded.
