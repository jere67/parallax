"""Reconciliation (action/reconcile.jac): drift against Alpaca, the gate-bypass audit, and the
daily mark's peak and drawdown."""
import from datetime { datetime, timezone }
import from action.executor { execute_run, keep_stops, open_positions, sync_orders }
import from action.fixtures { Call, broker_for, finished_run, market, team }
import from action.reconcile { audit_orders, reconcile }
import from models.graph { Order, OrderPurpose, OrderSide, Portfolio, Sent, TradeAction }
import from tests.fakes.broker_server { FakeBroker }

glob DAY: str = "2026-10-21";
glob NOW: datetime = datetime(2026, 10, 21, 13, 45, tzinfo=timezone.utc);
glob CLOSE: datetime = datetime(2026, 10, 21, 20, 30, tzinfo=timezone.utc);

def holding_aaa(fake: FakeBroker) -> Portfolio {
    broker = broker_for(fake);
    portfolio = team();
    fake.set_price("AAA", 100.0);
    execute_run(portfolio, finished_run(portfolio, DAY, [Call(ticker="AAA", action=TradeAction.BUY)]), broker, NOW, market({"AAA": 100.0}, NOW));
    fake.fill(f"{DAY}-AAA-entry");
    sync_orders(portfolio, broker, NOW);
    keep_stops(portfolio, broker, NOW);
    return portfolio;
}

test "a share count that differs from Alpaca's is corrected and listed as drift" {
    fake = FakeBroker();
    try {
        portfolio = holding_aaa(fake);
        fake.positions["AAA"].qty = 35;
        mark = reconcile(portfolio, broker_for(fake), CLOSE, DAY);
        assert mark.drift == ["AAA: 40 shares on record, 35 at Alpaca; record corrected"];
        assert open_positions(portfolio)["AAA"].qty == 35 and mark.bypasses == [];
    } finally {
        fake.stop();
    }
}

test "an order with no approving risk check, and a stop with no position, are bypasses" {
    fake = FakeBroker();
    try {
        portfolio = holding_aaa(fake);
        stray = Order(client_order_id="stray", purpose=OrderPurpose.ENTRY, side=OrderSide.BUY, qty=5, order_type="limit", time_in_force="day", submitted_at=NOW.isoformat(), alpaca_order_id="x", ticker="AAA");
        orphan = Order(client_order_id="orphan-stop", purpose=OrderPurpose.STOP, side=OrderSide.SELL, qty=5, order_type="stop", time_in_force="gtc", submitted_at=NOW.isoformat(), alpaca_order_id="y", ticker="AAA");
        portfolio +>:Sent():+> stray;
        portfolio +>:Sent():+> orphan;
        found = audit_orders(portfolio, broker_for(fake), portfolio.opened_at);
        assert found == ["stray: buy 5 AAA without a risk-gate approval for it", "orphan-stop: a stop with no position"];
    } finally {
        fake.stop();
    }
}

test "peak equity only moves up, and the mark measures drawdown from it" {
    fake = FakeBroker();
    try {
        portfolio = holding_aaa(fake);
        broker = broker_for(fake);
        first = reconcile(portfolio, broker, CLOSE, DAY);
        assert first.drawdown == 0.0 and portfolio.peak_equity == first.equity;
        peak = portfolio.peak_equity;
        fake.set_price("AAA", 97.0);
        second = reconcile(portfolio, broker, datetime(2026, 10, 22, 20, 30, tzinfo=timezone.utc), "2026-10-22");
        assert portfolio.peak_equity == peak and second.equity == peak - 120.0;
        assert abs(second.drawdown - 120.0 / peak) < 1e-12 and second.open_positions == 1;
        again = reconcile(portfolio, broker, datetime(2026, 10, 22, 20, 45, tzinfo=timezone.utc), "2026-10-22");
        assert again is second;
    } finally {
        fake.stop();
    }
}
