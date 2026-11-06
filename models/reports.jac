"""Shared, non-personal report queue; personal history stays on each user's root."""
import from models.users { ReportStatus }
import from models.graph { InsightCard }
import from models.policy_views { ReplayRow }

node ReportCatalog {
    has symbols: list[str] = [], trading_date: str = "", refreshed_at: str = "";
    has generation_enabled: bool = False, model_requests_left: int = 0, demo: bool = False;
}

node ReportJob {
    has ticker: str, trading_date: str, created_at: str;
    has status: ReportStatus = ReportStatus.PENDING, error: str = "",
        started_at: str = "", finished_at: str = "", worker: str = "",
        card: InsightCard | None = None, demo: bool = False,
        charged: bool = True, model_requests: int = 0;
}

obj ReportView {
    has id: str, ticker: str, trading_date: str, requested_at: str, status: str;
    has error: str = "", card: InsightCard | None = None, demo: bool = False,
        my_policy: ReplayRow | None = None, my_policy_version: int = 0;
}

obj ReportsView {
    has reports: list[ReportView] = [], symbols: list[str] = [], trading_date: str = "",
        remaining: int = 0, global_remaining: int = 0, cache_only: bool = True,
        message: str = "", demo: bool = False;
}

obj ReportReply {
    has accepted: bool, message: str;
    has item: ReportView | None = None;
}
