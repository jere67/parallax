"""Moving a server's records to a new server (site/guide/deploy.md, "Bring your records along").

A server keeps everything in its Postgres database: the graph (`anchors`, `graph_types`) and the
sign-in accounts (`identity_users`, `identity_lookups`, `sso_lookups`). `scripts/export-data.sh`
reads all of them from the old server's database into one file, and an admin uploads that file on
the new server's settings page. The new server then replaces its own graph and accounts with the
file's in one transaction, so a move either lands whole or changes nothing.

Two things differ between servers and are rewritten on the way in:
- a stored object names its class's module, which a built app prefixes with a digest of its
  folder (`_jac_app_<digest>.models.graph`). Each is renamed to this server's prefix, or every row
  would load as an unknown type.
- each row's `version` is raised past this server's highest. A job that read the old graph before
  the move then fails its write, instead of writing the old graph's rows over the new one.

Only a server that has never run takes a move, so nothing a server did itself is lost: a fresh
deployment, before its first morning. While the move runs it holds every scheduled job's lease,
so no job starts on a graph about to be replaced. The sign-in accounts move with the graph, so
afterwards everyone signs in with their accounts from the old server.
"""
import base64;
import binascii;
import gzip;
import json;
import logging;
import re;
import threading;
import time;
import uuid;
import zlib;
import from datetime { datetime, timezone }
import from zoneinfo { ZoneInfo }
import from jaclang { JacRuntime as Jac }
import jaclang.runtime.runtime as jac_runtime;
import from jaclang.data.store { ConnInfo, PgStore, TxnIsolation }
import accounts.sharing as sharing;
import accounts.store as accounts_store;
import dashboard.api as dashboard_api;
import from accounts.store { DEMO_PORTFOLIO, caller_is_admin }
import from dashboard.cache { VIEWS }
import from models.accounts { ExportPart, ExportReady, TransferStatus }
import from models.graph { Portfolio }

glob LOG: logging.Logger = logging.getLogger("trading_agent.transfer");
glob FORMAT: str = "parallax-data";
glob FORMAT_VERSION: int = 1;
# Where the latest move's state is kept, so every worker and a later page load see it.
glob STATE_KEY: str = "parallax:transfer";
glob LEASE_OWNER: str = "parallax-transfer";
# Long enough to cover a move; the leases are released as soon as it ends.
glob LEASE_TTL_S: int = 600;
# A job holds its lease for 45 seconds from when it fires, so every lease is free within a minute.
glob LEASE_WAIT_S: float = 120.0;
glob LEASE_POLL_S: float = 2.0;
# Once no job can start, the time a job that fired just before is given to finish.
glob SETTLE_S: float = 20.0;
glob ATTEMPTS: int = 3;
glob CHUNK: int = 1000;
# A move that has said nothing for this long died with its process.
glob STALE_S: float = 1800.0;
glob MAX_UPLOAD_CHARS: int = 80000000;
# JacHammer's proxy answers 502 to a request body over 1 MiB, so the file goes up in parts of at
# most this many base64 characters, kept in kv_state until the move starts or they expire.
glob PART_CHARS: int = 524288;
glob MAX_PARTS: int = MAX_UPLOAD_CHARS // PART_CHARS + 1;
glob PART_PREFIX: str = "parallax:transfer-part:";
glob PART_TTL_S: int = 3600;
glob UPLOAD_ID: re.Pattern[str] = re.compile(r"^[A-Za-z0-9-]{8,64}$");
glob EXPORT_PREFIX: str = "parallax:transfer-export:";
# The query `scripts/export-data.sh` runs, kept word for word in `scripts/export-data.sql`
# (transfer_tests.jac checks the two match). One statement, so it reads one snapshot.
glob EXPORT_SQL: str = """-- One JSON document with a server's whole record, read by scripts/export-data.sh and taken by
-- accounts/transfer.jac. One statement, so every table is read from the same snapshot.
SELECT json_build_object(
    'format', 'parallax-data',
    'version', 1,
    'exported_at', now(),
    'anchors', (
        SELECT coalesce(json_agg(json_build_array(
            id, kind, arch_type, arch_module, fingerprint, root_id, src, dst, undirected, props,
            format_version, version, seq) ORDER BY seq), '[]')
        FROM anchors),
    'graph_types', (
        SELECT coalesce(json_agg(json_build_array(type_name, ancestor)), '[]') FROM graph_types),
    'identity_users', (
        SELECT coalesce(json_agg(json_build_array(user_id, doc)), '[]') FROM identity_users),
    'identity_lookups', (
        SELECT coalesce(json_agg(json_build_array(value_normalized, user_id)), '[]')
        FROM identity_lookups),
    'sso_lookups', (
        SELECT coalesce(json_agg(json_build_array(provider, external_id, user_id)), '[]')
        FROM sso_lookups)
)""";
glob SUPER_ROOT: str = "00000000-0000-0000-0000-000000000000";
glob ANCHOR_FIELDS: list[str] = ["id", "kind", "arch_type", "arch_module", "fingerprint", "root_id", "src", "dst", "undirected", "props", "format_version", "version", "seq"];
# A stored class's module: the app's own (models/...), with or without a built app's prefix.
glob APP_MODULE: re.Pattern[str] = re.compile(r"^(?:_jac_app_[0-9a-f]{16}\.)?(models\..+)$");
glob RUNTIME_MODULE: str = "jaclang.";
# The admin account the runtime makes at start ([scale.admin] in jac.toml), whose password this
# server's operator set: the moved admin signs in with it, not with the old server's.
glob ADMIN_NAME: str = "admin";
# Every scheduled job main.jac serves (transfer_tests.jac keeps this list in step with it).
glob JOBS: list[str] = [
    "reports_job",
    "morning_job",
    "trading_job",
    "lost_run_job",
    "manual_run_job",
    "agent_run_slot_1",
    "agent_run_slot_2",
    "agent_run_slot_3",
    "agents_trading_job",
    "demo_job",
    "demo_account_job",
    "demo_history_job",
    "refresh_job",
    "news_refresh_job",
    "market_job"
];

