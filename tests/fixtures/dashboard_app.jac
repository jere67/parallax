"""The dashboard's endpoints over a team graph seeded the way the scheduled job writes it, for
dashboard_tests.jac."""
import accounts.store as store;
import from action.fixtures { Call, finished_run }
import from dashboard.api { get_decision_trail, get_performance, get_portfolio, get_run, list_runs }
import from dashboard.news { get_news_feed, get_news_story }
import from models.agents { Domain, Evidence, ResearchReport, Stance }
import from models.graph { Coverage, Covers, DailyMark, Marked, Portfolio, PortfolioMode, Researched, ResearchRecord, TradeAction }
import from models.views { NewsFeed, NewsStory, PerformanceView, PortfolioView, RunSummary, RunView, TrailView }
import from run.public { public }

"""Stands in for the admin role, which comes from the server's user store."""
def:priv set_admin(on: bool) -> str {
    setattr(store, "is_admin_root", lambda (_users: object, _caller: str) -> bool { on; });
    store._ROLES.clear();
    return "ok";
}

"""Write a public team portfolio with one run, one decision, and one mark."""
def:priv seed_team_graph -> str {
    team = public(root.shared ++> Portfolio(name="team", mode=PortfolioMode.AUTO, starting_cash=100000.0, opened_at="2026-10-21T13:00:00+00:00"));
    run = finished_run(team, "2026-10-21", [Call(ticker="AAPL", action=TradeAction.BUY, conviction=0.6)]);
    for cov in [run ->:Covers:->[?:Coverage]] {
        public(cov +>:Researched():+> ResearchRecord(
            ticker="AAPL",
            domain=Domain.NEWS,
            as_of="2026-10-21T13:00:00+00:00",
            model="mock",
            body=ResearchReport(
                summary="Apple raised its guidance for the year: sales rose 12%.",
                view=Stance.BUY,
                confidence=0.7,
                evidence=[Evidence(claim="Guidance rose.", source_url="https://example.com/apple", published="2026-10-20")]
            )
        ));
    }
    public(team +>:Marked():+> DailyMark(day="2026-10-21", equity=100500.0, cash=95000.0, positions_value=5500.0, peak_equity=100500.0, marked_at="2026-10-21T20:30:00+00:00"));
    return "ok";
}
