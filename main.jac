import from reports.worker { reports_job }
import from reports.api { request_report, list_reports, get_report }
import from policy.api { get_policy_catalog, get_policy_workspace, get_team_policy, preview_policy, restore_policy_version, save_policy_version }
import from models.health { Health }
import from run.health { health }
import from run.jobs { morning_job, trading_job }
import from run.manual { manual_run_job, start_morning_run }
import from dashboard.demo { demo_job }
import from dashboard.api { get_decision_trail, get_performance, get_portfolio, get_run, list_runs, refresh_job }
import from dashboard.display { chart_points, money, percent, ratio }
import from models.views { PerformanceView, PortfolioView, RunSummary, RunView, TrailView }
import from models.policy_views { PolicyCatalog, PolicyDoc, PolicySaveReply, PolicyWorkspace, ReplayView }

import "./dashboard/theme.css";
import from .dashboard.App { App }

def:pub app -> JsxElement {
    <App/>
}
