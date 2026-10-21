"""The executor (action/executor.jac) against the fake broker: the gate's approvals become
orders, fills move positions, and every position keeps one stop through entries, partial
fills, adds, trims, exits, and stops that fire or expire."""
import os;
import from datetime { datetime, timezone }
import from action.executor { ORDERS_OFF_ENV, close_day_orders, execute_run, keep_stops, open_positions, sync_orders }
import from action.fixtures { Call, broker_for, finished_run, market, team }
import from models.graph {
    CheckedBy,
    Coverage,
    Covers,
    Decided,
    Decision,
    FilledBy,
    Fill,
    Order,
    OrderPurpose,
    Placed,
    Portfolio,
    PortfolioMode,
    Position,
    RiskCheck,
    RiskOutcome,
    Run,
    Sent,
    TradeAction
}
import from tests.fakes.broker_server { FakeBroker }

glob DAY1: str = "2026-10-21";
glob DAY2: str = "2026-10-22";
glob NOW1: datetime = datetime(2026, 10, 21, 13, 45, tzinfo=timezone.utc);
glob NOW2: datetime = datetime(2026, 10, 22, 13, 45, tzinfo=timezone.utc);

def checks_of(run: Run) -> dict[str, RiskCheck] {
    found: dict[str, RiskCheck] = {};
    for cov in [run ->:Covers:->[?:Coverage]] {
        for d in [cov ->:Decided:->[?:Decision]] {
            for rc in [d ->:CheckedBy:->[?:RiskCheck]] {
                found[cov.ticker] = rc;
            }
        }
    }
    return found;
}

def sent(portfolio: Portfolio) -> list[Order] {
    return [o for o in [portfolio ->:Sent:->[?:Order]]];
}

def stops_at(fake: FakeBroker, ticker: str) -> list[tuple[int, float | None]] {
    return [(o.qty, o.stop_price) for o in fake.working_orders(ticker) if o.order_type == "stop"];
}

"""Open a 50-share AAA position at 100 with its stop at 96: buy, fill, stop."""
def opened(fake: FakeBroker, portfolio: Portfolio) -> Position {
    broker = broker_for(fake);
    fake.set_price("AAA", 100.0);
    execute_run(portfolio, finished_run(portfolio, DAY1, [Call(ticker="AAA", action=TradeAction.BUY, conviction=0.5)]), broker, NOW1, market({"AAA": 100.0}, NOW1));
    fake.fill(f"{DAY1}-AAA-entry", 0, 100.0);
    sync_orders(portfolio, broker, NOW1);
    keep_stops(portfolio, broker, NOW1);
    return open_positions(portfolio)["AAA"];
}

test "an approved buy is sent once as a marketable limit, and its fill opens a position with a stop" {
    fake = FakeBroker();
    try {
        broker = broker_for(fake);
        portfolio = team();
        fake.set_price("AAA", 100.0);
        run = finished_run(portfolio, DAY1, [Call(ticker="AAA", action=TradeAction.BUY, conviction=0.5), Call(ticker="BBB", action=TradeAction.NO_ACTION)]);
        done = execute_run(portfolio, run, broker, NOW1, market({"AAA": 100.0, "BBB": 50.0}, NOW1));
        checks = checks_of(run);
        assert list(checks) == ["AAA"] and checks["AAA"].outcome == RiskOutcome.APPROVED;
        # Sizing: 0.08 x 0.5 / (0.2 / 0.2) = 4% of 100,000 is 40 shares.
        assert checks["AAA"].approved_qty == 40 and checks["AAA"].stop_distance == 4.0;
        order = fake.find(f"{DAY1}-AAA-entry");
        assert order is not None and order.qty == 40 and order.limit_price == 100.3 and order.time_in_force == "day";
        assert run.executed_at and "1 approved" in done.note;
        again = execute_run(portfolio, run, broker, NOW1, market({"AAA": 100.0}, NOW1));
        assert again.note.startswith("already executed") and len(fake.orders) == 1;

        assert keep_stops(portfolio, broker, NOW1) == [];
        fake.fill(f"{DAY1}-AAA-entry", 0, 100.1);
        changes = sync_orders(portfolio, broker, NOW1);
        assert any("opened 40 @ 100.10" in c for c in changes);
        position = open_positions(portfolio)["AAA"];
        assert position.qty == 40 and position.stop_price == 96.1;
        assert [f.qty for o in sent(portfolio) for f in [o ->:FilledBy:->[?:Fill]]] == [40];
        keep_stops(portfolio, broker, NOW1);
        assert stops_at(fake, "AAA") == [(40, 96.1)] and position.stop_order_id;
        assert keep_stops(portfolio, broker, NOW1) == [] and len(fake.orders) == 2;
    } finally {
        fake.stop();
    }
}

