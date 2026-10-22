"""How the dashboard writes numbers, dates, and times.

Plain functions with no browser API, so the pages and `jac test` run the same code. A figure
the record does not have shows as MISSING. Money and returns carry an explicit sign where a
change is meant (+$120.00, -0.42%), and times are New York times, since that is the market's
clock (TDD §3, rule 11).
"""

glob MISSING: str = "-";
glob MONTHS: list[str] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
glob WEEKDAYS: list[str] = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

"""`digits` decimals with thousands separators, and no sign."""
def grouped(x: float, digits: int = 2) -> str {
    text = f"{abs(x):.{digits}f}" if digits > 0 else str(int(round(abs(x))));
    parts = text.split(".");
    whole = parts[0];
    out = "";
    count = 0;
    i = len(whole) - 1;
    while i >= 0 {
        out = whole[i] + out;
        count += 1;
        if count % 3 == 0 and i > 0 {
            out = "," + out;
        }
        i -= 1;
    }
    return out + "." + parts[1] if len(parts) > 1 else out;
}

def is_zero(x: float, digits: int) -> bool {
    return abs(x) < 0.5 * 10 ** (0 - digits);
}

def num(x: float | None, digits: int = 2) -> str {
    if x is None {
        return MISSING;
    }
    return ("-" if x < 0 and not is_zero(x, digits) else "") + grouped(x, digits);
}

def signed(x: float | None, digits: int = 2) -> str {
    if x is None {
        return MISSING;
    }
    if is_zero(x, digits) {
        return grouped(0.0, digits);
    }
    return ("+" if x > 0 else "-") + grouped(x, digits);
}

def money(x: float | None, digits: int = 2) -> str {
    if x is None {
        return MISSING;
    }
    return ("-" if x < 0 and not is_zero(x, digits) else "") + "$" + grouped(x, digits);
}

def signed_money(x: float | None, digits: int = 2) -> str {
    if x is None {
        return MISSING;
    }
    if is_zero(x, digits) {
        return "$" + grouped(0.0, digits);
    }
    return ("+" if x > 0 else "-") + "$" + grouped(x, digits);
}

"""A fraction as a percentage: 0.0123 is 1.23%."""
def pct(x: float | None, digits: int = 2) -> str {
    return MISSING if x is None else num(x * 100.0, digits) + "%";
}

def signed_pct(x: float | None, digits: int = 2) -> str {
    return MISSING if x is None else signed(x * 100.0, digits) + "%";
}

def qty(x: int | None) -> str {
    return MISSING if x is None else num(float(x), 0);
}

"""Large share volumes as 12.3M or 840K."""
def compact(x: float | None) -> str {
    if x is None {
        return MISSING;
    }
    if abs(x) >= 1e9 {
        return num(x / 1e9, 1) + "B";
    }
    if abs(x) >= 1e6 {
        return num(x / 1e6, 1) + "M";
    }
    return num(x / 1e3, 0) + "K" if abs(x) >= 1e3 else num(x, 0);
}

"""The Tailwind text color for a change: green up, red down, muted at zero or unknown."""
def tone(x: float | None) -> str {
    if x is None or x == 0 {
        return "text-muted";
    }
    return "text-up" if x > 0 else "text-down";
}

def parse_day(day: str) -> tuple[int, int, int] {
    return (int(day[0:4]), int(day[5:7]), int(day[8:10]));
}

"""Day of the week, 0 for Sunday (Sakamoto's method)."""
def weekday(y: int, m: int, d: int) -> int {
    offsets = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4];
    yy = y - 1 if m < 3 else y;
    return (yy + yy // 4 - yy // 100 + yy // 400 + offsets[m - 1] + d) % 7;
}

"""Oct 21."""
def day_short(day: str) -> str {
    if len(day) < 10 {
        return MISSING;
    }
    (y, m, d) = parse_day(day);
    return f"{MONTHS[m - 1]} {d}";
}

"""Wed, Oct 21, 2026."""
def day_long(day: str) -> str {
    if len(day) < 10 {
        return MISSING;
    }
    (y, m, d) = parse_day(day);
    return f"{WEEKDAYS[weekday(y, m, d)]}, {MONTHS[m - 1]} {d}, {y}";
}

"""The `n`th `dow` (0 Sunday) of month `m` in year `y`."""
def nth_weekday(y: int, m: int, dow: int, n: int) -> int {
    first = weekday(y, m, 1);
    return 1 + (dow - first + 7) % 7 + 7 * (n - 1);
}

"""Hours New York is behind UTC at UTC time (y, m, d, hour): 4 in daylight time, which runs
from 2 a.m. on the second Sunday of March to 2 a.m. on the first Sunday of November."""
def new_york_offset(y: int, m: int, d: int, hour: int) -> int {
    start = (3, nth_weekday(y, 3, 0, 2), 7);
    end = (11, nth_weekday(y, 11, 0, 1), 6);
    now = (m, d, hour);
    return 4 if start <= now and now < end else 5;
}

"""New York wall-clock time of an ISO timestamp in UTC, as (day, hour, minute)."""
def new_york(iso: str) -> tuple[str, int, int] {
    (y, m, d) = parse_day(iso);
    hour = int(iso[11:13]);
    minute = int(iso[14:16]);
    hour -= new_york_offset(y, m, d, hour);
    if hour < 0 {
        hour += 24;
        d -= 1;
        if d < 1 {
            m -= 1;
            if m < 1 {
                m = 12;
                y -= 1;
            }
            d = [31, 29 if (y % 4 == 0 and (y % 100 != 0 or y % 400 == 0)) else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1];
        }
    }
    month = f"0{m}" if m < 10 else str(m);
    dd = f"0{d}" if d < 10 else str(d);
    return (f"{y}-{month}-{dd}", hour, minute);
}

"""4:30 PM."""
def clock(hour: int, minute: int) -> str {
    h = hour % 12;
    mm = f"0{minute}" if minute < 10 else str(minute);
    return f"{12 if h == 0 else h}:{mm} {'AM' if hour < 12 else 'PM'}";
}

"""4:30 PM ET, from an ISO timestamp in UTC."""
def time_et(iso: str) -> str {
    if len(iso) < 16 {
        return MISSING;
    }
    (_, hour, minute) = new_york(iso);
    return clock(hour, minute) + " ET";
}

"""Oct 21, 4:30 PM ET."""
def stamp_et(iso: str) -> str {
    if len(iso) < 16 {
        return MISSING;
    }
    (day, hour, minute) = new_york(iso);
    return f"{day_short(day)}, {clock(hour, minute)} ET";
}

"""The New York date of an ISO timestamp in UTC."""
def day_et(iso: str) -> str {
    return new_york(iso)[0] if len(iso) >= 16 else "";
}

"""Trading-style label for an action value: NO_ACTION reads "No action"."""
def action_label(action: str) -> str {
    return "No action" if action == "NO_ACTION" else action;
}

"""Capitalize the first letter: "equal_weight" reads "Equal weight"."""
def title(text: str) -> str {
    spaced = text.replace("_", " ");
    return spaced[0:1].upper() + spaced[1:] if spaced else spaced;
}
