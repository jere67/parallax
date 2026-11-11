"""One Alpaca account per agent (TDD §9, accounts).

Two agents on one paper account trade each other's cash and positions: each marks the whole
account as its own, and an order one places can be taken for the other's. On 2026-11-11 a
user's agent and the team agent shared the team's account, and the team's AMZN buy found the
user's order instead of placing its own. So keys that open an account another agent trades are
refused when connected, paper trading cannot be turned on with them, and an agent connected
before this check keeps researching but places no orders.

An account is known by `account_fingerprint`, a digest of its number, stored on each
`AgentAccount`. The team agent's account is read with the server's own keys, once per process.
"""
import threading;
import from accounts.providers { account_fingerprint, read_account }
import from accounts.store { all_accounts, credentials_of, read_as_system }
import from accounts.vault { VaultError }
import from action.broker { Broker, BrokerError }
import from models.accounts { AgentAccount }
import from research.collector { SourceError }
import from research.credentials { ALPACA_KEY, ALPACA_SECRET, enter_server_keys, leave_credentials, user_key }

glob TEAM_WORDS: str = "These keys open the team agent's Alpaca paper account. Each agent needs its own: create another paper account on Alpaca's dashboard and connect its keys.";
glob AGENT_WORDS: str = "These keys open a paper account another agent already trades. Each agent needs its own: create another paper account on Alpaca's dashboard and connect its keys.";

glob _LOCK: threading.Lock = threading.Lock();
# The team agent's account by a digest of the server's key ID, so new keys are read afresh.
glob _TEAM: dict[str, str] = {};
# Fingerprints a trading tick read for agents connected before `alpaca_account` was stored, by
# owner: the tick may not write the account (run/agents.jac), so it remembers them here.
glob _SEEN: dict[str, str] = {};

"""The team agent's account fingerprint, or "" when the server has no Alpaca keys or Alpaca could
not be reached (then nothing is refused for sharing it, and the next call asks again)."""
def team_account -> str {
    token = enter_server_keys();
    try {
        key = account_fingerprint(user_key(ALPACA_KEY));
        with _LOCK {
            if key in _TEAM {
                return _TEAM[key];
            }
        }
        found = account_fingerprint(Broker(max_retries=0).account().number);
    } except (BrokerError, SourceError) {
        return "";
    } finally {
        leave_credentials(token);
    }
    if found {
        with _LOCK {
            _TEAM[key] = found;
        }
    }
    return found;
}

"""The account `account`'s keys open: the stored fingerprint, else the one a tick read, else read
from Alpaca with its keys now, or "" when Alpaca could not be reached."""
def account_of(account: AgentAccount) -> str {
    if account.alpaca_account {
        return account.alpaca_account;
    }
    with _LOCK {
        if account.owner_root in _SEEN {
            return _SEEN[account.owner_root];
        }
    }
    try {
        keys = credentials_of(account).keys;
    } except VaultError {
        return "";
    }
    if ALPACA_KEY not in keys or ALPACA_SECRET not in keys {
        return "";
    }
    try {
        found = account_fingerprint(read_account(keys[ALPACA_KEY], keys[ALPACA_SECRET]).number);
    } except BrokerError {
        return "";
    }
    remember(account.owner_root, found);
    return found;
}

def remember(owner: str, fingerprint: str) {
    if fingerprint {
        with _LOCK {
            _SEEN[owner] = fingerprint;
        }
    }
}

"""Why the account `fingerprint` cannot be `owner`'s agent's, or "" when it is its alone."""
def sharing_problem(fingerprint: str, owner: str) -> str {
    if not fingerprint {
        return "";
    }
    if fingerprint == team_account() {
        return TEAM_WORDS;
    }
    with _LOCK {
        seen = dict(_SEEN);
    }
    for other in read_as_system(all_accounts) {
        if other.owner_root != owner and (other.alpaca_account or seen.get(other.owner_root, "")) == fingerprint {
            return AGENT_WORDS;
        }
    }
    return "";
}
