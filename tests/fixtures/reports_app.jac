import from reports.api { request_report, list_reports, get_report }
import from models.reports { ReportCatalog, ReportJob }
import from models.users { ReportStatus }
import from research.collector { utc_now }
import from run.public { public }

def:priv seed_report_catalog -> str {
    public(root.shared ++> ReportCatalog(symbols=["AAPL", "MSFT", "NVDA", "AMZN", "BRK-B"], trading_date="2026-11-02", refreshed_at=utc_now().isoformat(), generation_enabled=True, model_requests_left=1000));
    return "ok";
}

def:priv make_cache_only -> str {
    for c in [root.shared -->[?:ReportCatalog]] { c.generation_enabled = False; }
    public(root.shared ++> ReportJob(ticker="BRK-B", trading_date="2026-11-02", created_at=utc_now().isoformat(), status=ReportStatus.READY, charged=False));
    return "ok";
}
