"""The Action layer's trading day (TDD §4, daily schedule; TDD §8, execution and
reconciliation), driven by one scheduled tick a minute.

Each tick reads New York time and the day's market calendar, so an early close moves the
afternoon steps with it, and does whatever step is due and not yet done:

- from 9:45 a.m., once the morning run has finished: size, gate, and submit its orders, with
  the sizing and risk limits of the team policy version the run decided under, so a policy
  saved after the run changes the next run, not this one's orders;
- until ten minutes before the close: record fills and keep every position's stop, every
  minute until 10:00 and every five minutes after;
- ten minutes before the close (3:50 p.m., or 12:50 on an early close): cancel the run's
  unfilled DAY orders and place stops for what filled;
- thirty minutes after the close (4:30 p.m., or 1:30): reconcile with Alpaca and mark the
  portfolio, once a day, then score the panel's votes and decisions and the screens whose
  windows have closed, simulate the forward-test baselines, and store the day's evaluation
  (analysis/evaluation.jac);
- on or after the date the operator set in FORWARD_TEST_ENV, start the forward test
  (action/baselines.jac), once: at the first tick of a session day, as long as the day's run
  has not executed and the cancel window has not begun, so a server started after 9:45 still
  trades that day. Positions the account already held are taken over, and their stops are
  placed in the same tick.

An agent that trades options buys them right after the run's stock orders go out, once, and
checks its open contracts' exits every half hour (action/options.jac).

Coins trade every day. On a day the stock market is closed, a run that covered coins
(run/guard.jac) is traded on the same clock: its orders from 9:45, fills and coin stops every five
minutes, and its unfilled orders canceled at 3:50. Stocks are left alone, and nothing is
reconciled or scored until the next session.

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
import from action.options { OptionsDeps, manage_options, open_options }
import from models.assets { CRYPTO, OPTIONS }
import from research.crypto { is_crypto }
import from action.reconcile { marks_of, reconcile }
import from analysis.evaluation { evaluate, record_evaluation, start_of }
import from analysis.history { History }
import from analysis.policy { gate_config, sizing_config }
import from analysis.scoring { score_screens, score_votes }
import from models.graph { DailyMark, Portfolio, PortfolioMode, Ran, Run, RunStatus }
import from research.alpaca { MarketDay, market_calendar }
import from research.collector { run_budget }
import from policy.store { policy_version }
import from research.credentials { redact }
import from run.attempts { busy }
import from run.guard { NEW_YORK }
import from run.switches { demo_mode }

glob EXECUTION_START: time = time(9, 45);
glob FAST_POLL_UNTIL: time = time(10, 0);
glob SLOW_POLL_MINUTES: int = 5;
glob OPTION_EXIT_MINUTES: int = 30;
# The clock a day without a stock session keeps for coins.
glob COIN_DAY_CLOSE: time = time(16, 0);
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
        history: History | None = None,
        start_day: str | None = None,
        options: OptionsDeps | None = None;

    def option_deps -> OptionsDeps {
        return self.options or OptionsDeps();
    }

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
            policy = policy_version(run.policy_version);
            seen = deps.read_market(tickers);
            done = execute_run(portfolio, run, broker, now, seen, sizing_config(policy), gate_config(policy));
            lines.append(f"execute: {done.line()}");
            lines.extend(f"option: {c}" for c in open_options(portfolio, run, broker, now, seen, gate_config(policy), deps.option_deps()));
            lines.extend(f"fill: {c}" for c in sync_orders(portfolio, broker, now));
            lines.extend(f"stop: {c}" for c in keep_stops(portfolio, broker, now));
        } elif local.time() < FAST_POLL_UNTIL or local.minute % SLOW_POLL_MINUTES == 0 {
            lines.extend(f"fill: {c}" for c in sync_orders(portfolio, broker, now));
            lines.extend(f"stop: {c}" for c in keep_stops(portfolio, broker, now));
            if local.minute % OPTION_EXIT_MINUTES == 0 {
                lines.extend(f"option: {c}" for c in manage_options(portfolio, broker, now, deps.option_deps()));
            }
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

"""Whether the evening steps (scoring, the baselines, the evaluation) still have work for `run`."""
def evening_due(portfolio: Portfolio, run: Run) -> bool {
    return not run.votes_scored_at or (not run.baselines_at and bool(baselines_of(portfolio))) or not run.evaluated_at;
}

"""Start the forward test once the operator has set its date, on a session day before the
cancel window and before the day's run has executed, so the team still trades that day."""
def start_due(portfolio: Portfolio, run: Run | None, now: datetime, day: str, deps: TradingDeps) -> list[str] {
    wanted = deps.start_day if deps.start_day is not None else forward_test_day();
    if not wanted or wanted > day or baselines_of(portfolio) or (run is not None and run.executed_at) {
        return [];
    }
    session = deps.session(day);
    if session is None or now >= session_times(session).cancel_at {
        return [];
    }
    broker = deps.broker_client();
    lines = [f"start: {start_forward_test(portfolio, broker, now, day)}"];
    # Positions taken over at the start lost their old stops; protect them now, not at 9:45.
    lines.extend(f"stop: {c}" for c in keep_stops(portfolio, broker, now));
    return lines;
}

