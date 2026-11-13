"""Formats the server's numbers and times for the screens. The views send numbers, not text
(models/views.jac): money in dollars, returns as fractions, times in UTC. A missing figure is
None and shows as a dash, never as zero."""

glob DASH: str = "-";
glob NEW_YORK: str = "America/New_York";

def grouped(value: float, digits: int) -> str {
    n: any = value;
    return n.toLocaleString("en-US", {"minimumFractionDigits": digits, "maximumFractionDigits": digits});
}

"""$105,406.43"""
def:pub money(value: float | None, digits: int = 2) -> str {
    if value is None {
        return DASH;
    }
    return ("-$" if value < 0 else "$") + grouped(abs(value), digits);
}

"""+$1,456.12 or -$80.00"""
def:pub signed_money(value: float | None) -> str {
    if value is None {
        return DASH;
    }
    return ("+" if value >= 0 else "-") + "$" + grouped(abs(value), 2);
}

"""5.4%"""
def:pub percent(value: float | None, digits: int = 1) -> str {
    if value is None {
        return DASH;
    }
    return grouped(value * 100, digits) + "%";
}

"""+1.40% or -0.20%"""
def:pub signed_percent(value: float | None, digits: int = 2) -> str {
    if value is None {
        return DASH;
    }
    return ("+" if value >= 0 else "-") + grouped(abs(value) * 100, digits) + "%";
}

"""The price of one share: $197.62"""
def:pub price(value: float | None) -> str {
    return money(value, 2);
}

"""A signed score in [-1, 1], as the web dashboard shows it: +0.91"""
def:pub score(value: float | None) -> str {
    if value is None {
        return DASH;
    }
    return ("+" if value >= 0 else "-") + grouped(abs(value), 2);
}

"""9:33 AM ET, in New York time, from an ISO timestamp; `zone=False` leaves off the ET."""
def:pub clock(stamp: str, zone: bool = True) -> str {
    if not stamp {
        return DASH;
    }
    when = new(Date, stamp);  # jac:ignore[W2001]
    text: str = when.toLocaleTimeString("en-US", {"timeZone": NEW_YORK, "hour": "numeric", "minute": "2-digit"});
    return text + " ET" if zone else text;
}

"""7:30 to 8:33 AM ET, or 11:50 AM to 12:10 PM ET across noon."""
def:pub clock_span(start: str, end: str) -> str {
    a = clock(start, False);
    b = clock(end, False);
    if a[-2:] == b[-2:] {
        a = a[:-3];
    }
    return f"{a} to {b} ET";
}

"""An order's broker status in words: new reads open, partially_filled reads partly filled."""
def:pub order_word(status: str) -> str {
    words = {"new": "open", "accepted": "open", "pending_new": "open", "partially_filled": "partly filled", "canceled": "canceled", "expired": "expired", "rejected": "rejected", "filled": "filled"};
    return words[status] if status in words else status.replace("_", " ");
}

"""Wed, Nov 11, from a "YYYY-MM-DD" New York date."""
def:pub day_label(day: str) -> str {
    if not day {
        return DASH;
    }
    when = new(Date, day + "T12:00:00Z");  # jac:ignore[W2001]
    return when.toLocaleDateString("en-US", {"timeZone": "UTC", "weekday": "short", "month": "short", "day": "numeric"});
}

"""The trading action as a word: BUY reads Buy, NO_ACTION reads No action."""
def:pub action_word(action: str) -> str {
    if not action or action == "NO_ACTION" or action == "HOLD" {
        return "Hold" if action == "HOLD" else "No action";
    }
    return action[0] + action[1:].lower();
}

"""Up, down, or flat, for coloring a trading action."""
def:pub action_lean(action: str) -> str {
    if action == "BUY" or action == "ADD" {
        return "up";
    }
    if action == "SELL" or action == "TRIM" {
        return "down";
    }
    return "flat";
}

"""A run's status in words."""
def:pub status_word(status: str) -> str {
    words = {"normal": "Finished", "fallback": "Finished on the fallback", "failed": "Failed", "skipped": "Skipped"};
    return words[status] if status in words else status;
}

"""The first sentence of a paragraph, for a one-line preview."""
def:pub first_sentence(text: str) -> str {
    if not text {
        return "";
    }
    at = text.find(". ");
    return text if at < 0 else text[:at + 1];
}
