---
title: Data model
description: "The team graph: every node and edge the system stores, what each one holds, and how nodes are made public."
related:
  - { text: Data types, link: /api/types }
  - { text: Dashboard internals, link: /system/dashboard }
---

Everything the system knows is stored in one Jac graph, on the server's shared root.
A run, its reports, votes, decision, risk check, and orders are nodes, joined by typed edges, so the dashboard can walk from a portfolio to any fill and back.
The node types are in [`models/graph.jac`](https://github.com/jere67/parallax/blob/main/models/graph.jac).

## The graph

```text
root.shared
  └─ Portfolio
       ├─ Holds ──> Position ──OpenedBy──> Decision
       │              └─ StoppedBy ──> Order (its protective stops)
       ├─ Sent ──> Order (every order, for reconciliation)
       ├─ Marked ──> DailyMark(day) (the 4:30 p.m. mark and reconciliation)
       ├─ Benchmarks ──> Baseline(kind) (simulated forward-test baselines)
       │    ├─ SimHolds ──> Position
       │    └─ SimMarked ──> DailyMark(day)
       ├─ Counted ──> RequestCount(day)
       └─ Ran ──> Run(run_date)
            ├─ HasMacro ──> MacroRecord
            └─ Covers ──> Coverage(ticker)
                 ├─ Researched ──> ResearchRecord (one per domain)
                 ├─ Voted ──> VoteRecord (one per specialist sample)
                 ├─ Concluded ──> ConsensusResult
                 ├─ Decided ──> Decision ──CheckedBy──> RiskCheck ──Placed──> Order ──FilledBy──> Fill
                 └─ Published ──> InsightCard
```

Two conventions hold everywhere:

- Timestamps are ISO 8601 strings in UTC.
- Trading dates are `YYYY-MM-DD` strings in New York time.

## Nodes

### Portfolio and positions

| Node | Holds |
| --- | --- |
| `Portfolio` | `name`, `mode` (auto or insight), `starting_cash`, `opened_at`, `peak_equity`, and `demo`. The team portfolio is named `team`. |
| `Position` | `ticker`, `sector`, `qty`, `avg_entry_price`, `opened_at`; the stop (`stop_price`, `stop_order_id`), the `time_stop` date, the last price, and, once closed, `closed_at` and `exit_price`. A position is open while `closed_at` is empty. |
| `DailyMark` | One day's close: `equity`, `cash`, `positions_value`, `peak_equity`, `drawdown`, `open_positions`, and the reconciliation's `drift` and `bypasses`. |
| `Baseline` | A simulated portfolio: `kind` (equal_weight or spy), `starting_cash`, `start_day`, `cash`, `peak_equity`, how far it is simulated, and its trade log. |
| `RequestCount` | Model requests spent on one UTC day. |

### A run

| Node | Holds |
| --- | --- |
| `Run` | `run_date` and `status`, whether it was reduced, when it started, finished, executed, closed its day orders, reconciled, scored votes, and advanced the baselines, its action log and summary, and its model versions, requests by role, and tokens. |
| `MacroRecord` | The macro agent's report (`MacroReport`) and the regime inputs it read. |
| `Coverage` | One covered ticker: `sector`, why it was covered (`reason`), its screen score, fetch and analysis errors, a flag reason, and the facts the risk gate needs (last close, 14-day ATR, 20-day volatility and volume, sessions to earnings). |
| `ResearchRecord` | One research report (`ResearchReport`) for one domain, and the follow-up question that asked for it, if any. |
| `VoteRecord` | One specialist sample's `Vote`, and once scored, its `excess_return` against SPY. |
| `ConsensusResult` | `score`, `agreement`, the interval (`ci_low`, `ci_high`), the `draft_action`, each specialist's score and weight, and samples used and dropped. |
| `Decision` | The final `action` and `conviction`, the thesis, risks, exit condition, time stop, and why it was downgraded or forced to hold. |
| `RiskCheck` | The gate's `outcome` (approved, resized, or rejected), `approved_qty`, every rule's result, and what it was asked for. |
| `Order` | `client_order_id`, `purpose` (entry, add, exit, trim, or stop), `side`, `qty`, type, time in force, prices, status, fills so far, and the reject reason. |
| `Fill` | `qty`, `price`, and `filled_at`. |
| `InsightCard` | The published card: action, conviction, thesis, risks, exit condition, consensus figures, each specialist's tally, up to 8 sources, and the disclaimer. |

## Enums

| Enum | Values |
| --- | --- |
| `PortfolioMode` | `auto`, `insight` |
| `RunStatus` | `running`, `normal`, `fallback`, `skipped`, `failed` |
| `CoverageReason` | `screen`, `held`, `wildcard`, `user_request` |
| `TradeAction` | `BUY`, `ADD`, `HOLD`, `TRIM`, `SELL`, `NO_ACTION` |
| `RiskOutcome` | `approved`, `resized`, `rejected` |
| `OrderSide` | `buy`, `sell` |
| `OrderPurpose` | `entry`, `add`, `exit`, `trim`, `stop` |
| `BaselineKind` | `equal_weight`, `spy` |

## Making nodes public

The team graph belongs to the server.
Other users and anonymous callers see a node only after it is granted read access, and a grant covers one node, not its subtree.
So every team node is created through one helper, which grants read access as it attaches the node.
This grant is a storage rule, not what makes the dashboard private: every data endpoint is `def:priv` and answers 401 to an anonymous caller, and each user's own agent graph sits on that user's root with no grant at all.
The helper looks like this:

```jac
def public[T](child: T) -> T {
    grant(child, level=AccessLevel.READ);
    return child;
}

run = public(portfolio +>:Ran():+> Run(...));
```

Edges need no grant: a reader can follow a typed edge to any granted node.
[`tests/public_tests.jac`](https://github.com/jere67/parallax/blob/main/tests/public_tests.jac) checks that an anonymous caller sees granted nodes, with their typed report bodies, and does not see an ungranted one.

## Changing the schema

Stored rows name their type by module path.

- **Never move a node type to another module** once data is stored: its rows would be quarantined until a schema rule maps the old path.
- **Add fields with defaults** freely.
- **Rename a field** only with `schema_alias`.

::: info Where it differs from the TDD
[TDD §11](/design/tdd#graph-layout) names the report nodes `MacroReport`, `ResearchReport`, and `Vote`.
In the code, those are the typed objects, wrapped by the nodes `MacroRecord`, `ResearchRecord`, and `VoteRecord`.
The TDD's graph also leaves out the `Sent`, `Marked`, `Benchmarks`, `SimHolds`, `SimMarked`, and `StoppedBy` edges, and lists only three run statuses; the code adds `running` and `failed`.
The user graph for on-demand reports (`models/users.jac`) is defined but not used yet.
:::
