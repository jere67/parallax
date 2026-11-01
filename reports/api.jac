"""Fast authenticated admission. No collector, model, broker, or scheduler work in HTTP.

Read/check/create happens in the server's serializable request transaction, so racing
submissions cannot spend the last quota slot twice or create duplicate ticker/day jobs.
"""
import os;
import from datetime { timedelta }
import from models.users { ReportRequest, ReportStatus }
import from models.reports { ReportCatalog, ReportJob, ReportView, ReportsView, ReportReply }
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

def report_view(r: ReportRequest) -> ReportView {
    j = job_for(r.ticker, r.trading_date);
    return ReportView(id=jid(r), ticker=r.ticker, trading_date=r.trading_date,
        requested_at=r.requested_at, status=j.status.value if j else r.status.value,
        error=j.error if j else r.error, card=j.card if j else None, demo=j.demo if j else False);
}

def:priv list_reports -> ReportsView {
    c = catalog();
    mine = [r for r in [root -->[?:ReportRequest]]];
    view = ReportsView(reports=[report_view(r) for r in sorted(mine, key=lambda (r: ReportRequest) { r.requested_at; }, reverse=True)][:100]);
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
    view.cache_only = not fresh or not c.generation_enabled or c.model_requests_left < RESERVE;
    if view.cache_only { view.message = "Only existing reports are available while new analysis is unavailable or the model budget is low."; }
    return view;
}

def:priv get_report(request_id: str) -> ReportView | None {
    # Resolve only from the caller's own history, never an unchecked jobj(id).
    for r in [root -->[?:ReportRequest]] {
        if jid(r) == request_id { return report_view(r); }
    }
    return None;
}

def:priv request_report(ticker: str) -> ReportReply {
    symbol = ticker.strip().upper().replace(".", "-");
    c = catalog();
    if c is None or symbol not in c.symbols {
        return ReportReply(accepted=False, message="Choose a stock from the current S&P 500 list.");
    }
    for r in [root -->[?:ReportRequest]] {
        if r.ticker == symbol and r.trading_date == c.trading_date {
            return ReportReply(accepted=True, message="Your existing request is shown below.", item=report_view(r));
        }
    }
    j = job_for(symbol, c.trading_date);
    charged = j is None;
    if charged {
        limits = list_reports();
        if limits.cache_only or limits.remaining == 0 or limits.global_remaining == 0 {
            return ReportReply(accepted=False, message="New-report quota or model capacity is unavailable. Existing reports remain accessible.");
        }
        j = public(root.shared ++> ReportJob(ticker=symbol, trading_date=c.trading_date, created_at=utc_now().isoformat(), demo=c.demo));
    }
    r = root ++> ReportRequest(ticker=symbol, trading_date=c.trading_date, requested_at=utc_now().isoformat(), charged=charged);
    return ReportReply(accepted=True, message="Report requested.", item=report_view(r));
}