glob _LOCK: threading.Lock = threading.Lock();

"""What a move file holds, ready to write: rows by table, with this server's module names."""
obj Moved {
    has anchors: list[dict[str, object]],
        graph_types: list[dict[str, str]],
        users: list[dict[str, object]],
        lookups: list[dict[str, str]],
        sso: list[dict[str, str]],
        runs: int,
        exported_at: str;
}

class TransferError(Exception) {}

"""This server's prefix for the app's modules: "" when it runs from source, or the built app's
`_jac_app_<digest>.`."""
def module_prefix -> str {
    name = Portfolio.__module__;
    tail = "models.graph";
    if not name.endswith(tail) {
        raise TransferError(f"this server stores its classes under {name}, which this move does not know");
    }
    return name[:len(name) - len(tail)];
}

"""`name` under `prefix`, or None when it is neither the app's module nor the runtime's."""
def rename_module(name: str, prefix: str) -> str | None {
    if name.startswith(RUNTIME_MODULE) {
        return name;
    }
    found = APP_MODULE.match(name);
    if found is None {
        return None;
    }
    return prefix + found.group(1);
}

"""`value` with every `__module__` in it renamed under `prefix`. A module that is neither the
app's nor the runtime's is added to `unknown`."""
def rename_modules(value: object, prefix: str, unknown: set[str]) -> object {
    if isinstance(value, dict) {
        out: dict[str, object] = {};
        for (key, item) in value.items() {
            if key == "__module__" and isinstance(item, str) {
                renamed = rename_module(item, prefix);
                if renamed is None {
                    unknown.add(item);
                    out[key] = item;
                } else {
                    out[key] = renamed;
                }
            } else {
                out[key] = rename_modules(item, prefix, unknown);
            }
        }
        return out;
    }
    if isinstance(value, list) {
        return [rename_modules(item, prefix, unknown) for item in value];
    }
    return value;
}

"""The document in an upload: base64 of the gzipped JSON `scripts/export-data.sh` writes, or of
the JSON itself."""
def decode(data: str) -> dict[str, object] {
    if len(data) > MAX_UPLOAD_CHARS {
        raise TransferError("The file is larger than a move can take.");
    }
    try {
        raw = base64.b64decode(data, validate=True);
    } except (binascii.Error, ValueError) {
        raise TransferError("The file did not arrive whole. Choose it again.");
    }
    if raw[:2] == b"\x1f\x8b" {
        try {
            raw = gzip.decompress(raw);
        } except (OSError, EOFError, zlib.error) {
            raise TransferError("The file is not a whole gzip file. Export it again.");
        }
    }
    try {
        doc = json.loads(raw);
    } except ValueError {
        raise TransferError("The file is not an export from scripts/export-data.sh.");
    }
    if not isinstance(doc, dict) or doc.get("format") != FORMAT {
        raise TransferError("The file is not an export from scripts/export-data.sh.");
    }
    if doc.get("version") != FORMAT_VERSION {
        raise TransferError(f"The file is export version {doc.get('version')}, and this server reads version {FORMAT_VERSION}.");
    }
    return doc;
}

