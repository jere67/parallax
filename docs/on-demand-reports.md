# On-demand reports

Part of #31 and FR-11.
The feature uses three small layers: private request endpoints, a scheduled worker, and a Reports page.
Requests never submit trades.

## Request API

`request_report(ticker)`, `list_reports()`, and `get_report(request_id)` require authentication.
A request belongs to the caller's root; a shared ticker/trading-date job contains no user identity.
Repeated submissions return the same request, and users share an existing job without spending another new-report slot.
The response states are `pending`, `running`, `ready`, and `failed`.
A missing or stale catalog fails closed for new analysis.

`REPORTS_PER_USER_DAY` defaults to 3 and `REPORTS_GLOBAL_DAY` to 15.
These are configurable proposed GAP-06 values, not a claim of team sign-off.
Quotas count new jobs admitted, including failed attempts, per report trading date; cache reuse is free.
A zero or invalid quota disables new work.
At fewer than 150 remaining model requests, only existing jobs are available.
The scheduler supplies the catalog and capacity snapshot; HTTP endpoints never fetch providers or call models.

## Worker

A one-minute scheduled job refreshes the S&P 500 catalog, the latest trading date from Alpaca's calendar, and the conservative provider budget.
Weekend and holiday requests use the most recent trading session.
No key, an unavailable provider counter, or stale metadata permits cached reports only.
In demo mode, only the existing simulated tickers/cards are offered and no provider is contacted.

The scheduler first reuses the team's published daily insight cards.
It processes one new report at a time, starting network work only after the running claim commits.
The worker collects only the requested ticker plus macro benchmarks, and offers the existing Orchestrator research, follow-up, panel, and summary tools, never submission or broker tools.
The next tick stores its result under a separate insight portfolio and exposes the card to waiting users.
The shared model limiter enforces an 80-request ceiling including retries and a ten-minute dispatch deadline for each report; network tasks inherit that ceiling.
A provider request already in flight can finish after the deadline.
The latency target remains under five minutes; it requires live measurement, not a claim based on mocked tests.

A failed or interrupted job remains failed for that ticker/date, with a safe error and no automatic re-spend.
After fifteen minutes an abandoned running claim becomes failed.
Pending work from a previous trading date expires instead of generating a misleading current report.
The worker uses a process-local future, so deploy one application replica for this first implementation; a multi-replica durable worker is outside this scoped feature.
