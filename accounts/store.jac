"""Finding the signed-in user's agent, and every agent for the scheduled jobs (TDD §9, accounts).

Every endpoint that shows or changes an agent goes through `my_portfolio` and `my_account`,
which take no argument from the client: a request can only ever reach its caller's own agent.
The admin's agent is the team portfolio on root.shared, which runs on the server's own keys.
A server in demo mode shows every user the made-up history, since it runs nothing, and the demo
account (accounts/demo.jac) sees its own made-up history on any server, and changes nothing.
"""
import hashlib;
import os;
import time;
import from jaclang { JacRuntime as Jac }
import from jaclang.server.identity.user_manager { UserManager }
import from models.accounts { AgentAccount, DemoLogin }
import from models.graph { Portfolio, PortfolioMode }
import from research.collector { utc_now }
import from research.credentials { ALPACA_KEY, ALPACA_SECRET, Credentials, OPENROUTER_KEY }
import from accounts.vault { unseal }
import from run.guard { find_team_portfolio }
import from run.switches { DEMO_ENV, demo_mode }

glob AGENT_PORTFOLIO: str = "agent";
glob MAX_AGENTS_ENV: str = "PARALLAX_MAX_AGENTS";
# Three agents run at a time from 7:30 a.m. and each takes about half an hour, so ten are done
# with time to spare before orders go out at 9:45 (run/agents.jac).
glob DEFAULT_MAX_AGENTS: int = 10;
glob REQUIRED_KEYS: tuple[str, ...] = (ALPACA_KEY, ALPACA_SECRET, OPENROUTER_KEY);
glob ADMIN_ROLE: str = "admin";
glob USER_PAGE: int = 100;
# How long a caller's role is remembered. The role decides whose agent a request sees, and reading
# it walks the user table.
glob ROLE_TTL_S: float = 60.0;
glob _ROLES: dict[str, tuple[bool, float]] = {};
# The demo account (accounts/demo.jac): its username, the portfolio it shows on root.shared, and
# what it answers a request to change anything.
glob DEMO_USERNAME: str = "demo";
glob DEMO_PORTFOLIO: str = "demo";
glob DEMO_REFUSAL: str = "The demo account only browses made-up history, so it cannot change anything. Create an account to run your own agent.";
# The demo user's graph root, as read last and when, so a request does not read it each time.
glob _DEMO_ROOT: dict[str, tuple[str, float]] = {};

def max_agents -> int {
    try {
        return max(0, int(os.environ.get(MAX_AGENTS_ENV, str(DEFAULT_MAX_AGENTS))));
    } except ValueError {
        return DEFAULT_MAX_AGENTS;
    }
}

"""True when the graph root `caller` (`jid(root)`) belongs to a user with the admin role."""
def is_admin_root(users: UserManager, caller: str) -> bool {
    offset = 0;
    while True {
        page = users.list_all_users(limit=USER_PAGE, offset=offset);
        for u in page {
            if u.get("role") == ADMIN_ROLE and str(u.get("root_id", "")) == caller {
                return True;
            }
        }
        if len(page) < USER_PAGE {
            return False;
        }
        offset += USER_PAGE;
    }
    return False;
}

def caller_is_admin -> bool {
    caller = str(jid(root));
    known = _ROLES.get(caller);
    if known is not None and time.monotonic() - known[1] < ROLE_TTL_S {
        return known[0];
    }
    found = is_admin_root(UserManager(base_path="."), caller);
    _ROLES[caller] = (found, time.monotonic());
    return found;
}

"""The demo account's sign-in record, or None before the demo job writes it. Read as the server,
since it carries no grant."""
def demo_login -> DemoLogin | None {
    found = read_as_system(demo_logins);
    return found[0] if found else None;
}

def demo_logins -> list[DemoLogin] {
    return [d for d in [root.shared -->[?:DemoLogin]]];
}

