"""The health report names the switches that decide whether a server can trade."""
import os;
import from action.executor { ORDERS_OFF_ENV }
import from run.health { health }
import from run.switches { DEMO_ENV }

glob SWITCHES: list[str] = [DEMO_ENV, ORDERS_OFF_ENV, "ALPACA_BASE_URL"];

"""Run `check` with the switches set as in `env` and the rest unset, then put them back."""
def with_switches(env: dict[str, str], check: Callable[[], None]) {
    saved = {k: os.environ.get(k) for k in SWITCHES};
    for k in SWITCHES {
        os.environ.pop(k, None);
    }
    os.environ.update(env);
    try {
        check();
    } finally {
        for (k, v) in saved.items() {
            if v is None {
                os.environ.pop(k, None);
            } else {
                os.environ[k] = v;
            }
        }
    }
}

test "a plain server trades on Alpaca's paper API" {
    def check {
        h = health();
        assert (h.status, h.demo, h.orders, h.broker) == ("ok", False, "on", "paper");
    }
    with_switches({}, check);
}

test "a demo server with orders off and a local broker says so" {
    def check {
        h = health();
        assert (h.demo, h.orders, h.broker) == (True, "off", "test");
    }
    with_switches({DEMO_ENV: "1", ORDERS_OFF_ENV: "1", "ALPACA_BASE_URL": "http://127.0.0.1:8399"}, check);
}

test "a live trading host is reported as refused" {
    def check {
        assert health().broker == "refused";
    }
    with_switches({"ALPACA_BASE_URL": "https://api.alpaca.markets"}, check);
}
