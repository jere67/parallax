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
import logging;
import from datetime { datetime, timezone }
import from models.graph { Portfolio }
import from run.attempts { attempt_for, record_lost, unsettled }
import from run.guard { NEW_YORK, find_team_portfolio, morning_window, scheduled_cutoff, team_portfolio }
import from run.orchestration { morning_run }
import from run.trading { run_for, team_trading_tick }

glob LOG: logging.Logger = logging.getLogger("trading_agent.jobs");

"""True when the team's morning run should start at `local` (New York time): inside the morning
window, with no run on record for the day. The record check keeps the firings after the run cheap,
since the run's own claim would only be reached after preflight's network calls."""
def morning_due(portfolio: Portfolio | None, local: datetime) -> bool {
    if not morning_window(local) {
        return False;
    }
    day = local.date().isoformat();
    # A run this process started for the day, still working or not yet saved, is never started
    # again by the schedule: a lost one is recorded, and the admin decides (run/attempts.jac).
    if attempt_for(day) is not None {
        return False;
    }
    return portfolio is None or run_for(portfolio, day) is None;
}

"""Fires every weekday minute from 11:00 to 14:59 UTC, which holds 7:30 to 9:15 a.m. New York time
in daylight and standard time alike; `morning_due` decides."""
@schedule(trigger=ScheduleTrigger.STATIC, cron="* 11-14 * * 0-4")
def morning_job {
    local = datetime.now(NEW_YORK);
    if morning_due(find_team_portfolio(), local) {
        morning_run(local.date().isoformat(), scheduled_cutoff(local.date().isoformat()));
    }
}

"""Records a team run the server could not save (run/attempts.jac). Fires every minute, and
reads the graph only when a run's work ended over three minutes ago and its record is unseen."""
@schedule(trigger=ScheduleTrigger.STATIC, cron="* * * * *")
def lost_run_job {
    now = datetime.now(timezone.utc);
    if not unsettled(now) {
        return;
    }
    found = find_team_portfolio();
    if found is not None {
        for line in record_lost(found, now) {
            LOG.warning("%s", line);
        }
    }
}

"""Fires every minute from 13:00 to 21:59 UTC on weekdays, which spans 9:45 a.m. to 4:30 p.m.
in New York in daylight and standard time alike."""
@schedule(trigger=ScheduleTrigger.STATIC, cron="* 13-21 * * 0-4")
def trading_job {
    team_trading_tick(team_portfolio(), datetime.now(timezone.utc));
}
