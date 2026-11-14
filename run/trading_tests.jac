"""The trading day (run/trading.jac), ticked through a session on a fake clock against the fake
broker: execution at 9:45, fills and stops, the cancel window, reconciliation, and vote
scoring, including an early close, drift, a gate bypass, insight mode, and the forward-test
start and baselines."""
import os;
import from datetime { datetime, timedelta, timezone }
import from action.baselines { FORWARD_TEST_ENV, baselines_of }
import from action.executor { MarketView, open_positions }
import from action.fixtures { Call, broker_for, finished_run, market, team }
import from action.reconcile { marks_of }
import from analysis.history { History, bar }
import from research.alpaca { Bar, MarketDay }
import from models.agents { Specialist, Stance, Vote }
import from models.graph { Coverage, Covers, Portfolio, PortfolioMode, RunStatus, TradeAction, VoteRecord, Voted }
import from models.policy { Policy, PolicyScope }
import from models.research { Stamp }
import from policy.store { save_policy, team_policy }
import from run.guard { NEW_YORK }
import from run.attempts { attempt_for, begin, finish, forget }
import from run.trading { TradingDeps, db_conflict, team_trading_tick, trading_tick }
import from tests.fakes.broker_server { FakeBroker, FakeOrder, FakePosition, Scripted }

glob DAY: str = "2026-10-21";

def ny(hhmm: str, day: str = DAY) -> datetime {
    return datetime.fromisoformat(f"{day}T{hhmm}:00").replace(tzinfo=NEW_YORK).astimezone(timezone.utc);
}

def session(day: str, close: str = "16:00") -> MarketDay {
    return MarketDay(day=day, open="09:30", close=close, early_close=close != "16:00", stamp=Stamp(source="alpaca_trading", dataset="alpaca.calendar", source_url="u", published_at=day, fetched_at=day));
}

"""Deps on the fake: its prices as the latest trades at the fake's clock, a calendar of
regular sessions except the `early` ones, and vote scoring over weekday sessions and
`closes`."""
def deps_for(fake: FakeBroker, early: set[str] | None = None, holidays: set[str] | None = None, closes: dict[str, dict[str, float]] | None = None) -> TradingDeps {
    shortened = early or set();
    shut = holidays or set();
    prices = closes or {};
    def read(_tickers: list[str]) -> MarketView {
        return market(dict(fake.prices), datetime.fromisoformat(fake.now));
    }
    def calendar(day: str) -> MarketDay | None {
        return None if day in shut else session(day, "13:00" if day in shortened else "16:00");
    }
    def sessions(start: str, end: str) -> list[str] {
        days = [datetime.fromisoformat(start).date() + timedelta(days=i) for i in range((datetime.fromisoformat(end) - datetime.fromisoformat(start)).days + 1)];
        return [d.isoformat() for d in days if d.weekday() < 5 and d.isoformat() not in shut];
    }
    def read_bars(symbols: list[str], _start: str, _end: str) -> dict[str, dict[str, Bar]] {
        return {s: {d: bar(d, c) for (d, c) in prices[s].items()} for s in symbols if s in prices};
    }
    return TradingDeps(broker=broker_for(fake), view=read, calendar=calendar, history=History(bars=read_bars, sessions=sessions));
}

"""Tick at New York time `hhmm`, with the fake's clock set to the same moment."""
def tick_at(fake: FakeBroker, portfolio: Portfolio, deps: TradingDeps, hhmm: str, day: str = DAY) -> list[str] {
    when = ny(hhmm, day);
    fake.now = when.isoformat();
    return trading_tick(portfolio, when, deps);
}

