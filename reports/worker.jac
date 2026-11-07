"""One background report at a time. Only plain values cross the worker boundary.

Claims commit before a worker is launched. The next tick stores the result in a short
transaction; restarting a server leaves a visible failed request after the lease expires.
"""
import os;
import time;
import uuid;
import from concurrent.futures { Future, ThreadPoolExecutor }
import from datetime { timedelta }
import from accounts.store { all_accounts, credentials_of, has_required_keys }
import from accounts.vault { VaultError }
import from agents.models { FREE_REQUESTS_PER_DAY, LIMITER, REQUEST_BUDGET, RequestBudget, models_disabled, provider_requests_left }
import from agents.orchestrator { Committee }
import from jaclang.byllm.types { IterationAction, IterationContext }
import from analysis.policy { consensus_config }
import from models.graph { Coverage, Covers, CoverageReason, InsightCard, Portfolio, PortfolioMode, Published, Ran, Run, RunStatus }
import from models.policy { Policy }
import from models.reports { ReportCatalog, ReportJob }
import from models.users { ReportStatus }
import from research.alpaca { MarketDay, market_calendar }
import from research.collector { RunBudget, parse_utc, run_budget, utc_now }
import from research.credentials { ALPACA_KEY, Credentials, enter_credentials, leave_credentials }
import from research.wikipedia { constituents }
import from run.guard { NEW_YORK, RunLimits, RunSession, record_run, stored_requests, team_portfolio }
import from run.research { collect_pass }
import from run.agents { is_running }
import from run.public { public }
import from reports.api { RESERVE, catalog, job_for }

glob WORKER: str = str(uuid.uuid4());
glob POOL: ThreadPoolExecutor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="reports");
glob FUTURES: dict[str, Future[RunSession]] = {};
glob REPORT_LIMIT: int = 80;

"""Same committee, without submit_decisions or any execution tool, on the requester's `keys` (the
server's own when None). A report is shared with everyone who asks for that stock that day, so it
decides under the default policy, and each reader's page says what their own makes of it."""
def generate(ticker: str, day: str, allowance: int, policy: Policy = Policy(), version: int = 0, keys: Credentials | None = None) -> RunSession {
    budget = RequestBudget(remaining=allowance, deadline=time.monotonic() + 600.0);
    token = REQUEST_BUDGET.set(budget);
    scope = enter_credentials(keys) if keys is not None else None;
    try { return analyze_report(ticker, day, allowance, policy, version); }
    finally {
        if scope is not None { leave_credentials(scope); }
        REQUEST_BUDGET.reset(token);
    }
}

def analyze_report(ticker: str, day: str, allowance: int, policy: Policy = Policy(), version: int = 0) -> RunSession {
    collection = collect_pass(day, [], requested_ticker=ticker);
    s = RunSession(run_day=day, collection=collection, holdings={}, config=consensus_config(policy),
        limits=RunLimits(deadline_s=600.0, react_iterations=6), run_requests=allowance, policy=policy, policy_version=version);
    s.write_macro();
    def stop(_ctx: IterationContext) -> IterationAction {
        return IterationAction.ABORT_WITH_SUMMARY if s.overdue() or s.requests_left() < 2 else IterationAction.CONTINUE;
    }
    try {
        committee = Committee(tools=[s.get_run_context, s.dispatch_research, s.request_followup, s.flag_ticker, s.convene_panel, s.write_run_summary], on_iteration=stop, max_iterations=6, report_mode=True);
        committee.run(day, ticker);
    } except Exception {
        # Deterministic phase ordering reuses the same safe research/panel methods.
        s.actions.append("Report Orchestrator unavailable; completing in fixed order.");
    }
    s.dispatch_research([ticker], ["market", "fundamentals", "news"]);
    s.convene_panel([ticker]);
    if ticker not in s.analyses {
        raise RuntimeError("The analysis could not finish. Please try on the next trading day.");
    }
    return s;
}

def start(job_id: str, ticker: str, day: str, allowance: int, keys: Credentials | None) {
    FUTURES[job_id] = POOL.submit(generate, ticker, day, allowance, Policy(), 0, keys);
}

"""The keys job `j` runs on: its requester's, or the server's own (None) when the admin's agent
asked. Raises VaultError or KeyError when the requester's can no longer be opened."""
def job_keys(j: ReportJob) -> Credentials | None {
    if not j.requested_by {
        return None;
    }
    for account in all_accounts() {
        if account.owner_root == j.requested_by and has_required_keys(account) {
            return credentials_of(account);
        }
    }
    raise KeyError("the requester's keys are not connected");
}

"""Read the market calendar with the server's key, or the first connected agent's on a server with
none of its own, since the calendar is the same for everyone."""
def read_sessions(start_day: str, end_day: str, budget: RunBudget) -> list[MarketDay] {
    if not os.environ.get(ALPACA_KEY, "") {
        for account in all_accounts() {
            if has_required_keys(account) {
                scope = enter_credentials(credentials_of(account));
                try { return market_calendar(start_day, end_day, budget); }
                finally { leave_credentials(scope); }
            }
        }
    }
    return market_calendar(start_day, end_day, budget);
}

def save_result(j: ReportJob, s: RunSession) {
    # Separate insight portfolio: trading jobs select only the named team portfolio.
    p = public(root.shared ++> Portfolio(name=f"report:{j.trading_date}:{j.ticker}", mode=PortfolioMode.INSIGHT, starting_cash=0.0, opened_at=j.created_at));
    r = public(p +>:Ran():+> Run(run_date=j.trading_date, started_at=j.started_at));
    record_run(p, r, s, RunStatus.NORMAL);
    for cov in [r ->:Covers:->[?:Coverage]] {
        cov.reason = CoverageReason.USER_REQUEST;
        cards = [card for card in [cov ->:Published:->[?:InsightCard]]];
        if cards { j.card = cards[0]; }
    }
    if j.card is None { raise RuntimeError("No insight card was produced."); }
    j.model_requests = r.model_requests;
    j.status = ReportStatus.READY;
    j.finished_at = utc_now().isoformat();
}

