"""The settings page's endpoints (TDD §9, accounts): connect keys, choose paper trading, and ask
for a run. Every one acts on the caller's own account, named by nothing the client sends.

A key is checked with its provider before it is stored, and is never sent back: the page sees a
hint and when it was checked. The admin's agent runs on the server's own keys, so this page only
describes it.
"""
import from datetime { datetime }
import logging;
import from accounts.providers { KeyCheck, check_alpaca, check_finnhub, check_openrouter, tail_of }
import from accounts.store {
    REQUIRED_KEYS,
    caller_is_admin,
    credentials_of,
    demo_mode,
    ensure_own_portfolio,
    has_required_keys,
    has_room,
    my_account,
    my_portfolio
}
import from accounts.vault { VaultError, seal, vault_ready }
import from action.baselines { baselines_of }
import from accounts.sharing { account_of, sharing_problem }
import from action.broker { Broker, BrokerError }
import from models.accounts { AgentAccount, AgentReply, AgentSettings, KeyStatus, KeysReply, RunState }
import from research.collector { utc_now }
import from research.credentials { ALPACA_KEY, ALPACA_SECRET, FINNHUB_KEY, OPENROUTER_KEY, enter_credentials, leave_credentials }
import from run.agents { is_running }
import from run.guard { NEW_YORK, find_team_portfolio }
import from run.manual { manual_refusal, request_run }
import from run.trading { run_for }

glob LOG: logging.Logger = logging.getLogger("trading_agent.accounts");
glob MAX_KEY_CHARS: int = 256;
glob KEY_ROWS: list[tuple[str, str, bool]] = [
    (ALPACA_KEY, "Alpaca API key ID", True),
    (ALPACA_SECRET, "Alpaca secret key", True),
    (OPENROUTER_KEY, "OpenRouter API key", True),
    (FINNHUB_KEY, "Finnhub API key", False)
];

"""True when every sealed key opens: a server whose secret changed shows them as not connected,
so the owner connects them again."""
def keys_open(account: AgentAccount) -> bool {
    try {
        credentials_of(account);
        return True;
    } except VaultError {
        return False;
    }
}

def key_rows(account: AgentAccount | None) -> list[KeyStatus] {
    if account is None or not keys_open(account) {
        return [KeyStatus(name=name, label=label, required=required, connected=False) for (name, label, required) in KEY_ROWS];
    }
    return [
        KeyStatus(name=name, label=label, required=required, connected=name in account.sealed, hint=account.hints.get(name, ""), checked_at=account.checked_at.get(name, ""))
        for (name, label, required) in KEY_ROWS
    ];
}

"""Why the caller's own agent cannot start a run on `day`, or "" when it can."""
def own_run_refusal(account: AgentAccount | None, day: str, local: datetime) -> str {
    if demo_mode() {
        return "This server only shows demo history, so it runs nothing.";
    }
    if account is None or not has_required_keys(account) or not keys_open(account) {
        return "Connect your Alpaca and OpenRouter keys first.";
    }
    if local.weekday() >= 5 {
        return f"{day} is a weekend; the market is closed.";
    }
    if is_running(account.owner_root) {
        return "Today's run is working now.";
    }
    if account.run_requested_day == day {
        return "Your run starts within a minute or two.";
    }
    return "";
}

def run_state(account: AgentAccount | None, admin: bool) -> RunState {
    local = datetime.now(NEW_YORK);
    day = local.date().isoformat();
    portfolio = my_portfolio();
    found = run_for(portfolio, day) if portfolio is not None else None;
    status = found.status.value if found is not None else "";
    if admin {
        refusal = manual_refusal(True, find_team_portfolio(), day, local);
        return RunState(day=day, status=status, can_start=not refusal, note=refusal);
    }
    if found is not None {
        return RunState(day=day, status=status, note=f"The run for {day} has finished.");
    }
    if account is not None and is_running(account.owner_root) {
        return RunState(day=day, status="running", note="Today's run is working now. It takes about half an hour.");
    }
    refusal = own_run_refusal(account, day, local);
    return RunState(day=day, status="queued" if account is not None and account.run_requested_day == day else "", can_start=not refusal, note=refusal);
}

def settings_view -> AgentSettings {
    admin = caller_is_admin();
    account = my_account();
    portfolio = my_portfolio();
    rows = key_rows(account);
    return AgentSettings(
        managed=admin,
        demo=demo_mode(),
        can_store=vault_ready(),
        full=account is None and not admin and not has_room(),
        ready=admin or all(r.connected for r in rows if r.required),
        paper_trading=(account.paper_trading if account is not None else False) or (admin and portfolio is not None and portfolio.mode.value == "auto"),
        keys=rows,
        run=run_state(account, admin),
        requests_note=account.requests_note if account is not None else "",
        trading_started=portfolio is not None and bool(baselines_of(portfolio)),
        alpaca_problem=sharing_problem(account_of(account), account.owner_root) if account is not None and not admin and ALPACA_KEY in account.sealed else ""
    );
}