test "a trading day: execute at 9:45, stop each fill, cancel the rest at 3:50, reconcile at 4:30" {
    fake = FakeBroker();
    try {
        deps = deps_for(fake);
        portfolio = team();
        fake.set_price("AAA", 100.0);
        fake.set_price("BBB", 50.0);
        run = finished_run(portfolio, DAY, [Call(ticker="AAA", action=TradeAction.BUY, conviction=0.5), Call(ticker="BBB", action=TradeAction.BUY, conviction=0.5, sector="Energy", close=50.0, atr=1.0)]);
        assert tick_at(fake, portfolio, deps, "09:30") == [];
        assert tick_at(fake, portfolio, deps, "09:44") == [];
        lines = tick_at(fake, portfolio, deps, "09:45");
        assert lines[0].startswith("execute: 2 checks, 2 approved") and run.executed_at;
        fake.fill(f"{DAY}-AAA-entry", 0, 100.2);
        fake.fill(f"{DAY}-BBB-entry", 30, 50.1);
        lines = tick_at(fake, portfolio, deps, "09:46");
        assert any("AAA: opened 40" in l for l in lines) and any("BBB: opened 30" in l for l in lines);
        assert [(o.symbol, o.qty) for o in fake.working_orders() if o.order_type == "stop"] == [("AAA", 40)];
        assert tick_at(fake, portfolio, deps, "10:01") == [] and tick_at(fake, portfolio, deps, "10:05") == [];
        lines = tick_at(fake, portfolio, deps, "15:50");
        assert any("BBB-entry: canceled at the close window (30 of 80 filled)" in l for l in lines);
        assert sorted((o.symbol, o.qty) for o in fake.working_orders()) == [("AAA", 40), ("BBB", 30)];
        assert tick_at(fake, portfolio, deps, "15:55") == [];
        assert tick_at(fake, portfolio, deps, "16:29") == [];
        fake.set_price("AAA", 101.0);
        lines = tick_at(fake, portfolio, deps, "16:30");
        assert lines[0].startswith("reconcile:") and "0 drift, 0 bypasses" in lines[0];
        assert lines[-3:] == [
            "score: 0 votes scored, 0 without prices, 0 still open, 0 decisions scored",
            "score: 0 screens scored, 0 without prices, 1 still open",
            "evaluate: 1 session from 2026-10-21, 0 baselines compared, 0 screens and 0 votes scored"
        ] and run.votes_scored_at and run.evaluated_at;
        mark = marks_of(portfolio)[DAY];
        assert mark.open_positions == 2 and mark.drift == [] and mark.bypasses == [];
        assert abs(mark.equity - (100000.0 - 40 * 100.2 - 30 * 50.1 + 40 * 101.0 + 30 * 50.0)) < 0.01;
        assert portfolio.peak_equity == mark.equity and run.reconciled_at;
        assert tick_at(fake, portfolio, deps, "16:31") == [];
        assert any(l.endswith("execute: 2 checks, 2 approved; AAA buy 40 @ 100.30: new; BBB buy 80 @ 50.15: new") for l in run.action_log);
    } finally {
        fake.stop();
    }
}

test "an early close moves the cancel window to 12:50 and reconciliation to 1:30" {
    fake = FakeBroker();
    try {
        deps = deps_for(fake, early={DAY});
        portfolio = team();
        fake.set_price("AAA", 100.0);
        run = finished_run(portfolio, DAY, [Call(ticker="AAA", action=TradeAction.BUY)]);
        tick_at(fake, portfolio, deps, "09:45");
        assert tick_at(fake, portfolio, deps, "12:49") == [];
        assert any("canceled at the close window" in l for l in tick_at(fake, portfolio, deps, "12:50"));
        assert tick_at(fake, portfolio, deps, "13:30")[0].startswith("reconcile:");
        assert run.day_orders_closed_at and DAY in marks_of(portfolio);
    } finally {
        fake.stop();
    }
}

test "nothing happens in insight mode, on a holiday, on a weekend, or before the run finishes" {
    fake = FakeBroker();
    try {
        insight = team(PortfolioMode.INSIGHT);
        finished_run(insight, DAY, [Call(ticker="AAA", action=TradeAction.BUY)]);
        fake.set_price("AAA", 100.0);
        assert tick_at(fake, insight, deps_for(fake), "09:45") == [];
        holiday = team();
        finished_run(holiday, DAY, [Call(ticker="AAA", action=TradeAction.BUY)]);
        assert tick_at(fake, holiday, deps_for(fake, holidays={DAY}), "09:45") == [];
        assert tick_at(fake, team(), deps_for(fake), "10:00", "2026-10-24") == [];
        running = team();
        finished_run(running, DAY, [Call(ticker="AAA", action=TradeAction.BUY)], status=RunStatus.RUNNING);
        tick_at(fake, running, deps_for(fake), "09:45");
        assert fake.orders == [];
    } finally {
        fake.stop();
    }
}

test "the demo history is never traded, reconciled, or scored, even in auto mode" {
    fake = FakeBroker();
    try {
        demo = team();
        demo.demo = True;
        run = finished_run(demo, DAY, [Call(ticker="AAA", action=TradeAction.BUY)]);
        fake.set_price("AAA", 100.0);
        deps = deps_for(fake);
        assert [tick_at(fake, demo, deps, t) for t in ["09:45", "09:46", "15:50", "16:30"]] == [[], [], [], []];
        assert fake.orders == [] and not run.executed_at and not run.reconciled_at and not run.votes_scored_at;
        assert marks_of(demo) == {};
    } finally {
        fake.stop();
    }
}

