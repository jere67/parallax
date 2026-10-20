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
  portfolio, once a day.

Every step records that it ran, so a second firing does nothing, and nothing trades unless
the team portfolio is in auto mode. What each tick did goes on the day's run, in
`action_log`, and in the server log.
"""
import logging;
import threading;
import from datetime { date, datetime, time, timedelta }
import from action.broker { Broker }
import from action.executor { MarketView, close_day_orders, decisions_of, execute_run, keep_stops, market_view, open_positions, sync_orders }
import from action.reconcile { marks_of, reconcile }
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
calendar. Tests pass fakes; the defaults call Alpaca."""
obj TradingDeps {
    has broker: Broker | None = None,
        view: Callable[[list[str]], MarketView] | None = None,
        calendar: Callable[[str], MarketDay | None] | None = None;

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

"""Do whatever step of `portfolio`'s trading day is due at `now`, and return what it did."""
def trading_tick(portfolio: Portfolio, now: datetime, deps: TradingDeps = TradingDeps()) -> list[str] {
    if portfolio.mode != PortfolioMode.AUTO {
        return [];
    }
    local = now.astimezone(NEW_YORK);
    day = local.date().isoformat();
    if local.weekday() >= 5 or local.time() < EXECUTION_START {
        return [];
    }
    session = deps.session(day);
    if session is None {
        return [];
    }
    times = session_times(session);
    run = run_for(portfolio, day);
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
