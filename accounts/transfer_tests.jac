"""Moving a server's records: an export is read whole or refused, its class modules are renamed to
this server's, and the move replaces the graph and the accounts in one go while the scheduled jobs
are held off, only on a server that has not run."""
import base64;
import gzip;
import json;
import re;
import from pathlib { Path }
import from uuid { UUID }
import from jaclang { JacRuntime as Jac }
import jaclang.runtime.runtime as jac_runtime;
import from jaclang.data.store { PgStore }
import from accounts.transfer {
    JOBS,
    LEASE_OWNER,
    SUPER_ROOT,
    TransferError,
    carry_out,
    decode,
    forget_cached,
    hold_jobs,
    keep_part,
    part_problem,
    PART_CHARS,
    module_prefix,
    prepare,
    read_state,
    release_jobs,
    rename_module,
    status_of,
    take_parts
}

glob PROJECT_ROOT: Path = Path(__file__).resolve().parent.parent;
glob OLD: str = "_jac_app_0123456789abcdef.";
glob PORTFOLIO_ID: str = "11111111-1111-1111-1111-111111111111";
glob RUN_ID: str = "22222222-2222-2222-2222-222222222222";
glob RAN_ID: str = "33333333-3333-3333-3333-333333333333";
glob SCHEDULED: re.Pattern[str] = re.compile(r"@schedule\([^)]*\)\s*(?:async\s+)?def(?::\w+)?\s+(\w+)");

def node_props(id: str, module: str, archetype: dict[str, object]) -> dict[str, object] {
    return {"id": id, "root": SUPER_ROOT, "version": 3, "__type__": "NodeAnchor", "__module__": "jaclang.runtime.archetype", "persistent": True, "archetype": {**archetype, "__module__": module}};
}

"""An export of a small server: its root, a portfolio that ran once, and an admin and a user."""
def export_doc(module_prefix: str = OLD) -> dict[str, object] {
    graph_module = module_prefix + "models.graph";
    return {
        "format": "parallax-data",
        "version": 1,
        "exported_at": "2026-11-14T12:00:00-05:00",
        "anchors": [
            [SUPER_ROOT, "NodeAnchor", "Root", "jaclang.runtime.archetype", "fp-root", None, None, None, False, {"id": SUPER_ROOT, "archetype": {"__type__": "Root", "__module__": "jaclang.runtime.archetype"}}, 1, 7, 10],
            [PORTFOLIO_ID, "NodeAnchor", "Portfolio", graph_module, "fp-portfolio", SUPER_ROOT, None, None, False, node_props(PORTFOLIO_ID, graph_module, {"name": "team", "policy": {"__module__": module_prefix + "models.policy", "cash_floor": 0.1}}), 1, 2, 11],
            [RUN_ID, "NodeAnchor", "Run", graph_module, "fp-run", SUPER_ROOT, None, None, False, node_props(RUN_ID, graph_module, {"run_date": "2026-11-13"}), 1, 5, 12],
            [RAN_ID, "EdgeAnchor", "Ran", graph_module, "fp-ran", SUPER_ROOT, PORTFOLIO_ID, RUN_ID, False, {"id": RAN_ID, "archetype": {"__module__": graph_module}}, 1, 0, 13]
        ],
        "graph_types": [["Root", "Root"], ["Portfolio", "Portfolio"], ["Run", "Run"], ["Ran", "Ran"]],
        "identity_users": [
            ["u-admin", {"role": "admin", "root_id": "aaaaaaaa-0000-0000-0000-000000000000", "credentials": [{"type": "password", "password_hash": "old-server-hash"}], "requires_password_reset": True}],
            ["u-user", {"role": "user", "root_id": "bbbbbbbb-0000-0000-0000-000000000000"}]
        ],
        "identity_lookups": [["admin", "u-admin"], ["user@example.com", "u-user"]],
        "sso_lookups": []
    };
}

def upload(doc: dict[str, object], zipped: bool = True) -> str {
    raw = json.dumps(doc).encode();
    return base64.b64encode(gzip.compress(raw) if zipped else raw).decode();
}

def refusal(work: Callable[[], object]) -> str {
    try {
        work();
    } except TransferError as e {
        return str(e);
    }
    return "";
}

def own_store -> PgStore {
    current: any = Jac.get_context().mem.store;
    return PgStore(conninfo=current.conninfo);
}

test "an app module moves under this server's prefix, and the runtime's stays" {
    assert rename_module(OLD + "models.graph", "") == "models.graph";
    assert rename_module("models.graph", "_jac_app_fedcba9876543210.") == "_jac_app_fedcba9876543210.models.graph";
    assert rename_module(OLD + "models.users", OLD) == OLD + "models.users";
    assert rename_module("jaclang.runtime.archetype", "x.") == "jaclang.runtime.archetype";
    assert rename_module("research.collector", "") is None;
    assert rename_module("_jac_app_short.models.graph", "") is None;
}

