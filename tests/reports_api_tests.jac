"""Real-server auth, owner isolation, daily quotas, and same-day cache reuse."""
import tempfile;
import from pathlib { Path }
import from jaclang.testing.testing { JacTestClient }

glob APP: str = str(Path(__file__).resolve().parent / "fixtures" / "reports_app.jac");

test "report history is private; duplicate and shared requests do not spend quota twice" {
    c = JacTestClient.from_file(APP, base_path=tempfile.mkdtemp());
    try {
        assert c.post("/function/request_report", json={"ticker": "AAPL"}).status_code == 401;
        c.register_user("alice", "test-password-1");
        assert c.post("/function/set_admin", json={"on": True}).ok;
        assert c.post("/function/seed_report_catalog", json={}).ok;
        a = c.post("/function/request_report", json={"ticker": " aapl "}).json()["data"]["result"];
        assert a["accepted"];
        id = a["item"]["id"];
        again = c.post("/function/request_report", json={"ticker": "AAPL"}).json()["data"]["result"];
        assert again["item"]["id"] == id;
        state = c.post("/function/list_reports", json={}).json()["data"]["result"];
        assert state["remaining"] == 2 and len(state["reports"]) == 1;
        c.clear_auth();
        c.register_user("bob", "test-password-2");
        assert c.post("/function/get_report", json={"request_id": id}).json()["data"]["result"] is None;
        assert c.post("/function/list_reports", json={}).json()["data"]["result"]["reports"] == [];
        shared = c.post("/function/request_report", json={"ticker": "AAPL"}).json()["data"]["result"];
        assert shared["accepted"] and shared["item"]["id"] != id;
        assert c.post("/function/list_reports", json={}).json()["data"]["result"]["remaining"] == 3;
    } finally { c.close(); }
}

test "new-report quota and cache-only mode still permit existing reports" {
    c = JacTestClient.from_file(APP, base_path=tempfile.mkdtemp());
    try {
        c.register_user("alice", "test-password-1");
        c.post("/function/set_admin", json={"on": True});
        c.post("/function/seed_report_catalog", json={});
        for ticker in ["AAPL", "MSFT", "NVDA"] {
            assert c.post("/function/request_report", json={"ticker": ticker}).json()["data"]["result"]["accepted"];
        }
        assert not c.post("/function/request_report", json={"ticker": "AMZN"}).json()["data"]["result"]["accepted"];
        assert not c.post("/function/request_report", json={"ticker": "INVALID"}).json()["data"]["result"]["accepted"];
        c.post("/function/make_cache_only", json={});
        cached = c.post("/function/request_report", json={"ticker": "brk.b"}).json()["data"]["result"];
        assert cached["accepted"] and cached["item"]["status"] == "ready";
    } finally { c.close(); }
}

test "a member with no keys is told to connect them, and can still read a cached report" {
    c = JacTestClient.from_file(APP, base_path=tempfile.mkdtemp());
    try {
        c.register_user("alice", "test-password-1");
        c.post("/function/set_admin", json={"on": False});
        c.post("/function/seed_report_catalog", json={});
        refused = c.post("/function/request_report", json={"ticker": "AAPL"}).json()["data"]["result"];
        assert not refused["accepted"];
        assert "Settings" in c.post("/function/list_reports", json={}).json()["data"]["result"]["message"];
        c.post("/function/make_cache_only", json={});
        assert c.post("/function/request_report", json={"ticker": "brk.b"}).json()["data"]["result"]["accepted"];
    } finally { c.close(); }
}
