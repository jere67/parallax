"""The dashboard's endpoints through a real server: each account sees its own agent, the admin's
is the team's, and an anonymous reader sees nothing."""
import os;
import tempfile;
import from pathlib { Path }
import from jaclang.testing.testing { JacTestClient }
import from market.demo { DEMO_ENV }

glob APP: str = str(Path(__file__).resolve().parent / "fixtures" / "dashboard_app.jac");

def call(client: JacTestClient, name: str, body: dict[str, str | bool] | None = None) -> object {
    resp = client.post(f"/function/{name}", json=body or {});
    assert resp.status_code == 200, f"{name}: {resp.status_code} {resp.text[:300]}";
    return resp.json()["data"]["result"];
}

test "the admin reads the team agent's news feed and a story, leaving out what they do not need" {
    client = JacTestClient.from_file(APP, base_path=tempfile.mkdtemp());
    try {
        client.register_user("team-admin", "writer-password-1");
        assert client.post("/function/set_admin", json={"on": True}).ok;
        assert client.post("/function/seed_team_graph", json={}).ok;
        whole = call(client, "get_news_feed");
        filtered = call(client, "get_news_feed", {"desk": "news", "q": "guidance"});
        none = call(client, "get_news_feed", {"ticker": "MSFT"});
        story = call(client, "get_news_story", {"day": "2026-10-21", "ticker": "aapl", "desk": "news"});
        missing = call(client, "get_news_story", {"day": "2026-10-21", "ticker": "MSFT", "desk": "news"});
    } finally {
        client.close();
    }
    assert whole["total"] == 2 and whole["desks"]["macro"] == 1 and whole["desks"]["news"] == 1;
    assert whole["tickers"] == ["AAPL"] and whole["days"] == ["2026-10-21"];
    assert [i["id"] for i in filtered["items"]] == ["2026-10-21/AAPL/news/0"];
    assert filtered["items"][0]["headline"] == "Apple raised its guidance for the year";
    assert none["total"] == 0;
    assert story["body"] == "Sales rose 12%." and story["trail"] is True and story["action"] == "BUY";
    assert story["sources"][0]["url"] == "https://example.com/apple" and story["sources"][0]["claims"] == ["Guidance rose."];
    assert missing is None;
}

test "a reader's feed holds their own agent's notes and their own reports, and nothing else" {
    client = JacTestClient.from_file(APP, base_path=tempfile.mkdtemp());
    address = {"day": "2026-10-21", "ticker": "NVDA", "desk": "news", "requested": True};
    try {
        client.register_user("team-admin", "writer-password-1");
        assert client.post("/function/set_admin", json={"on": True}).ok;
        assert client.post("/function/seed_team_graph", json={}).ok;
        assert client.post("/function/set_admin", json={"on": False}).ok;
        client.clear_auth();
        client.register_user("asker", "writer-password-1");
        assert client.post("/function/seed_report", json={}).ok;
        assert client.post("/function/ask_for_report", json={}).ok;
        asked = call(client, "get_news_feed");
        story = call(client, "get_news_story", address);
        client.clear_auth();
        client.register_user("bystander", "writer-password-1");
        other = call(client, "get_news_feed");
        unasked = call(client, "get_news_story", address);
    } finally {
        client.close();
    }
    assert [i["id"] for i in asked["items"]] == ["2026-10-21/NVDA/news/0/requested"];
    assert asked["tickers"] == ["NVDA"];
    assert story["body"] == "Sales rose 12%." and story["trail"] is False;
    assert other["total"] == 0 and other["items"] == [];
    assert unasked is None;
}

test "the admin reads the team agent's portfolio, runs, and decision trail" {
    client = JacTestClient.from_file(APP, base_path=tempfile.mkdtemp());
    try {
        client.register_user("team-admin", "writer-password-1");
        assert client.post("/function/set_admin", json={"on": True}).ok;
        empty = call(client, "get_portfolio");
        assert client.post("/function/seed_team_graph", json={}).ok;
        portfolio = call(client, "get_portfolio");
        performance = call(client, "get_performance");
        runs = call(client, "list_runs");
        run = call(client, "get_run");
        trail = call(client, "get_decision_trail", {"run_date": "2026-10-21", "ticker": "aapl"});
        specialists = call(client, "get_specialists");
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
    assert isinstance(specialists, list);
    assert len(specialists) == 5 and all(s["votes"] == 0 and s["hit_rate"] is None for s in specialists);
    assert missing is None;
}

test "every data endpoint refuses an anonymous reader" {
    client = JacTestClient.from_file(APP, base_path=tempfile.mkdtemp());
    try {
        for name in ["get_portfolio", "get_performance", "list_runs", "get_run", "get_specialists", "get_news_feed"] {
            assert client.post(f"/function/{name}", json={}).status_code == 401, name;
        }
        assert client.post("/function/get_decision_trail", json={"run_date": "2026-10-21", "ticker": "AAPL"}).status_code == 401;
        assert client.post("/function/get_news_story", json={"day": "2026-10-21", "ticker": "AAPL", "desk": "news"}).status_code == 401;
        for name in ["screen_stocks", "get_stock", "get_stock_history", "get_stock_about"] {
            assert client.post(f"/function/{name}", json={"symbol": "AAPL"} if name != "screen_stocks" else {}).status_code == 401, name;
        }
    } finally {
        client.close();
    }
}

test "a member sees only their own agent, never the team's" {
    client = JacTestClient.from_file(APP, base_path=tempfile.mkdtemp());
    try {
        client.register_user("team-admin", "writer-password-1");
        assert client.post("/function/set_admin", json={"on": True}).ok;
        assert client.post("/function/seed_team_graph", json={}).ok;
        assert call(client, "get_portfolio")["started"] is True;
        client.clear_auth();
        client.register_user("member", "member-password-1");
        assert client.post("/function/set_admin", json={"on": False}).ok;
        mine = call(client, "get_portfolio");
        assert mine["started"] is False and mine["positions"] == [];
        assert call(client, "list_runs") == [];
        specialists = call(client, "get_specialists");
        assert isinstance(specialists, list);
        assert len(specialists) == 5 and all(s["votes"] == 0 for s in specialists);
        assert call(client, "get_decision_trail", {"run_date": "2026-10-21", "ticker": "AAPL"}) is None;
    } finally {
        client.close();
    }
}

"""A stock page reads the caller's agent through get_portfolio and get_run, whose tests above keep a
member from the team's agent. A demo server shows every account the demo agent, so this checks the
lookup and its link into the app, not the isolation."""
test "a stock page shows the agent's last decision on it, with a link into the app" {
    before = os.environ.get(DEMO_ENV);
    os.environ[DEMO_ENV] = "1";
    client = JacTestClient.from_file(APP, base_path=tempfile.mkdtemp());
    try {
        client.register_user("team-admin", "writer-password-1");
        assert client.post("/function/set_admin", json={"on": True}).ok;
        assert client.post("/function/seed_team_graph", json={}).ok;
        held = call(client, "get_stock", {"symbol": "AAPL"});
        other = call(client, "get_stock", {"symbol": "MSFT"});
    } finally {
        client.close();
        if before is None {
            del os.environ[DEMO_ENV];
        } else {
            os.environ[DEMO_ENV] = before;
        }
    }
    assert held["found"] and held["committee"]["action"] == "BUY" and held["committee"]["run_day"] == "2026-10-21";
    assert held["committee"]["trail"] == "/app/runs/2026-10-21/AAPL";
    assert other["found"] and other["committee"]["action"] == "" and other["committee"]["trail"] == "";
}