test "a move renames every stored module, nested ones too, and counts the runs" {
    prefix = module_prefix();
    moved = prepare(decode(upload(export_doc())), prefix);
    assert moved.runs == 1;
    assert len(moved.anchors) == 4 and len(moved.users) == 2 and len(moved.lookups) == 2;
    portfolio = [a for a in moved.anchors if a["id"] == PORTFOLIO_ID][0];
    assert portfolio["arch_module"] == prefix + "models.graph";
    assert portfolio["props"]["archetype"]["__module__"] == prefix + "models.graph";
    assert portfolio["props"]["archetype"]["policy"]["__module__"] == prefix + "models.policy";
    assert portfolio["props"]["__module__"] == "jaclang.runtime.archetype";
    assert OLD not in json.dumps(moved.anchors);
}

test "an export is read gzipped or plain, and anything else is refused" {
    assert decode(upload(export_doc(), zipped=False))["format"] == "parallax-data";
    assert "did not arrive whole" in refusal(lambda { decode("not base64!"); });
    assert "not an export" in refusal(lambda { decode(base64.b64encode(b"hello").decode()); });
    assert "not an export" in refusal(lambda { decode(upload({"format": "other"})); });
    assert "version 2" in refusal(lambda { decode(upload({**export_doc(), "version": 2})); });
    assert "not a whole gzip" in refusal(lambda { decode(base64.b64encode(gzip.compress(b"{}")[:12]).decode()); });
}

test "a file that is not a whole server's records is refused" {
    prefix = module_prefix();
    doc = export_doc();
    stranger = [*doc["anchors"], ["44444444-4444-4444-4444-444444444444", "NodeAnchor", "Thing", "elsewhere.things", "", SUPER_ROOT, None, None, False, {}, 1, 0, 14]];
    assert "elsewhere.things" in refusal(lambda { prepare({**doc, "anchors": stranger}, prefix); });
    rootless = [a for a in doc["anchors"] if a[0] != SUPER_ROOT];
    assert "no server root" in refusal(lambda { prepare({**doc, "anchors": rootless}, prefix); });
    no_admin = [["u-user", {"role": "user"}]];
    assert "no admin" in refusal(lambda { prepare({**doc, "identity_users": no_admin}, prefix); });
    assert "shape" in refusal(lambda { prepare({**doc, "anchors": [[SUPER_ROOT]]}, prefix); });
}

test "the move holds every job main.jac schedules" {
    scheduled: set[str] = set();
    for path in PROJECT_ROOT.rglob("*.jac") {
        parts = set(path.relative_to(PROJECT_ROOT).parts);
        if parts & {".jac", "node_modules", "tests", "mobile", ".claude"} or path.name.endswith("_tests.jac") {
            continue;
        }
        scheduled.update(SCHEDULED.findall(path.read_text()));
    }
    assert scheduled == set(JOBS), f"scheduled {sorted(scheduled)} but held {sorted(JOBS)}";
    main = (PROJECT_ROOT / "main.jac").read_text();
    assert all(re.search(rf"\b{name}\b", main) for name in JOBS);
}

