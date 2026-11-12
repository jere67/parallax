"""Scheduled jobs (TDD §4, daily schedule).

The scheduler reads cron expressions in UTC with day 0 as Monday, so the morning job fires every
minute through the UTC hours that hold the morning window (run/guard.jac, 7:30 to 9:15 a.m. New
York time) at both the EDT and EST offsets, and proceeds only inside that window while the team
portfolio has no run for the day. So the run starts at 7:30 on a server that is up, and at the
first minute after it wakes or starts on one that was asleep or down then. The run claims its date
before any work, so a second firing does nothing (TDD §4, idempotency); a day whose run failed is
not run again. A static job runs as the system user, which reaches root.shared (checked by firing
a probe job under `jac run`).

The trading job ticks every minute through the trading day's UTC hours at both offsets, and
the tick decides from New York time and the market calendar which Action step is due
(run/trading.jac). It trades only when the team portfolio is in auto mode. Neither job touches
a team portfolio that holds the local demo history (dashboard/demo.jac).
"""
import from datetime { datetime, timezone }
import from models.graph { Portfolio }
import from run.guard { NEW_YORK, find_team_portfolio, morning_window, team_portfolio }
import from run.orchestration { morning_run }
import from run.trading { run_for, team_trading_tick }

"""True when the team's morning run should start at `local` (New York time): inside the morning
window, with no run on record for the day. The record check keeps the firings after the run cheap,
since the run's own claim would only be reached after preflight's network calls."""
def morning_due(portfolio: Portfolio | None, local: datetime) -> bool {
    if not morning_window(local) {
        return False;
    }
    return portfolio is None or run_for(portfolio, local.date().isoformat()) is None;
}

"""Fires every weekday minute from 11:00 to 14:59 UTC, which holds 7:30 to 9:15 a.m. New York time
in daylight and standard time alike; `morning_due` decides."""
@schedule(trigger=ScheduleTrigger.STATIC, cron="* 11-14 * * 0-4")
def morning_job {
    if morning_due(find_team_portfolio(), datetime.now(NEW_YORK)) {
        morning_run();
    }
}

"""Fires every minute from 13:00 to 21:59 UTC on weekdays, which spans 9:45 a.m. to 4:30 p.m.
in New York in daylight and standard time alike."""
@schedule(trigger=ScheduleTrigger.STATIC, cron="* 13-21 * * 0-4")
def trading_job {
    team_trading_tick(team_portfolio(), datetime.now(timezone.utc));
}