"""The demo user's graph root (`jid(root)`), or "" before the demo job records it."""
def demo_root -> str {
    known = _DEMO_ROOT.get("root");
    if known is not None and known[0] and time.monotonic() - known[1] < ROLE_TTL_S {
        return known[0];
    }
    login = demo_login();
    found = login.root_id if login is not None else "";
    _DEMO_ROOT["root"] = (found, time.monotonic());
    return found;
}

"""Read the demo user's root again on the next request: it was just recorded."""
def forget_demo_root {
    _DEMO_ROOT.clear();
}

"""True when the caller is the shared demo account."""
def caller_is_demo -> bool {
    found = demo_root();
    return bool(found) and str(jid(root)) == found;
}

"""Why the caller cannot change anything, or "" when they can: the demo account is shared by
everyone who browses it, so nothing it does is kept."""
def demo_refusal -> str {
    return DEMO_REFUSAL if caller_is_demo() else "";
}

"""The demo account's made-up portfolio on root.shared, or None before the demo job seeds it."""
def demo_portfolio -> Portfolio | None {
    for p in [root.shared -->[?:Portfolio]] {
        if p.name == DEMO_PORTFOLIO {
            return p;
        }
    }
    return None;
}

"""The caller's agent account, or None before they connect a key. Another user's account is not
visible to them; a scheduled job, which sees every account, uses `all_accounts`."""
def my_account -> AgentAccount | None {
    caller = str(jid(root));
    for a in [root.shared -->[?:AgentAccount]] {
        if a.owner_root == caller {
            return a;
        }
    }
    return None;
}

"""Run `read` as the super root and come back to the caller. Only for reading: a node changed on
someone else's root under this would not be saved once the caller's root is back."""
def read_as_system[T](read: Callable[[], T]) -> T {
    ctx = Jac.get_context();
    caller = str(ctx.user_root.id);
    ctx.set_user_root(str(ctx.system_root.id));
    try {
        return read();
    } finally {
        ctx.set_user_root(caller);
    }
}

"""Every agent account. On the super root (a scheduled job) that is all of them."""
def all_accounts -> list[AgentAccount] {
    return [a for a in [root.shared -->[?:AgentAccount]]];
}

"""True when the server has room for a new agent."""
def has_room -> bool {
    return len(read_as_system(all_accounts)) < max_agents();
}

"""The agent's portfolio on the caller's own root, or None before they have one."""
def own_portfolio -> Portfolio | None {
    for p in [root -->[?:Portfolio]] {
        if p.name == AGENT_PORTFOLIO {
            return p;
        }
    }
    return None;
}

"""The portfolio the caller's dashboard shows."""
def my_portfolio -> Portfolio | None {
    if demo_mode() or caller_is_admin() {
        return find_team_portfolio();
    }
    if caller_is_demo() {
        return demo_portfolio();
    }
    return own_portfolio();
}

"""The agent's portfolio on the current root, created in insight mode on first use. Nodes on a
user's root carry no grant, so no other user can read them."""
def ensure_own_portfolio -> Portfolio {
    found = own_portfolio();
    if found is not None {
        return found;
    }
    return root ++> Portfolio(name=AGENT_PORTFOLIO, mode=PortfolioMode.INSIGHT, starting_cash=0.0, opened_at=utc_now().isoformat(), order_tag=order_tag_for(str(jid(root))));
}

"""The prefix of an agent's client order IDs (`Portfolio.order_tag`): short, and its owner's alone."""
def order_tag_for(owner: str) -> str {
    return "a" + hashlib.sha256(owner.encode()).hexdigest()[:8];
}

"""True when `account` has every key a run needs."""
def has_required_keys(account: AgentAccount) -> bool {
    return all(name in account.sealed for name in REQUIRED_KEYS);
}

"""The account's keys, opened for a run or a request. Raises VaultError when the server's secret
has changed since they were saved."""
def credentials_of(account: AgentAccount) -> Credentials {
    return Credentials({name: unseal(account.owner_root, name, box) for (name, box) in account.sealed.items()}, account.owner_root);
}