test "a move replaces the graph and the accounts, once, and lets the jobs go" {
    store = own_store();
    try {
        # This server's own admin, whose password its operator set.
        store.rows("CREATE TABLE IF NOT EXISTS identity_users (user_id text PRIMARY KEY, doc jsonb NOT NULL)", {});
        store.rows("CREATE TABLE IF NOT EXISTS identity_lookups (value_normalized text PRIMARY KEY, user_id text NOT NULL)", {});
        store.rows("INSERT INTO identity_users VALUES ('u-here', CAST(:d AS jsonb))", {"d": json.dumps({"role": "admin", "credentials": [{"type": "password", "password_hash": "this-server-hash"}], "requires_password_reset": False})});
        store.rows("INSERT INTO identity_lookups VALUES ('admin', 'u-here')", {});
        before = int(store.rows("SELECT coalesce(max(version), 0) FROM anchors", {})[0][0]);
        prefix = module_prefix();
        moved = prepare(decode(upload(export_doc())), prefix);
        carry_out(store.conninfo, moved, "2026-11-14T17:00:00+00:00", settle_s=0.0, wait_s=5.0);
        state = read_state(store);
        assert state["state"] == "done", state;
        assert "1 runs, 4 records, and 2 accounts" in state["message"];
        rows = store.rows("SELECT CAST(id AS text), arch_module, version, props FROM anchors ORDER BY seq", {});
        assert [r[0] for r in rows] == [SUPER_ROOT, PORTFOLIO_ID, RUN_ID, RAN_ID];
        assert all(r[1] in ("jaclang.runtime.archetype", prefix + "models.graph") for r in rows);
        props = rows[1][3] if isinstance(rows[1][3], dict) else json.loads(rows[1][3]);
        assert props["archetype"]["policy"]["__module__"] == prefix + "models.policy";
        # Every version is past what this server had, so a write from before the move conflicts.
        assert min(int(r[2]) for r in rows) > before;
        assert int(rows[2][2]) - int(rows[3][2]) == 5;
        ends = store.rows("SELECT CAST(src AS text), CAST(dst AS text) FROM anchors WHERE id = CAST(:i AS uuid)", {"i": RAN_ID});
        assert ends == [(PORTFOLIO_ID, RUN_ID)];
        users = store.rows("SELECT user_id, doc->>'role' FROM identity_users ORDER BY user_id", {});
        assert users == [("u-admin", "admin"), ("u-user", "user")];
        # The moved admin keeps its id and root, and signs in with this server's password.
        admin = store.rows("SELECT doc->'credentials'->0->>'password_hash', doc->>'requires_password_reset', doc->>'root_id' FROM identity_users WHERE user_id = 'u-admin'", {});
        assert admin == [("this-server-hash", "false", "aaaaaaaa-0000-0000-0000-000000000000")];
        assert store.rows("SELECT count(*) FROM identity_lookups", {})[0][0] == 2;
        assert store.rows("SELECT count(*) FROM kv_state WHERE key LIKE 'lease:%' AND value = :o", {"o": LEASE_OWNER})[0][0] == 0;
        status = status_of(store, True);
        assert status.runs == 1 and not status.ready and status.state == "done";

        carry_out(store.conninfo, moved, "2026-11-14T17:05:00+00:00", settle_s=0.0, wait_s=5.0);
        again = read_state(store);
        assert again["state"] == "failed" and "runs of its own" in again["message"], again;
        assert store.rows("SELECT count(*) FROM anchors", {})[0][0] == 4;
    } finally {
        store.close();
    }
}

test "a job that keeps its lease stops the move before anything changes" {
    store = own_store();
    try {
        assert store.kv_acquire_lease("sched:market_job", 60, "busy-worker");
        assert "kept running" in refusal(lambda { hold_jobs(store, wait_s=0.3, poll_s=0.1); });
        assert store.rows("SELECT count(*) FROM kv_state WHERE key LIKE 'lease:%' AND value = :o", {"o": LEASE_OWNER})[0][0] == 0;
        store.kv_release_lease("sched:market_job", "busy-worker");
        held = hold_jobs(store, wait_s=0.3, poll_s=0.1);
        assert sorted(held) == sorted("sched:" + name for name in JOBS);
        release_jobs(store, held);
    } finally {
        store.close();
    }
}

test "after a move the server looks up its shared root again" {
    saved = list(jac_runtime._shared_root_resolver);
    try {
        Jac.set_shared_root_resolver(lambda -> str | None { return "aaaaaaaa-0000-0000-0000-000000000000"; });
        assert Jac.shared_root_id() == UUID("aaaaaaaa-0000-0000-0000-000000000000");
        assert jac_runtime._shared_root_resolver[1] is not None;
        forget_cached();
        assert jac_runtime._shared_root_resolver[1] is None;
    } finally {
        jac_runtime._shared_root_resolver[0] = saved[0];
        jac_runtime._shared_root_resolver[1] = saved[1];
    }
}

test "an upload arrives in parts, is joined in order once, and refuses a missing part" {
    store = own_store();
    try {
        data = upload(export_doc());
        parts = [data[i:i + 100] for i in range(0, len(data), 100)];
        for (index, part) in enumerate(reversed(parts)) {
            keep_part(store, "upload-one", len(parts) - 1 - index, part);
        }
        assert take_parts(store, "upload-one", len(parts)) == data;
        assert "did not arrive whole" in refusal(lambda { take_parts(store, "upload-one", len(parts)); });
        keep_part(store, "upload-two", 0, parts[0]);
        assert "did not arrive whole" in refusal(lambda { take_parts(store, "upload-two", 2); });
        assert "did not arrive whole" in refusal(lambda { take_parts(store, "bad name!", 1); });
        assert part_problem("upload-one", 0, "x" * PART_CHARS) == "";
        assert "larger than the server takes" in part_problem("upload-one", 0, "x" * (PART_CHARS + 1));
        assert "no usable name" in part_problem("../x", 0, "x");
        assert "larger than a move" in part_problem("upload-one", 10 ** 6, "x");
    } finally {
        store.close();
    }
}
