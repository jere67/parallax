"""The demo account: one shared sign-in, named demo, with no password, so a visitor without API
keys can browse the app as if an agent had been running for weeks.

    root.shared ──> DemoLogin (granted to nobody: the demo user's ids)
    root.shared ──> Portfolio(name "demo", demo) ──> ... made-up history (dashboard/demo.jac)

The history is the demo environment's: `DemoSim`, the seeded simulation a server started with
TRADING_AGENT_DEMO=1 shows everyone, written here into its own portfolio, so the team's real one
is never touched. `my_portfolio` (accounts/store.jac) shows it to the demo user, and every
endpoint that changes anything refuses them (`demo_refusal`), since everyone who browses shares
the one account. On a demo server everyone sees the team's made-up history already, so the demo
user sees that and no second copy is seeded.

The user is made with a random password no one is told; `open_demo` hands out a token for it
instead. Only a user this server made is ever handed out: a "demo" user made before the server's
record of one (someone who signed up with that name) is left alone, and the sign-in stays off.
"""
import logging;
import secrets;
import threading;
import time;
import from datetime { date, datetime }
import from jaclang.server.identity.user_manager { UserManager }
import from jaclang.data.store { PgStore }
import from accounts.store { DEMO_PORTFOLIO, DEMO_USERNAME, demo_login, demo_portfolio, forget_demo_root }
import from accounts.transfer { JOBS, SETTLE_S, TransferError, hold_jobs, own_store, release_jobs }
import from dashboard.cache { VIEWS }
import from dashboard.demo { DEMO_VERSION, DemoSim, STARTING_CASH }
import from models.accounts { DemoLogin, DemoSignIn }
import from models.graph { Portfolio, PortfolioMode }
import from research.collector { parse_utc, utc_now }
import from run.guard { NEW_YORK }
import from run.public { public }
import from run.switches { demo_mode }

glob LOG: logging.Logger = logging.getLogger("trading_agent.demo_account");
glob _SEEDING: threading.Lock = threading.Lock();
glob NOT_READY: str = "The demo account is being set up. Try again in a minute.";
glob SEED_JOB: str = "demo_history_job";
# Whose hold the other jobs' leases are under while a seed writes, apart from a records move's.
glob SEED_LEASE_OWNER: str = "parallax-demo-seed";

"""Make the demo user and record it, a step a minute: the record first, then the user. A user
made between the two, by a job that stopped before it could record it, is the server's own."""
@schedule(trigger=ScheduleTrigger.STATIC, cron="* * * * *")
def demo_account_job {
    note = ensure_demo_user(UserManager(base_path="."));
    if note {
        LOG.warning("%s", note);
    }
}

"""One step toward a recorded demo user. Returns what went wrong, or ""."""
def ensure_demo_user(users: UserManager) -> str {
    login = demo_login();
    if login is None {
        root.shared ++> DemoLogin(created_at=utc_now().isoformat());
        return "";
    }
    found = users.find_user_by_identity(DEMO_USERNAME);
    if found is None {
        made = users.create_internal_user(DEMO_USERNAME, secrets.token_urlsafe(32));
        if "error" in made {
            return f"demo: the demo user could not be made: {made.get('error')}";
        }
        record(login, str(made["user_id"]), str(made["root_id"]));
        return "";
    }
    if str(found.get("user_id", "")) == login.user_id {
        return "";
    }
    if made_after(found, login) {
        record(login, str(found["user_id"]), str(found.get("root_id", "")));
        return "";
    }
    return "demo: a user named demo was made before this server's demo account, so the demo sign-in stays off";
}

def record(login: DemoLogin, user_id: str, root_id: str) {
    login.user_id = user_id;
    login.root_id = root_id;
    forget_demo_root();
}

"""True when the user `found` was made after the server's record of the demo account."""
def made_after(found: dict[str, object], login: DemoLogin) -> bool {
    try {
        return parse_utc(str(found.get("created_at", ""))) >= parse_utc(login.created_at);
    } except ValueError {
        return False;
    }
}

