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
import from datetime { date, datetime }
import from jaclang.server.identity.user_manager { UserManager }
import from accounts.store { DEMO_PORTFOLIO, DEMO_USERNAME, demo_login, demo_portfolio, forget_demo_root }
import from dashboard.demo { DemoSim, STARTING_CASH }
import from models.accounts { DemoLogin, DemoSignIn }
import from models.graph { Portfolio, PortfolioMode }
import from research.collector { parse_utc, utc_now }
import from run.guard { NEW_YORK }
import from run.public { public }
import from run.switches { demo_mode }

glob LOG: logging.Logger = logging.getLogger("trading_agent.demo_account");
glob _SEEDING: threading.Lock = threading.Lock();
glob NOT_READY: str = "The demo account is being set up. Try again in a minute.";

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

"""Seed the demo account's history once, outside a demo server. A seed takes about a minute and
commits only when its job ends, so the next minute's job skips while one is running."""
@schedule(trigger=ScheduleTrigger.STATIC, cron="* * * * *")
def demo_history_job {
    if demo_mode() or not _SEEDING.acquire(blocking=False) {
        return;
    }
    try {
        done = seed_demo_account(datetime.now(NEW_YORK).date());
        if done {
            LOG.warning("%s", done);
        }
    } finally {
        _SEEDING.release();
    }
}

"""Write the demo environment's history ending the last weekday before `today` into the demo
account's portfolio, unless it has one. Returns what it did, or "" when it did nothing."""
def seed_demo_account(today: date) -> str {
    if demo_portfolio() is not None {
        return "";
    }
    portfolio = public(root.shared ++> Portfolio(name=DEMO_PORTFOLIO, mode=PortfolioMode.AUTO, starting_cash=STARTING_CASH, opened_at=""));
    sim = DemoSim(portfolio=portfolio, today=today);
    sim.run();
    return f"demo account: wrote {len(sim.days)} sessions, {sim.decisions} decisions, {sim.orders} orders";
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
