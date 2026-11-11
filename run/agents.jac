"""Every user's agent on schedule (TDD §9, accounts).

The team's agent keeps its own jobs (run/jobs.jac). Every other agent lives on its owner's root,
and a job on the super root works on it by becoming that owner (`as_agent`): what it writes is
then the owner's, private to them, and everything it calls uses their keys and their limits.

A firing's writes commit when it ends, and a morning run takes about half an hour. So each of
`RUN_SLOTS` jobs takes one agent per firing, and the scheduler, which never overlaps a job with
itself, fires it again once that run is done. A job here must never write a node its owner's
requests can write (the account, or the owner's root): a conflict at commit would run the whole
job again. That is why a portfolio is made when the owner connects their keys, and why the owner's
choice of paper trading reaches the portfolio through `agent_tick`, not from their request.

`_RUNNING` and `_CLAIMED` live in this process, so this assumes one server, as the deployment
does. After a restart, an agent whose run had not committed is run again; nothing it did was saved.
"""
import logging;
import threading;
import from datetime { datetime, timezone }
import from jaclang { JacRuntime as Jac }
import from accounts.store { all_accounts, credentials_of, demo_mode, has_required_keys, own_portfolio }
import from action.baselines { baselines_of }
import from models.accounts { AgentAccount }
import from models.graph { PortfolioMode, Run }
import from policy.store { personal_versions, current_of }
import from research.credentials { enter_credentials, leave_credentials }
import from run.guard { NEW_YORK, RunLimits, RunOutcome, daily_run, morning_window }
import from run.orchestration { orchestrate }
import from run.trading { TradingDeps, guarded_tick, run_for }

glob LOG: logging.Logger = logging.getLogger("trading_agent.agents");
glob _LOCK: threading.Lock = threading.Lock();
glob _RUNNING: dict[str, str] = {};
glob _CLAIMED: set[str] = set();

"""Do `work` as the agent's owner, with their keys, and come back to the super root. Everything
it writes belongs to the owner."""
def as_agent[T](account: AgentAccount, work: Callable[[], T]) -> T {
    found = credentials_of(account);
    ctx = Jac.get_context();
    system = str(ctx.system_root.id);
    ctx.set_user_root(account.owner_root);
    token = enter_credentials(found);
    try {
        return work();
    } finally {
        leave_credentials(token);
        ctx.set_user_root(system);
    }
}

"""True while a run for this owner is working in this process."""
def is_running(owner: str) -> bool {
    return owner in _RUNNING;
}

"""Claim `owner`'s run on `day` for this firing: True for exactly one caller, per day."""
def claim(owner: str, day: str) -> bool {
    with _LOCK {
        key = f"{day}:{owner}";
        if key in _CLAIMED {
            return False;
        }
        _CLAIMED.intersection_update({k for k in _CLAIMED if k.startswith(day)});
        _CLAIMED.add(key);
        return True;
    }
}

def release(owner: str, day: str) -> None {
    with _LOCK {
        _CLAIMED.discard(f"{day}:{owner}");
    }
}

"""True when `account` should run on `day`: it was asked to, or it is the morning window (run/guard.jac),
which is long enough for a server's later agents, three at a time and about half an hour each, to
start and still finish before the orders go out at 9:45. An agent whose keys are incomplete never
runs."""
def due(account: AgentAccount, day: str, local: datetime) -> bool {
    return has_required_keys(account) and (account.run_requested_day == day or morning_window(local));
}

"""The agent's run for `day`, if one is on record. Must run as the owner."""
def recorded_run(day: str) -> Run | None {
    portfolio = own_portfolio();
    return run_for(portfolio, day) if portfolio is not None else None;
}

"""The next agent due on `day`, claimed for the caller, or None. Oldest account first, so a
server at its limit serves agents in the order they joined."""
def next_due(day: str, local: datetime) -> AgentAccount | None {
    for account in sorted(all_accounts(), key=lambda (a: AgentAccount) { a.created_at; }) {
        if due(account, day, local) and account.owner_root not in _RUNNING and claim(account.owner_root, day) {
            try {
                if as_agent(account, lambda { recorded_run(day); }) is None {
                    return account;
                }
            } except Exception as e {
                # The account's keys no longer open; its settings page says so. Reconnecting them
                # the same day should still be able to start a run.
                release(account.owner_root, day);
                LOG.warning("agent run on %s skipped: %s", day, type(e).__name__);
            }
        }
    }
    return None;
}

"""One agent's morning pipeline under its owner's policy. Must run as the owner."""
def run_owner(day: str) -> RunOutcome | None {
    portfolio = own_portfolio();
    if portfolio is None {
        return None;
    }
    return daily_run(portfolio, day, orchestrate, RunLimits(), current_of(personal_versions()));
}

"""Run the next agent due, if any. The slots share this, so at most RUN_SLOTS agents run at once."""
def run_next_agent(now: datetime) -> str {
    if demo_mode() {
        return "";
    }
    local = now.astimezone(NEW_YORK);
    if local.weekday() >= 5 {
        return "";
    }
    day = local.date().isoformat();
    account = next_due(day, local);
    if account is None {
        return "";
    }
    owner = account.owner_root;
    with _LOCK {
        _RUNNING[owner] = day;
    }
    try {
        outcome = as_agent(account, lambda { run_owner(day); });
        status = outcome.status.value if outcome is not None else "no portfolio";
        LOG.info("%s an agent's run finished: %s", day, status);
        return status;
    } finally {
        with _LOCK {
            _RUNNING.pop(owner, None);
        }
    }
}

"""Everything due for the agent now: its owner's choice reaches the portfolio, then the day's
trading steps. Must run as the owner."""
def agent_tick(account: AgentAccount, now: datetime) -> list[str] {
    portfolio = own_portfolio();
    if portfolio is None {
        return [];
    }
    if baselines_of(portfolio) {
        wanted = PortfolioMode.AUTO if account.paper_trading else PortfolioMode.INSIGHT;
        if portfolio.mode != wanted {
            portfolio.mode = wanted;
        }
    }
    # Made fresh for each agent: a client holds its owner's keys.
    return guarded_tick(portfolio, now, TradingDeps(start_day=account.trading_start_day if account.paper_trading else ""));
}

"""One minute's trading steps for every agent. An agent mid-run waits: its run holds the
portfolio's graph until it commits."""
def tick_agents(now: datetime) {
    if demo_mode() {
        return;
    }
    for account in all_accounts() {
        if not has_required_keys(account) or is_running(account.owner_root) {
            continue;
        }
        try {
            as_agent(account, lambda { agent_tick(account, now); });
        } except Exception as e {
            LOG.warning("an agent's trading tick was skipped: %s", type(e).__name__);
        }
    }
}

# Fired every weekday minute, since an owner can ask for a run at any time. `due` decides.
@schedule(trigger=ScheduleTrigger.STATIC, cron="* * * * 0-4")
def agent_run_slot_1 {
    run_next_agent(datetime.now(timezone.utc));
}

@schedule(trigger=ScheduleTrigger.STATIC, cron="* * * * 0-4")
def agent_run_slot_2 {
    run_next_agent(datetime.now(timezone.utc));
}

@schedule(trigger=ScheduleTrigger.STATIC, cron="* * * * 0-4")
def agent_run_slot_3 {
    run_next_agent(datetime.now(timezone.utc));
}

"""The same hours as the team's trading job (run/jobs.jac)."""
@schedule(trigger=ScheduleTrigger.STATIC, cron="* 13-21 * * 0-4")
def agents_trading_job {
    tick_agents(datetime.now(timezone.utc));
}
