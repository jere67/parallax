"""A screen as a web address, so it survives a reload, can be sent to someone, and the browser's back
and forward buttons undo and redo a change. Plain functions, so `jac test` covers them.

    ?tab=Performance&sort=perf_1y&asc=1&q=bank&watch=1&add=beta,roe&cols=price,pe&f=pe:5:20;sector~Energy|Utilities
"""
import from dashboard.market.columns { COLUMN_SETS, ColumnSet, DEFAULT_FILTERS, FIELD_BY_KEY }

"""A filter's bounds in the field's own units, or the words it may be."""
obj Bound {
    has low: float | None = None,
        high: float | None = None,
        one_of: list[str] = [];
}

"""Everything a reader has chosen. `sort` empty means the tab's own sort; `columns` empty means the
tab's own columns; `added` holds the filter pills beyond the defaults."""
obj Screen {
    has tab: str = "Overview",
        sort: str = "",
        ascending: bool = False,
        search: str = "",
        watch_only: bool = False,
        filters: dict[str, Bound] = {},
        added: list[str] = [],
        columns: list[str] = [];
}

def column_set(name: str) -> ColumnSet {
    for set_ in COLUMN_SETS {
        if set_.name == name {
            return set_;
        }
    }
    return COLUMN_SETS[0];
}

"""The columns this screen shows, after the symbol."""
def columns_of(screen: Screen) -> list[str] {
    return screen.columns if len(screen.columns) > 0 else column_set(screen.tab).columns;
}

def sort_of(screen: Screen) -> str {
    return screen.sort or column_set(screen.tab).sort;
}

"""Whether a sort on this screen runs highest first."""
def descending_of(screen: Screen) -> bool {
    return not screen.ascending;
}

"""The filter pills to show: the defaults, what was added, and anything already filtering."""
def pills_of(screen: Screen) -> list[str] {
    pills = list(DEFAULT_FILTERS);
    for key in screen.added {
        if key not in pills {
            pills.append(key);
        }
    }
    for key in screen.filters {
        if key not in pills {
            pills.append(key);
        }
    }
    return pills;
}

def known(key: str) -> bool {
    return key in FIELD_BY_KEY;
}

def to_number(text: str) -> float | None {
    if text == "" {
        return None;
    }
    try {
        value = float(text);
    } except ValueError {
        return None;
    }
    return None if value != value else value;
}

"""One filter from the address, or None for one that does not parse."""
def read_filter(text: str) -> tuple[str, Bound] | None {
    if "~" in text {
        parts = text.split("~");
        if len(parts) == 2 and known(parts[0]) and parts[1] {
            return (parts[0], Bound(one_of=parts[1].split("|")));
        }
        return None;
    }
    parts = text.split(":");
    if len(parts) != 3 or not known(parts[0]) {
        return None;
    }
    low = to_number(parts[1]);
    high = to_number(parts[2]);
    if low is None and high is None {
        return None;
    }
    return (parts[0], Bound(low=low, high=high));
}

def write_filter(key: str, bound: Bound) -> str {
    if len(bound.one_of) > 0 {
        return key + "~" + "|".join(bound.one_of);
    }
    low = str(bound.low) if bound.low is not None else "";
    high = str(bound.high) if bound.high is not None else "";
    return key + ":" + low + ":" + high;
}

"""The screen described by already-decoded query pairs."""
def read_screen(pairs: dict[str, str]) -> Screen {
    screen = Screen();
    tab = pairs.get("tab") or "";
    if column_set(tab).name == tab {
        screen.tab = tab;
    }
    sort = pairs.get("sort") or "";
    if known(sort) {
        screen.sort = sort;
    }
    screen.ascending = pairs.get("asc") == "1";
    screen.search = pairs.get("q") or "";
    screen.watch_only = pairs.get("watch") == "1";
    screen.added = [k for k in (pairs.get("add") or "").split(",") if known(k)];
    screen.columns = [k for k in (pairs.get("cols") or "").split(",") if known(k)];
    filters: dict[str, Bound] = {};
    for text in (pairs.get("f") or "").split(";") {
        if text {
            found = read_filter(text);
            if found is not None {
                filters[found[0]] = found[1];
            }
        }
    }
    screen.filters = filters;
    return screen;
}

"""The query pairs for a screen, leaving out whatever is at its default."""
def write_screen(screen: Screen) -> dict[str, str] {
    pairs: dict[str, str] = {};
    if screen.tab != "Overview" {
        pairs["tab"] = screen.tab;
    }
    if screen.sort {
        pairs["sort"] = screen.sort;
    }
    if screen.ascending {
        pairs["asc"] = "1";
    }
    if screen.search {
        pairs["q"] = screen.search;
    }
    if screen.watch_only {
        pairs["watch"] = "1";
    }
    if len(screen.added) > 0 {
        pairs["add"] = ",".join(screen.added);
    }
    if len(screen.columns) > 0 {
        pairs["cols"] = ",".join(screen.columns);
    }
    written = [write_filter(k, screen.filters[k]) for k in sorted(screen.filters.keys())];
    if len(written) > 0 {
        pairs["f"] = ";".join(written);
    }
    return pairs;
}

"""A filter as the endpoint reads it, in the row's units: what a reader typed times the field's scale."""
def request_filter(key: str, bound: Bound) -> dict[str, float | str | list[str]] {
    if len(bound.one_of) > 0 {
        return {"field": key, "one_of": bound.one_of};
    }
    field = FIELD_BY_KEY.get(key);
    scale = field.scale if field else 1.0;
    found: dict[str, float | str | list[str]] = {"field": key};
    if bound.low is not None {
        found["min"] = bound.low * scale;
    }
    if bound.high is not None {
        found["max"] = bound.high * scale;
    }
    return found;
}
