"""The policy chat on a real server, with the model scripted through byLLM's real parser: a
message is answered in the background, a proposal changes nothing until it is applied, and the
limits on who may ask and how often hold."""
import json;
import os;
import tempfile;
import time;
import from pathlib { Path }
import from jaclang.testing.testing { JacTestClient }
import from accounts.vault { SECRET_ENV }
import from tests.fakes.providers { FakeProviders, GOOD_ALPACA, GOOD_OPENROUTER, GOOD_SECRET }

glob APP: str = str(Path(__file__).resolve().parent / "fixtures" / "policy_app.jac");
glob RULE: dict = {"kind": "add_rule", "effect": "avoid_buy", "label": "Too hot", "conditions": [{"metric": "score", "op": "lt", "number": 0.6}]};

def call(c: JacTestClient, name: str, body: dict = {}) -> any {
    return c.post(f"/function/{name}", json=body).json()["data"]["result"];
}

def answer(reply: str, edits: list[dict] = []) -> str {
    return json.dumps({"reply": reply, "edits": edits});
}

"""A client with an API key in the environment, so the assistant counts as available."""
def client -> JacTestClient {
    os.environ["OPENROUTER_API_KEY"] = "test-key";
    os.environ.pop("POLICY_CHAT_PER_USER_DAY", None);
    return JacTestClient.from_file(APP, base_path=tempfile.mkdtemp());
}

"""Sign up as the admin, who chats on the server's key."""
def admin(c: JacTestClient) {
    c.register_user("team-admin", "test-password-1");
    call(c, "set_admin", {"on": True});
}

"""The chat once nothing is pending."""
def settled(c: JacTestClient) -> any {
    deadline = time.monotonic() + 30.0;
    while time.monotonic() < deadline {
        state = call(c, "get_policy_chat");
        if not state["pending"] {
            return state;
        }
        time.sleep(0.05);
    }
    assert False;
    return {};
}

test "a question is answered in the background and changes nothing" {
    c = client();
    try {
        assert c.post("/function/get_policy_chat", json={}).status_code == 401;
        admin(c);
        call(c, "seed_policy_run");
        call(c, "script_assistant", {"outputs": [answer("AAPL's agreement of 0.45 is under your bar of 0.50.")]});
        sent = call(c, "send_policy_message", {"text": "  Why   not AAPL? "});
        # A quick answer may already be in this reply, so the question is the first turn, not the last.
        assert sent["turns"][0]["text"] == "Why not AAPL?" and sent["turns"][0]["role"] == "user";
        state = settled(c);
        assert [t["role"] for t in state["turns"]] == ["user", "assistant"];
        assert "0.45" in state["turns"][1]["text"] and state["turns"][1]["changes"] == [];
        assert state["remaining"] == 19 and state["daily_limit"] == 20;
        assert call(c, "get_my_policy")["version"] == 0;
    } finally { c.close(); }
}

test "a message whose transaction fails leaves no model call and no turn behind" {
    c = client();
    try {
        admin(c);
        call(c, "seed_policy_run");
        call(c, "script_assistant", {"outputs": [answer("The one answer.")]});
        started = call(c, "answers_started");
        assert c.post("/function/send_then_fail", json={"text": "Why not AAPL?"}).status_code == 500;
        assert call(c, "answers_started") == started;
        assert call(c, "get_policy_chat")["turns"] == [];
        call(c, "send_policy_message", {"text": "Why not AAPL?"});
        state = settled(c);
        assert [t["role"] for t in state["turns"]] == ["user", "assistant"] and state["turns"][1]["text"] == "The one answer.";
        assert call(c, "answers_started") == started;
    } finally { c.close(); }
}

