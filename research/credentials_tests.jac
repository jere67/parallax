"""Whose keys work uses: a scope never falls back to the server's keys."""
import os;
import from research.collector { MissingKey, bucket_for, env_key }
import from research.credentials { ALPACA_KEY, Credentials, FINNHUB_KEY, enter_credentials, key_fingerprint, leave_credentials, redact, user_key }
import from research.sources { SOURCES }

def scoped[T](keys: dict[str, str], work: Callable[[], T]) -> T {
    token = enter_credentials(Credentials(keys, "owner"));
    try {
        return work();
    } finally {
        leave_credentials(token);
    }
}

test "outside a scope a key comes from the environment" {
    os.environ[FINNHUB_KEY] = "server-finnhub";
    assert user_key(FINNHUB_KEY) == "server-finnhub";
    assert key_fingerprint(FINNHUB_KEY) == "";
}

test "inside a scope a key comes from its owner and never from the environment" {
    os.environ[FINNHUB_KEY] = "server-finnhub";
    assert scoped({FINNHUB_KEY: "user-finnhub"}, lambda { user_key(FINNHUB_KEY); }) == "user-finnhub";
    assert scoped({ALPACA_KEY: "user-alpaca"}, lambda { user_key(FINNHUB_KEY); }) == "";
}

test "a key an owner did not connect is a missing key, which the collector reports as a gap" {
    os.environ[FINNHUB_KEY] = "server-finnhub";
    def read -> str {
        try {
            return env_key("finnhub", FINNHUB_KEY);
        } except MissingKey as e {
            return e.detail;
        }
    }
    assert "not connected in Settings" in scoped({}, read);
}

test "server settings that are not user keys still come from the environment in a scope" {
    os.environ["SEC_USER_AGENT"] = "Parallax test@example.com";
    assert scoped({}, lambda { user_key("SEC_USER_AGENT"); }) == "Parallax test@example.com";
}

test "two users' keys have separate rate limits, while the SEC's stays one for the server" {
    a = scoped({FINNHUB_KEY: "user-a-key"}, lambda { bucket_for(SOURCES["finnhub"]); });
    b = scoped({FINNHUB_KEY: "user-b-key"}, lambda { bucket_for(SOURCES["finnhub"]); });
    again = scoped({FINNHUB_KEY: "user-a-key"}, lambda { bucket_for(SOURCES["finnhub"]); });
    assert a is not b and a is again;
    sec_a = scoped({FINNHUB_KEY: "user-a-key"}, lambda { bucket_for(SOURCES["sec_data"]); });
    sec_b = scoped({FINNHUB_KEY: "user-b-key"}, lambda { bucket_for(SOURCES["sec_data"]); });
    assert sec_a is sec_b;
}

test "a provider's message cannot carry a key into anything stored" {
    said = scoped({FINNHUB_KEY: "user-finnhub-secret"}, lambda { redact("refused key user-finnhub-secret today"); });
    assert said == "refused key [key removed] today";
}

test "printing credentials does not print the keys" {
    assert "user-secret" not in repr(Credentials({FINNHUB_KEY: "user-secret"}, "owner"));
}
