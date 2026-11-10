"""Checking a key with the provider that issued it, before it is stored (TDD §9, accounts).

Each check spends no model request and places no order. It answers in words a user can act on,
never with the key, and treats a provider that cannot be reached differently from one that
refused: the first is worth trying again, the second is a wrong key.
"""
import os;
import httpx;
import from action.broker { Account, Broker, BrokerError, NotPaper }
import from agents.models { OPENROUTER_API_BASE, OPENROUTER_API_BASE_ENV }
import from research.credentials { ALPACA_KEY, ALPACA_SECRET, Credentials, enter_credentials, leave_credentials }
import from research.sources { SOURCES }

# A standard run's requests with retries (run/guard.jac, RunLimits).
glob FULL_RUN_REQUESTS: int = 460;
glob CHECK_TIMEOUT_S: float = 15.0;

"""What a check found: `problem` is empty when the key works, `hint` is what a reader may see of
it, and `note` is anything worth telling its owner."""
obj KeyCheck {
    has problem: str = "",
        hint: str = "",
        note: str = "";
}

"""The last four characters, which identify a key without giving it away."""
def tail_of(value: str) -> str {
    return "…" + value[-4:] if len(value) > 4 else "…";
}

def alpaca_words(e: BrokerError) -> str {
    if isinstance(e, NotPaper) {
        return "These keys belong to a live account. Parallax only trades on paper, so use the keys from Alpaca's paper trading dashboard.";
    }
    if e.status in (401, 403) {
        return "Alpaca's paper API refused these keys. Check that both come from the paper trading dashboard: live keys do not work here.";
    }
    return "Alpaca could not be reached, so these keys were not checked. Try again in a moment.";
}

"""The pair's paper account, read from the paper host only: live keys are refused there, and
Broker refuses any other host and any account that is not a paper one."""
def read_account(key: str, secret: str) -> Account {
    token = enter_credentials(Credentials({ALPACA_KEY: key, ALPACA_SECRET: secret}));
    try {
        return Broker(max_retries=0, timeout_s=CHECK_TIMEOUT_S).account();
    } finally {
        leave_credentials(token);
    }
}

def check_alpaca(key: str, secret: str) -> KeyCheck {
    try {
        found = read_account(key, secret);
        if found.trading_blocked {
            return KeyCheck(problem="Alpaca has blocked trading on this paper account. Reset it from Alpaca's dashboard, then connect it again.");
        }
        return KeyCheck(hint=tail_of(found.number));
    } except BrokerError as e {
        return KeyCheck(problem=alpaca_words(e));
    }
}

"""The key's free-model allowance. A full run needs more than a new account's free limit, so its
owner hears that now rather than from a run cut short."""
def check_openrouter(key: str) -> KeyCheck {
    base = os.environ.get(OPENROUTER_API_BASE_ENV, OPENROUTER_API_BASE).rstrip("/");
    try {
        response = httpx.get(f"{base}/key", headers={"Authorization": f"Bearer {key}"}, timeout=CHECK_TIMEOUT_S);
    } except httpx.TransportError {
        return KeyCheck(problem="OpenRouter could not be reached, so this key was not checked. Try again in a moment.");
    }
    if response.status_code in (401, 403) {
        return KeyCheck(problem="OpenRouter refused this key. Copy it again from your OpenRouter account's keys page.");
    }
    if response.status_code != 200 {
        return KeyCheck(problem="OpenRouter could not check this key just now. Try again in a moment.");
    }
    return KeyCheck(hint=tail_of(key), note=allowance_note(response));
}

def allowance_note(response: httpx.Response) -> str {
    try {
        usage = (response.json().get("data") or {}).get("free_model_daily_requests") or {};
        limit = int(usage["limit"]);
    } except (KeyError, TypeError, ValueError) {
        return "";
    }
    if limit >= FULL_RUN_REQUESTS {
        return "";
    }
    return f"This key allows {limit} free model requests a day, and a full run uses about {FULL_RUN_REQUESTS}, so its runs will cover fewer stocks. OpenRouter raises the limit to 1,000 a day after a one-time $10 credit purchase.";
}

def check_finnhub(key: str) -> KeyCheck {
    source = SOURCES["finnhub"];
    base = (os.environ.get(source.base_url_env) or source.base_url).rstrip("/");
    try {
        response = httpx.get(f"{base}/quote", params={"symbol": "SPY"}, headers={"X-Finnhub-Token": key}, timeout=CHECK_TIMEOUT_S);
    } except httpx.TransportError {
        return KeyCheck(problem="Finnhub could not be reached, so this key was not checked. Try again in a moment.");
    }
    if response.status_code in (401, 403) {
        return KeyCheck(problem="Finnhub refused this key. Copy it again from your Finnhub dashboard.");
    }
    if response.status_code != 200 {
        return KeyCheck(problem="Finnhub could not check this key just now. Try again in a moment.");
    }
    return KeyCheck(hint=tail_of(key));
}
