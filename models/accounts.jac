"""One user's agent account (TDD §9, accounts).

    root.shared ──> AgentAccount (created by its owner, granted to nobody)
    user root   ──> Portfolio(name "agent") ──> ... the same graph as models/graph.jac

The account sits on root.shared so the scheduled jobs, which run on the super root, can find
every agent. It carries no grant, so only its owner and the super root can read it: another
user's walk of root.shared does not see it (tests/accounts_api_tests.jac).

Keys are sealed (accounts/vault.jac), and nothing here ever leaves the server but their hints.

This module's path is frozen for the same reason as models/graph.jac.
"""

"""A user's agent: their sealed keys by environment name, and what they have asked it to do.

`hints` holds what a reader may see of each key (its last four characters, or the paper
account's). `paper_trading` is the owner's choice and `trading_start_day` the New York date
their forward test starts: the trading job turns these into the portfolio's mode, because a
morning run holds the portfolio for its whole transaction, and a write here must not conflict
with it. `run_requested_day` is a run asked for by hand. `alpaca_account` is the fingerprint of
the paper account the Alpaca keys open (accounts/sharing.jac), so no two agents trade one account."""
node AgentAccount {
    has owner_root: str,
        created_at: str;
    has sealed: dict[str, str] = {},
        hints: dict[str, str] = {},
        checked_at: dict[str, str] = {},
        requests_note: str = "",
        paper_trading: bool = False,
        trading_start_day: str = "",
        run_requested_day: str = "",
        alpaca_account: str = "";
}

"""One key on the settings page, without its value."""
obj KeyStatus {
    has name: str,
        label: str,
        required: bool,
        connected: bool;
    has hint: str = "",
        checked_at: str = "";
}

"""What today's run is doing for this agent, and whether the owner can start it."""
obj RunState {
    has day: str;
    has status: str = "",
        can_start: bool = False,
        note: str = "";
}

"""The settings page. `managed` is the admin's agent, which runs on the server's own keys and
which the page does not change; `demo` is a server that only shows the made-up history;
`can_store` is False when the server has no secret to seal keys with; `full` is a server at its
limit of agents, for a user who does not have one yet."""
obj AgentSettings {
    has managed: bool,
        demo: bool,
        can_store: bool,
        full: bool,
        ready: bool,
        paper_trading: bool,
        keys: list[KeyStatus],
        run: RunState;
    has requests_note: str = "",
        trading_started: bool = False,
        alpaca_problem: str = "";
}

"""What a save did: the page as it now is, and why each refused field was refused, by the
field's name. Nothing is saved unless every key sent passes."""
obj KeysReply {
    has saved: bool,
        settings: AgentSettings;
    has message: str = "",
        problems: dict[str, str] = {};
}

"""What a choice on the settings page did."""
obj AgentReply {
    has ok: bool,
        message: str,
        settings: AgentSettings;
}
