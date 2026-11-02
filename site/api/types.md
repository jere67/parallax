---
title: Data types
description: Every object the API returns, field by field, as defined in models/views.jac.
related:
  - { text: API overview, link: /api/overview }
  - { text: Data model, link: /system/data-model }
---

The API returns typed objects defined in [`models/views.jac`](https://github.com/jere67/parallax/blob/main/models/views.jac).
A field marked **required** is always present; every other field has a default (an empty string, 0, `false`, an empty list, or `null`).

Conventions: money is in dollars, returns are fractions, dates are New York `YYYY-MM-DD`, timestamps are UTC ISO 8601, and a missing figure is `null`, never 0.

## Portfolio

### PortfolioView

Returned by [`get_portfolio`](/api/get-portfolio).

| Field | Type | |
| --- | --- | --- |
| `name` | string | required |
| `mode` | string | required. `insight` or `auto` |
| `started` | boolean | required |
| `demo` | boolean | |
| `opened_at`, `as_of` | string | UTC |
| `last_day` | string | trading date of the last mark |
| `starting_cash` | number | |
| `equity`, `cash`, `positions_value` | number or null | |
| `day_pnl`, `day_return` | number or null | against the previous mark |
| `total_pnl`, `total_return` | number or null | against the starting balance |
| `peak_equity`, `drawdown` | number or null | |
| `gross_exposure` | number or null | positions value over equity |
| `sessions`, `bypasses`, `drift` | integer | |
| `positions`, `closed` | [PositionView](#positionview)[] | |
| `orders` | [OrderView](#orderview)[] | |

### PositionView

| Field | Type | |
| --- | --- | --- |
| `ticker`, `sector` | string | required |
| `qty` | integer | required |
| `avg_entry_price` | number | required |
| `opened_at` | string | required |
| `last_price` | number or null | |
| `priced_at` | string | |
| `market_value`, `weight` | number or null | |
| `pnl`, `pnl_pct` | number or null | unrealized when open, realized when closed |
| `stop_price`, `stop_distance` | number or null | distance as a fraction of the last price |
| `time_stop` | string | date |
| `closed_at` | string | empty while open |
| `exit_price` | number or null | |
| `entry_qty` | integer | |
| `thesis` | string | |
| `decision_day` | string | the run that opened it |

### OrderView

| Field | Type | |
| --- | --- | --- |
| `client_order_id` | string | required |
| `ticker`, `purpose`, `side` | string | required. `purpose` is `entry`, `add`, `exit`, `trim`, or `stop` |
| `qty` | integer | required |
| `order_type`, `time_in_force`, `status`, `submitted_at` | string | required |
| `limit_price`, `stop_price` | number or null | |
| `filled_qty` | integer | |
| `filled_avg_price` | number or null | |
| `updated_at`, `reject_reason`, `run_day` | string | |
| `fills` | [FillView](#fillview)[] | |

### FillView

| Field | Type | |
| --- | --- | --- |
| `qty` | integer | required |
| `price` | number | required |
| `filled_at` | string | required |

## Performance

### PerformanceView

Returned by [`get_performance`](/api/get-performance).

| Field | Type | |
| --- | --- | --- |
| `started` | boolean | required |
| `start_day` | string | |
| `starting_cash` | number | |
| `series` | [Series](#series)[] | |

### Series

| Field | Type | |
| --- | --- | --- |
| `key`, `label` | string | required |
| `points` | [MarkPoint](#markpoint)[] | required |
| `total_return`, `sharpe`, `max_drawdown`, `volatility` | number or null | |

### MarkPoint

| Field | Type | |
| --- | --- | --- |
| `day` | string | required |
| `equity` | number | required |
| `drawdown` | number | required |

## Runs

### RunSummary

Returned by [`list_runs`](/api/list-runs).

| Field | Type | |
| --- | --- | --- |
| `run_date`, `status` | string | required |
| `covered`, `trades` | integer | |
| `actions` | object | action to count |

### RunView

Returned by [`get_run`](/api/get-run).

| Field | Type | |
| --- | --- | --- |
| `run_date`, `status`, `mode` | string | required |
| `demo`, `reduced_mode` | boolean | |
| `started_at`, `finished_at`, `executed_at`, `reconciled_at` | string | UTC, empty until it happens |
| `execution_note`, `summary` | string | |
| `model_requests`, `prompt_tokens`, `completion_tokens` | integer | |
| `macro` | [MacroView](#macroview) or null | |
| `rows` | [CoverageRow](#coveragerow)[] | |
| `action_log` | string[] | |
| `previous_day`, `next_day` | string | |

### MacroView

| Field | Type | |
| --- | --- | --- |
| `regime` | string | required. `RISK_ON`, `NEUTRAL`, or `RISK_OFF` |
| `confidence` | number | required |
| `summary` | string | required |
| `risks` | string[] | |
| `spy_close`, `spy_sma_200`, `spy_vol_20` | number or null | |

### CoverageRow

| Field | Type | |
| --- | --- | --- |
| `ticker`, `sector`, `reason` | string | required |
| `reason_note`, `flag_reason` | string | |
| `screen_score`, `last_close` | number or null | |
| `action`, `draft_action` | string | |
| `conviction` | number or null | |
| `downgraded`, `forced_hold` | boolean | |
| `score`, `agreement`, `ci_low`, `ci_high` | number or null | |
| `gate_outcome`, `rejected_by` | string | |
| `requested_qty`, `approved_qty` | integer | |
| `order_status`, `order_side` | string | |
| `order_qty`, `filled_qty` | integer | |
| `filled_avg_price` | number or null | |

## Decision trail

### TrailView

Returned by [`get_decision_trail`](/api/get-decision-trail).

| Field | Type | |
| --- | --- | --- |
| `run_date`, `ticker`, `sector`, `reason`, `run_status`, `mode` | string | required |
| `demo` | boolean | |
| `reason_note`, `flag_reason` | string | |
| `screen_score` | number or null | |
| `fetch_errors` | string[] | |
| `last_close`, `atr_14`, `realized_vol_20`, `volume_20` | number or null | |
| `sessions_to_earnings` | integer or null | |
| `research` | [ResearchView](#researchview)[] | |
| `macro` | [MacroView](#macroview) or null | |
| `specialists` | [SpecialistView](#specialistview)[] | |
| `consensus` | [ConsensusView](#consensusview) or null | |
| `decision` | [DecisionView](#decisionview) or null | |
| `gate` | [GateView](#gateview) or null | |
| `orders` | [OrderView](#orderview)[] | |
| `position` | [PositionView](#positionview) or null | |
| `tickers` | string[] | the run's other tickers |
| `disclaimer` | string | |

### ResearchView

| Field | Type | |
| --- | --- | --- |
| `domain`, `view` | string | required |
| `confidence` | number | required |
| `summary` | string | required |
| `evidence` | [EvidenceView](#evidenceview)[] | |
| `risks`, `data_gaps` | string[] | |
| `model`, `as_of`, `followup_question` | string | |

### EvidenceView

| Field | Type | |
| --- | --- | --- |
| `claim`, `source_url`, `published` | string | required |
| `host` | string | |

### SpecialistView

| Field | Type | |
| --- | --- | --- |
| `specialist` | string | required. `fundamentals`, `technical`, `news`, `macro`, or `flow` |
| `score` | number | required |
| `weight` | number or null | |
| `samples` | [SampleView](#sampleview)[] | |

### SampleView

| Field | Type | |
| --- | --- | --- |
| `sample` | integer | required |
| `stance` | string | required |
| `confidence`, `signed` | number | required |
| `horizon_days` | integer | required |
| `rationale` | string | required |
| `cited` | integer[] | |
| `sources` | [EvidenceView](#evidenceview)[] | |
| `excess_return` | number or null | once scored |
| `hit` | boolean or null | once scored |

### ConsensusView

| Field | Type | |
| --- | --- | --- |
| `score`, `agreement`, `ci_low`, `ci_high` | number | required |
| `draft_action` | string | required |
| `samples_used`, `samples_dropped` | integer | |

### DecisionView

| Field | Type | |
| --- | --- | --- |
| `action` | string | required |
| `conviction` | number | required |
| `thesis` | string | |
| `risks` | string[] | |
| `exit_condition`, `time_stop`, `arbiter_verdict`, `downgrade_reason`, `forced_hold_reason`, `model` | string | |

### GateView

| Field | Type | |
| --- | --- | --- |
| `outcome`, `side`, `purpose` | string | required |
| `requested_qty`, `approved_qty` | integer | required |
| `checked_at` | string | required |
| `price`, `stop_distance` | number or null | |
| `gate_version` | string | |
| `rules` | [RuleView](#ruleview)[] | |

### RuleView

| Field | Type | |
| --- | --- | --- |
| `rule` | string | required |
| `passed` | boolean | required |
| `detail` | string | |
| `qty_before`, `qty_after` | integer | |

## Other types

### Health

Returned by [`health`](/api/health): `status` and `checked_at`, both strings, both required.

### ManualRun

Returned by [`start_morning_run`](/api/start-morning-run): `started` (boolean), `run_day` and `message` (strings), all required.