def rows_of(doc: dict[str, object], table: str, width: int) -> list[list[object]] {
    found = doc.get(table);
    if not isinstance(found, list) or any(not isinstance(r, list) or len(r) != width for r in found) {
        raise TransferError(f"The file's {table} are not in the shape this server reads.");
    }
    return found;
}

"""A stored portfolio's name, or "" when its props do not hold one."""
def portfolio_name(stored: object) -> str {
    archetype = stored.get("archetype") if isinstance(stored, dict) else None;
    return str(archetype.get("name", "")) if isinstance(archetype, dict) else "";
}

"""The rows of `doc` as this server writes them, with its module names under `prefix`. Its run
count leaves out the demo account's invented history, as `run_count` does."""
def prepare(doc: dict[str, object], prefix: str) -> Moved {
    anchors: list[dict[str, object]] = [];
    unknown: set[str] = set();
    runs: set[str] = set();
    demo_portfolios: set[str] = set();
    ran: list[tuple[str, str]] = [];
    roots: set[str] = set();
    for row in rows_of(doc, "anchors", len(ANCHOR_FIELDS)) {
        anchor = dict(zip(ANCHOR_FIELDS, row));
        module = str(anchor["arch_module"] or "");
        if module {
            renamed = rename_module(module, prefix);
            if renamed is None {
                unknown.add(module);
            } else {
                anchor["arch_module"] = renamed;
            }
        }
        anchor["props"] = rename_modules(anchor["props"], prefix, unknown);
        if anchor["arch_type"] == "Run" {
            runs.add(str(anchor["id"]));
        }
        if anchor["arch_type"] == "Portfolio" and portfolio_name(anchor["props"]) == DEMO_PORTFOLIO {
            demo_portfolios.add(str(anchor["id"]));
        }
        if anchor["arch_type"] == "Ran" {
            ran.append((str(anchor["src"]), str(anchor["dst"])));
        }
        if anchor["arch_type"] == "Root" {
            roots.add(str(anchor["id"]));
        }
        anchors.append(anchor);
    }
    if unknown {
        raise TransferError("The file holds records of types this server does not have: " + ", ".join(sorted(unknown)[:5]));
    }
    if SUPER_ROOT not in roots {
        raise TransferError("The file has no server root, so it is not a whole server's records.");
    }
    users = [{"user_id": str(r[0]), "doc": r[1]} for r in rows_of(doc, "identity_users", 2)];
    if not any(isinstance(u["doc"], dict) and u["doc"].get("role") == "admin" for u in users) {
        raise TransferError("The file has no admin account, so nobody could see the team's records after the move.");
    }
    return Moved(
        anchors=anchors,
        graph_types=[{"type_name": str(r[0]), "ancestor": str(r[1])} for r in rows_of(doc, "graph_types", 2)],
        users=users,
        lookups=[{"value_normalized": str(r[0]), "user_id": str(r[1])} for r in rows_of(doc, "identity_lookups", 2)],
        sso=[{"provider": str(r[0]), "external_id": str(r[1]), "user_id": str(r[2])} for r in rows_of(doc, "sso_lookups", 3)],
        runs=len(runs - {run for (portfolio, run) in ran if portfolio in demo_portfolios}),
        exported_at=str(doc.get("exported_at", ""))
    );
}

def chunks(rows: list[object]) -> list[list[object]] {
    return [rows[i:i + CHUNK] for i in range(0, len(rows), CHUNK)];
}

