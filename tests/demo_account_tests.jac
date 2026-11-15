"""The demo account (accounts/demo.jac): a visitor signs in with no password, browses made-up
history, and can change nothing, while every other user keeps their own agent."""
import os;
import tempfile;
import from pathlib { Path }
import from jaclang.testing.testing { JacTestClient }
import from accounts.vault { SECRET_ENV }

glob APP: str = str(Path(__file__).resolve().parent / "fixtures" / "demo_account_app.jac");
glob PASSWORD: str = "test-password-1";
glob TODAY: str = "2026-11-13";

with entry {
    os.environ[SECRET_ENV] = "x" * 40;
}

def server -> JacTestClient {
    return JacTestClient.from_file(APP, base_path=tempfile.mkdtemp());
}

def call(c: JacTestClient, name: str, body: dict[str, object] = {}) -> any {
    response = c.post("/function/" + name, json=body);
    assert response.ok, response.text;
    return response.json()["data"]["result"];
}

"""Make the demo user as the jobs would, a step a minute, and seed its history."""
def set_up_demo(c: JacTestClient) -> str {
    c.register_user("operator", PASSWORD);
    first = call(c, "demo_tick", {"today": TODAY, "seed": False});
    second = call(c, "demo_tick", {"today": TODAY});
    c.clear_auth();
    return first + second;
}

test "the demo account opens with no password, shows made-up history, and changes nothing" {
    c = server();
    try {
        assert call(c, "open_demo")["token"] == "";
        assert set_up_demo(c) == "";
        signed = call(c, "open_demo");
        assert signed["token"], signed;
        c.set_auth_token(signed["token"]);
        portfolio = call(c, "get_portfolio");
        assert portfolio["demo"] and portfolio["name"] == "demo" and portfolio["started"], portfolio;
        assert len(call(c, "list_runs")) > 0;
        assert call(c, "get_performance")["started"];
        settings = call(c, "get_agent_settings");
        assert settings["demo_account"] and not settings["managed"] and not settings["run"]["can_start"];
        policy = call(c, "get_my_policy");
        assert policy["read_only"];
        writes = [
            ("save_agent_keys", {"openrouter_key": "sk-or-v1-demo"}),
            ("remove_agent_keys", {"provider": "alpaca"}),
            ("set_paper_trading", {"on": True}),
            ("start_my_run", {}),
            ("set_asset_classes", {"classes": ["us_equity", "crypto"]}),
            ("save_policy_version", {"policy": dict(policy["policy"], buy_agreement=0.4), "base_version": policy["version"]}),
            ("request_report", {"ticker": "AAPL"})
        ];
        for (name, body) in writes {
            reply = call(c, name, body);
            assert "demo account" in str(reply), (name, reply);
        }
        chat = call(c, "send_policy_message", {"text": "Buy more when the specialists agree."});
        assert not chat["available"] and "demo account" in chat["note"] and chat["turns"] == [];
        assert call(c, "get_my_policy")["version"] == policy["version"];
        assert call(c, "own_root_nodes") == 0;
        assert call(c, "list_reports")["remaining"] == 0;
        c.clear_auth();
        c.register_user("member", PASSWORD);
        assert not call(c, "get_portfolio")["started"];
        assert not call(c, "get_agent_settings")["demo_account"];
        assert not call(c, "get_my_policy")["read_only"];
    } finally { c.close(); }
}

test "a user who signed up as demo before the server's demo account is never handed out" {
    c = server();
    try {
        c.register_user("demo", PASSWORD);
        c.clear_auth();
        assert "stays off" in set_up_demo(c);
        assert call(c, "open_demo")["token"] == "";
    } finally { c.close(); }
}
