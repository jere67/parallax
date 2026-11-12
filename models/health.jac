"""Service health, returned to the dashboard and to anyone checking a deployment."""
obj Health {
    has status: str,
        checked_at: str;
    has demo: bool = False,
        orders: str = "on",
        broker: str = "paper";
}

sem Health.status = "'ok' when the server is up and answering requests.";
sem Health.checked_at = "Server time of the check, ISO 8601 in UTC.";
sem Health.demo = "True when the server shows the seeded demo history, in which no agent runs or trades.";
sem Health.orders = "'on' when the executor may send orders, 'off' when TRADING_AGENT_DISABLE_ORDERS stops every order.";
sem Health.broker = "Where orders would go: 'paper' for Alpaca's paper API, 'test' for a local test server, 'refused' for any other host, which the broker never calls.";
