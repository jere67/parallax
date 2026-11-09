"""One agent per user, through a real server: keys are checked before they are stored, never come
back, stay sealed, and work done for an owner stays private to them."""
import os;
import tempfile;
import time;
import from datetime { datetime, timedelta, timezone }
import from pathlib { Path }
import from jaclang.testing.testing { JacTestClient }
import from accounts.vault { SECRET_ENV }
import from tests.fakes.providers { FakeProviders, GOOD_ALPACA, GOOD_FINNHUB, GOOD_OPENROUTER, GOOD_SECRET, LIVE_ALPACA, SMALL_OPENROUTER }

glob APP: str = str(Path(__file__).resolve().parent / "fixtures" / "accounts_app.jac");
glob PASSWORD: str = "test-password-1";
glob FULL_KEYS: dict[str, str] = {"alpaca_key": GOOD_ALPACA, "alpaca_secret": GOOD_SECRET, "openrouter_key": GOOD_OPENROUTER};

glob fake: FakeProviders = FakeProviders();
glob BASE: str = fake.start();

with entry {
    os.environ[SECRET_ENV] = "x" * 40;
    os.environ["ALPACA_BASE_URL"] = BASE;
    os.environ["OPENROUTER_API_BASE"] = BASE + "/api/v1";
    os.environ["FINNHUB_BASE_URL"] = BASE + "/api/v1";
}

def server -> JacTestClient {
    return JacTestClient.from_file(APP, base_path=tempfile.mkdtemp());
}

def call(c: JacTestClient, name: str, body: dict[str, object] = {}) -> any {
    response = c.post("/function/" + name, json=body);
    assert response.ok, response.text;
    return response.json()["data"]["result"];
}

def named(settings: dict[str, object], name: str) -> dict[str, object] {
    return [k for k in settings["keys"] if k["name"] == name][0];
}

test "a new user sees nothing connected, and every key needs signing in" {
    c = server();
    try {
        assert c.post("/function/get_agent_settings", json={}).status_code == 401;
        c.register_user("new-user", PASSWORD);
        found = call(c, "get_agent_settings");
        assert not found["ready"] and not found["managed"] and found["can_store"];
        assert [k["connected"] for k in found["keys"]] == [False, False, False, False];
        assert [k["required"] for k in found["keys"]] == [True, True, True, False];
    } finally { c.close(); }
}

test "good keys are stored sealed, and only their hints ever come back" {
    c = server();
    try {
        c.register_user("owner", PASSWORD);
        reply = call(c, "save_agent_keys", {**FULL_KEYS, "finnhub_key": GOOD_FINNHUB});
        assert reply["saved"], reply;
        settings = reply["settings"];
        assert settings["ready"];
        assert named(settings, "ALPACA_API_KEY")["hint"] == "…0001";
        assert named(settings, "ALPACA_SECRET_KEY")["hint"] == "Paper account …7890";
        text = c.post("/function/get_agent_settings", json={}).text;
        for secret in [GOOD_ALPACA, GOOD_SECRET, GOOD_OPENROUTER, GOOD_FINNHUB] {
            assert secret not in text;
        }
        raw = call(c, "raw_account");
        assert all(v.startswith("v1.") for v in raw["sealed"].values());
        assert GOOD_SECRET not in str(raw["sealed"]);
    } finally { c.close(); }
}

test "a refused key stores nothing, and says what to fix" {
    c = server();
    try {
        c.register_user("owner", PASSWORD);
        reply = call(c, "save_agent_keys", {"alpaca_key": LIVE_ALPACA, "alpaca_secret": "wrong", "openrouter_key": GOOD_OPENROUTER});
        assert not reply["saved"];
        assert "paper" in reply["problems"]["alpaca"];
        assert call(c, "raw_account") == {};
        half = call(c, "save_agent_keys", {"alpaca_key": GOOD_ALPACA});
        assert "pair" in half["problems"]["alpaca"];
        router = call(c, "save_agent_keys", {"openrouter_key": "sk-or-bad"});
        assert "OpenRouter refused" in router["problems"]["openrouter"];
        finnhub = call(c, "save_agent_keys", {"finnhub_key": "bad"});
        assert "Finnhub refused" in finnhub["problems"]["finnhub"];
        spaced = call(c, "save_agent_keys", {"finnhub_key": "two words"});
        assert "does not look like" in spaced["message"];
    } finally { c.close(); }
}

test "a provider that is down is a reason to try again, not a wrong key" {
    c = server();
    fake.down = True;
    try {
        c.register_user("owner", PASSWORD);
        reply = call(c, "save_agent_keys", {"alpaca_key": GOOD_ALPACA, "alpaca_secret": GOOD_SECRET});
        assert "Try again" in reply["problems"]["alpaca"];
    } finally {
        fake.down = False;
        c.close();
    }
}