# The runtime's sign-in tables (jaclang/server/identity), which it makes at the first sign-up.
glob IDENTITY_TABLES: list[str] = [
    "CREATE TABLE IF NOT EXISTS identity_users (user_id text PRIMARY KEY, doc jsonb NOT NULL)",
    "CREATE TABLE IF NOT EXISTS identity_lookups (value_normalized text PRIMARY KEY, user_id text NOT NULL)",
    "CREATE TABLE IF NOT EXISTS sso_lookups (provider text NOT NULL, external_id text NOT NULL, user_id text NOT NULL, PRIMARY KEY (provider, external_id))",
    "CREATE INDEX IF NOT EXISTS idx_identity_lookups_user ON identity_lookups (user_id)"
];

def as_doc(value: object) -> dict[str, object] {
    found = json.loads(value) if isinstance(value, str) else value;
    return found if isinstance(found, dict) else {};
}

"""`moved`'s users, with the admin account signing in as this server's admin does. The old
server's admin may still have the laptop's fallback password, which a public server must not take."""
def with_own_admin(store: PgStore, moved: Moved) -> list[dict[str, object]] {
    mine = store.rows(
        """
        SELECT u.doc FROM identity_lookups l JOIN identity_users u ON u.user_id = l.user_id
        WHERE l.value_normalized = :name
        """,
        {"name": ADMIN_NAME}
    );
    theirs = [l["user_id"] for l in moved.lookups if l["value_normalized"] == ADMIN_NAME];
    if not mine or not theirs {
        return moved.users;
    }
    here = as_doc(mine[0][0]);
    users: list[dict[str, object]] = [];
    for u in moved.users {
        if u["user_id"] == theirs[0] {
            doc = dict(as_doc(u["doc"]));
            doc["credentials"] = here.get("credentials", []);
            doc["requires_password_reset"] = bool(here.get("requires_password_reset", False));
            users.append({"user_id": u["user_id"], "doc": doc});
        } else {
            users.append(u);
        }
    }
    return users;
}

"""Replace the graph and the accounts with `moved`, in the transaction already open on `store`.
New sequence numbers keep the old order, and versions start past every version this server has
written."""
def write_moved(store: PgStore, moved: Moved) {
    for statement in IDENTITY_TABLES {
        store.rows(statement, {});
    }
    offset = int(store.rows("SELECT coalesce(max(version), 0) + 1 FROM anchors", {})[0][0]);
    users = with_own_admin(store, moved);
    for table in ["anchors", "quarantine", "identity_lookups", "sso_lookups", "identity_users"] {
        store.rows(f"DELETE FROM {table}", {});
    }
    for part in chunks(moved.anchors) {
        store.rows(
            """
            INSERT INTO anchors
                (id, kind, arch_type, arch_module, fingerprint, root_id, src, dst, undirected,
                 props, format_version, version, updated_at)
            SELECT id, kind, arch_type, arch_module, fingerprint, root_id, src, dst, undirected,
                   props, format_version, version + :offset, now()
            FROM jsonb_to_recordset(CAST(:rows AS jsonb)) AS r(
                id uuid, kind text, arch_type text, arch_module text, fingerprint text,
                root_id uuid, src uuid, dst uuid, undirected boolean, props jsonb,
                format_version integer, version bigint, seq bigint)
            ORDER BY seq
            """,
            {"rows": json.dumps(part), "offset": offset}
        );
    }
    for part in chunks(moved.graph_types) {
        store.rows(
            """
            INSERT INTO graph_types (type_name, ancestor)
            SELECT type_name, ancestor FROM jsonb_to_recordset(CAST(:rows AS jsonb))
                AS r(type_name text, ancestor text)
            ON CONFLICT DO NOTHING
            """,
            {"rows": json.dumps(part)}
        );
    }
    for part in chunks(users) {
        store.rows(
            """
            INSERT INTO identity_users (user_id, doc)
            SELECT user_id, doc FROM jsonb_to_recordset(CAST(:rows AS jsonb))
                AS r(user_id text, doc jsonb)
            """,
            {"rows": json.dumps(part)}
        );
    }
    for part in chunks(moved.lookups) {
        store.rows(
            """
            INSERT INTO identity_lookups (value_normalized, user_id)
            SELECT value_normalized, user_id FROM jsonb_to_recordset(CAST(:rows AS jsonb))
                AS r(value_normalized text, user_id text)
            """,
            {"rows": json.dumps(part)}
        );
    }
    for part in chunks(moved.sso) {
        store.rows(
            """
            INSERT INTO sso_lookups (provider, external_id, user_id)
            SELECT provider, external_id, user_id FROM jsonb_to_recordset(CAST(:rows AS jsonb))
                AS r(provider text, external_id text, user_id text)
            """,
            {"rows": json.dumps(part)}
        );
    }
}

