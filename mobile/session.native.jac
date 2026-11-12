"""Remembers the signed-in session between launches - NATIVE variant, in the iOS keychain or
Android keystore through expo-secure-store. Same names as `session.jac`."""

import from "expo-secure-store" { getItemAsync, setItemAsync, deleteItemAsync }

glob KEY: str = "parallax.session";

"""The saved session as {"server", "token", "username", "seen"}, or None."""
async def:pub load_session -> dict[str, str] | None {
    try {
        raw = await getItemAsync(KEY);
        return JSON.parse(raw) if raw else None;  # jac:ignore[E1002,E1032]
    } except Exception {
        return None;
    }
}

async def:pub save_session(session: dict[str, str]) {
    try {
        await setItemAsync(KEY, JSON.stringify(session));  # jac:ignore[E1032]
    } except Exception { }
}

async def:pub clear_session {
    try {
        await deleteItemAsync(KEY);
    } except Exception { }
}
