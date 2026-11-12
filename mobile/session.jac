"""Remembers the signed-in session between launches - WEB variant, in the browser's storage.
`session.native.jac` keeps it in the phone's keychain; both export the same names."""

glob KEY: str = "parallax.session";

"""The saved session as {"server", "token", "username", "seen"}, or None."""
async def:pub load_session -> dict[str, str] | None {
    try {
        raw = localStorage.getItem(KEY);
        return JSON.parse(raw) if raw else None;  # jac:ignore[E1002,E1032]
    } except Exception {
        return None;
    }
}

async def:pub save_session(session: dict[str, str]) {
    try {
        localStorage.setItem(KEY, JSON.stringify(session));  # jac:ignore[E1032]
    } except Exception { }
}

async def:pub clear_session {
    try {
        localStorage.removeItem(KEY);
    } except Exception { }
}
