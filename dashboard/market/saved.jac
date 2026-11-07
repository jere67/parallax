"""What one reader keeps in this browser: a watchlist of symbols and named screens. Reading fails
quietly, in a private window for instance, and the pages work without it."""

glob WATCH_KEY: str = "trading-agent-watchlist";
glob SCREENS_KEY: str = "trading-agent-screens";

def read_json(key: str, fallback: any) -> any {
    try {
        text = localStorage.getItem(key);
        return JSON.parse(text) if text else fallback;
    } except Exception {
        return fallback;
    }
}

def write_json(key: str, value: any) {
    try {
        localStorage.setItem(key, JSON.stringify(value));
    } except Exception { }
}

def:pub watched -> list[str] {
    return read_json(WATCH_KEY, []);
}

"""Add or remove a symbol, and return the new watchlist."""
def:pub toggle_watch(symbol: str) -> list[str] {
    now = watched();
    next = [s for s in now if s != symbol] if symbol in now else now + [symbol];
    write_json(WATCH_KEY, next);
    return next;
}

"""Saved screens as name to its address's query string."""
def:pub saved_screens -> dict[str, str] {
    return read_json(SCREENS_KEY, {});
}

def:pub save_screen(name: str, query: str) -> dict[str, str] {
    screens = saved_screens();
    screens[name] = query;
    write_json(SCREENS_KEY, screens);
    return screens;
}

def:pub delete_screen(name: str) -> dict[str, str] {
    screens = saved_screens();
    kept: dict[str, str] = {};
    for key in Object.keys(screens) {
        if key != name {
            kept[key] = screens[key];
        }
    }
    write_json(SCREENS_KEY, kept);
    return kept;
}
