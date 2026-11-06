"""The policy endpoints over a seeded team run, for policy_api_tests.jac. `set_admin` stands in
for the admin role, which comes from the server's user store; the Playwright suite signs in as
the real admin."""
import policy.api as policy_api;
import from action.fixtures { Call, finished_run }
import from models.graph { Concluded, ConsensusResult, Coverage, Covers, Portfolio, PortfolioMode, TradeAction }
import from policy.api { get_policy_catalog, get_policy_workspace, get_team_policy, preview_policy, restore_policy_version, save_policy_version }
import from run.public { public }

def:priv set_admin(on: bool) -> str {
    setattr(policy_api, "caller_is_admin", lambda -> bool { on; });
    return "ok";
}

def:priv seed_policy_run -> str {
    team = public(root.shared ++> Portfolio(name="team", mode=PortfolioMode.AUTO, starting_cash=100000.0, opened_at="2026-10-21T13:00:00+00:00"));
    run = finished_run(team, "2026-11-03", [Call(ticker="AAPL", action=TradeAction.NO_ACTION, conviction=0.2), Call(ticker="MSFT", action=TradeAction.BUY, conviction=0.4)]);
    scores = {"AAPL": (0.3, 0.45), "MSFT": (0.5, 0.8)};
    for cov in [run ->:Covers:->[?:Coverage]] {
        (score, agreement) = scores[cov.ticker];
        public(cov +>:Concluded():+> ConsensusResult(ticker=cov.ticker, score=score, agreement=agreement, ci_low=score - 0.1, ci_high=score + 0.1, draft_action=TradeAction.BUY if agreement >= 0.5 else TradeAction.NO_ACTION));
    }
    return "ok";
}
