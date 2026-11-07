"""Filter and sort the rows. Pure, so tests and the endpoint run the same code.

A page sends its filters as JSON: `{"field": "pe", "min": 5, "max": 20}` keeps rows within the
bounds, and `{"field": "sector", "one_of": ["Energy"]}` keeps rows with one of the words. The input
comes from anyone on the web, so `read_filters` keeps only known fields and caps how much it takes.
A row missing a filtered figure does not match, and sorts last in either direction.
"""
import math;

glob MAX_FILTERS: int = 40;
glob MAX_CHOICES: int = 100;
glob MAX_SYMBOLS: int = 500;
glob MAX_LIMIT: int = 200;
glob MAX_SEARCH: int = 40;

"""One condition on one field."""
obj RowFilter {
    has field: str,
        low: float | None = None,
        high: float | None = None,
        one_of: list[str] = [];

    def matches(row: dict[str, float | str | None]) -> bool {
        value = row.get(self.field);
        if self.one_of {
            return value in self.one_of;
        }
        if not isinstance(value, (int, float)) {
            return False;
        }
        return (self.low is None or value >= self.low) and (self.high is None or value <= self.high);
    }
}

"""An argument as a list. Jac's server fills an argument left out of the request with its default as
text ("[]", "0"), and the rest comes from anyone on the web, so `screen_stocks` trusts no argument's
type."""
def as_list(value: object) -> list {
    return value if isinstance(value, list) else [];
}

def as_text(value: object) -> str {
    return value if isinstance(value, str) else "";
}

def as_flag(value: object, fallback: bool) -> bool {
    if isinstance(value, bool) {
        return value;
    }
    word = as_text(value).strip().lower();
    return word == "true" if word in ("true", "false") else fallback;
}

def as_count(value: object, fallback: int) -> int {
    if isinstance(value, bool) {
        return fallback;
    }
    if isinstance(value, int) {
        return value;
    }
    if isinstance(value, float) and math.isfinite(value) {
        return int(value);
    }
    word = as_text(value).strip();
    return int(word) if word.lstrip("-").isdecimal() else fallback;
}

def bound(value: object) -> float | None {
    if isinstance(value, bool) or not isinstance(value, (int, float)) {
        return None;
    }
    return float(value) if math.isfinite(value) else None;
}

"""The usable filters out of what a page sent; anything else in the list is left out."""
def read_filters(raw: list[dict[str, any]], fields: set[str]) -> list[RowFilter] {
    found: list[RowFilter] = [];
    for item in raw[:MAX_FILTERS] {
        if not isinstance(item, dict) or not isinstance(item.get("field"), str) or item["field"] not in fields {
            continue;
        }
        choices = item.get("one_of");
        words = [str(c) for c in choices[:MAX_CHOICES]] if isinstance(choices, list) else [];
        low = bound(item.get("min"));
        high = bound(item.get("max"));
        if words or low is not None or high is not None {
            found.append(RowFilter(field=str(item["field"]), low=low, high=high, one_of=words));
        }
    }
    return found;
}

"""Whether a search matches a row: its symbol's start, or a word in its name."""
def searched(row: dict[str, float | str | None], text: str) -> bool {
    return str(row.get("symbol") or "").startswith(text.upper()) or text.lower() in str(row.get("name") or "").lower();
}

"""One page of the rows that pass, in order, and how many passed. Ties fall to the symbol, so a
page never reorders between requests."""
def run_query(
    rows: list[dict[str, float | str | None]],
    filters: list[RowFilter],
    search: str,
    symbols: list[str],
    sort: str,
    descending: bool,
    offset: int,
    limit: int
) -> tuple[list[dict[str, float | str | None]], int] {
    text = search.strip()[:MAX_SEARCH];
    only = set(symbols[:MAX_SYMBOLS]);
    kept = [
        row
        for row in rows
        if (not only or row.get("symbol") in only)
        and (not text or searched(row, text))
        and all(f.matches(row) for f in filters)
    ];
    def present(row: dict[str, float | str | None]) -> bool {
        value = row.get(sort);
        return value is not None and value != "";
    }
    filled = [row for row in kept if present(row)];
    empty = [row for row in kept if not present(row)];
    filled.sort(key=lambda (row: dict[str, float | str | None]) { str(row.get("symbol") or ""); });
    empty.sort(key=lambda (row: dict[str, float | str | None]) { str(row.get("symbol") or ""); });
    def sort_value(row: dict[str, float | str | None]) -> any {
        value: any = row.get(sort);
        return value.lower() if isinstance(value, str) else value;
    }
    filled.sort(key=sort_value, reverse=descending);
    ordered = filled + empty;
    start = max(0, offset);
    return (ordered[start:start + max(1, min(limit, MAX_LIMIT))], len(ordered));
}

"""The stocks most like `row`: the same industry first, then the same sector, nearest in size."""
def peers_of(row: dict[str, float | str | None], rows: list[dict[str, float | str | None]], limit: int = 8) -> list[dict[str, float | str | None]] {
    def distance(other: dict[str, float | str | None]) -> float {
        mine: any = row.get("market_cap");
        theirs: any = other.get("market_cap");
        if not theirs or theirs <= 0 {
            return math.inf;
        }
        # A stock with no size yet is compared with the industry's largest, not its first.
        return abs(math.log(theirs / mine)) if mine and mine > 0 else -theirs;
    }
    def usable(other: dict[str, float | str | None]) -> bool {
        return other.get("symbol") != row.get("symbol") and other.get("market_cap") is not None and other.get("name") != row.get("name");
    }
    same_industry = sorted([o for o in rows if usable(o) and row.get("industry") and o.get("industry") == row.get("industry")], key=distance);
    if len(same_industry) >= limit {
        return same_industry[:limit];
    }
    taken = {o.get("symbol") for o in same_industry};
    same_sector = sorted([o for o in rows if usable(o) and o.get("symbol") not in taken and row.get("sector") and o.get("sector") == row.get("sector")], key=distance);
    return (same_industry + same_sector)[:limit];
}