"""Do whatever step of `portfolio`'s trading day is due at `now`, and return what it did.
Nothing is ever due on the local demo history: its orders, positions, and votes are made up,
so trading, reconciling, or scoring them against Alpaca would be wrong (dashboard/demo.jac)."""
def trading_tick(portfolio: Portfolio, now: datetime, deps: TradingDeps = TradingDeps()) -> list[str] {
    if portfolio.demo or demo_mode() {
        return [];
    }
    local = now.astimezone(NEW_YORK);
    day = local.date().isoformat();
    run = run_for(portfolio, day);
    weekday = local.weekday() < 5;
    if not weekday and not coins_due(portfolio, run) {
        return [];
    }
    lines = start_due(portfolio, run, now, day, deps) if weekday else [];
    if local.time() >= EXECUTION_START {
        lines.extend(day_steps(portfolio, run, day, local, now, deps));
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

"""True when a day without a stock session has coin work for `portfolio`: a run that covered
coins, or coins it holds (their stops)."""
def coins_due(portfolio: Portfolio, run: Run | None) -> bool {
    if portfolio.mode != PortfolioMode.AUTO {
        return False;
    }
    if run is not None and CRYPTO in run.asset_classes {
        return True;
    }
    return any(is_crypto(t) for t in open_positions(portfolio));
}

"""A day without a stock session, for coins: orders from 9:45, fills and coin stops every five
minutes, and unfilled orders canceled at 3:50. Nothing is reconciled or scored."""
def coin_steps(portfolio: Portfolio, run: Run | None, local: datetime, now: datetime, deps: TradingDeps) -> list[str] {
    if not coins_due(portfolio, run) {
        return [];
    }
    close = datetime.combine(local.date(), COIN_DAY_CLOSE, NEW_YORK);
    lines: list[str] = [];
    broker = deps.broker_client();
    if local < close - CANCEL_BEFORE_CLOSE {
        if run is not None and run.status not in (RunStatus.RUNNING, RunStatus.SKIPPED) and not run.executed_at {
            tickers = sorted(set(decisions_of(run)) | set(open_positions(portfolio)));
            policy = policy_version(run.policy_version);
            done = execute_run(portfolio, run, broker, now, deps.read_market(tickers), sizing_config(policy), gate_config(policy));
            lines.append(f"execute: {done.line()}");
            lines.extend(f"fill: {c}" for c in sync_orders(portfolio, broker, now));
            lines.extend(f"stop: {c}" for c in keep_stops(portfolio, broker, now, coins_only=True));
        } elif local.minute % SLOW_POLL_MINUTES == 0 {
            lines.extend(f"fill: {c}" for c in sync_orders(portfolio, broker, now));
            lines.extend(f"stop: {c}" for c in keep_stops(portfolio, broker, now, coins_only=True));
        }
    } elif run is not None and run.executed_at and not run.day_orders_closed_at {
        lines.extend(f"close: {c}" for c in close_day_orders(portfolio, run, broker, now, coins_only=True));
    }
    return lines;
}

"""The steps due from 9:45 a.m.: trading in auto mode, then vote scoring and the baselines
after the close. A day without a stock session trades coins alone (`coin_steps`)."""
def day_steps(portfolio: Portfolio, run: Run | None, day: str, local: datetime, now: datetime, deps: TradingDeps) -> list[str] {
    trading = portfolio.mode == PortfolioMode.AUTO;
    if local.weekday() >= 5 {
        return coin_steps(portfolio, run, local, now, deps);
    }
    if not trading and (run is None or not evening_due(portfolio, run)) {
        return [];
    }
    session = deps.session(day);
    if session is None {
        return coin_steps(portfolio, run, local, now, deps);
    }
    times = session_times(session);
    lines: list[str] = [];
    if trading {
        lines.extend(trading_step(portfolio, run, day, local, now, times, deps));
    }
    history = deps.history or History();
    if local >= times.reconcile_at and run is not None and not run.votes_scored_at {
        found = score_votes(portfolio, now, history);
        lines.append(f"score: {found.line()}");
        lines.append(f"score: {score_screens(portfolio, now, history).line()}");
        run.votes_scored_at = now.isoformat();
    }
    if local >= times.reconcile_at and run is not None and not run.baselines_at and baselines_of(portfolio) {
        lines.extend(f"baseline: {line}" for line in advance_baselines(portfolio, now, history));
        run.baselines_at = now.isoformat();
    }
    if local >= times.reconcile_at and run is not None and run.votes_scored_at and not run.evaluated_at and (run.baselines_at or not baselines_of(portfolio)) {
        lines.append(f"evaluate: {evaluation_line(portfolio, now, day, history)}");
        run.evaluated_at = now.isoformat();
    }
    return lines;
}

"""Rebuild and store `portfolio`'s evaluation through `day`, and say what it holds."""
def evaluation_line(portfolio: Portfolio, now: datetime, day: str, history: History) -> str {
    runs = [portfolio ->:Ran:->[?:Run]];
    start = start_of(portfolio, runs) or day;
    body = evaluate(portfolio, history.read_sessions(start, day), now);
    record_evaluation(portfolio, body);
    return f"{body.sessions} session{'' if body.sessions == 1 else 's'} from {body.start_day or day}, {len(body.comparisons)} baselines compared, {body.screen.runs} screens and {sum(s.votes for s in body.specialists)} votes scored";
}

"""The scheduled tick on the team portfolio. Never raises: a failure is logged and recorded
on the day's run, and the next tick tries again. While the day's morning run may still write
the team portfolio (run/attempts.jac), the tick waits, writing nothing, so the two firings never
both write it and the run's record is not lost to the conflict (#240). The run's orders then go
out on the first tick after it is saved."""
def team_trading_tick(portfolio: Portfolio, now: datetime, deps: TradingDeps = TradingDeps()) -> list[str] {
    if busy(portfolio, now.astimezone(NEW_YORK).date().isoformat(), now) {
        return ["skipped: the morning run is still running"];
    }
    if not _TICK_LOCK.acquire(blocking=False) {
        return ["skipped: the previous tick is still running"];
    }
    try {
        return guarded_tick(portfolio, now, deps);
    } finally {
        _TICK_LOCK.release();
    }
}

# The SQLSTATEs the runtime replays a unit of work on (jaclang's session, `run_request`).
glob CONFLICT_CODES: set[str] = {"40001", "40P01", "55P03", "08006"};

"""True when `e`, or an error it came from, is the database asking for a retry: a concurrent
transaction won. The runtime then rolls the whole firing back and replays it, which is safe
because every order's client ID is fixed by the run and the position, so a replay finds the
orders the first attempt placed (TDD §8, idempotency)."""
def db_conflict(e: BaseException) -> bool {
    cur: BaseException | None = e;
    for _ in range(8) {
        if cur is None {
            return False;
        }
        for arg in cur.args {
            if isinstance(arg, dict) and arg.get("C") in CONFLICT_CODES {
                return True;
            }
        }
        cur = cur.__cause__ or cur.__context__;
    }
    return False;
}

"""`trading_tick`, with a failure logged and recorded on the day's run, for the next tick to try
again. A database conflict is not a failure: it goes up to the runtime, which replays the firing."""
def guarded_tick(portfolio: Portfolio, now: datetime, deps: TradingDeps) -> list[str] {
    try {
        return trading_tick(portfolio, now, deps);
    } except Exception as e {
        if db_conflict(e) {
            raise;
        }
        reason = redact(f"{type(e).__name__}: {str(e)[:300]}");
        LOG.error("trading tick failed: %s", reason);
        run = run_for(portfolio, now.astimezone(NEW_YORK).date().isoformat());
        if run is not None {
            run.action_log = (run.action_log + [f"{now.astimezone(NEW_YORK).strftime('%H:%M')} error: {reason}"])[-MAX_LOG_LINES:];
        }
        return [f"error: {reason}"];
    }
}
