"""The morning run with the Orchestrator at the wheel (TDD §4): the Run Guard's `daily_run`
with the Orchestrator as its driver, on the team portfolio.

The Orchestrator's tools are the run session's own methods, so every limit it meets is the
one the fallback meets. Its loop stops with a summary when the run's request budget is down
to the reserve for that summary, or the run's deadline has passed; the Run Guard then
finishes whatever is left in fixed order and marks the run fallback.
"""
import from datetime { datetime, timezone }
import from jaclang.byllm.types { IterationAction, IterationContext }
import from agents.orchestrator { Committee }
import from policy.store { team_policy }
import from models.graph { RunStatus }
import from run.attempts { begin, finish, forget, working }
import from run.guard { RunLimits, RunOutcome, RunSession, daily_run, team_portfolio, trading_date_now }

# Requests the loop keeps back for its own closing summary.
glob SUMMARY_RESERVE: int = 2;

"""Drive `s` with the Orchestrator and return its closing summary."""
def orchestrate(s: RunSession) -> str {
    def stop_when_spent(ctx: IterationContext) -> IterationAction {
        if s.requests_left() <= SUMMARY_RESERVE or s.overdue() {
            s.actions.append(f"orchestrator stopped at iteration {ctx.iteration}: {'deadline passed' if s.overdue() else 'request budget spent'}");
            return IterationAction.ABORT_WITH_SUMMARY;
        }
        return IterationAction.CONTINUE;
    }
    committee = Committee(
        tools=[s.get_run_context, s.dispatch_research, s.request_followup, s.flag_ticker, s.convene_panel, s.submit_decisions, s.write_run_summary],
        on_iteration=stop_when_spent,
        max_iterations=s.limits.react_iterations
    );
    return committee.run(s.run_day, ", ".join(s.tickers()));
}

"""The team's morning run for `run_day` (today in New York by default), under the team policy
in force, stopping its model work at `cutoff` when that comes before its deadline. `rerun` lets
it run a day whose run failed before deciding anything (run/guard.jac, `rerunnable`). The run
is noted in run/attempts.jac from its start to the end of its work, so the trading tick waits
for it and a run the server cannot save is still recorded."""
def morning_run(run_day: str = "", cutoff: datetime | None = None, rerun: bool = False) -> RunOutcome {
    day = run_day or trading_date_now();
    if working(day) {
        return RunOutcome(run_day=day, status=RunStatus.SKIPPED, note=f"the run for {day} is already working");
    }
    begin(day, datetime.now(timezone.utc));
    try {
        outcome = daily_run(team_portfolio(), day, orchestrate, RunLimits(), team_policy(), cutoff, rerun);
    } except Exception {
        # `daily_run` never raises once it has claimed the day, so nothing was written: forget
        # the attempt and let the schedule's next firing try again, as before #240.
        forget(day);
        raise;
    }
    if outcome.run is None or outcome.status == RunStatus.SKIPPED {
        forget(day);
    } else {
        finish(day, datetime.now(timezone.utc), outcome.status.value, outcome.run.summary);
    }
    return outcome;
}

"""The daily pipeline as a walker (TDD §3, code sketch). It is not an endpoint: main.jac does
not import it, and only the scheduled job starts a run (TDD §14, unauthorized run triggers)."""
walker DailyRun {
    has run_day: str = "";

    can start with Root entry {
        outcome = morning_run(self.run_day);
        report {"run_day": outcome.run_day, "status": outcome.status.value, "note": outcome.note};
    }
}