test "an answer survives a transaction that fails while collecting it" {
    c = client();
    try {
        admin(c);
        call(c, "seed_policy_run");
        call(c, "script_assistant", {"outputs": [answer("Worth keeping.")]});
        call(c, "send_policy_message", {"text": "Why not AAPL?"});
        deadline = time.monotonic() + 30.0;
        while not call(c, "calls_finished") and time.monotonic() < deadline {
            time.sleep(0.05);
        }
        assert c.post("/function/collect_then_fail", json={}).status_code == 500;
        state = settled(c);
        assert [t["role"] for t in state["turns"]] == ["user", "assistant"] and state["turns"][1]["text"] == "Worth keeping.";
    } finally { c.close(); }
}

test "a proposal says what it would change, and saves only when applied" {
    c = client();
    try {
        admin(c);
        call(c, "seed_policy_run");
        call(c, "script_assistant", {"outputs": [answer("This blocks weak buys.", [RULE]), answer("A tighter bar.", [{"kind": "set", "setting": "buy_score", "value": 0.7}])]});
        call(c, "send_policy_message", {"text": "Avoid weak buys"});
        turn = settled(c)["turns"][-1];
        assert turn["status"] == "proposed" and any("R1" in x for x in turn["changes"]);
        assert turn["impact"][0] == "In the 2026-11-03 run:" and "MSFT: BUY would become NO_ACTION" in turn["impact"];
        assert call(c, "get_my_policy")["version"] == 0;

        applied = call(c, "apply_policy_proposal", {"turn_id": turn["id"]});
        assert applied["ok"] and applied["doc"]["version"] == 1 and applied["doc"]["policy"]["rules"][0]["id"] == "R1";
        assert applied["doc"]["history"][0]["source"] == "chat" and applied["doc"]["history"][0]["note"] == "Avoid weak buys";
        assert applied["chat"]["turns"][-1]["status"] == "applied" and applied["chat"]["turns"][-1]["applied_version"] == 1;
        assert not call(c, "apply_policy_proposal", {"turn_id": turn["id"]})["ok"];

        call(c, "send_policy_message", {"text": "Tighter"});
        second = settled(c)["turns"][-1];
        discarded = call(c, "discard_policy_proposal", {"turn_id": second["id"]});
        assert discarded["ok"] and discarded["chat"]["turns"][-1]["status"] == "discarded";
        assert call(c, "get_my_policy")["policy"]["buy_score"] == 0.2;
    } finally { c.close(); }
}

test "a proposal past a limit cannot be applied, and an old one goes stale" {
    c = client();
    try {
        admin(c);
        call(c, "script_assistant", {"outputs": [answer("A big position.", [{"kind": "set", "setting": "max_position_weight", "value": 0.5}]), answer("Stricter.", [{"kind": "set", "setting": "buy_score", "value": 0.4}])]});
        call(c, "send_policy_message", {"text": "Half my money in one stock"});
        over = settled(c)["turns"][-1];
        assert over["status"] == "invalid" and over["problems"] and over["changes"] == [];
        assert not call(c, "apply_policy_proposal", {"turn_id": over["id"]})["ok"];

        call(c, "send_policy_message", {"text": "Stricter"});
        open_one = settled(c)["turns"][-1];
        assert open_one["status"] == "proposed";
        space = call(c, "get_my_policy");
        moved = dict(space["policy"], buy_agreement=0.8);
        assert call(c, "save_policy_version", {"policy": moved, "base_version": 0})["saved"];
        assert settled(c)["turns"][-1]["status"] == "stale";
        refused = call(c, "apply_policy_proposal", {"turn_id": open_one["id"]});
        assert not refused["ok"];
        assert call(c, "get_my_policy")["policy"]["buy_score"] == 0.2;
    } finally { c.close(); }
}