"""Take every scheduled job's lease, waiting for a job that just fired to let its own go.
Returns the leases taken; raises when one stays held."""
def hold_jobs(store: PgStore, wait_s: float = LEASE_WAIT_S, poll_s: float = LEASE_POLL_S) -> list[str] {
    held: list[str] = [];
    waiting = ["sched:" + name for name in JOBS];
    deadline = time.monotonic() + wait_s;
    while waiting {
        for key in list(waiting) {
            if store.kv_acquire_lease(key, LEASE_TTL_S, LEASE_OWNER) {
                held.append(key);
                waiting.remove(key);
            }
        }
        if not waiting {
            break;
        }
        if time.monotonic() >= deadline {
            release_jobs(store, held);
            raise TransferError("A scheduled job kept running, so nothing was moved. Try again in a few minutes.");
        }
        time.sleep(poll_s);
    }
    return held;
}

def release_jobs(store: PgStore, held: list[str]) {
    for key in held {
        try {
            store.kv_release_lease(key, LEASE_OWNER);
        } except Exception as e {
            LOG.warning("transfer: could not release %s: %s", key, e);
        }
    }
}

"""Forget what this process remembers of the old graph: the shared root, built views, roles, and
accounts. `root.shared` is the guest account's root, which the runtime looks up once per process;
the guest account moved with the rest, so registering the same lookup again makes it look anew."""
def forget_cached {
    resolver = jac_runtime._shared_root_resolver[0];
    if resolver is not None {
        Jac.set_shared_root_resolver(resolver);
    }
    VIEWS.clear();
    accounts_store._ROLES.clear();
    accounts_store.forget_demo_root();
    sharing._SEEN.clear();
    dashboard_api._SPECIALISTS_BUILT_FROM.clear();
}

def now_iso -> str {
    return datetime.now(timezone.utc).isoformat(timespec="seconds");
}

def read_state(store: PgStore) -> dict[str, object] {
    text = store.kv_get(STATE_KEY);
    if not text {
        return {};
    }
    try {
        found = json.loads(text);
    } except ValueError {
        return {};
    }
    return found if isinstance(found, dict) else {};
}

def write_state(store: PgStore, state: str, message: str, started_at: str = "") {
    store.kv_put(STATE_KEY, json.dumps({"state": state, "message": message, "started_at": started_at, "updated_at": now_iso(), "at": time.time()}));
}

"""True when a move said it was running but has not been heard from in STALE_S."""
def is_stale(found: dict[str, object]) -> bool {
    stamp = found.get("at");
    heard = float(stamp) if isinstance(stamp, (int, float)) else 0.0;
    return found.get("state") == "running" and time.time() - heard > STALE_S;
}

"""The number of runs on this server. A server that has run keeps its own records. The demo
account's invented history (accounts/demo.jac) is left out: every server seeds it at boot, and a move
replaces it, after which the server seeds it again."""
def run_count(store: PgStore) -> int {
    return int(store.rows(
        """
        SELECT count(*) FROM anchors run
        WHERE run.arch_type = 'Run'
          AND NOT EXISTS (
            SELECT 1 FROM anchors ran
            JOIN anchors portfolio ON portfolio.id = ran.src
            WHERE ran.arch_type = 'Ran' AND ran.dst = run.id
              AND portfolio.arch_type = 'Portfolio'
              AND portfolio.props->'archetype'->>'name' = :demo
          )
        """,
        {"demo": DEMO_PORTFOLIO}
    )[0][0]);
}