"""Copy already-published cards into the shared report cache without model calls."""
def reuse_daily(team: Portfolio, day: str) {
    for r in [team ->:Ran:->[?:Run]] {
        if r.run_date != day { continue; }
        for cov in [r ->:Covers:->[?:Coverage]] {
            cards = [card for card in [cov ->:Published:->[?:InsightCard]]];
            if not cards { continue; }
            j = job_for(cov.ticker, day);
            if j is None {
                j = public(root.shared ++> ReportJob(ticker=cov.ticker, trading_date=day, created_at=utc_now().isoformat(), charged=False));
            }
            if j.status != ReportStatus.RUNNING {
                j.card = cards[0];
                j.status = ReportStatus.READY;
                j.demo = team.demo;
                j.finished_at = utc_now().isoformat();
            }
        }
    }
}

"""Refresh only metadata here; constituents and calendar are cached by SourceClient."""
def refresh_catalog(team: Portfolio) -> ReportCatalog {
    c = catalog();
    if c is None { c = public(root.shared ++> ReportCatalog()); }
    now = utc_now();
    c.generation_enabled = False;
    if team.demo {
        days = [r.run_date for r in [team ->:Ran:->[?:Run]]];
        c.trading_date = max(days) if days else "";
        c.symbols = sorted(set(cov.ticker for r in [team ->:Ran:->[?:Run]] for cov in [r ->:Covers:->[?:Coverage]]));
        c.demo = True;
        c.refreshed_at = now.isoformat();
        return c;
    }
    try {
        budget = run_budget();
        members = constituents(budget);
        today = now.astimezone(NEW_YORK).date();
        sessions = read_sessions((today - timedelta(days=10)).isoformat(), today.isoformat(), budget);
        if not sessions { return c; }
        c.symbols = sorted(m.symbol for m in members);
        c.trading_date = max(d.day for d in sessions);
        c.refreshed_at = now.isoformat();
        provider_left = provider_requests_left();
        used = max(stored_requests(team, now.date().isoformat()), LIMITER.sent_by_day.get(now.date().isoformat(), 0));
        # Persisted report usage survives process restarts. Conservatively reserve the
        # full allowance for unsuccessful/interrupted jobs whose usage is unknown.
        jobs = [j for j in [root.shared -->[?:ReportJob]] if j.created_at[:10] == now.date().isoformat() and j.charged and j.status != ReportStatus.PENDING];
        report_used = sum(j.model_requests if j.status == ReportStatus.READY else REPORT_LIMIT for j in jobs);
        c.model_requests_left = max(0, min(FREE_REQUESTS_PER_DAY - stored_requests(team, now.date().isoformat()) - report_used, FREE_REQUESTS_PER_DAY - used, provider_left if provider_left is not None else 0));
        active_morning = any(r.status == RunStatus.RUNNING for r in [team ->:Ran:->[?:Run]]);
        # Only what the server's own key pays for depends on its allowance.
        if active_morning { c.model_requests_left = 0; }
        c.generation_enabled = not models_disabled();
    } except Exception {
        # Fail closed; users retain access to cached results and see cache-only mode.
        c.generation_enabled = False;
    }
    return c;
}

def forget(job_id: str) -> Callable[[], object] {
    return lambda { FUTURES.pop(job_id, None); };
}

@schedule(trigger=ScheduleTrigger.STATIC, cron="* * * * *")
def reports_job {
    team = team_portfolio();
    c = refresh_catalog(team);
    if c.trading_date { reuse_daily(team, c.trading_date); }
    jobs = sorted([j for j in [root.shared -->[?:ReportJob]]], key=lambda (j: ReportJob) { j.created_at; });
    now = utc_now();
    for j in jobs {
        if j.status != ReportStatus.RUNNING { continue; }
        f = FUTURES.get(jid(j));
        if f is not None and f.done() {
            try { save_result(j, f.result()); }
            except Exception { j.status = ReportStatus.FAILED; j.error = "Research could not complete. No trade was placed."; j.finished_at = now.isoformat(); }
            # Keep the future until commit; a transaction retry must not lose its result.
            key = jid(j);
            on_commit(forget(key));
        } elif now - parse_utc(j.started_at) > timedelta(minutes=15) {
            j.status = ReportStatus.FAILED;
            j.error = "The report worker stopped or exceeded its time limit. No trade was placed.";
            j.finished_at = now.isoformat();
        } else { return; }
    }
    if any(not f.done() for f in FUTURES.values()) { return; }
    for j in jobs {
        if j.status != ReportStatus.PENDING { continue; }
        if j.trading_date != c.trading_date {
            j.status = ReportStatus.FAILED; j.error = "This queued request expired at the next trading date.";
            continue;
        }
        if not c.generation_enabled { return; }
        if not j.requested_by and c.model_requests_left < RESERVE + REPORT_LIMIT { continue; }
        if is_running(j.requested_by) { continue; }
        try {
            keys = job_keys(j);
        } except (KeyError, VaultError) {
            j.status = ReportStatus.FAILED;
            j.error = "The keys this report needs are no longer connected. No trade was placed.";
            continue;
        }
        j.status = ReportStatus.RUNNING;
        j.started_at = now.isoformat();
        j.worker = WORKER;
        key = jid(j); ticker = j.ticker; day = j.trading_date;
        on_commit(lambda { start(key, ticker, day, REPORT_LIMIT, keys); });
        return;
    }
}
