"""The demo account over a real server, for demo_account_tests.jac. `demo_tick` stands in for a
minute of the demo jobs, which run on the super root."""
import from datetime { date }
import from jaclang { JacRuntime as Jac }
import from jaclang.server.identity.user_manager { UserManager }
import from accounts.demo { ensure_demo_user, open_demo, seed_demo_account }
import from accounts.api { get_agent_settings, remove_agent_keys, save_agent_keys, set_asset_classes, set_paper_trading, start_my_run }
import from dashboard.api { get_performance, get_portfolio, list_runs }
import from policy.api { get_my_policy, save_policy_version }
import from policy.chat { get_policy_chat, send_policy_message }
import from reports.api { list_reports, request_report }
import from models.accounts { AgentReply, AgentSettings, DemoSignIn, KeysReply }
import from models.policy_views { ChatState, PolicyDoc, PolicySaveReply }
import from models.reports { ReportReply, ReportsView }
import from models.views { PerformanceView, PortfolioView, RunSummary }

"""One minute of the demo jobs: one step toward the demo user, then the history unless `seed` is
off. It stays on the super root, since a write under a job must commit from there."""
def:priv demo_tick(today: str, seed: bool = True) -> str {
    ctx = Jac.get_context();
    ctx.set_user_root(str(ctx.system_root.id));
    note = ensure_demo_user(UserManager(base_path="."));
    if seed {
        seed_demo_account(date.fromisoformat(today));
    }
    return note;
}

"""How many nodes hang off the caller's own root: what their requests kept."""
def:priv own_root_nodes -> int {
    return len([root -->]);
}
