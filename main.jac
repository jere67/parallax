import from models.health { Health }
import from run.health { health }
import from run.jobs { morning_job, trading_job }
import from dashboard.demo { demo_job }
import from dashboard.api { get_decision_trail, get_performance, get_portfolio, get_run, list_runs, refresh_job }
import from models.views { PerformanceView, PortfolioView, RunSummary, RunView, TrailView }

import "./dashboard/theme.css";
import from .dashboard.App { App }

def:pub app -> JsxElement {
    <App/>
}
