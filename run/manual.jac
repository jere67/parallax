"""Start today's morning run by hand (TDD §4, daily schedule; TDD §14, unauthorized run
triggers).

The 7:30 a.m. job fires only between 7:30 and 7:45 New York time (run/jobs.jac), so a server
that is down or asleep then has no run that day. `start_morning_run` lets the platform admin
ask for it later, and `manual_run_job`, a static job that checks every minute, runs it.

The request is a row in the server's app token store (`jaclang.server.identity.app_tokens`),
kept in Postgres beside the graph, with the New York date as its subject and an expiry at the
end of that day. The job takes it with `token_revoke`, a single `DELETE ... RETURNING`, so only
one firing on one server ever gets a request, and runs the day's pipeline.

Why not run it from the request, or through the scheduler's dynamic jobs:
- A request runs on the caller's own root, which can read the team portfolio but not attach a
  run to it. Static jobs run on the super root, which owns everything the 7:30 job writes.
- Dynamic jobs (`@schedule(trigger=ScheduleTrigger.DYNAMIC)`) stop firing after the dev
  server's hot reload, which a run's own writes to storage/ set off: in Jac 0.37.12 the
  reload replaces the job scheduler with one that is never started. Static jobs keep firing.
  The scheduler's `/jobs` API would also let any signed-in user schedule them.

A day's run is claimed once (run/guard.jac, `claim_run`), so a manual run and the 7:30 job never
both run, and a day whose run failed is not run again.
"""
import logging;
import from datetime { datetime, time, timedelta }
import from jaclang.server.identity.app_tokens { token_create, token_revoke }
import from accounts.store { caller_is_admin }
import from models.graph { Portfolio }
import from run.guard { NEW_YORK, find_team_portfolio }
import from run.orchestration { morning_run }
import from run.trading { run_for }

# The app token purpose that holds manual run requests.
glob REQUEST_PURPOSE: str = "manual-morning-run";

glob LOG: logging.Logger = logging.getLogger("trading_agent.manual");

"""What `start_morning_run` did: whether the run was requested, for which New York date, and
why not when it was refused."""
obj ManualRun {
    has started: bool,
        run_day: str,
        message: str;
}

"""Why a manual run for `day` cannot start, or "" when it can. `local` is New York time and
`portfolio` the team portfolio, if it exists yet."""
def manual_refusal(is_admin: bool, portfolio: Portfolio | None, day: str, local: datetime) -> str {
    if not is_admin {
        return "Only the admin can start a run.";
    }
    if local.weekday() >= 5 {
        return f"{day} is a weekend; the market is closed.";
    }
    if portfolio is not None and portfolio.demo {
        return "The team portfolio holds the demo history, which never runs.";
    }
    if portfolio is not None {
        found = run_for(portfolio, day);
        if found is not None {
            return f"The run for {day} has already started (status: {found.status.value}).";
        }
    }
    return "";
}

"""Seconds from `local` (New York time) to the end of its day, at least one minute."""
def seconds_left_today(local: datetime) -> int {
    midnight = datetime.combine(local.date() + timedelta(days=1), time(0, 0), NEW_YORK);
    return max(60, int((midnight - local).total_seconds()));
}

"""Record the admin's request for the run on `day`, until the end of that day."""
def request_run(day: str, local: datetime) {
    token_create(REQUEST_PURPOSE, subject=day, ttl_seconds=seconds_left_today(local));
}

"""Take the request for `day`, if there is one: True for exactly one caller."""
def take_request(day: str) -> bool {
    return token_revoke(REQUEST_PURPOSE, day) > 0;
}

"""Ask for today's morning run on the team portfolio. Admin only; the run starts within a
minute, from `manual_run_job`."""
def:priv start_morning_run -> ManualRun {
    local = datetime.now(NEW_YORK);
    day = local.date().isoformat();
    refusal = manual_refusal(caller_is_admin(), find_team_portfolio(), day, local);
    if refusal {
        return ManualRun(started=False, run_day=day, message=refusal);
    }
    request_run(day, local);
    LOG.info("%s manual morning run requested", day);
    return ManualRun(started=True, run_day=day, message=f"The morning run for {day} starts within a minute and takes about 20 minutes. The trading tick executes it once it finishes, if the team portfolio is in auto mode.");
}

"""Run today's morning run if the admin asked for it. Fires every minute; taking the request
deletes it, so it runs once."""
@schedule(trigger=ScheduleTrigger.STATIC, cron="* * * * *")
def manual_run_job {
    day = datetime.now(NEW_YORK).date().isoformat();
    if not take_request(day) {
        return;
    }
    LOG.info("%s manual morning run starting", day);
    outcome = morning_run(day);
    LOG.info("%s manual morning run %s: %s", outcome.run_day, outcome.status.value, outcome.note);
}
