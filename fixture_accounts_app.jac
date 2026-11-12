"""The settings endpoints and an agent's scheduled work over a real server, for
accounts_api_tests.jac. `become_system` stands in for a static job, which runs on the super root."""
import os;
import from datetime { datetime, timezone }
import from jaclang { JacRuntime as Jac }
import accounts.api as accounts_api;
import accounts.store as store;
import from accounts.api { get_agent_settings, remove_agent_keys, save_agent_keys, set_paper_trading, start_my_run }
import from accounts.store { all_accounts, ensure_own_portfolio, my_account, own_portfolio }
import from models.accounts { AgentAccount, AgentReply, AgentSettings, KeysReply }
import from models.graph { Portfolio, Ran, Run, RunStatus, PortfolioMode }
import from research.credentials { ALPACA_KEY, user_key }
import from action.baselines { baselines_of }
import from run.agents { as_agent, due, is_running, next_due, tick_agents }
import from run.guard { NEW_YORK, RunSession }
import reports.worker as worker;
import from reports.api { catalog, request_report }
import from models.reports { ReportCatalog }
import from models.policy { Policy }
import from research.credentials { OPENROUTER_KEY }
import from research.collector { utc_now }
import from run.public { public }

glob report_keys_seen: list[str] = [];

"""Stands in for the research behind a report, and records the key that work would pay with."""
def record_report_key(_ticker: str, _day: str, _allowance: int, _policy: Policy = Policy(), _version: int = 0) -> RunSession {
    report_keys_seen.append(user_key(OPENROUTER_KEY));
    raise RuntimeError("recorded");
}

def stub_catalog(_team: Portfolio) -> ReportCatalog {
    found = catalog();
    assert found is not None;
    return found;
}

"""Offer one stock for reports, with the research behind a report replaced by `record_report_key`."""
def:priv open_reports -> str {
    public(root.shared ++> ReportCatalog(symbols=["AAPL"], trading_date="2026-11-09", refreshed_at=utc_now().isoformat(), generation_enabled=True, model_requests_left=1000));
    worker.refresh_catalog = stub_catalog;
    worker.analyze_report = record_report_key;
    return "ok";
}

"""As the static job would: become the super root and run one pass of the report worker."""
def:priv report_job_pass -> list[str] {
    ctx = Jac.get_context();
    ctx.set_user_root(str(ctx.system_root.id));
    worker.reports_job();
    return report_keys_seen;
}

def:priv set_admin(on: bool) -> str {
    setattr(store, "caller_is_admin", lambda -> bool { on; });
    setattr(accounts_api, "caller_is_admin", lambda -> bool { on; });
    return "ok";
}

def:priv set_env(name: str, value: str) -> str {
    os.environ[name] = value;
    return "ok";
}

def:priv owner_id -> str { return str(jid(root)); }

"""What the raw account holds, as the owner may read it, to prove what is stored."""
def:priv raw_account -> dict[str, object] {
    found = my_account();
    return {"sealed": found.sealed, "hints": found.hints, "requested": found.run_requested_day, "trading": found.paper_trading, "alpaca_account": found.alpaca_account} if found is not None else {};
}

"""Forget which Alpaca account the caller's keys open, as for an agent connected before that was
stored (accounts/sharing.jac)."""
def:priv forget_alpaca_account -> str {
    found = my_account();
    if found is not None {
        found.alpaca_account = "";
    }
    return "ok";
}

"""Every account a request by this caller can see."""
def:priv accounts_seen -> list[str] {
    return [a.owner_root for a in all_accounts()];
}

"""As a static job would: become the super root, find every account, then for each do something as
its owner. Reports which keys and root each owner's work saw, and leaves a run on its portfolio."""
def:priv job_work_as_owners -> list[dict[str, str]] {
    ctx = Jac.get_context();
    ctx.set_user_root(str(ctx.system_root.id));
    seen: list[dict[str, str]] = [];
    for account in all_accounts() {
        def work {
            portfolio = ensure_own_portfolio();
            portfolio +>:Ran():+> Run(run_date="2026-11-09", started_at="2026-11-09T12:30:00+00:00", status=RunStatus.NORMAL);
            seen.append({"owner": account.owner_root, "root": str(jid(root)), "alpaca": user_key(ALPACA_KEY)});
        }
        as_agent(account, work);
    }
    return seen;
}

"""The run dates on the caller's own portfolio."""
def:priv my_run_days -> list[str] {
    found = own_portfolio();
    if found is None {
        return [];
    }
    return [r.run_date for r in [found ->:Ran:->[?:Run]]];
}

def:priv job_due_days(day: str, iso_now: str) -> list[str] {
    ctx = Jac.get_context();
    caller = str(ctx.user_root.id);
    ctx.set_user_root(str(ctx.system_root.id));
    local = datetime.fromisoformat(iso_now).astimezone(NEW_YORK);
    found = [a.owner_root for a in all_accounts() if due(a, day, local)];
    ctx.set_user_root(caller);
    return found;
}

"""One minute of the trading job, on the super root as a static job is. It stays there, since a
write under a job must commit from the super root."""
def:priv job_tick(iso_now: str) -> str {
    ctx = Jac.get_context();
    ctx.set_user_root(str(ctx.system_root.id));
    tick_agents(datetime.fromisoformat(iso_now));
    return "ok";
}

"""The caller's portfolio, as its owner sees it."""
def:priv my_portfolio_state -> dict[str, object] {
    found = own_portfolio();
    if found is None {
        return {};
    }
    return {"mode": found.mode.value, "cash": found.starting_cash, "baselines": len(baselines_of(found))};
}