test "a key with a small allowance is accepted, and its owner hears what that means" {
    c = server();
    try {
        c.register_user("owner", PASSWORD);
        reply = call(c, "save_agent_keys", {"openrouter_key": SMALL_OPENROUTER});
        assert reply["saved"];
        assert "$10" in reply["settings"]["requests_note"];
    } finally { c.close(); }
}

test "with no server secret, no key is stored and the page says so" {
    c = server();
    saved = os.environ.pop(SECRET_ENV);
    try {
        c.register_user("owner", PASSWORD);
        assert not call(c, "get_agent_settings")["can_store"];
        reply = call(c, "save_agent_keys", FULL_KEYS);
        assert not reply["saved"] and SECRET_ENV in reply["message"];
    } finally {
        os.environ[SECRET_ENV] = saved;
        c.close();
    }
}

test "keys saved under another secret show as not connected, rather than failing the page" {
    c = server();
    try {
        c.register_user("owner", PASSWORD);
        assert call(c, "save_agent_keys", FULL_KEYS)["saved"];
        os.environ[SECRET_ENV] = "y" * 40;
        found = call(c, "get_agent_settings");
        assert not found["ready"] and not named(found, "ALPACA_API_KEY")["connected"];
    } finally {
        os.environ[SECRET_ENV] = "x" * 40;
        c.close();
    }
}

test "disconnecting a required key stops the agent and its paper trading" {
    c = server();
    try {
        c.register_user("owner", PASSWORD);
        call(c, "save_agent_keys", FULL_KEYS);
        assert call(c, "set_paper_trading", {"on": True})["ok"];
        reply = call(c, "remove_agent_keys", {"provider": "alpaca"});
        assert reply["ok"] and not reply["settings"]["ready"] and not reply["settings"]["paper_trading"];
        assert not named(reply["settings"], "ALPACA_API_KEY")["connected"];
        assert GOOD_SECRET not in str(call(c, "raw_account"));
        assert not call(c, "remove_agent_keys", {"provider": "nonsense"})["ok"];
    } finally { c.close(); }
}

test "paper trading starts off, is the owner's choice, and needs an empty paper account" {
    c = server();
    try {
        c.register_user("owner", PASSWORD);
        refused = call(c, "set_paper_trading", {"on": True});
        assert not refused["ok"] and "Connect" in refused["message"];
        settings = call(c, "save_agent_keys", FULL_KEYS)["settings"];
        assert not settings["paper_trading"];
        fake.positions = [{"symbol": "AAPL", "qty": "3", "avg_entry_price": "100", "market_value": "300", "current_price": "100", "side": "long"}];
        held = call(c, "set_paper_trading", {"on": True});
        fake.positions = [];
        assert not held["ok"] and "empty" in held["message"], held;
        on = call(c, "set_paper_trading", {"on": True});
        assert on["ok"] and on["settings"]["paper_trading"];
        off = call(c, "set_paper_trading", {"on": False});
        assert off["ok"] and not off["settings"]["paper_trading"];
    } finally {
        fake.positions = [];
        c.close();
    }
}

test "the admin's agent runs on the server's keys, which this page does not change" {
    c = server();
    try {
        c.register_user("admin-like", PASSWORD);
        call(c, "set_admin", {"on": True});
        found = call(c, "get_agent_settings");
        assert found["managed"] and found["ready"];
        reply = call(c, "save_agent_keys", FULL_KEYS);
        assert not reply["saved"] and "server" in reply["message"];
        assert not call(c, "set_paper_trading", {"on": True})["ok"];
    } finally {
        call(c, "set_admin", {"on": False});
        c.close();
    }
}

test "a server at its limit refuses a new agent, and an existing one keeps working" {
    c = server();
    os.environ["PARALLAX_MAX_AGENTS"] = "1";
    try {
        c.register_user("first", PASSWORD);
        assert call(c, "save_agent_keys", FULL_KEYS)["saved"];
        assert call(c, "save_agent_keys", {"finnhub_key": GOOD_FINNHUB})["saved"];
        c.clear_auth();
        c.register_user("second", PASSWORD);
        assert call(c, "get_agent_settings")["full"];
        reply = call(c, "save_agent_keys", FULL_KEYS);
        assert not reply["saved"] and "limit" in reply["message"];
    } finally {
        os.environ.pop("PARALLAX_MAX_AGENTS");
        c.close();
    }
}

test "one user's account is invisible to another, and a job sees them all" {
    c = server();
    try {
        c.register_user("first", PASSWORD);
        call(c, "save_agent_keys", FULL_KEYS);
        first = call(c, "owner_id");
        c.clear_auth();
        c.register_user("second", PASSWORD);
        call(c, "save_agent_keys", FULL_KEYS);
        second = call(c, "owner_id");
        assert call(c, "accounts_seen") == [second];
        seen = call(c, "job_work_as_owners");
        assert {s["owner"] for s in seen} == {first, second};
    } finally { c.close(); }
}