test "reconciliation adopts a position the record lacks, closes one Alpaca lacks, and flags a bypass" {
    fake = FakeBroker();
    try {
        deps = deps_for(fake);
        portfolio = team();
        fake.set_price("AAA", 100.0);
        finished_run(portfolio, DAY, [Call(ticker="AAA", action=TradeAction.BUY), Call(ticker="ZZZ", action=TradeAction.HOLD, atr=3.0)]);
        tick_at(fake, portfolio, deps, "09:45");
        fake.fill(f"{DAY}-AAA-entry");
        tick_at(fake, portfolio, deps, "09:46");
        # Someone sells AAA by hand and buys ZZZ outside the executor.
        fake.now = ny("11:00").isoformat();
        for o in fake.working_orders("AAA") {
            o.status = "canceled";
        }
        hand = FakeOrder(id="hand-1", client_order_id="by-hand", symbol="ZZZ", side="buy", order_type="market", time_in_force="day", qty=5, submitted_at=fake.now);
        fake.orders.append(hand);
        fake.set_price("ZZZ", 20.0);
        fake.fill("by-hand", 0, 20.0);
        del fake.positions["AAA"];
        lines = tick_at(fake, portfolio, deps, "16:30");
        mark = marks_of(portfolio)[DAY];
        assert mark.drift == ["AAA: 40 shares on record, none at Alpaca; closed on the record", "ZZZ: 5 shares at Alpaca not on record; adopted with a stop at 14.00"];
        assert len(mark.bypasses) == 1 and "by-hand" in mark.bypasses[0] and "placed outside the executor" in mark.bypasses[0];
        assert any(l.startswith("bypass: by-hand") for l in lines);
        assert open_positions(portfolio)["ZZZ"].stop_price == 14.0;
    } finally {
        fake.stop();
    }
}

"""What Postgres raises when a concurrent transaction won: the driver's error dict carries SQLSTATE
40001, as the PgWireError at the 2026-11-11 9:45 execution did."""
obj SerializationFailure(Exception) {}

def conflicting_view(_tickers: list[str]) -> MarketView {
    raise SerializationFailure({"S": "ERROR", "C": "40001", "M": "could not serialize access due to concurrent update"});
}

test "a conflict is recognized by its SQLSTATE, also when another error wraps it" {
    assert db_conflict(SerializationFailure({"C": "40001"})) and db_conflict(SerializationFailure({"C": "40P01"}));
    assert not db_conflict(SerializationFailure({"C": "23505"})) and not db_conflict(RuntimeError("40001"));
    wrapped = RuntimeError("the tick failed");
    wrapped.__cause__ = SerializationFailure({"C": "40001"});
    assert db_conflict(wrapped);
}

test "a database conflict is left to the runtime to replay, not logged as the run's error" {
    fake = FakeBroker();
    try {
        deps = deps_for(fake);
        deps.view = conflicting_view;
        portfolio = team();
        fake.set_price("AAA", 100.0);
        run = finished_run(portfolio, DAY, [Call(ticker="AAA", action=TradeAction.BUY)]);
        fake.now = ny("09:45").isoformat();
        raised = False;
        try {
            team_trading_tick(portfolio, ny("09:45"), deps);
        } except SerializationFailure {
            raised = True;
        }
        assert raised and not any("error" in line for line in run.action_log);
        # The runtime rolls the whole attempt back and replays it; nothing here is half-done.
        assert fake.orders == [];
    } finally {
        fake.stop();
    }
}

test "a failing tick is logged on the run and the next tick tries again" {
    fake = FakeBroker();
    try {
        deps = deps_for(fake);
        portfolio = team();
        fake.set_price("AAA", 100.0);
        run = finished_run(portfolio, DAY, [Call(ticker="AAA", action=TradeAction.BUY)]);
        fake.script = [Scripted(method="GET", path="/v2/account", status=403, body="{\"message\": \"forbidden\"}")];
        fake.now = ny("09:45").isoformat();
        lines = team_trading_tick(portfolio, ny("09:45"), deps);
        assert lines[0].startswith("error: BrokerError") and "forbidden" in run.action_log[-1];
        # The claim was taken before the failure, so execution does not retry blindly.
        assert run.executed_at and fake.orders == [];
    } finally {
        fake.stop();
    }
}

