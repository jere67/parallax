"""Fast authenticated admission. No collector, model, broker, or scheduler work in HTTP.

Read/check/create happens in the server's serializable request transaction, so racing
submissions cannot spend the last quota slot twice or create duplicate ticker/day jobs.
"""
import os;
import from datetime { timedelta }
import from accounts.store { caller_is_admin, has_required_keys, my_account }
import from models.policy { Policy }
import from models.users { ReportRequest, ReportStatus }
import from models.reports { ReportCatalog, ReportJob, ReportView, ReportsView, ReportReply }
import from policy.replay { replay_card }
import from policy.store { current_of, my_scope, versions_of }
import from research.collector { utc_now, parse_utc }
import from run.public { public }

glob RESERVE: int = 150;

def quota(name: str, fallback: int) -> int {
    try { return max(0, int(os.environ.get(name, str(fallback)))); }
    except ValueError { return 0; }
}

def catalog -> ReportCatalog | None {
    items = [c for c in [root.shared -->[?:ReportCatalog]]];
    return items[0] if items else None;
}

def job_for(ticker: str, day: str) -> ReportJob | None {
    for j in [root.shared -->[?:ReportJob]] {
        if j.ticker == ticker and j.trading_date == day { return j; }
    }
    return None;
}

"""A request as its owner sees it. `mine` is the owner's policy and version: from their first
saved version on, a finished card also says what that policy makes of it."""
def report_view(r: ReportRequest, mine: tuple[Policy, int]) -> ReportView {
    j = job_for(r.ticker, r.trading_date);
    card = j.card if j else None;
    (policy, version) = mine;
    return ReportView(id=jid(r), ticker=r.ticker, trading_date=r.trading_date,
        requested_at=r.requested_at, status=j.status.value if j else r.status.value,
        error=j.error if j else r.error, card=card, demo=j.demo if j else False,
        my_policy=replay_card(policy, card) if card is not None and version > 0 else None,
        my_policy_version=version);
}

"""True when a new report can run on the caller's keys: their own, or for the admin's agent the
server's, with its morning run's share held back."""
def can_request_new(c: ReportCatalog) -> bool {
    if caller_is_admin() {
        return c.model_requests_left >= RESERVE;
    }
    account = my_account();
    return account is not None and has_required_keys(account);
}

def:protect list_reports -> ReportsView {
    c = catalog();
    mine = [r for r in [root -->[?:ReportRequest]]];
    policy = current_of(versions_of(my_scope()));
    view = ReportsView(reports=[report_view(r, policy) for r in sorted(mine, key=lambda (r: ReportRequest) { r.requested_at; }, reverse=True)][:100]);
    if c is None {
        view.message = "The report catalog is warming up. Try again shortly.";
        return view;
    }
    day = c.trading_date;
    view.symbols = c.symbols;
    view.trading_date = day;
    view.demo = c.demo;
    view.remaining = max(0, quota("REPORTS_PER_USER_DAY", 3) - len([r for r in mine if r.trading_date == day and r.charged]));
    jobs = [j for j in [root.shared -->[?:ReportJob]] if j.trading_date == day and j.charged];
    view.global_remaining = max(0, quota("REPORTS_GLOBAL_DAY", 15) - len(jobs));
    fresh = bool(c.refreshed_at) and utc_now() - parse_utc(c.refreshed_at) < timedelta(minutes=5);
    can_pay = can_request_new(c);
    view.cache_only = not fresh or not c.generation_enabled or not can_pay;
    if not can_pay and c.generation_enabled {
        view.message = "Connect your Alpaca and OpenRouter keys in Settings to request new reports. Reports already written are still available.";
    } elif view.cache_only {
        view.message = "Only existing reports are available while new analysis is unavailable or the model budget is low.";
    }
    return view;
}

def:protect get_report(request_id: str) -> ReportView | None {
    # Resolve only from the caller's own history, never an unchecked jobj(id).
    for r in [root -->[?:ReportRequest]] {
        if jid(r) == request_id { return report_view(r, current_of(versions_of(my_scope()))); }
    }
    return None;
}

def:protect request_report(ticker: str) -> ReportReply {
    symbol = ticker.strip().upper().replace(".", "-");
    c = catalog();
    if c is None or symbol not in c.symbols {
        return ReportReply(accepted=False, message="Choose a stock from the current S&P 500 list.");
    }
    for r in [root -->[?:ReportRequest]] {
        if r.ticker == symbol and r.trading_date == c.trading_date {
            return ReportReply(accepted=True, message="Your existing request is shown below.", item=report_view(r, current_of(versions_of(my_scope()))));
        }
    }
    j = job_for(symbol, c.trading_date);
    charged = j is None;
    if charged {
        limits = list_reports();
        if limits.cache_only or limits.remaining == 0 or limits.global_remaining == 0 {
            return ReportReply(accepted=False, message="New-report quota or model capacity is unavailable. Existing reports remain accessible.");
        }
        j = public(root.shared ++> ReportJob(ticker=symbol, trading_date=c.trading_date, created_at=utc_now().isoformat(), demo=c.demo, requested_by="" if caller_is_admin() else str(jid(root))));
    }
    r = root ++> ReportRequest(ticker=symbol, trading_date=c.trading_date, requested_at=utc_now().isoformat(), charged=charged);
    return ReportReply(accepted=True, message="Report requested.", item=report_view(r, current_of(versions_of(my_scope()))));
}
