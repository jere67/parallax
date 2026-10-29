"""The Action layer's trading day (TDD §4, daily schedule; TDD §8, execution and
reconciliation), driven by one scheduled tick a minute.

Each tick reads New York time and the day's market calendar, so an early close moves the
afternoon steps with it, and does whatever step is due and not yet done:

- from 9:45 a.m., once the morning run has finished: size, gate, and submit its orders;
- until ten minutes before the close: record fills and keep every position's stop, every
  minute until 10:00 and every five minutes after;
- ten minutes before the close (3:50 p.m., or 12:50 on an early close): cancel the run's
  unfilled DAY orders and place stops for what filled;
- thirty minutes after the close (4:30 p.m., or 1:30): reconcile with Alpaca and mark the
  portfolio, once a day, then score the panel's votes whose windows have closed and simulate
  the forward-test baselines;
- before 9:45 a.m. on or after the date the operator set in FORWARD_TEST_ENV, start the
  forward test (action/baselines.jac), once.

Every step records that it ran, so a second firing does nothing. Nothing trades unless the
team portfolio is in auto mode, but votes are scored in both modes. A daily bar is final
only in the evening (research/alpaca.jac, BARS_FINAL_AT), so a window ending today is scored
after tomorrow's close. What each tick did goes on the day's run, in
`action_log`, and in the server log.
"""
import logging;
import threading;
import from datetime { date, datetime, time, timedelta }
import from action.baselines { advance_baselines, baselines_of, forward_test_day, start_forward_test }
import from action.broker { Broker }
import from action.executor { MarketView, close_day_orders, decisions_of, execute_run, keep_stops, market_view, open_positions, sync_orders }
import from action.reconcile { marks_of, reconcile }
import from analysis.history { History }
import from analysis.scoring { score_votes }
import from models.graph { DailyMark, Portfolio, PortfolioMode, Ran, Run, RunStatus }
import from research.alpaca { MarketDay, market_calendar }
import from research.collector { run_budget }
import from run.guard { NEW_YORK }

glob EXECUTION_START: time = time(9, 45);
glob FAST_POLL_UNTIL: time = time(10, 0);
glob SLOW_POLL_MINUTES: int = 5;
glob CANCEL_BEFORE_CLOSE: timedelta = timedelta(minutes=10);
glob RECONCILE_AFTER_CLOSE: timedelta = timedelta(minutes=30);
glob MAX_LOG_LINES: int = 400;

glob LOG: logging.Logger = logging.getLogger("trading_agent.action");
# One tick at a time: a slow tick (an execution waiting on cancels) makes the next one skip.
glob _TICK_LOCK: threading.Lock = threading.Lock();

"""What a tick reads from outside: the broker, the latest trades and assets, and the market
calendar, and the daily bars and sessions read after the close. Tests pass fakes; the defaults call
Alpaca."""
obj TradingDeps {
    has broker: Broker | None = None,
        view: Callable[[list[str]], MarketView] | None = None,
        calendar: Callable[[str], MarketDay | None] | None = None,
        history: History | None = None;

    def broker_client -> Broker {
        if self.broker is None {
            self.broker = Broker();
        }
        return self.broker;
    }

    def read_market(tickers: list[str]) -> MarketView {
        return self.view(tickers) if self.view is not None else market_view(tickers);
    }

    def session(day: str) -> MarketDay | None {
        if self.calendar is not None {
            return self.calendar(day);
        }
        found = [d for d in market_calendar(day, day, run_budget()) if d.day == day];
        return found[0] if found else None;
    }
}

"""The run for New York trading date `day`, if the morning job made one."""
def run_for(portfolio: Portfolio, day: str) -> Run | None {
    for r in [portfolio ->:Ran:->[?:Run]] {
        if r.run_date == day {
            return r;
        }
    }
    return None;
}

"""The day's times in New York: execution start, the cancel window, and reconciliation."""
obj SessionTimes {
    has execute_at: datetime,
        cancel_at: datetime,
        reconcile_at: datetime;
}

def session_times(session: MarketDay) -> SessionTimes {
    day = date.fromisoformat(session.day);
    close = datetime.combine(day, time.fromisoformat(session.close), NEW_YORK);
    return SessionTimes(execute_at=datetime.combine(day, EXECUTION_START, NEW_YORK), cancel_at=close - CANCEL_BEFORE_CLOSE, reconcile_at=close + RECONCILE_AFTER_CLOSE);
}

