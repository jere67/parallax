"""The vault: a sealed value opens only for its owner and field, and only under its secret."""
import os;
import from accounts.vault { SECRET_ENV, VaultError, seal, unseal, vault_ready }

glob SECRET: str = "s" * 40;

def with_secret[T](value: str | None, work: Callable[[], T]) -> T {
    saved = os.environ.get(SECRET_ENV);
    if value is None {
        os.environ.pop(SECRET_ENV, None);
    } else {
        os.environ[SECRET_ENV] = value;
    }
    try {
        return work();
    } finally {
        if saved is None {
            os.environ.pop(SECRET_ENV, None);
        } else {
            os.environ[SECRET_ENV] = saved;
        }
    }
}

def refused(work: Callable[[], object]) -> bool {
    try {
        work();
    } except VaultError {
        return True;
    }
    return False;
}

test "a sealed key opens for its owner and hides its value" {
    def check {
        box = seal("owner-1", "ALPACA_API_KEY", "PKABCDEF1234");
        assert "PKABCDEF1234" not in box;
        assert unseal("owner-1", "ALPACA_API_KEY", box) == "PKABCDEF1234";
        assert seal("owner-1", "ALPACA_API_KEY", "PKABCDEF1234") != box;
    }
    with_secret(SECRET, check);
}

test "a sealed key does not open for another owner, another field, or after tampering" {
    def check {
        box = seal("owner-1", "ALPACA_API_KEY", "PKABCDEF1234");
        assert refused(lambda { unseal("owner-2", "ALPACA_API_KEY", box); });
        assert refused(lambda { unseal("owner-1", "FINNHUB_API_KEY", box); });
        assert refused(lambda { unseal("owner-1", "ALPACA_API_KEY", box[:-4] + "AAAA"); });
        assert refused(lambda { unseal("owner-1", "ALPACA_API_KEY", "v0." + box[3:]); });
    }
    with_secret(SECRET, check);
}

test "a sealed key does not open under another secret" {
    box = with_secret(SECRET, lambda { seal("owner-1", "ALPACA_API_KEY", "PKABCDEF1234"); });
    assert with_secret("t" * 40, lambda { refused(lambda { unseal("owner-1", "ALPACA_API_KEY", box); }); });
}

test "with no secret or a short one, nothing can be sealed" {
    assert with_secret(None, lambda { not vault_ready() and refused(lambda { seal("o", "n", "v"); }); });
    assert with_secret("short", lambda { not vault_ready() and refused(lambda { seal("o", "n", "v"); }); });
}