test "insight mode, a skipped run, and the kill switch send nothing" {
    fake = FakeBroker();
    try {
        broker = broker_for(fake);
        insight = team(PortfolioMode.INSIGHT);
        assert execute_run(insight, finished_run(insight, DAY1, [Call(ticker="AAA", action=TradeAction.BUY)]), broker, NOW1, market({"AAA": 100.0}, NOW1)).note.startswith("insight mode");
        portfolio = team();
        os.environ[ORDERS_OFF_ENV] = "1";
        try {
            run = finished_run(portfolio, DAY1, [Call(ticker="AAA", action=TradeAction.BUY)]);
            done = execute_run(portfolio, run, broker, NOW1, market({"AAA": 100.0}, NOW1));
            assert "orders are disabled" in done.note and list(checks_of(run)) == ["AAA"];
        } finally {
            del os.environ[ORDERS_OFF_ENV];
        }
        assert fake.orders == [] and sent(portfolio) == [];
    } finally {
        fake.stop();
    }
}

test "a gate rejection is recorded with its rule and sends nothing" {
    fake = FakeBroker();
    try {
        broker = broker_for(fake);
        portfolio = team();
        run = finished_run(portfolio, DAY1, [Call(ticker="AAA", action=TradeAction.BUY, earnings_in=1)]);
        done = execute_run(portfolio, run, broker, NOW1, market({"AAA": 100.0}, NOW1));
        rc = checks_of(run)["AAA"];
        assert rc.outcome == RiskOutcome.REJECTED and [r.rule for r in rc.rules if not r.passed] == ["earnings blackout"];
        assert fake.orders == [] and done.refused == ["AAA buy 40: earnings blackout"];
    } finally {
        fake.stop();
    }
}

test "a partial fill gets its stop only after the rest of the buy is canceled at the close window" {
    fake = FakeBroker();
    try {
        broker = broker_for(fake);
        portfolio = team();
        fake.set_price("AAA", 100.0);
        run = finished_run(portfolio, DAY1, [Call(ticker="AAA", action=TradeAction.BUY, conviction=0.5)]);
        execute_run(portfolio, run, broker, NOW1, market({"AAA": 100.0}, NOW1));
        fake.fill(f"{DAY1}-AAA-entry", 15, 100.0);
        sync_orders(portfolio, broker, NOW1);
        keep_stops(portfolio, broker, NOW1);
        assert open_positions(portfolio)["AAA"].qty == 15 and stops_at(fake, "AAA") == [];
        close_day_orders(portfolio, run, broker, NOW1);
        entry_order = fake.find(f"{DAY1}-AAA-entry");
        assert entry_order is not None and entry_order.status == "canceled";
        assert stops_at(fake, "AAA") == [(15, 96.0)] and fake.rejections == [];
        assert close_day_orders(portfolio, run, broker, NOW1)[0].startswith("day orders already closed");
    } finally {
        fake.stop();
    }
}

test "an add cancels the stop, buys, and re-places one stop for every share, never lower" {
    fake = FakeBroker();
    try {
        broker = broker_for(fake);
        portfolio = team();
        position = opened(fake, portfolio);
        fake.set_price("AAA", 110.0);
        run = finished_run(portfolio, DAY2, [Call(ticker="AAA", action=TradeAction.ADD, conviction=0.8, atr=2.5)]);
        execute_run(portfolio, run, broker, NOW2, market({"AAA": 110.0}, NOW2));
        assert stops_at(fake, "AAA") == [] and fake.rejections == [];
        add = fake.find(f"{DAY2}-AAA-add");
        # Equity is 96,000 cash + 40 x 110 = 100,400; 6.4% of it is 6,425.6, of which 4,400 is held,
        # so the add buys 18 shares.
        assert add is not None and add.qty == 18 and checks_of(run)["AAA"].purpose == OrderPurpose.ADD;
        fake.fill(f"{DAY2}-AAA-add", 0, 110.0);
        sync_orders(portfolio, broker, NOW2);
        keep_stops(portfolio, broker, NOW2);
        # The add's stop is 110 - 5 = 105, above the entry's 96, so the stop moves up.
        assert position.qty == 58 and position.stop_price == 105.0 and stops_at(fake, "AAA") == [(58, 105.0)];
        assert abs(position.avg_entry_price - (40 * 100.0 + 18 * 110.0) / 58) < 1e-9;
    } finally {
        fake.stop();
    }
}

test "a trim cancels the stop, sells half, and re-places the stop for the rest at the same price" {
    fake = FakeBroker();
    try {
        broker = broker_for(fake);
        portfolio = team();
        position = opened(fake, portfolio);
        run = finished_run(portfolio, DAY2, [Call(ticker="AAA", action=TradeAction.TRIM)]);
        execute_run(portfolio, run, broker, NOW2, market({"AAA": 100.0}, NOW2));
        trim = fake.find(f"{DAY2}-AAA-trim");
        assert trim is not None and trim.qty == 20 and trim.limit_price == 99.7;
        fake.fill(f"{DAY2}-AAA-trim", 0, 99.8);
        sync_orders(portfolio, broker, NOW2);
        keep_stops(portfolio, broker, NOW2);
        assert position.qty == 20 and position.open() and stops_at(fake, "AAA") == [(20, 96.0)];
        assert fake.rejections == [];
    } finally {
        fake.stop();
    }
}