"""The trading step due at `local`: execute, poll, close the day's orders, or reconcile."""
def trading_step(portfolio: Portfolio, run: Run | None, day: str, local: datetime, now: datetime, times: SessionTimes, deps: TradingDeps) -> list[str] {
    lines: list[str] = [];
    if local < times.cancel_at {
        broker = deps.broker_client();
        if run is not None and run.status not in (RunStatus.RUNNING, RunStatus.SKIPPED) and not run.executed_at {
            tickers = sorted(set(decisions_of(run)) | set(open_positions(portfolio)));
            done = execute_run(portfolio, run, broker, now, deps.read_market(tickers));
            lines.append(f"execute: {done.line()}");
            lines.extend(f"fill: {c}" for c in sync_orders(portfolio, broker, now));
            lines.extend(f"stop: {c}" for c in keep_stops(portfolio, broker, now));
        } elif local.time() < FAST_POLL_UNTIL or local.minute % SLOW_POLL_MINUTES == 0 {
            lines.extend(f"fill: {c}" for c in sync_orders(portfolio, broker, now));
            lines.extend(f"stop: {c}" for c in keep_stops(portfolio, broker, now));
        }
    } elif local < times.reconcile_at {
        if run is not None and run.executed_at and not run.day_orders_closed_at {
            lines.extend(f"close: {c}" for c in close_day_orders(portfolio, run, deps.broker_client(), now));
        }
    } elif day not in marks_of(portfolio) {
        mark = reconcile(portfolio, deps.broker_client(), now, day);
        lines.append(f"reconcile: equity {mark.equity:,.2f}, {mark.open_positions} positions, drawdown {mark.drawdown:.1%}, {len(mark.drift)} drift, {len(mark.bypasses)} bypasses");
        lines.extend(f"drift: {d}" for d in mark.drift);
        lines.extend(f"bypass: {b}" for b in mark.bypasses);
        if run is not None {
            run.reconciled_at = now.isoformat();
        }
    }
    return lines;
}

"""Whether the evening steps (vote scoring, the baselines) still have work for `run`."""
def evening_due(portfolio: Portfolio, run: Run) -> bool {
    return not run.votes_scored_at or (not run.baselines_at and bool(baselines_of(portfolio)));
}

"""Start the forward test on a session morning once the operator has set its date."""
def start_due(portfolio: Portfolio, now: datetime, day: str, deps: TradingDeps) -> list[str] {
    wanted = forward_test_day();
    if not wanted or wanted > day or baselines_of(portfolio) or deps.session(day) is None {
        return [];
    }
    line = f"start: {start_forward_test(portfolio, deps.broker_client(), now, day)}";
    LOG.info("%s %s", day, line);
    return [line];
}

"""Do whatever step of `portfolio`'s trading day is due at `now`, and return what it did.
Nothing is ever due on the local demo history: its orders, positions, and votes are made up,
so trading, reconciling, or scoring them against Alpaca would be wrong (dashboard/demo.jac)."""
def trading_tick(portfolio: Portfolio, now: datetime, deps: TradingDeps = TradingDeps()) -> list[str] {
    if portfolio.demo {
        return [];
    }
    local = now.astimezone(NEW_YORK);
    day = local.date().isoformat();
    if local.weekday() >= 5 {
        return [];
    }
    if local.time() < EXECUTION_START {
        return start_due(portfolio, now, day, deps);
    }
    run = run_for(portfolio, day);
    trading = portfolio.mode == PortfolioMode.AUTO;
    if not trading and (run is None or not evening_due(portfolio, run)) {
        return [];
    }
    session = deps.session(day);
    if session is None {
        return [];
    }
    times = session_times(session);
    lines: list[str] = [];
    if trading {
        lines.extend(trading_step(portfolio, run, day, local, now, times, deps));
    }
    if local >= times.reconcile_at and run is not None and not run.votes_scored_at {
        found = score_votes(portfolio, now, deps.history or History());
        run.votes_scored_at = now.isoformat();
        lines.append(f"score: {found.line()}");
    }
    if local >= times.reconcile_at and run is not None and not run.baselines_at and baselines_of(portfolio) {
        lines.extend(f"baseline: {line}" for line in advance_baselines(portfolio, now, deps.history or History()));
        run.baselines_at = now.isoformat();
    }
    if lines and run is not None {
        stamp = local.strftime("%H:%M");
        run.action_log = (run.action_log + [f"{stamp} {line}" for line in lines])[-MAX_LOG_LINES:];
    }
    for line in lines {
        LOG.info("%s %s", day, line);
    }
    return lines;
}

"""The scheduled tick on the team portfolio. Never raises: a failure is logged and recorded
on the day's run, and the next tick tries again."""
def team_trading_tick(portfolio: Portfolio, now: datetime, deps: TradingDeps = TradingDeps()) -> list[str] {
    if not _TICK_LOCK.acquire(blocking=False) {
        return ["skipped: the previous tick is still running"];
    }
    try {
        return trading_tick(portfolio, now, deps);
    } except Exception as e {
        reason = f"{type(e).__name__}: {str(e)[:300]}";
        LOG.exception("trading tick failed");
        run = run_for(portfolio, now.astimezone(NEW_YORK).date().isoformat());
        if run is not None {
            run.action_log = (run.action_log + [f"{now.astimezone(NEW_YORK).strftime('%H:%M')} error: {reason}"])[-MAX_LOG_LINES:];
        }
        return [f"error: {reason}"];
    } finally {
        _TICK_LOCK.release();
    }
}