test "a job's work for an owner uses their root and keys, and only they can see what it wrote" {
    c = server();
    try {
        c.register_user("first", PASSWORD);
        call(c, "save_agent_keys", FULL_KEYS);
        c.clear_auth();
        c.register_user("second", PASSWORD);
        seen = call(c, "job_work_as_owners");
        assert len(seen) == 1;
        assert seen[0]["root"] == seen[0]["owner"];
        assert seen[0]["alpaca"] == GOOD_ALPACA;
        assert call(c, "my_run_days") == [];
        c.clear_auth();
        c.login("first", PASSWORD);
        assert call(c, "my_run_days") == ["2026-11-09"];
    } finally { c.close(); }
}

test "a member's report runs on that member's keys, not another member's or the server's" {
    c = server();
    try {
        c.register_user("first", PASSWORD);
        call(c, "save_agent_keys", FULL_KEYS);
        c.clear_auth();
        c.register_user("second", PASSWORD);
        call(c, "save_agent_keys", {**FULL_KEYS, "openrouter_key": SMALL_OPENROUTER});
        call(c, "open_reports");
        assert call(c, "request_report", {"ticker": "AAPL"})["accepted"];
        seen: list[str] = [];
        for _ in range(40) {
            seen = call(c, "report_job_pass");
            if seen { break; }
            time.sleep(0.1);
        }
        assert seen == [SMALL_OPENROUTER];
    } finally { c.close(); }
}

test "asking for a run marks only today, and an agent without keys is never due" {
    c = server();
    try {
        c.register_user("owner", PASSWORD);
        refused = call(c, "start_my_run");
        assert not refused["ok"] and "Connect" in refused["message"];
        call(c, "save_agent_keys", FULL_KEYS);
        # 10:00 New York on a Monday is past the morning window, so only a request makes it due.
        (day, now) = ("2026-11-09", "2026-11-09T15:00:00+00:00");
        assert call(c, "job_due_days", {"day": day, "iso_now": now}) == [];
        # Anywhere from 7:30 to 9:15 New York is the window, so it is due with no request.
        assert len(call(c, "job_due_days", {"day": day, "iso_now": "2026-11-09T12:35:00+00:00"})) == 1;
        assert len(call(c, "job_due_days", {"day": day, "iso_now": "2026-11-09T14:14:00+00:00"})) == 1;
        assert call(c, "job_due_days", {"day": day, "iso_now": "2026-11-09T14:15:00+00:00"}) == [];
        assert call(c, "job_due_days", {"day": day, "iso_now": "2026-11-09T12:29:00+00:00"}) == [];
    } finally { c.close(); }
}

"""10:00 a.m. New York on the next weekday at least a day ahead, in UTC, as a job would see it."""
def next_morning -> str {
    day = datetime.now(timezone.utc) + timedelta(days=1);
    while day.weekday() >= 5 {
        day += timedelta(days=1);
    }
    return day.replace(hour=15, minute=0, second=0, microsecond=0).isoformat();
}

test "an owner's choice reaches their agent at the next tick, on their keys alone" {
    c = server();
    os.environ["ALPACA_API_KEY"] = "SERVER-KEY-NEVER-USED";
    os.environ["ALPACA_SECRET_KEY"] = "SERVER-SECRET-NEVER-USED";
    try {
        c.register_user("owner", PASSWORD);
        call(c, "save_agent_keys", FULL_KEYS);
        now = next_morning();
        call(c, "job_tick", {"iso_now": now});
        assert call(c, "my_portfolio_state") == {"mode": "insight", "cash": 0.0, "baselines": 0};
        assert call(c, "set_paper_trading", {"on": True})["ok"];
        fake.alpaca_seen = [];
        call(c, "job_tick", {"iso_now": now});
        started = call(c, "my_portfolio_state");
        assert started == {"mode": "auto", "cash": 100000.0, "baselines": 2}, started;
        assert set(fake.alpaca_seen) == {GOOD_ALPACA};
        assert call(c, "get_agent_settings")["trading_started"];
        assert call(c, "set_paper_trading", {"on": False})["ok"];
        call(c, "job_tick", {"iso_now": now});
        assert call(c, "my_portfolio_state")["mode"] == "insight";
    } finally {
        os.environ.pop("ALPACA_API_KEY");
        os.environ.pop("ALPACA_SECRET_KEY");
        c.close();
    }
}

test "an agent with no keys left does not trade, and a job never fails over it" {
    c = server();
    try {
        c.register_user("owner", PASSWORD);
        call(c, "save_agent_keys", FULL_KEYS);
        call(c, "set_paper_trading", {"on": True});
        call(c, "remove_agent_keys", {"provider": "alpaca"});
        fake.alpaca_seen = [];
        call(c, "job_tick", {"iso_now": next_morning()});
        assert fake.alpaca_seen == [];
    } finally { c.close(); }
}