test "insight mode trades nothing but scores the panel's votes after the close, once a day" {
    fake = FakeBroker();
    try {
        deps = deps_for(fake, closes={"AAA": {"2026-10-20": 100.0, "2026-10-21": 103.0}, "SPY": {"2026-10-20": 500.0, "2026-10-21": 500.0}});
        portfolio = team(PortfolioMode.INSIGHT);
        yesterday = finished_run(portfolio, "2026-10-21", [Call(ticker="AAA", action=TradeAction.BUY)]);
        cov = [c for c in [yesterday ->:Covers:->[?:Coverage]]][0];
        cast = VoteRecord(ticker="AAA", specialist=Specialist.TECHNICAL, sample=0, model="m", body=Vote(stance=Stance.BUY, confidence=0.7, horizon_days=1, rationale="r", cited_evidence=[1]));
        cov +>:Voted():+> cast;
        today = finished_run(portfolio, "2026-10-22", [Call(ticker="AAA", action=TradeAction.BUY)]);
        assert tick_at(fake, portfolio, deps, "09:45", "2026-10-22") == [] and tick_at(fake, portfolio, deps, "16:29", "2026-10-22") == [];
        assert tick_at(fake, portfolio, deps, "16:30", "2026-10-22") == [
            "score: 1 votes scored, 0 without prices, 0 still open, 0 decisions scored",
            "score: 0 screens scored, 0 without prices, 2 still open",
            "evaluate: 2 sessions from 2026-10-21, 0 baselines compared, 0 screens and 1 votes scored"
        ];
        assert cast.excess_return is not None and abs(cast.excess_return - 0.03) < 1e-12 and today.votes_scored_at and not yesterday.votes_scored_at;
        assert tick_at(fake, portfolio, deps, "16:31", "2026-10-22") == [] and fake.orders == [];
    } finally {
        fake.stop();
    }
}

test "the forward test starts before 9:45 on the operator's date, and its baselines are simulated after the close" {
    fake = FakeBroker();
    os.environ[FORWARD_TEST_ENV] = DAY;
    try {
        deps = deps_for(fake, closes={"AAA": {DAY: 100.0}, "SPY": {DAY: 500.0}});
        portfolio = team(PortfolioMode.INSIGHT);
        assert tick_at(fake, portfolio, deps, "09:30", "2026-10-20") == [];
        lines = tick_at(fake, portfolio, deps, "09:30");
        assert lines == ["start: forward test started on 2026-10-21: starting balance 100,000.00, team portfolio in auto mode, baselines equal_weight and spy created"];
        assert portfolio.mode == PortfolioMode.AUTO and len(baselines_of(portfolio)) == 2;
        assert tick_at(fake, portfolio, deps, "09:31") == [];
        fake.set_price("AAA", 100.0);
        first = finished_run(portfolio, DAY, [Call(ticker="AAA", action=TradeAction.BUY)]);
        assert tick_at(fake, portfolio, deps, "09:45")[0].startswith("execute: 1 checks, 1 approved");
        # Wednesday's bars are not final at 4:30, so the baselines wait for Thursday evening.
        evening = tick_at(fake, portfolio, deps, "16:30");
        assert not any(l.startswith("baseline:") for l in evening) and first.baselines_at;
        second = finished_run(portfolio, "2026-10-22", []);
        lines = tick_at(fake, portfolio, deps, "16:30", "2026-10-22");
        assert "baseline: equal_weight 2026-10-21 AAA bought 80 at 100.00, stop 96.00" in lines and "baseline: spy 2026-10-21 SPY bought 200 at 500.00" in lines;
        assert second.baselines_at and tick_at(fake, portfolio, deps, "16:31", "2026-10-22") == [];
    } finally {
        os.environ.pop(FORWARD_TEST_ENV, None);
        fake.stop();
    }
}

test "a start on an account another server traded takes over its positions, re-places their stops, and reconciles clean" {
    fake = FakeBroker(cash=50000.0);
    os.environ[FORWARD_TEST_ENV] = DAY;
    try {
        deps = deps_for(fake);
        portfolio = team(PortfolioMode.INSIGHT);
        fake.positions["AMZN"] = FakePosition(symbol="AMZN", qty=4, avg_entry_price=260.0);
        fake.set_price("AMZN", 268.74);
        fake.orders.append(FakeOrder(id="old-stop", client_order_id="AMZN-20261111144600-stop2", symbol="AMZN", side="sell", order_type="stop", time_in_force="gtc", qty=4, submitted_at="2026-10-20T14:00:00+00:00", stop_price=250.38));
        lines = tick_at(fake, portfolio, deps, "09:30");
        assert lines[0].endswith("; took over 1 position (AMZN); canceled 1 open order");
        assert lines[1:] == ["stop: AMZN: stop for 4 at 250.38: pending_new"];
        working = [o for o in fake.orders if o.working()];
        assert len(working) == 1 and working[0].id != "old-stop" and working[0].stop_price == 250.38 and working[0].qty == 4;
        assert open_positions(portfolio)["AMZN"].stop_order_id == working[0].id;
        finished_run(portfolio, DAY, []);
        evening = tick_at(fake, portfolio, deps, "16:30");
        assert any(l.startswith("reconcile:") and l.endswith(", 1 positions, drawdown 0.0%, 0 drift, 0 bypasses") for l in evening);
    } finally {
        os.environ.pop(FORWARD_TEST_ENV, None);
        fake.stop();
    }
}