"""Do the move: hold the jobs, let one that just fired finish, write, and let them go."""
def carry_out(info: ConnInfo, moved: Moved, started_at: str, settle_s: float = SETTLE_S, wait_s: float = LEASE_WAIT_S) {
    store = PgStore(conninfo=info);
    held: list[str] = [];
    try {
        held = hold_jobs(store, wait_s);
        time.sleep(settle_s);
        problem: Exception | None = None;
        for attempt in range(ATTEMPTS) {
            try {
                store.begin(TxnIsolation.SERIALIZABLE);
                if run_count(store) > 0 {
                    store.rollback();
                    raise TransferError("This server has runs of its own now, so nothing was moved.");
                }
                write_moved(store, moved);
                store.commit();
                problem = None;
                break;
            } except TransferError {
                raise;
            } except Exception as e {
                problem = e;
                store.rollback();
                LOG.warning("transfer: attempt %d failed: %s", attempt + 1, e);
            }
        }
        if problem is not None {
            raise problem;
        }
        forget_cached();
        words = f"Moved {moved.runs} runs, {len(moved.anchors)} records, and {len(moved.users)} accounts, exported {moved.exported_at[:16].replace('T', ' ')}.";
        write_state(store, "done", words, started_at);
        LOG.info("transfer: %s", words);
    } except Exception as e {
        LOG.exception("transfer failed");
        words = str(e) if isinstance(e, TransferError) else f"The move failed, and nothing was changed: {e}";
        try {
            write_state(store, "failed", words, started_at);
        } except Exception {
            LOG.exception("transfer: could not record the failure");
        }
    } finally {
        release_jobs(store, held);
        store.close();
    }
}

"""The state of a move as the settings page shows it. `ready` is the admin of a server that has
not run and has no move under way."""
def status_of(store: PgStore, admin: bool) -> TransferStatus {
    found = read_state(store);
    state = str(found.get("state", ""));
    message = str(found.get("message", ""));
    if is_stale(found) {
        state = "failed";
        message = "The last move stopped partway, when the server restarted. Nothing it did was kept; try again.";
    }
    runs = run_count(store);
    return TransferStatus(state=state, message=message, ready=admin and runs == 0 and state != "running", runs=runs);
}

def own_store -> PgStore {
    current = Jac.get_context().mem.store;
    if not isinstance(current, PgStore) {
        raise TransferError("This server keeps no Postgres database, so it cannot take a move.");
    }
    # The runtime starts an embedded Postgres on its store's first use; the callback lets this
    # store start it too, rather than dial a socket that is not there yet.
    return PgStore(conninfo=current.conninfo, ensure_cb=current.ensure_cb);
}

def part_key(upload: str, index: int) -> str {
    return f"{PART_PREFIX}{upload}:{index}";
}

"""Why a part cannot be kept, or "" when it can."""
def part_problem(upload: str, index: int, part: str) -> str {
    if not UPLOAD_ID.match(upload) {
        return "The upload has no usable name.";
    }
    if index < 0 or index >= MAX_PARTS {
        return "The file is larger than a move can take.";
    }
    if len(part) > PART_CHARS {
        return "A part of the file is larger than the server takes in one request.";
    }
    return "";
}

"""Keep one part of an upload until the move starts, or for an hour."""
def keep_part(store: PgStore, upload: str, index: int, part: str) {
    store.kv_put_ttl(part_key(upload, index), part, PART_TTL_S);
}

"""The upload's `count` parts joined, and their keys removed. Raises when one is missing."""
def take_parts(store: PgStore, upload: str, count: int) -> str {
    if not UPLOAD_ID.match(upload) or count < 1 or count > MAX_PARTS {
        raise TransferError("The file did not arrive whole. Choose it again.");
    }
    parts: list[str] = [];
    for index in range(count) {
        found = store.kv_get(part_key(upload, index));
        if found is None {
            raise TransferError("The file did not arrive whole. Choose it again.");
        }
        parts.append(found);
    }
    for index in range(count) {
        store.kv_delete(part_key(upload, index));
    }
    return "".join(parts);
}

"""Keep part `index` of the export file `upload` is sending (base64, at most PART_CHARS). Admins
only; `start_transfer` joins the parts."""
def:priv send_transfer_part(upload: str, index: int, part: str) -> TransferStatus {
    if not caller_is_admin() {
        return TransferStatus(state="refused", message="Only an admin can move records onto this server.", ready=False, runs=0);
    }
    problem = part_problem(upload, index, part);
    if problem {
        return TransferStatus(state="refused", message=problem, ready=True, runs=0);
    }
    store = own_store();
    try {
        keep_part(store, upload, index, part);
        return TransferStatus(state="", message="", ready=True, runs=0);
    } finally {
        store.close();
    }
}

"""Whether this server can take a move, and how the last one went. Admins only."""
def:priv get_transfer_status -> TransferStatus {
    if not caller_is_admin() {
        return TransferStatus(state="", message="", ready=False, runs=0);
    }
    store = own_store();
    try {
        return status_of(store, True);
    } finally {
        store.close();
    }
}

