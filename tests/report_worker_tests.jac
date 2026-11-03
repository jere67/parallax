import tempfile;
import time;
import from pathlib { Path }
import from jaclang.testing.testing { JacTestClient }

glob APP: str = str(Path(__file__).resolve().parent / "fixtures" / "report_worker_app.jac");

test "queued report becomes a persisted insight with votes and sources but no orders" {
    c = JacTestClient.from_file(APP, base_path=tempfile.mkdtemp());
    try {
        c.register_user("reporter", "test-password-1");
        assert c.post("/function/setup_worker", json={}).ok;
        reply = c.post("/function/request_report", json={"ticker": "AAPL"}).json()["data"]["result"];
        id = reply["item"]["id"];
        assert reply["item"]["status"] == "pending";
        assert c.post("/function/tick_worker", json={}).ok;
        view = c.post("/function/get_report", json={"request_id": id}).json()["data"]["result"];
        assert view["status"] == "running";
        for _ in range(40) {
            time.sleep(0.1);
            response = c.post("/function/tick_worker", json={});
            assert response.ok, response.text;
            view = c.post("/function/get_report", json={"request_id": id}).json()["data"]["result"];
            if view["status"] != "running" { break; }
        }
        assert view["status"] == "ready", view;
        assert view["card"]["mode"] == "insight";
        assert len(view["card"]["specialists"]) == 5;
        assert view["card"]["sources"] and view["card"]["thesis"];
        assert c.post("/function/order_count", json={}).json()["data"]["result"] == 0;
    } finally { c.close(); }
}

test "interrupted work expires without being rerun or exposing provider details" {
    c = JacTestClient.from_file(APP, base_path=tempfile.mkdtemp());
    try {
        c.register_user("reporter", "test-password-1");
        c.post("/function/setup_worker", json={});
        c.post("/function/abandoned_job", json={});
        reply = c.post("/function/request_report", json={"ticker": "FAIL"}).json()["data"]["result"];
        c.post("/function/tick_worker", json={});
        view = c.post("/function/get_report", json={"request_id": reply["item"]["id"]}).json()["data"]["result"];
        assert view["status"] == "failed";
        assert "time limit" in view["error"];
        assert c.post("/function/order_count", json={}).json()["data"]["result"] == 0;
    } finally { c.close(); }
}