def:protect get_agent_settings -> AgentSettings {
    return settings_view();
}

"""True when a pasted key, without the spaces a copy can pick up at its ends, could be a key."""
def plausible_key(value: str) -> bool {
    text = value.strip();
    return len(text) <= MAX_KEY_CHARS and not any(c.isspace() for c in text);
}

"""The checks for the keys sent for `owner`'s agent: what to store by name, each refused field's
words, the note on the OpenRouter key's allowance (or None if it was not sent), and the
fingerprint of the Alpaca account the keys open (or "" if none were sent). Alpaca keys that open
an account another agent trades are refused (accounts/sharing.jac)."""
def check_sent(alpaca_key: str, alpaca_secret: str, openrouter_key: str, finnhub_key: str, owner: str) -> tuple[dict[str, str], dict[str, str], dict[str, str], str | None, str] {
    keep: dict[str, str] = {};
    hints: dict[str, str] = {};
    problems: dict[str, str] = {};
    note: str | None = None;
    account = "";
    if alpaca_key or alpaca_secret {
        if not alpaca_key or not alpaca_secret {
            problems["alpaca"] = "Enter both the key ID and the secret: Alpaca issues them as a pair.";
        } else {
            found = check_alpaca(alpaca_key, alpaca_secret);
            shared = "" if found.problem else sharing_problem(found.account, owner);
            if found.problem or shared {
                problems["alpaca"] = found.problem or shared;
            } else {
                account = found.account;
                keep[ALPACA_KEY] = alpaca_key;
                keep[ALPACA_SECRET] = alpaca_secret;
                hints[ALPACA_KEY] = tail_of(alpaca_key);
                hints[ALPACA_SECRET] = "Paper account " + found.hint;
            }
        }
    }
    if openrouter_key {
        found = check_openrouter(openrouter_key);
        if found.problem {
            problems["openrouter"] = found.problem;
        } else {
            keep[OPENROUTER_KEY] = openrouter_key;
            hints[OPENROUTER_KEY] = found.hint;
            note = found.note;
        }
    }
    if finnhub_key {
        found = check_finnhub(finnhub_key);
        if found.problem {
            problems["finnhub"] = found.problem;
        } else {
            keep[FINNHUB_KEY] = finnhub_key;
            hints[FINNHUB_KEY] = found.hint;
        }
    }
    return (keep, hints, problems, note, account);
}

"""Why the caller cannot change their keys, or "" when they can."""
def keys_refusal(account: AgentAccount | None) -> str {
    if caller_is_admin() {
        return "This agent runs on the server's own keys.";
    }
    if not vault_ready() {
        return "This server is not set up to store keys yet. Its operator needs to set PARALLAX_KEYS_SECRET.";
    }
    if account is None and not has_room() {
        return "This server is at its limit of agents, so a new one cannot be added right now.";
    }
    if account is not None and is_running(account.owner_root) {
        return "Today's run is working now. Change your keys once it finishes.";
    }
    return "";
}

"""Check the keys sent, and store them all or none. A blank field keeps what is stored."""
def:protect save_agent_keys(alpaca_key: str = "", alpaca_secret: str = "", openrouter_key: str = "", finnhub_key: str = "") -> KeysReply {
    account = my_account();
    refusal = keys_refusal(account);
    if refusal {
        return KeysReply(saved=False, settings=settings_view(), message=refusal);
    }
    if not all(plausible_key(k) for k in [alpaca_key, alpaca_secret, openrouter_key, finnhub_key]) {
        return KeysReply(saved=False, settings=settings_view(), message="One of those does not look like an API key. Copy it again, with no spaces.");
    }
    owner = account.owner_root if account is not None else str(jid(root));
    (keep, hints, problems, note, alpaca_account) = check_sent(alpaca_key.strip(), alpaca_secret.strip(), openrouter_key.strip(), finnhub_key.strip(), owner);
    if problems {
        return KeysReply(saved=False, settings=settings_view(), message="Nothing was saved. Fix the keys marked below.", problems=problems);
    }
    if not keep {
        return KeysReply(saved=False, settings=settings_view(), message="Enter a key to connect.");
    }
    if account is None {
        account = root.shared ++> AgentAccount(owner_root=str(jid(root)), created_at=utc_now().isoformat());
        # Made here, not by the first run: a job must never write the owner's root (run/agents.jac).
        ensure_own_portfolio();
    }
    now = utc_now().isoformat();
    account.sealed = {**account.sealed, **{name: seal(account.owner_root, name, value) for (name, value) in keep.items()}};
    account.hints = {**account.hints, **hints};
    account.checked_at = {**account.checked_at, **{name: now for name in keep}};
    if note is not None {
        account.requests_note = note;
    }
    if alpaca_account {
        account.alpaca_account = alpaca_account;
    }
    LOG.info("an agent connected %s", ", ".join(sorted(keep)));
    return KeysReply(saved=True, settings=settings_view(), message="Connected. Each key was checked with its provider.");
}