"""Start moving the records in the export file sent as `parts` parts of `upload`, replacing this
server's graph and accounts. The move runs in the background; the page asks for its state."""
def:priv start_transfer(upload: str, parts: int) -> TransferStatus {
    if not caller_is_admin() {
        return TransferStatus(state="refused", message="Only an admin can move records onto this server.", ready=False, runs=0);
    }
    store = own_store();
    try {
        with _LOCK {
            current = status_of(store, True);
            if current.state == "running" {
                return current;
            }
            if current.runs > 0 {
                return TransferStatus(state="refused", message=f"This server has {current.runs} runs of its own, so it keeps its records. A move only goes to a server that has not run yet.", ready=False, runs=current.runs);
            }
            try {
                moved = prepare(decode(take_parts(store, upload, parts)), module_prefix());
            } except TransferError as e {
                return TransferStatus(state="refused", message=str(e), ready=True, runs=0);
            }
            started_at = now_iso();
            write_state(store, "running", f"Moving {moved.runs} runs and {len(moved.anchors)} records. This takes a minute or two.", started_at);
            threading.Thread(target=carry_out, args=(store.conninfo, moved, started_at), name="parallax-transfer", daemon=True).start();
            return status_of(store, True);
        }
    } finally {
        store.close();
    }
}

"""This server's whole record, as the gzipped file `scripts/export-data.sh` writes. A server that
nobody has signed up on yet has no account tables, so they are made first, empty."""
def export_bytes(store: PgStore) -> bytes {
    for statement in IDENTITY_TABLES {
        store.rows(statement, {});
    }
    found = store.rows(EXPORT_SQL, {})[0][0];
    text = found if isinstance(found, str) else json.dumps(found);
    return gzip.compress(text.encode("utf-8"), compresslevel=9);
}

def export_key(copy: str, index: int) -> str {
    return f"{EXPORT_PREFIX}{copy}:{index}";
}

"""Keep `data` for an hour in parts of at most PART_CHARS base64 characters, which each fit in
one response under JacHammer's proxy limit. Returns the copy's name and how many parts it has."""
def keep_export(store: PgStore, data: bytes) -> tuple[str, int] {
    text = base64.b64encode(data).decode("ascii");
    parts = [text[i:i + PART_CHARS] for i in range(0, len(text), PART_CHARS)] or [""];
    copy = str(uuid.uuid4());
    for (index, part) in enumerate(parts) {
        store.kv_put_ttl(export_key(copy, index), part, PART_TTL_S);
    }
    return (copy, len(parts));
}

"""Part `index` of a kept copy, or None when there is no such part."""
def export_part(store: PgStore, copy: str, index: int) -> str | None {
    if not UPLOAD_ID.match(copy) or index < 0 or index >= MAX_PARTS {
        return None;
    }
    return store.kv_get(export_key(copy, index));
}

"""Make a copy of this server's records, the file another server's move takes, and keep it for
an hour for the page to fetch in parts. Admins only: it holds password hashes and sealed keys."""
def:priv start_export -> ExportReady {
    if not caller_is_admin() {
        return ExportReady(state="refused", message="Only an admin can download this server's records.");
    }
    store = own_store();
    try {
        data = export_bytes(store);
        (copy, parts) = keep_export(store, data);
        day = datetime.now(ZoneInfo("America/New_York")).date().isoformat();
        LOG.info("transfer: kept a copy of the records, %d bytes in %d parts", len(data), parts);
        return ExportReady(state="ready", copy=copy, parts=parts, size=len(data), name=f"parallax-data-{day}.json.gz");
    } except TransferError as e {
        return ExportReady(state="refused", message=str(e));
    } finally {
        store.close();
    }
}

"""Part `index` of the copy `start_export` kept. Admins only."""
def:priv get_export_part(copy: str, index: int) -> ExportPart {
    if not caller_is_admin() {
        return ExportPart(data="", message="Only an admin can download this server's records.");
    }
    store = own_store();
    try {
        found = export_part(store, copy, index);
        if found is None {
            return ExportPart(data="", message="The copy is gone. Download the records again.");
        }
        return ExportPart(data=found);
    } finally {
        store.close();
    }
}
