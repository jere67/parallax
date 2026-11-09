"""The policy endpoints on a real server: whose policy each account sees, optimistic concurrency,
hard limits the client cannot loosen, and replay."""
import tempfile;
import from pathlib { Path }
import from jaclang.testing.testing { JacTestClient }

glob APP: str = str(Path(__file__).resolve().parent / "fixtures" / "policy_app.jac");

def call(c: JacTestClient, name: str, body: dict = {}) -> any {
    return c.post(f"/function/{name}", json=body).json()["data"]["result"];
}

test "every policy endpoint takes an account" {
    c = JacTestClient.from_file(APP, base_path=tempfile.mkdtemp());
    try {
        for (name, body) in [
            ("get_policy_catalog", {}),
            ("get_my_policy", {}),
            ("preview_policy", {"policy": {}}),
            ("save_policy_version", {"policy": {}, "base_version": 0}),
            ("restore_policy_version", {"version": 0, "base_version": 0})
        ] {
            assert c.post(f"/function/{name}", json=body).status_code == 401, name;
        }
    } finally { c.close(); }
}

test "a new account starts from the defaults, and can try a draft with no run yet" {
    c = JacTestClient.from_file(APP, base_path=tempfile.mkdtemp());
    try {
        c.register_user("alice", "test-password-1");
        assert call(c, "set_admin", {"on": False}) == "ok";
        catalog = call(c, "get_policy_catalog");
        assert catalog["defaults"]["buy_score"] == 0.2 and catalog["max_rules"] == 20;
        assert any(k["name"] == "max_position_weight" and k["high"] == 0.15 for k in catalog["knobs"]);
        assert any(m["name"] == "rsi_14" for m in catalog["metrics"]);
        mine = call(c, "get_my_policy");
        assert mine["version"] == 0 and mine["history"] == [] and mine["sentences"];
        # No run yet: an empty replay, not an error.
        assert call(c, "preview_policy", {"policy": dict(mine["policy"], buy_agreement=0.4)})["rows"] == [];
    } finally { c.close(); }
}

test "a draft replays the agent's own run without saving anything" {
    c = JacTestClient.from_file(APP, base_path=tempfile.mkdtemp());
    try {
        c.register_user("team-admin", "test-password-1");
        assert call(c, "set_admin", {"on": True}) == "ok";
        assert call(c, "seed_policy_run") == "ok";
        draft = dict(call(c, "get_my_policy")["policy"], buy_agreement=0.4);
        view = call(c, "preview_policy", {"policy": draft});
        assert view["run_date"] == "2026-11-03" and view["differs"] == 1;
        changed = [r for r in view["rows"] if r["changed"]][0];
        assert changed["ticker"] == "AAPL" and changed["action"] == "BUY" and changed["run_action"] == "NO_ACTION" and changed["unreviewed"];
        too_big = dict(draft, max_position_weight=0.5);
        refused = call(c, "preview_policy", {"policy": too_big});
        assert refused["problems"] and refused["rows"] == [];
        assert call(c, "get_my_policy")["version"] == 0;

        # Another account has no run of its own, so it replays nothing of the team's.
        c.clear_auth();
        c.register_user("bob", "test-password-2");
        assert call(c, "set_admin", {"on": False}) == "ok";
        assert call(c, "preview_policy", {"policy": draft})["rows"] == [];
    } finally { c.close(); }
}

test "a policy is its owner's, versioned, and checked; a stale save is refused" {
    c = JacTestClient.from_file(APP, base_path=tempfile.mkdtemp());
    try {
        c.register_user("alice", "test-password-1");
        assert call(c, "set_admin", {"on": False}) == "ok";
        doc = call(c, "get_my_policy");
        assert doc["version"] == 0;
        mine = dict(doc["policy"], buy_score=0.5);
        saved = call(c, "save_policy_version", {"policy": mine, "base_version": 0, "note": "Stricter"});
        assert saved["saved"] and saved["version"] == 1 and saved["doc"]["history"][0]["note"] == "Stricter";
        stale = call(c, "save_policy_version", {"policy": dict(mine, buy_score=0.6), "base_version": 0});
        assert not stale["saved"] and "changed since" in stale["message"];
        over = call(c, "save_policy_version", {"policy": dict(mine, gross_limit=2.0), "base_version": 1});
        assert not over["saved"] and over["problems"];
        restored = call(c, "restore_policy_version", {"version": 0, "base_version": 1});
        assert restored["saved"] and restored["version"] == 2 and restored["doc"]["policy"]["buy_score"] == 0.2;
        assert restored["doc"]["history"][0]["source"] == "restore";
        again = call(c, "restore_policy_version", {"version": 1, "base_version": 2});
        assert again["saved"] and again["doc"]["policy"]["buy_score"] == 0.5;
        # Nobody else sees it.
        c.clear_auth();
        c.register_user("bob", "test-password-2");
        assert call(c, "get_my_policy")["version"] == 0;
    } finally { c.close(); }
}

test "the admin's policy is the team agent's, and no other account's save reaches it" {
    c = JacTestClient.from_file(APP, base_path=tempfile.mkdtemp());
    try {
        c.register_user("team-admin", "test-password-1");
        assert call(c, "set_admin", {"on": True}) == "ok";
        draft = dict(call(c, "get_my_policy")["policy"], buy_score=0.3);
        saved = call(c, "save_policy_version", {"policy": draft, "base_version": 0, "note": "Higher bar"});
        assert saved["saved"] and saved["version"] == 1 and saved["doc"]["scope"] == "team";
        assert any("0.2" in change and "0.3" in change for change in saved["changes"]);
        assert saved["doc"]["history"][0]["note"] == "Higher bar";

        c.clear_auth();
        c.register_user("member", "test-password-2");
        assert call(c, "set_admin", {"on": False}) == "ok";
        theirs = call(c, "get_my_policy");
        assert theirs["scope"] == "personal" and theirs["version"] == 0 and theirs["policy"]["buy_score"] == 0.2;
        assert call(c, "save_policy_version", {"policy": dict(theirs["policy"], buy_score=0.9), "base_version": 0})["saved"];

        c.clear_auth();
        c.login("team-admin", "test-password-1");
        assert call(c, "set_admin", {"on": True}) == "ok";
        assert call(c, "get_my_policy")["policy"]["buy_score"] == 0.3;
    } finally { c.close(); }
}