test "a server started after 9:45 still starts the forward test and trades the day's run on the same tick" {
    fake = FakeBroker();
    os.environ[FORWARD_TEST_ENV] = DAY;
    try {
        deps = deps_for(fake);
        portfolio = team(PortfolioMode.INSIGHT);
        fake.set_price("AAA", 100.0);
        run = finished_run(portfolio, DAY, [Call(ticker="AAA", action=TradeAction.BUY)]);
        lines = tick_at(fake, portfolio, deps, "11:05");
        assert lines[0].startswith("start: forward test started on 2026-10-21") and lines[1].startswith("execute: 1 checks, 1 approved");
        assert portfolio.mode == PortfolioMode.AUTO and run.executed_at;
        assert run.action_log[0].startswith("11:05 start: forward test started");
    } finally {
        os.environ.pop(FORWARD_TEST_ENV, None);
        fake.stop();
    }
}

test "the forward test waits for the next session once the cancel window has begun" {
    fake = FakeBroker();
    os.environ[FORWARD_TEST_ENV] = DAY;
    try {
        deps = deps_for(fake);
        portfolio = team(PortfolioMode.INSIGHT);
        assert tick_at(fake, portfolio, deps, "15:50") == [] and tick_at(fake, portfolio, deps, "16:30") == [];
        assert portfolio.mode == PortfolioMode.INSIGHT and not baselines_of(portfolio);
        assert tick_at(fake, portfolio, deps, "08:00", "2026-10-22")[0].startswith("start: forward test started on 2026-10-22");
    } finally {
        os.environ.pop(FORWARD_TEST_ENV, None);
        fake.stop();
    }
}

test "orders are sized and gated under the policy version the run decided with" {
    fake = FakeBroker();
    try {
        deps = deps_for(fake);
        portfolio = team();
        fake.set_price("AAA", 100.0);
        fake.set_price("BBB", 50.0);
        run = finished_run(portfolio, DAY, [Call(ticker="AAA", action=TradeAction.BUY, conviction=0.5), Call(ticker="BBB", action=TradeAction.BUY, conviction=0.5, sector="Energy", close=50.0, atr=1.0)]);
        (_, base) = team_policy();
        one_a_day = save_policy(PolicyScope.TEAM, Policy(new_positions_per_day=1), base);
        assert one_a_day.saved;
        run.policy_version = one_a_day.version;
        # A policy saved after the run decided changes the next run, not this one's orders.
        assert save_policy(PolicyScope.TEAM, Policy(new_positions_per_day=5), one_a_day.version).saved;
        lines = tick_at(fake, portfolio, deps, "09:45");
        assert lines[0].startswith("execute: 2 checks, 1 approved");
    } finally {
        fake.stop();
    }
}

test "while the morning run may still write, the team tick waits, then trades it on the first tick after it is saved" {
    fake = FakeBroker();
    try {
        deps = deps_for(fake);
        portfolio = team();
        fake.set_price("AAA", 100.0);
        begin(DAY, ny("09:00"));
        fake.now = ny("09:45").isoformat();
        assert team_trading_tick(portfolio, ny("09:45"), deps) == ["skipped: the morning run is still running"];
        assert fake.orders == [];
        # The run is saved at 9:46, after the first execution minute.
        run = finished_run(portfolio, DAY, [Call(ticker="AAA", action=TradeAction.BUY, conviction=0.5)]);
        finish(DAY, ny("09:46"), "normal");
        assert run.action_log == [] and not run.executed_at;
        fake.now = ny("09:47").isoformat();
        lines = team_trading_tick(portfolio, ny("09:47"), deps);
        assert lines[0].startswith("execute: 1 checks, 1 approved") and run.executed_at;
        assert attempt_for(DAY) is None;
    } finally {
        forget(DAY);
        fake.stop();
    }
}
