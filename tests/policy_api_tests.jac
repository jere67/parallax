"""The policy endpoints on a real server: who may read and save what, optimistic concurrency,
hard limits the client cannot loosen, and replay."""
import tempfile;
import from pathlib { Path }
import from jaclang.testing.testing { JacTestClient }

glob APP: str = str(Path(__file__).resolve().parent / "fixtures" / "policy_app.jac");

def call(c: JacTestClient, name: str, body: dict = {}) -> any {
    return c.post(f"/function/{name}", json=body).json()["data"]["result"];
}

test "anyone can read the team policy and catalog and try a draft; saving takes an account" {
    c = JacTestClient.from_file(APP, base_path=tempfile.mkdtemp());
    try {
        catalog = call(c, "get_policy_catalog");
        assert catalog["defaults"]["buy_score"] == 0.2 and catalog["max_rules"] == 20;
        assert any(k["name"] == "max_position_weight" and k["high"] == 0.15 for k in catalog["knobs"]);
        assert any(m["name"] == "rsi_14" for m in catalog["metrics"]);
        team = call(c, "get_team_policy");
        assert team["version"] == 0 and team["history"] == [] and team["sentences"];
        draft = dict(team["policy"], buy_agreement=0.4);
        # No team portfolio yet: an empty replay, not an error.
        assert call(c, "preview_policy", {"policy": draft})["rows"] == [];
        assert c.post("/function/get_policy_workspace", json={}).status_code == 401;
        assert c.post("/function/save_policy_version", json={"scope": "personal", "policy": draft, "base_version": 0}).status_code == 401;
    } finally { c.close(); }
}

test "a draft replays the team's run without saving anything" {
    c = JacTestClient.from_file(APP, base_path=tempfile.mkdtemp());
    try {
        c.register_user("alice", "test-password-1");
        assert call(c, "seed_policy_run") == "ok";
        c.clear_auth();
        draft = dict(call(c, "get_team_policy")["policy"], buy_agreement=0.4);
        view = call(c, "preview_policy", {"policy": draft});
        assert view["run_date"] == "2026-11-03" and view["differs"] == 1;
        changed = [r for r in view["rows"] if r["changed"]][0];
        assert changed["ticker"] == "AAPL" and changed["action"] == "BUY" and changed["team_action"] == "NO_ACTION" and changed["unreviewed"];
        too_big = dict(draft, max_position_weight=0.5);
        refused = call(c, "preview_policy", {"policy": too_big});
        assert refused["problems"] and refused["rows"] == [];
        assert call(c, "get_team_policy")["version"] == 0;
    } finally { c.close(); }
}

test "a personal policy is private, versioned, and checked; a stale save is refused" {
    c = JacTestClient.from_file(APP, base_path=tempfile.mkdtemp());
    try {
        c.register_user("alice", "test-password-1");
        space = call(c, "get_policy_workspace");
        assert space["mine"]["version"] == 0 and not space["can_edit_team"];
        mine = dict(space["mine"]["policy"], buy_score=0.5);
        saved = call(c, "save_policy_version", {"scope": "personal", "policy": mine, "base_version": 0, "note": "Stricter"});
        assert saved["saved"] and saved["version"] == 1 and saved["doc"]["history"][0]["note"] == "Stricter";
        stale = call(c, "save_policy_version", {"scope": "personal", "policy": dict(mine, buy_score=0.6), "base_version": 0});
        assert not stale["saved"] and "changed since" in stale["message"];
        over = call(c, "save_policy_version", {"scope": "personal", "policy": dict(mine, gross_limit=2.0), "base_version": 1});
        assert not over["saved"] and over["problems"];
        restored = call(c, "restore_policy_version", {"scope": "personal", "version": 0, "base_version": 1});
        assert restored["saved"] and restored["version"] == 2 and restored["doc"]["policy"]["buy_score"] == 0.2;
        assert restored["doc"]["history"][0]["source"] == "restore";
        again = call(c, "restore_policy_version", {"scope": "personal", "version": 1, "base_version": 2});
        assert again["saved"] and again["doc"]["policy"]["buy_score"] == 0.5;
        # Nobody else sees it, and the team's policy did not move.
        c.clear_auth();
        c.register_user("bob", "test-password-2");
        other = call(c, "get_policy_workspace");
        assert other["mine"]["version"] == 0 and other["team"]["version"] == 0;
    } finally { c.close(); }
}

test "only the admin saves the team policy, and everyone then reads it" {
    c = JacTestClient.from_file(APP, base_path=tempfile.mkdtemp());
    try {
        c.register_user("member", "test-password-1");
        assert call(c, "set_admin", {"on": False}) == "ok";
        draft = dict(call(c, "get_team_policy")["policy"], buy_score=0.3);
        refused = call(c, "save_policy_version", {"scope": "team", "policy": draft, "base_version": 0});
        assert not refused["saved"] and refused["message"] == "Only the admin can change the team policy.";
        assert not call(c, "restore_policy_version", {"scope": "team", "version": 0, "base_version": 0})["saved"];
        assert not call(c, "save_policy_version", {"scope": "everyone", "policy": draft, "base_version": 0})["saved"];
        assert call(c, "get_team_policy")["version"] == 0;

        assert call(c, "set_admin", {"on": True}) == "ok";
        assert call(c, "get_policy_workspace")["can_edit_team"];
        saved = call(c, "save_policy_version", {"scope": "team", "policy": draft, "base_version": 0, "note": "Higher bar"});
        assert saved["saved"] and saved["version"] == 1;
        assert any("0.2" in change and "0.3" in change for change in saved["changes"]);

        c.clear_auth();
        team = call(c, "get_team_policy");
        assert team["version"] == 1 and team["policy"]["buy_score"] == 0.3;
        assert team["history"][0]["author"] == "Team admin" and team["history"][0]["note"] == "Higher bar";
    } finally {
        c.close();
    }
}
