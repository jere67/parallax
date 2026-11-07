---
title: Repository layout
description: Where each layer lives in the repository, and the rules that keep module paths stable.
related:
  - { text: Architecture, link: /system/architecture }
  - { text: Contributing, link: /guide/contributing }
---

The repository follows the layout in [TDD §3](/design/tdd#repository-layout).
Each folder is one layer of the system, and the layers depend only downward.

```text
main.jac        server entry; imports every endpoint by name
models/         node, edge, obj, and enum definitions; no server-only imports
agents/         role model instances, Orchestrator, research sub-agents, specialists, Arbiter
research/       data collectors and the S&P 500 screener
analysis/       indicators, the consensus engine, and vote scoring
action/         broker client, sizing, risk gate, executor, reconciliation, insight cards, baselines
run/            daily run, Run Guard, trading day, scheduled jobs, health
market/         whole-market data for the screener and stock pages
dashboard/      client pages and components
assets/         static files served at /static/assets/
tests/          integration and smoke tests, fixtures, fakes
e2e/            the dashboard's browser checks on each device (Playwright)
docs/           design documents and spike findings
site/           this documentation site (VitePress)
```

## Where to look

| To change | Start in |
| --- | --- |
| What a node or report holds | `models/graph.jac` (graph), `models/research.jac` and `models/agents.jac` (typed reports and votes), `models/views.jac` (API responses) |
| A data source, its limits, or its cache lifetime | `research/sources.jac`, then the source's collector |
| The universe screen | `research/screener.jac` |
| A screener field or tab | `market/rows.jac`, then `dashboard/market/columns.jac` |
| A technical indicator | `research/indicators.jac` |
| An agent's prompt or output type | `agents/` |
| The consensus or the decision rule | `analysis/consensus.jac` |
| Position sizing | `action/sizing.jac` |
| A risk rule | `action/gate.jac` |
| Order handling | `action/executor.jac`, `action/broker.jac` |
| The schedule | `run/jobs.jac`, `run/trading.jac` |
| What a run may spend | `run/guard.jac` |
| A dashboard page | `dashboard/` |
| An endpoint | its module, then import it by name in `main.jac` |

## Rules that keep it working

- **Every endpoint is imported by name in `main.jac`.**
  An endpoint that is not imported returns 404 or 405.
  `tests/endpoints_tests.jac` fails for any `def:pub` or `def:priv` the server does not serve.
- **Module paths that declare node types are frozen once data is stored.**
  Stored rows name their type by module path, so moving a module strands them.
- **Import from the project root.**
  Write `import from analysis.consensus { ... }`, never a `..` import.
  A `..` import passes `jac check` but breaks `jac build`.
- **Tests sit beside their modules** as `module_tests.jac`.
  Never name a file `test_*.jac`.
- **Collectors never touch the graph.**
  A test fails if a module in `research/` does.
- **Models are called through a role instance** in `agents/models.jac`, never the builtin `llm`, which skips the rate limiter.
  A test fails if any module uses the builtin.

Read [Contributing](/guide/contributing) for the full list.
