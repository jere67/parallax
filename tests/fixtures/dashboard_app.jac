"""The dashboard's endpoints over a team graph seeded the way the scheduled job writes it, for
dashboard_tests.jac."""
import from action.fixtures { Call, finished_run }
import from dashboard.api { get_decision_trail, get_performance, get_portfolio, get_run, list_runs }
import from models.graph { DailyMark, Marked, Portfolio, PortfolioMode, TradeAction }
import from models.views { PerformanceView, PortfolioView, RunSummary, RunView, TrailView }
import from run.public { public }

"""Write a public team portfolio with one run, one decision, and one mark."""
def:priv seed_team_graph -> str {
    team = public(root.shared ++> Portfolio(name="team", mode=PortfolioMode.AUTO, starting_cash=100000.0, opened_at="2026-10-21T13:00:00+00:00"));
    finished_run(team, "2026-10-21", [Call(ticker="AAPL", action=TradeAction.BUY, conviction=0.6)]);
    public(team +>:Marked():+> DailyMark(day="2026-10-21", equity=100500.0, cash=95000.0, positions_value=5500.0, peak_equity=100500.0, marked_at="2026-10-21T20:30:00+00:00"));
    return "ok";
}
