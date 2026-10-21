"""Post-close vote scoring (TDD §7, scoring and calibration; GAP-14, decided 2026-10-20).

A vote made on run date D with a horizon of H trading days is scored on its window: from the
close of the last session before D, the last price the panel could have known, to the close
of the H-th session counting D itself. Its excess return is the stock's return over the
window minus SPY's over the same sessions. A directional vote is a hit when its sign matches
the excess return's; a HOLD vote keeps its excess return but is never a hit or a miss.

A vote is scored once, after the close of its window's last session is final. When either
close is missing, the vote is marked scored with no excess return, so it is never retried.
"""
import statistics;
import from datetime { date, datetime, timedelta }
import from analysis.consensus { sign, signed_score }
import from models.graph { Covers, Portfolio, Ran, Run, RunStatus, VoteRecord, Voted }
import from analysis.history { History }
import from research.alpaca { bars_final }

glob SCORING_VERSION: str = "2026-10-20.1";
glob BENCHMARK: str = "SPY";

"""The window of a vote made on `run_day` with a horizon of `horizon` sessions: the last
session before it and the `horizon`-th session counting it, or None when `sessions` does not
reach either end."""
def vote_window(sessions: list[str], run_day: str, horizon: int) -> tuple[str, str] | None {
    before = sorted(s for s in sessions if s < run_day);
    ahead = sorted(s for s in sessions if s >= run_day);
    if not before or horizon < 1 or len(ahead) < horizon {
        return None;
    }
    return (before[-1], ahead[horizon - 1]);
}

"""The stock's return over the window minus SPY's, from `closes` (by symbol, by session), or
None when a close is missing."""
def excess_return(closes: dict[str, dict[str, float]], ticker: str, start: str, end: str) -> float | None {
    stock = closes.get(ticker, {});
    spy = closes.get(BENCHMARK, {});
    if not (stock.get(start) and stock.get(end) and spy.get(start) and spy.get(end)) {
        return None;
    }
    return (stock[end] / stock[start] - 1.0) - (spy[end] / spy[start] - 1.0);
}

"""Whether a scored vote was right: None for a HOLD vote or an unscored one."""
def hit(v: VoteRecord) -> bool | None {
    direction = sign(signed_score(v.body));
    if v.excess_return is None or direction == 0 {
        return None;
    }
    return sign(v.excess_return) == direction;
}

"""A specialist's record over its scored directional votes."""
obj SpecialistRecord {
    has specialist: str;
    has scored: int = 0,
        hits: int = 0,
        mean_confidence: float = 0.0;

    def hit_rate -> float | None {
        return self.hits / self.scored if self.scored else None;
    }
}

def records(votes: list[VoteRecord]) -> dict[str, SpecialistRecord] {
    found: dict[str, SpecialistRecord] = {};
    grouped: dict[str, list[VoteRecord]] = {};
    for v in votes {
        if hit(v) is not None {
            grouped.setdefault(v.specialist.value, []).append(v);
        }
    }
    for (s, mine) in grouped.items() {
        found[s] = SpecialistRecord(specialist=s, scored=len(mine), hits=len([v for v in mine if hit(v)]), mean_confidence=statistics.fmean(v.body.confidence for v in mine));
    }
    return found;
}

obj ScoringReport {
    has scored: int = 0,
        unscorable: int = 0,
        waiting: int = 0;

    def line -> str {
        return f"{self.scored} votes scored, {self.unscorable} without prices, {self.waiting} still open";
    }
}

"""Score every vote on `portfolio`'s runs whose window has closed by `now`. Each vote is
scored once."""
def score_votes(portfolio: Portfolio, now: datetime, history: History = History()) -> ScoringReport {
    found = ScoringReport();
    pending: list[tuple[str, VoteRecord]] = [];
    for run in [portfolio ->:Ran:->[?:Run]] {
        if run.status == RunStatus.SKIPPED {
            continue;
        }
        for cov in [run ->:Covers:->] {
            pending.extend((run.run_date, v) for v in [cov ->:Voted:->[?:VoteRecord]] if not v.scored_at);
        }
    }
    if not pending {
        return found;
    }
    first = min(day for (day, _) in pending);
    today = now.date().isoformat();
    sessions = history.read_sessions((date.fromisoformat(first) - timedelta(days=10)).isoformat(), today);
    final = [s for s in sessions if bars_final(s, now)];
    if not final {
        found.waiting = len(pending);
        return found;
    }
    due: list[tuple[VoteRecord, str, str]] = [];
    for (day, v) in pending {
        window = vote_window(sessions, day, v.body.horizon_days);
        if window is None or window[1] > final[-1] {
            found.waiting += 1;
        } else {
            due.append((v, window[0], window[1]));
        }
    }
    if not due {
        return found;
    }
    tickers = sorted({v.ticker for (v, _, _) in due} | {BENCHMARK});
    bars = history.read_bars(tickers, min(s for (_, s, _) in due), max(e for (_, _, e) in due));
    closes = {t: {day: b.close for (day, b) in found_.items()} for (t, found_) in bars.items()};
    for (v, start, end) in due {
        v.excess_return = excess_return(closes, v.ticker, start, end);
        v.scored_at = now.isoformat();
        if v.excess_return is None {
            found.unscorable += 1;
        } else {
            found.scored += 1;
        }
    }
    return found;
}
