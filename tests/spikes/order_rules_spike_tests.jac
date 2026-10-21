"""The order-rule spike (tests/spikes/order_rules_spike.jac) run end to end against the fake
broker, which fills marketable orders at once, so the script is known to work before it
touches the paper account."""
import os;
import tempfile;
import from pathlib { Path }
import from action.broker { Broker }
import from research.collector { TokenBucket }
import from tests.fakes.broker_server { FakeBroker }
import from tests.spikes.order_rules_spike { SYMBOL, Spike }

test "the spike runs every step on a fake account and leaves it flat" {
    fake = FakeBroker(auto_fill=True);
    url = fake.start();
    saved = {k: os.environ.get(k) for k in ["ALPACA_DATA_URL", "ALPACA_API_KEY", "ALPACA_SECRET_KEY"]};
    os.environ["ALPACA_DATA_URL"] = url;
    os.environ["ALPACA_API_KEY"] = os.environ.get("ALPACA_API_KEY") or "test-key";
    os.environ["ALPACA_SECRET_KEY"] = os.environ.get("ALPACA_SECRET_KEY") or "test-secret";
    try {
        fake.set_price(SYMBOL, 10.0);
        out = Path(tempfile.mkdtemp()) / "spike.json";
        broker = Broker(base_url=url, headers={"APCA-API-KEY-ID": "k", "APCA-API-SECRET-KEY": "s"}, bucket=TokenBucket(per_minute=60000.0, burst=1000));
        spike = Spike(broker=broker, tag="test", out=out);
        spike.run();
        steps = {s.name: s for s in spike.steps};
        assert steps["entry"].orders[0]["status"] == "filled";
        assert steps["reuse-id"].status == 422;
        assert steps["stop-after-fill"].status == 200 and steps["stop-after-fill"].orders[0]["status"] == "pending_new";
        assert steps["add-with-stop"].status == 403 and "wash trade" in steps["add-with-stop"].message;
        assert steps["exit-with-stop"].status == 403 and "insufficient qty" in steps["exit-with-stop"].message;
        assert steps["add"].orders[0]["status"] == "filled" and steps["add-restop"].sent["qty"] == "3";
        assert steps["trim"].orders[0]["status"] == "filled" and steps["trim-restop"].sent["qty"] == "2";
        assert steps["cancel-twice"].note == "cancel accepted: True";
        assert steps["oto"].status == 422;
        assert fake.positions == {} and fake.working_orders() == [];
        assert out.exists();
    } finally {
        for (k, v) in saved.items() {
            if v is None {
                os.environ.pop(k, None);
            } else {
                os.environ[k] = v;
            }
        }
        fake.stop();
    }
}

test "the closed-market part checks submission rules, fills nothing, and cancels every order" {
    fake = FakeBroker(is_open=False);
    url = fake.start();
    saved = {k: os.environ.get(k) for k in ["ALPACA_DATA_URL", "ALPACA_API_KEY", "ALPACA_SECRET_KEY"]};
    os.environ["ALPACA_DATA_URL"] = url;
    os.environ["ALPACA_API_KEY"] = os.environ.get("ALPACA_API_KEY") or "test-key";
    os.environ["ALPACA_SECRET_KEY"] = os.environ.get("ALPACA_SECRET_KEY") or "test-secret";
    try {
        fake.set_price(SYMBOL, 10.0);
        broker = Broker(base_url=url, headers={"APCA-API-KEY-ID": "k", "APCA-API-SECRET-KEY": "s"}, bucket=TokenBucket(per_minute=60000.0, burst=1000));
        spike = Spike(broker=broker, tag="test", out=Path(tempfile.mkdtemp()) / "spike.json");
        spike.run_closed();
        steps = {s.name: s for s in spike.steps};
        assert steps["closed-entry"].status == 200 and steps["closed-entry"].orders[0]["status"] == "accepted" and steps["closed-entry"].orders[0]["filled_qty"] == 0;
        assert steps["closed-reuse-id"].status == 422;
        assert steps["closed-opposite-sell"].status == 403 and "wash trade" in steps["closed-opposite-sell"].message;
        assert steps["closed-stop-no-shares"].status == 403;
        assert steps["closed-oto"].status == 422;
        assert steps["cancel-twice"].note == "cancel accepted: True";
        assert fake.positions == {} and fake.working_orders() == [];
    } finally {
        for (k, v) in saved.items() {
            if v is None {
                os.environ.pop(k, None);
            } else {
                os.environ[k] = v;
            }
        }
        fake.stop();
    }
}
