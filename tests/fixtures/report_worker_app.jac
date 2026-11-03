import reports.worker as worker;
import from reports.api { request_report, list_reports, get_report, catalog }
import from reports.worker { reports_job, save_result, reuse_daily }
import from models.reports { ReportCatalog, ReportJob }
import from models.users { ReportStatus }
import from models.graph { Portfolio, Sent, Run, Ran }
import from research.collector { utc_now }
import from run.guard { RunSession }
import from run.stubs { Stubs, collection }
import from analysis.consensus { ConsensusConfig }
import from run.guard { RunLimits }
import from run.public { public }

def fake_refresh(_team: Portfolio) -> ReportCatalog {
    c = catalog();
    assert c is not None;
    return c;
}

def fake_generate(ticker: str, day: str, allowance: int) -> RunSession {
    if ticker == "FAIL" { raise RuntimeError("secret-provider-detail"); }
    stubs = Stubs(symbols=[ticker]);
    stubs.install();
    try {
        s = RunSession(run_day=day, collection=collection([ticker], [], day), holdings={}, config=ConsensusConfig(), limits=RunLimits(), run_requests=allowance);
        s.write_macro();
        s.dispatch_research([ticker], ["market", "fundamentals", "news"]);
        s.convene_panel([ticker]);
        return s;
    } finally { stubs.restore(); }
}

def:priv setup_worker -> str {
    public(root.shared ++> ReportCatalog(symbols=["AAPL", "FAIL"], trading_date="2026-10-16", refreshed_at=utc_now().isoformat(), generation_enabled=True, model_requests_left=1000));
    worker.refresh_catalog = fake_refresh;
    worker.generate = fake_generate;
    return "ok";
}

def:priv tick_worker -> str { reports_job(); return "ok"; }

def:priv order_count -> int {
    return sum(len([p ->:Sent:->]) for p in [root.shared -->[?:Portfolio]]);
}

def:priv abandoned_job -> str {
    public(root.shared ++> ReportJob(ticker="FAIL", trading_date="2026-10-16", created_at=utc_now().isoformat(), status=ReportStatus.RUNNING, started_at="2026-01-01T00:00:00+00:00", worker="previous-process"));
    return "ok";
}