test "a member chats on their own OpenRouter key, and a chat and its proposals are theirs alone" {
    c = client();
    fake = FakeProviders();
    base = fake.start();
    os.environ[SECRET_ENV] = "x" * 40;
    os.environ["ALPACA_BASE_URL"] = base;
    os.environ["OPENROUTER_API_BASE"] = base + "/api/v1";
    try {
        c.register_user("alice", "test-password-1");
        call(c, "set_admin", {"on": False});
        locked = call(c, "get_policy_chat");
        assert not locked["available"] and "Connect your OpenRouter key" in locked["note"];
        assert call(c, "send_policy_message", {"text": "Stricter"})["turns"] == [];

        assert call(c, "save_agent_keys", {"alpaca_key": GOOD_ALPACA, "alpaca_secret": GOOD_SECRET, "openrouter_key": GOOD_OPENROUTER})["saved"];
        call(c, "script_assistant", {"outputs": [answer("Stricter.", [{"kind": "set", "setting": "buy_score", "value": 0.4}])]});
        assert call(c, "get_policy_chat")["available"];
        call(c, "send_policy_message", {"text": "Stricter"});
        mine = settled(c)["turns"][-1];

        c.clear_auth();
        c.register_user("bob", "test-password-2");
        assert call(c, "get_policy_chat")["turns"] == [];
        assert not call(c, "apply_policy_proposal", {"turn_id": mine["id"]})["ok"];
        assert call(c, "get_my_policy")["version"] == 0;
    } finally {
        os.environ.pop("ALPACA_BASE_URL", None);
        os.environ.pop("OPENROUTER_API_BASE", None);
        fake.stop();
        c.close();
    }
}

test "the admin's proposals change the team agent's policy, on the server's key" {
    c = client();
    try {
        admin(c);
        call(c, "script_assistant", {"outputs": [answer("Stricter for all.", [{"kind": "set", "setting": "buy_score", "value": 0.5}])]});
        call(c, "send_policy_message", {"text": "Stricter for all"});
        turn = settled(c)["turns"][-1];
        assert call(c, "apply_policy_proposal", {"turn_id": turn["id"]})["ok"];
        doc = call(c, "get_my_policy");
        assert doc["scope"] == "team" and doc["policy"]["buy_score"] == 0.5;
    } finally { c.close(); }
}

test "the daily limit, the budget reserve, and a failed call each behave" {
    c = client();
    try {
        os.environ["POLICY_CHAT_PER_USER_DAY"] = "1";
        admin(c);
        # A failed call gives its place in the day's limit back and says nothing changed.
        call(c, "script_assistant", {"outputs": ["not json", "still not json"]});
        call(c, "send_policy_message", {"text": "Hello"});
        failed = settled(c);
        assert failed["turns"][-1]["status"] == "error" and "nothing changed" in failed["turns"][-1]["text"];
        assert failed["remaining"] == 1 and failed["available"];

        call(c, "script_assistant", {"outputs": [answer("Hi.")]});
        call(c, "send_policy_message", {"text": "Hello again"});
        used = settled(c);
        assert used["remaining"] == 0 and not used["available"] and "today's 1 messages" in used["note"];
        before = len(used["turns"]);
        assert len(call(c, "send_policy_message", {"text": "One more"})["turns"]) == before;

        os.environ["POLICY_CHAT_PER_USER_DAY"] = "20";
        call(c, "spend_requests", {"requests": 400});
        low = call(c, "get_policy_chat");
        assert not low["available"] and "held back" in low["note"];
        call(c, "spend_requests", {"requests": 0});

        os.environ["TRADING_AGENT_DISABLE_MODELS"] = "1";
        off = call(c, "get_policy_chat");
        assert not off["available"] and "off on this server" in off["note"];
    } finally {
        os.environ.pop("TRADING_AGENT_DISABLE_MODELS", None);
        os.environ.pop("POLICY_CHAT_PER_USER_DAY", None);
        c.close();
    }
}

test "an empty or overlong message is not sent" {
    c = client();
    try {
        admin(c);
        assert call(c, "send_policy_message", {"text": "   "})["turns"] == [];
        long = call(c, "send_policy_message", {"text": "x" * 600});
        assert long["turns"] == [] and "500 characters" in long["note"];
    } finally { c.close(); }
}
