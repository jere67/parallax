"""Export runs from a local server's embedded Postgres for tests/spikes/decision_backtest.jac.

Only one portfolio's runs count, the team's unless EXPORT_PORTFOLIO names another (`agent`
while only one user has an agent of their own): an on-demand report keeps its own portfolio,
and its runs share the dates. For each run it writes the macro record and, per covered
ticker, the market figures, the research reports in write order, the specialist votes, the
consensus, and the decision, as JSON keyed by run date. It reads in one read-only transaction, so it is safe
beside a running server.

The Jac CLI bundles its own Postgres driver, so this uses psycopg from a scratch environment:

    python3 -m venv /tmp/pg && /tmp/pg/bin/pip install "psycopg[binary]"
    /tmp/pg/bin/python tests/spikes/export_runs.py <socket dir> <database> \
        runs.json 2026-11-02 2026-11-03 2026-11-04

The socket directory is the `unix_socket_directories` of the embedded postgres process (see
`ps`), and the database is `jac_<project>_<sha1 of the project path>[:8]`.
"""
import json
import os
import sys

import psycopg

HIDDEN = ("__type__", "__module__")


def strip(value):
    """The archetype's fields without Jac's type markers."""
    if isinstance(value, dict):
        return {k: strip(v) for k, v in value.items() if k not in HIDDEN}
    if isinstance(value, list):
        return [strip(v) for v in value]
    return value


def main(socket_dir, database, out_path, days):
    with psycopg.connect(host=socket_dir, port=5432, user="jac", dbname=database, options="-c default_transaction_read_only=on") as conn:
        rows = conn.execute("select id, arch_type, src, dst, props->'archetype' from anchors order by seq").fetchall()
    nodes = {r[0]: (r[1], r[4]) for r in rows if r[2] is None}
    edges = [(r[1], r[2], r[3]) for r in rows if r[2] is not None]

    def children(node_id, edge_type, node_type):
        """The `node_type` nodes an `edge_type` edge leads to from `node_id`, in write order."""
        return [(d, nodes[d][1]) for (t, s, d) in edges if s == node_id and t == edge_type and d in nodes and nodes[d][0] == node_type]

    def first(node_id, edge_type, node_type):
        found = children(node_id, edge_type, node_type)
        return strip(found[0][1]) if found else None

    out = {}
    name = os.environ.get("EXPORT_PORTFOLIO", "team")
    chosen = [nid for nid, (t, a) in nodes.items() if t == "Portfolio" and a.get("name") == name]
    for run_id, run in [r for portfolio in chosen for r in children(portfolio, "Ran", "Run")]:
        day = run["run_date"]
        if day not in days:
            continue
        if day in out:
            raise SystemExit(f"two {name} runs on {day}")
        tickers = {}
        for cov_id, cov in children(run_id, "Covers", "Coverage"):
            tickers[cov["ticker"]] = {
                "coverage": strip(cov),
                "research": [strip(r) for _, r in children(cov_id, "Researched", "ResearchRecord")],
                "votes": [strip(v) for _, v in children(cov_id, "Voted", "VoteRecord")],
                "decision": first(cov_id, "Decided", "Decision"),
                "consensus": first(cov_id, "Concluded", "ConsensusResult"),
            }
        out[day] = {
            "run": {k: run[k] for k in ("status", "started_at", "finished_at", "mode") if k in run},
            "macro": first(run_id, "HasMacro", "MacroRecord"),
            "tickers": tickers,
        }
    with open(out_path, "w") as f:
        json.dump(out, f, indent=1)
    for day, run in sorted(out.items()):
        votes = sum(len(t["votes"]) for t in run["tickers"].values())
        sys.stdout.write(f"{day}: {run['run']['status']}, {len(run['tickers'])} tickers, {votes} votes\n")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:])
