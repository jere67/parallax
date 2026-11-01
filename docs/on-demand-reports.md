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