"""Disconnect a provider's keys. Without Alpaca or OpenRouter the agent stops running and trading;
its positions stay open on Alpaca, where its owner can close them."""
def:protect remove_agent_keys(provider: str) -> AgentReply {
    account = my_account();
    names = {"alpaca": [ALPACA_KEY, ALPACA_SECRET], "openrouter": [OPENROUTER_KEY], "finnhub": [FINNHUB_KEY]}.get(provider);
    if account is None or names is None {
        return AgentReply(ok=False, message="There is nothing to disconnect.", settings=settings_view());
    }
    if is_running(account.owner_root) {
        return AgentReply(ok=False, message="Today's run is working now. Disconnect once it finishes.", settings=settings_view());
    }
    account.sealed = {k: v for (k, v) in account.sealed.items() if k not in names};
    account.hints = {k: v for (k, v) in account.hints.items() if k not in names};
    account.checked_at = {k: v for (k, v) in account.checked_at.items() if k not in names};
    if provider == "openrouter" {
        account.requests_note = "";
    }
    if provider == "alpaca" {
        account.alpaca_account = "";
    }
    stopped = not has_required_keys(account);
    if stopped {
        account.paper_trading = False;
    }
    return AgentReply(ok=True, message="Disconnected. Your agent stops running until you connect it again." if stopped else "Disconnected.", settings=settings_view());
}

"""Why the paper account cannot start a forward test, or "": it must hold nothing, so the agent and
its two baselines start alike."""
def flat_problem(account: AgentAccount) -> str {
    token = enter_credentials(credentials_of(account));
    try {
        broker = Broker(max_retries=0);
        held = [s for (s, p) in broker.positions().items() if p.qty != 0];
        working = broker.orders("open");
    } except BrokerError {
        return "Alpaca could not be reached, so paper trading was not turned on. Try again in a moment.";
    } finally {
        leave_credentials(token);
    }
    if held or working {
        return f"Your paper account must be empty to start, so your agent and its benchmarks begin alike. It holds {len(held)} positions and {len(working)} open orders. Close them or reset it on Alpaca, then try again.";
    }
    return "";
}

"""Turn the agent's paper orders on or off. On asks only for its next chance to trade: the trading
job carries it out, since a morning run may hold the portfolio."""
def:protect set_paper_trading(on: bool) -> AgentReply {
    account = my_account();
    if caller_is_admin() {
        return AgentReply(ok=False, message="This agent's trading is set on the server.", settings=settings_view());
    }
    if demo_mode() {
        return AgentReply(ok=False, message="This server only shows demo history, so it places no orders.", settings=settings_view());
    }
    if account is None or not has_required_keys(account) or not keys_open(account) {
        return AgentReply(ok=False, message="Connect your Alpaca and OpenRouter keys first.", settings=settings_view());
    }
    if not on {
        account.paper_trading = False;
        return AgentReply(ok=True, message="Paper trading is off. Your agent keeps researching, and open positions stay on Alpaca with their stops.", settings=settings_view());
    }
    found = account_of(account);
    if found and not account.alpaca_account {
        account.alpaca_account = found;
    }
    shared = sharing_problem(found, account.owner_root);
    if shared {
        return AgentReply(ok=False, message=shared, settings=settings_view());
    }
    portfolio = my_portfolio();
    if portfolio is None or not baselines_of(portfolio) {
        problem = flat_problem(account);
        if problem {
            return AgentReply(ok=False, message=problem, settings=settings_view());
        }
        account.trading_start_day = datetime.now(NEW_YORK).date().isoformat();
    }
    account.paper_trading = True;
    return AgentReply(ok=True, message="Paper trading is on. Your agent places paper orders from its next morning run, after 9:45 a.m. New York time.", settings=settings_view());
}

"""Ask for today's run now. It uses the caller's own keys and starts within a couple of minutes."""
def:protect start_my_run -> AgentReply {
    local = datetime.now(NEW_YORK);
    day = local.date().isoformat();
    if caller_is_admin() {
        refusal = manual_refusal(True, find_team_portfolio(), day, local);
        if not refusal {
            request_run(day, local);
        }
        return AgentReply(ok=not refusal, message=refusal or "The run starts within a minute and takes about half an hour.", settings=settings_view());
    }
    account = my_account();
    refusal = own_run_refusal(account, day, local);
    portfolio = my_portfolio();
    if not refusal and portfolio is not None and run_for(portfolio, day) is not None {
        refusal = f"The run for {day} has already finished.";
    }
    if refusal or account is None {
        return AgentReply(ok=False, message=refusal, settings=settings_view());
    }
    account.run_requested_day = day;
    return AgentReply(ok=True, message="Your run starts within a minute or two and takes about half an hour.", settings=settings_view());
}
