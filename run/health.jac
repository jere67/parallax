"""Health endpoint for probes, the dashboard, and checking a deployment."""
import from datetime { datetime, timezone }
import from urllib.parse { urlsplit }
import from run.switches { demo_mode }
import from action.broker { NotPaper, PAPER_HOST, trading_base_url }
import from action.executor { orders_disabled }
import from models.health { Health }

"""Where orders would go: Alpaca's paper API, a local test server, or a host the broker refuses."""
def broker_target -> str {
    try {
        url = trading_base_url();
    } except NotPaper {
        return "refused";
    }
    return "paper" if urlsplit(url).hostname == PAPER_HOST else "test";
}

"""Report that the server is up, stamped with the current UTC time, with the switches that decide
whether it can trade. It names no key and no account, so it needs no login."""
def:pub health -> Health {
    return Health(
        status="ok",
        checked_at=datetime.now(timezone.utc).isoformat(),
        demo=demo_mode(),
        orders="off" if orders_disabled() else "on",
        broker=broker_target()
    );
}