"""Seed the demo account's history once, outside a demo server. A seed takes about a minute (five
on a JacHammer host) and commits only when its job ends, so the next minute's job skips while one
is running. It holds the other scheduled jobs meanwhile, as a records move does: they write every
minute, and a write to the graph the seed has read cancels its whole transaction (a serialization
failure, Postgres 40001), so with them running a seed failed every minute and never finished."""
@schedule(trigger=ScheduleTrigger.STATIC, cron="* * * * *")
def demo_history_job {
    if demo_mode() or not _SEEDING.acquire(blocking=False) {
        return;
    }
    store: PgStore | None = None;
    held: list[str] = [];
    try {
        try {
            store = own_store();
        } except TransferError {
            store = None;
        }
        # Asked of the database directly, so this job's transaction reads the graph only once the
        # other jobs are held.
        if store is not None {
            if not needs_seed(store) {
                return;
            }
            held = hold_jobs(store, jobs=[j for j in JOBS if j != SEED_JOB], owner=SEED_LEASE_OWNER);
            # A job that fired just before the hold is given time to finish.
            time.sleep(SETTLE_S);
        }
        done = seed_demo_account(datetime.now(NEW_YORK).date());
        if done {
            LOG.warning("%s", done);
        }
    } except TransferError as e {
        LOG.warning("demo account: not seeded this minute: %s", e);
    } finally {
        if store is not None {
            release_jobs(store, held, SEED_LEASE_OWNER);
            store.close();
        }
        _SEEDING.release();
    }
}

"""False when the portfolio named demo holds the current history, or holds no demo history at all
(which `seed_demo_account` leaves alone)."""
def needs_seed(store: PgStore) -> bool {
    return int(store.rows(
        """
        SELECT count(*) FROM anchors
        WHERE arch_type = 'Portfolio'
          AND props->'archetype'->>'name' = :name
          AND (props->'archetype'->>'demo_version' = :version OR props->'archetype'->>'demo' = 'false')
        """,
        {"name": DEMO_PORTFOLIO, "version": str(DEMO_VERSION)}
    )[0][0]) == 0;
}

"""Write the demo environment's history ending yesterday into the demo account's portfolio,
unless it holds the current version of it (`DEMO_VERSION`). An older version is deleted first.
Returns what it did, or "" when it did nothing."""
def seed_demo_account(today: date) -> str {
    portfolio = demo_portfolio();
    removed = 0;
    if portfolio is not None {
        if portfolio.demo_version == DEMO_VERSION {
            return "";
        }
        if not portfolio.demo {
            return "demo account: the portfolio named demo holds no demo history, so it is left alone";
        }
        removed = clear_history(portfolio);
    } else {
        portfolio = public(root.shared ++> Portfolio(name=DEMO_PORTFOLIO, mode=PortfolioMode.AUTO, starting_cash=STARTING_CASH, opened_at=""));
    }
    sim = DemoSim(portfolio=portfolio, today=today);
    sim.run();
    VIEWS.clear();
    replaced = f" in place of {removed} records of version {DEMO_VERSION - 1 if removed else 0}" if removed else "";
    return f"demo account: wrote {len(sim.run_days)} runs ({len(sim.days)} sessions), {sim.decisions} decisions, {sim.orders} orders{replaced}";
}

"""Delete everything `portfolio`'s history holds: each node reachable from it, without passing
another portfolio. The portfolio itself stays, so whatever points to it still does. Returns how
many nodes went."""
def clear_history(portfolio: Portfolio) -> int {
    seen: set[str] = set();
    doomed = [];
    todo = [n for n in [portfolio -->]];
    while todo {
        n = todo.pop();
        key = str(jid(n));
        if key in seen or isinstance(n, Portfolio) {
            continue;
        }
        seen.add(key);
        doomed.append(n);
        todo.extend([m for m in [n -->]]);
    }
    for n in doomed {
        del n;
    }
    return len(doomed);
}

"""A sign-in token for the demo account, which needs no password. Anyone may ask: the account
only browses made-up history and changes nothing."""
def:pub open_demo -> DemoSignIn {
    login = demo_login();
    if login is None or not login.user_id {
        return DemoSignIn(message=NOT_READY);
    }
    users = UserManager(base_path=".");
    found = users.find_user_by_identity(DEMO_USERNAME);
    if found is None or str(found.get("user_id", "")) != login.user_id {
        return DemoSignIn(message=NOT_READY);
    }
    forget_demo_root();
    return DemoSignIn(token=users.create_jwt_token(login.user_id));
}
