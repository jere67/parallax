"""Whose API keys a piece of work uses.

The server's own keys live in its environment and run the admin's agent, as they always have.
Every other agent runs on the keys its owner connected in Settings. A run enters its owner's
scope, and everything underneath it (collectors, the broker, model calls, including their
worker threads, since run/workers.jac copies the context) reads keys through `user_key`.

Inside a scope, a key the owner did not connect is missing: it never falls back to the
server's, so one user's agent can never spend another account's allowance.

This module sits below the collectors and models, so it imports neither.
"""
import hashlib;
import os;
import from contextvars { ContextVar, Token }

glob ALPACA_KEY: str = "ALPACA_API_KEY";
glob ALPACA_SECRET: str = "ALPACA_SECRET_KEY";
glob OPENROUTER_KEY: str = "OPENROUTER_API_KEY";
glob FINNHUB_KEY: str = "FINNHUB_API_KEY";
# The keys a user brings. Anything else, such as SEC_USER_AGENT, is the server's setting.
glob USER_KEYS: tuple[str, ...] = (ALPACA_KEY, ALPACA_SECRET, OPENROUTER_KEY, FINNHUB_KEY);
glob REDACTED: str = "[key removed]";

"""One user's keys by environment name. Its repr leaves the values out, so a log line or a
traceback that prints it cannot leak them."""
class Credentials {
    def init(self: Credentials, keys: dict[str, str], owner: str = "") -> None {
        self.keys = keys;
        self.owner = owner;
    }

    def __repr__(self: Credentials) -> str {
        return f"Credentials(owner={self.owner!r}, keys={sorted(self.keys)})";
    }
}

glob _SCOPE: ContextVar[Credentials | None] = ContextVar("parallax_credentials", `default=None);

def enter_credentials(found: Credentials) -> Token {
    return _SCOPE.set(found);
}

def leave_credentials(token: Token) {
    _SCOPE.reset(token);
}

"""The scope this work runs in, or None for the server's own keys."""
def current_credentials -> Credentials | None {
    return _SCOPE.get();
}

"""The value of key `name` for this work, stripped, or "" when it has none."""
def user_key(name: str) -> str {
    scope = _SCOPE.get();
    if scope is not None and name in USER_KEYS {
        return scope.keys.get(name, "").strip();
    }
    return os.environ.get(name, "").strip();
}

"""A short digest of key `name` that tells two users' rate limits apart, or "" for the server's
own keys, whose limits stay process-wide."""
def key_fingerprint(name: str) -> str {
    if _SCOPE.get() is None {
        return "";
    }
    return hashlib.sha256(user_key(name).encode()).hexdigest()[:16];
}

"""`text` without any key this work can use, for anything stored or shown: a provider's error
message can quote the key it refused."""
def redact(text: str) -> str {
    for name in USER_KEYS {
        value = user_key(name);
        if len(value) >= 8 {
            text = text.replace(value, REDACTED);
        }
    }
    return text;
}
