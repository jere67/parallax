"""The paper broker client (action/broker.jac) against the fake broker, so no test reaches
Alpaca."""
import os;
import from action.broker { Broker, BrokerError, NotPaper, OrderRequest, tick_price, trading_base_url }
import from tests.fakes.broker_server { FakeBroker, Scripted }

glob KEYS: dict[str, str] = {"APCA-API-KEY-ID": "test-key", "APCA-API-SECRET-KEY": "test-secret"};

def broker_on(fake: FakeBroker) -> Broker {
    return Broker(base_url=fake.start(), headers=KEYS, backoff_s=0.0);
}

def limit_buy(symbol: str, qty: int, cid: str, price: float = 10.0) -> OrderRequest {
    return OrderRequest(symbol=symbol, side="buy", qty=qty, order_type="limit", time_in_force="day", client_order_id=cid, limit_price=price);
}

test "only the paper host or a local test server may receive orders" {
    saved = os.environ.get("ALPACA_BASE_URL");
    try {
        os.environ["ALPACA_BASE_URL"] = "https://api.alpaca.markets";
        try {
            trading_base_url();
            assert False, "a live URL was accepted";
        } except NotPaper {}
        try {
            Broker(base_url="https://api.alpaca.markets", headers=KEYS);
            assert False, "a live URL was accepted";
        } except NotPaper {}
        os.environ["ALPACA_BASE_URL"] = "https://paper-api.alpaca.markets/";
        assert trading_base_url() == "https://paper-api.alpaca.markets";
        del os.environ["ALPACA_BASE_URL"];
        assert trading_base_url() == "https://paper-api.alpaca.markets";
    } finally {
        if saved is None {
            os.environ.pop("ALPACA_BASE_URL", None);
        } else {
            os.environ["ALPACA_BASE_URL"] = saved;
        }
    }
}

test "an account that is not a paper account is refused" {
    fake = FakeBroker(account_number="912345678");
    try {
        broker = broker_on(fake);
        try {
            broker.account();
            assert False, "a live account was accepted";
        } except NotPaper {}
    } finally {
        fake.stop();
    }
}

test "the account, positions, and orders parse into whole shares and floats" {
    fake = FakeBroker(cash=10000.0);
    try {
        broker = broker_on(fake);
        fake.set_price("F", 10.0);
        placed = broker.submit(limit_buy("F", 5, "run-F-buy", 10.03));
        assert placed.working() and placed.qty == 5 and placed.limit_price == 10.03 and placed.order_type == "limit";
        fake.fill("run-F-buy", 2, 10.01);
        seen = broker.order(placed.id);
        assert seen.status == "partially_filled" and seen.filled_qty == 2 and seen.filled_avg_price == 10.01;
        held = broker.positions()["F"];
        assert held.qty == 2 and held.avg_entry_price == 10.01;
        account = broker.account();
        assert account.number.startswith("PA") and round(account.cash, 2) == round(10000.0 - 20.02, 2);
        assert [o.client_order_id for o in broker.orders("open")] == ["run-F-buy"];
        assert broker.orders("closed") == [];
    } finally {
        fake.stop();
    }
}

test "submitting a client order ID twice returns the first order and places nothing new" {
    fake = FakeBroker();
    try {
        broker = broker_on(fake);
        fake.set_price("F", 10.0);
        first = broker.submit(limit_buy("F", 1, "run-F-buy"));
        again = broker.submit(limit_buy("F", 1, "run-F-buy"));
        assert again.id == first.id and len(fake.orders) == 1;
        assert broker.order_by_client_id("missing") is None;
    } finally {
        fake.stop();
    }
}

test "a POST that fails with a 5xx is retried only when the order was not created" {
    fake = FakeBroker();
    try {
        broker = broker_on(fake);
        fake.set_price("F", 10.0);
        fake.script = [Scripted(method="POST", path="/v2/orders", status=503, body="{\"message\": \"busy\"}")];
        placed = broker.submit(limit_buy("F", 1, "run-F-buy"));
        assert placed.client_order_id == "run-F-buy" and len(fake.orders) == 1;
        assert fake.requests.count("POST /v2/orders") == 2;
    } finally {
        fake.stop();
    }
}

test "a refusal such as wash-trade protection raises with Alpaca's message and is not retried" {
    fake = FakeBroker();
    try {
        broker = broker_on(fake);
        fake.set_price("F", 10.0);
        broker.submit(limit_buy("F", 2, "run-F-buy"));
        fake.fill("run-F-buy");
        broker.submit(OrderRequest(symbol="F", side="sell", qty=2, order_type="stop", time_in_force="gtc", client_order_id="run-F-stop", stop_price=9.0));
        try {
            broker.submit(limit_buy("F", 1, "run-F-add"));
            assert False, "the add went through a working stop";
        } except BrokerError as e {
            assert e.status == 403 and "wash trade" in e.detail;
        }
        assert fake.requests.count("POST /v2/orders") == 3;
    } finally {
        fake.stop();
    }
}

test "cancel reports whether the order could still be canceled, and cancel_and_wait returns it closed" {
    fake = FakeBroker();
    try {
        broker = broker_on(fake);
        fake.set_price("F", 10.0);
        placed = broker.submit(limit_buy("F", 1, "run-F-buy"));
        closed = broker.cancel_and_wait(placed.id);
        assert closed.status == "canceled" and not closed.working();
        assert not broker.cancel(placed.id);
    } finally {
        fake.stop();
    }
}

test "prices go out on Alpaca's tick and a bad order never leaves" {
    assert tick_price(10.0349) == "10.03" and tick_price(10.035) in ("10.03", "10.04");
    assert tick_price(0.51234) == "0.5123";
    for bad in [0.0, -1.0, float("nan")] {
        try {
            tick_price(bad);
            assert False, f"{bad} was accepted";
        } except ValueError {}
    }
    for (qty, side, kind) in [(0, "buy", "limit"), (1, "short", "limit"), (1, "buy", "stop")] {
        try {
            OrderRequest(symbol="F", side=side, qty=qty, order_type=kind, time_in_force="day", client_order_id="x");
            assert False, f"{qty} {side} {kind} was accepted";
        } except ValueError {}
    }
    body = OrderRequest(symbol="F", side="buy", qty=1, order_type="limit", time_in_force="day", client_order_id="x", limit_price=10.0, stop_loss_price=9.0).body();
    assert body["order_class"] == "oto" and body["stop_loss"] == {"stop_price": "9.00"} and body["qty"] == "1";
}
