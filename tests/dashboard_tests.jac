"""The dashboard's endpoints through a real server: anonymous readers see the team graph."""
import tempfile;
import from pathlib { Path }
import from jaclang.testing.testing { JacTestClient }

glob APP: str = str(Path(__file__).resolve().parent / "fixtures" / "dashboard_app.jac");

def call(client: JacTestClient, name: str, body: dict[str, str] | None = None) -> object {
    resp = client.post(f"/function/{name}", json=body or {});
    assert resp.status_code == 200, f"{name}: {resp.status_code} {resp.text[:300]}";
    return resp.json()["data"]["result"];
}

test "anonymous readers get the portfolio, its runs, and a decision trail" {
    client = JacTestClient.from_file(APP, base_path=tempfile.mkdtemp());
    try {
        empty = call(client, "get_portfolio");
        client.register_user("writer", "writer-password-1");
        assert client.post("/function/seed_team_graph", json={}).ok;
        client.clear_auth();
        portfolio = call(client, "get_portfolio");
        performance = call(client, "get_performance");
        runs = call(client, "list_runs");
        run = call(client, "get_run");
        trail = call(client, "get_decision_trail", {"run_date": "2026-10-21", "ticker": "aapl"});
        missing = call(client, "get_decision_trail", {"run_date": "2026-10-21", "ticker": "MSFT"});
    } finally {
        client.close();
    }
    assert empty["started"] is False and empty["positions"] == [];
    assert portfolio["started"] is True and portfolio["equity"] == 100500.0 and portfolio["mode"] == "auto";
    assert performance["started"] is True and [p["equity"] for p in performance["series"][0]["points"]] == [100500.0];
    assert [r["run_date"] for r in runs] == ["2026-10-21"] and runs[0]["actions"] == {"BUY": 1};
    assert run["run_date"] == "2026-10-21" and [r["ticker"] for r in run["rows"]] == ["AAPL"];
    assert trail["ticker"] == "AAPL" and trail["decision"]["action"] == "BUY" and trail["disclaimer"];
    assert missing is None;
}
