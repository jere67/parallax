"""The trading day (run/trading.jac), ticked through a session on a fake clock against the fake
broker: execution at 9:45, fills and stops, the cancel window, and reconciliation, including
an early close, drift, and a gate bypass."""
import from datetime { datetime, timedelta, timezone }
import from action.executor { MarketView, open_positions }
import from action.fixtures { Call, broker_for, finished_run, market, team }
import from action.reconcile { marks_of }
import from models.graph { Portfolio, PortfolioMode, RunStatus, TradeAction }
import from models.research { Stamp }
import from research.alpaca { MarketDay }
import from run.guard { NEW_YORK }
import from run.trading { TradingDeps, team_trading_tick, trading_tick }
import from tests.fakes.broker_server { FakeBroker, FakeOrder, Scripted }

glob DAY: str = "2026-10-21";

def ny(hhmm: str, day: str = DAY) -> datetime {
    return datetime.fromisoformat(f"{day}T{hhmm}:00").replace(tzinfo=NEW_YORK).astimezone(timezone.utc);
}

def session(day: str, close: str = "16:00") -> MarketDay {
    return MarketDay(day=day, open="09:30", close=close, early_close=close != "16:00", stamp=Stamp(source="alpaca_trading", dataset="alpaca.calendar", source_url="u", published_at=day, fetched_at=day));
}

"""Deps on the fake: its prices as the latest trades at the fake's clock, and a calendar of
regular sessions except the `early` ones."""
def deps_for(fake: FakeBroker, early: set[str] | None = None, holidays: set[str] | None = None) -> TradingDeps {
    closes = early or set();
    shut = holidays or set();
    def read(_tickers: list[str]) -> MarketView {
        return market(dict(fake.prices), datetime.fromisoformat(fake.now));
    }
    def calendar(day: str) -> MarketDay | None {
        return None if day in shut else session(day, "13:00" if day in closes else "16:00");
    }
    return TradingDeps(broker=broker_for(fake), view=read, calendar=calendar);
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
