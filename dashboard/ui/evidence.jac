"""How the pages show a figure that rests on too few observations, and where a figure came from.

One rule, the one models/evaluation.jac states: a hit rate needs MIN_VOTES scored votes, and an
interval over sessions or runs needs MIN_SESSIONS of them. Below that a page writes "Not enough
data" with how many there are of how many it needs, never a bare figure. The final report applies
the same rule to the same stored evaluation (analysis/final_report.jac).
"""
import from models.evaluation { MIN_SESSIONS, MIN_VOTES }
import from dashboard.ui.parts { PILL_BASE, TONE_ACCENT, TONE_QUIET, TONE_WARN }

# Where a figure came from. Only the live forward test is a result; the others are research, and a
# partial replay is never a benchmark.
glob SOURCES: dict[str, tuple[str, str]] = {
    "live": ("Live paper trading", TONE_ACCENT),
    "demo": ("Simulated demo data", TONE_WARN),
    "backtest": ("Historical backtest", TONE_QUIET),
    "replay": ("LLM replay", TONE_QUIET),
    "partial": ("Partial LLM replay", TONE_WARN)
};

def enough(have: int, need: int) -> bool {
    return have >= need;
}

"""'3 of 20 scored votes': how far a figure is from being shown."""
def progress_words(have: int, need: int, unit: str) -> str {
    return str(have) + " of " + str(need) + " " + unit;
}

"""The words a page shows in place of a figure with too few observations behind it."""
def thin_words(have: int, need: int, unit: str) -> str {
    return "Not enough data: " + progress_words(have, need, unit);
}

def:pub Thin(have: int, need: int, unit: str, className: str = "") -> JsxElement {
    <span className={"text-faint " + className}>{thin_words(have, need, unit)}</span>
}

def votes_needed -> int {
    return MIN_VOTES;
}

def sessions_needed -> int {
    return MIN_SESSIONS;
}

"""A small label naming where a figure came from: live paper trading, a historical backtest, or an
LLM replay (partial while it runs)."""
def:pub Provenance(kind: str, detail: str = "") -> JsxElement {
    (label, tone_) = SOURCES.get(kind, (kind, TONE_QUIET));
    <span className={PILL_BASE + " " + tone_}>{label + ((" · " + detail) if detail else "")}</span>
}