test "an exit cancels the stop and sells everything, and the position closes with no new stop" {
    fake = FakeBroker();
    try {
        broker = broker_for(fake);
        portfolio = team();
        position = opened(fake, portfolio);
        run = finished_run(portfolio, DAY2, [Call(ticker="AAA", action=TradeAction.SELL)]);
        execute_run(portfolio, run, broker, NOW2, market({"AAA": 98.0}, NOW2));
        fake.fill(f"{DAY2}-AAA-exit", 0, 97.9);
        sync_orders(portfolio, broker, NOW2);
        assert keep_stops(portfolio, broker, NOW2) == [];
        assert not position.open() and position.exit_price == 97.9 and open_positions(portfolio) == {};
        assert fake.positions == {} and fake.working_orders() == [] and fake.rejections == [];
    } finally {
        fake.stop();
    }
}

test "an exit that does not fill is canceled at the close window and the stop comes back" {
    fake = FakeBroker();
    try {
        broker = broker_for(fake);
        portfolio = team();
        opened(fake, portfolio);
        run = finished_run(portfolio, DAY2, [Call(ticker="AAA", action=TradeAction.SELL)]);
        execute_run(portfolio, run, broker, NOW2, market({"AAA": 98.0}, NOW2));
        assert stops_at(fake, "AAA") == [];
        close_day_orders(portfolio, run, broker, NOW2);
        assert stops_at(fake, "AAA") == [(40, 96.0)] and open_positions(portfolio)["AAA"].qty == 40;
    } finally {
        fake.stop();
    }
}

test "a stop that fires closes the position" {
    fake = FakeBroker();
    try {
        broker = broker_for(fake);
        portfolio = team();
        position = opened(fake, portfolio);
        fake.set_price("AAA", 95.0);
        changes = sync_orders(portfolio, broker, NOW2);
        assert any("closed @ 95.00 (stop)" in c for c in changes) and not position.open();
    } finally {
        fake.stop();
    }
}

test "a stop that expired is re-placed with a fresh ID, and one above the price becomes a sale" {
    fake = FakeBroker();
    try {
        broker = broker_for(fake);
        portfolio = team();
        position = opened(fake, portfolio);
        first = fake.working_orders("AAA")[0];
        first.status = "expired";
        keep_stops(portfolio, broker, NOW2);
        again = fake.working_orders("AAA");
        assert len(again) == 1 and again[0].client_order_id.endswith("-stop2") and position.stops_placed == 2;
        again[0].status = "canceled";
        fake.prices["AAA"] = 95.5;
        changes = keep_stops(portfolio, broker, NOW2, {"AAA": 95.5});
        sale = fake.working_orders("AAA")[0];
        assert sale.order_type == "limit" and sale.side == "sell" and sale.qty == 40 and sale.limit_price == 95.21;
        assert "at or below the stop" in changes[0];
    } finally {
        fake.stop();
    }
}

test "a refusal by the broker is recorded on the order and the stop comes back" {
    fake = FakeBroker();
    try {
        broker = broker_for(fake);
        portfolio = team();
        opened(fake, portfolio);
        fake.untradable.add("AAA");
        run = finished_run(portfolio, DAY2, [Call(ticker="AAA", action=TradeAction.SELL)]);
        execute_run(portfolio, run, broker, NOW2, market({"AAA": 98.0}, NOW2));
        exit_order = [o for o in sent(portfolio) if o.purpose == OrderPurpose.EXIT][0];
        assert exit_order.status == "rejected" and "not tradable" in exit_order.reject_reason;
        fake.untradable.discard("AAA");
        keep_stops(portfolio, broker, NOW2);
        assert stops_at(fake, "AAA") == [(40, 96.0)];
    } finally {
        fake.stop();
    }
}

test "every order sent traces back to a risk check or a position" {
    fake = FakeBroker();
    try {
        broker = broker_for(fake);
        portfolio = team();
        opened(fake, portfolio);
        run = finished_run(portfolio, DAY2, [Call(ticker="AAA", action=TradeAction.TRIM)]);
        execute_run(portfolio, run, broker, NOW2, market({"AAA": 100.0}, NOW2));
        for o in sent(portfolio) {
            checks = [rc for rc in [o <-:Placed:<-[?:RiskCheck]]];
            if o.purpose == OrderPurpose.STOP {
                assert checks == [];
            } else {
                assert len(checks) == 1 and checks[0].approved_qty >= o.qty and checks[0].outcome != RiskOutcome.REJECTED;
            }
        }
        assert {o.client_order_id for o in sent(portfolio)} == {o.client_order_id for o in fake.orders};
    } finally {
        fake.stop();
    }
}
