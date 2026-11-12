"""Post-close vote scoring (TDD §7, scoring and calibration; GAP-14, decided 2026-10-20).

A vote made on run date D with a horizon of H trading days is scored on its window: from the
close of the last session before D, the last price the panel could have known, to the close
of the H-th session counting D itself. Its excess return is the stock's return over the
window minus SPY's over the same sessions. A directional vote is a hit when its sign matches
the excess return's; a HOLD vote keeps its excess return but is never a hit or a miss.

A vote is scored once, after the close of its window's last session is final. When either
close is missing, the vote is marked scored with no excess return, so it is never retried.

Each decision is scored the same way over the default ten-session horizon (run/analysis.jac,
DEFAULT_HORIZON_DAYS), whatever its action, so a buy the Arbiter blocked can be judged as if it
had been taken (TDD §13, Arbiter downgrade value). Each run's screen is scored over the same
window (TDD §5, screen hit rate): the mean excess return of the names it shortlisted against the
mean of every other S&P 500 member that day.
"""
import statistics;
import from datetime { date, datetime, timedelta }
import from analysis.consensus { sign, signed_score }
import from models.graph { Coverage, CoverageReason, Covers, Decided, Decision, Portfolio, Ran, Run, RunStatus, VoteRecord, Voted }
import from analysis.history { History }
import from research.alpaca { bars_final }
import from run.analysis { DEFAULT_HORIZON_DAYS }

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

"""Each specialist's votes in `votes` as [votes, scored directional votes, hits]: what a run's
`specialist_tallies` holds, so the Specialists page can count a run without reading its votes."""
def tally_votes(votes: list[VoteRecord]) -> dict[str, list[int]] {
    found: dict[str, list[int]] = {};
    for v in votes {
        row = found.setdefault(v.specialist.value, [0, 0, 0]);
        row[0] += 1;
        result = hit(v);
        if result is not None {
            row[1] += 1;
            if result {
                row[2] += 1;
            }
        }
    }
    return found;
}

def votes_of(run: Run) -> list[VoteRecord] {
    return [v for c in [run ->:Covers:->[?:Coverage]] for v in [c ->:Voted:->[?:VoteRecord]]];
}

"""Store `run`'s tally from its votes, writing only when it changed."""
def tally_run(run: Run, votes: list[VoteRecord] | None = None) {
    tally = tally_votes(votes if votes is not None else votes_of(run));
    if tally != run.specialist_tallies {
        run.specialist_tallies = tally;
    }
}

obj ScoringReport {
    has scored: int = 0,
        unscorable: int = 0,
        waiting: int = 0,
        decisions: int = 0;

    def line -> str {
        return f"{self.scored} votes scored, {self.unscorable} without prices, {self.waiting} still open, {self.decisions} decisions scored";
    }
}

"""What one scoring pass must price: a vote or a decision, its run date, and its horizon."""
obj Pending {
    has run_day: str,
        ticker: str,
        horizon: int;
    has vote: VoteRecord | None = None,
        decision: Decision | None = None;
}

"""Score every vote and decision on `portfolio`'s runs whose window has closed by `now`, then
refresh each run's `specialist_tallies` from the votes this pass already read. Each is scored
once."""
def score_votes(portfolio: Portfolio, now: datetime, history: History = History()) -> ScoringReport {
    walked: list[tuple[Run, list[VoteRecord]]] = [];
    pending: list[Pending] = [];
    for run in [portfolio ->:Ran:->[?:Run]] {
        if run.status == RunStatus.SKIPPED {
            continue;
        }
        votes: list[VoteRecord] = [];
        for cov in [run ->:Covers:->[?:Coverage]] {
            mine = [v for v in [cov ->:Voted:->[?:VoteRecord]]];
            votes.extend(mine);
            pending.extend(Pending(run_day=run.run_date, ticker=v.ticker, horizon=v.body.horizon_days, vote=v) for v in mine if not v.scored_at);
            pending.extend(Pending(run_day=run.run_date, ticker=d.ticker, horizon=DEFAULT_HORIZON_DAYS, decision=d) for d in [cov ->:Decided:->[?:Decision]] if not d.scored_at);
        }
        walked.append((run, votes));
    }
    found = score_pending(pending, now, history);
    for (run, votes) in walked {
        tally_run(run, votes);
    }
    return found;
}

def score_pending(pending: list[Pending], now: datetime, history: History) -> ScoringReport {
    found = ScoringReport();
    if not pending {
        return found;
    }
    first = min(p.run_day for p in pending);
    today = now.date().isoformat();
    sessions = history.read_sessions((date.fromisoformat(first) - timedelta(days=10)).isoformat(), today);
    final = [s for s in sessions if bars_final(s, now)];
    if not final {
        found.waiting = len([p for p in pending if p.vote is not None]);
        return found;
    }
    due: list[tuple[Pending, str, str]] = [];
    for p in pending {
        window = vote_window(sessions, p.run_day, p.horizon);
        if window is None or window[1] > final[-1] {
            if p.vote is not None {
                found.waiting += 1;
            }
        } else {
            due.append((p, window[0], window[1]));
        }
    }
    if not due {
        return found;
    }
    tickers = sorted({p.ticker for (p, _, _) in due} | {BENCHMARK});
    bars = history.read_bars(tickers, min(s for (_, s, _) in due), max(e for (_, _, e) in due));
    closes = {t: {day: b.close for (day, b) in found_.items()} for (t, found_) in bars.items()};
    stamp = now.isoformat();
    for (p, start, end) in due {
        result = excess_return(closes, p.ticker, start, end);
        if p.decision is not None {
            p.decision.excess_return = result;
            p.decision.scored_at = stamp;
            found.decisions += 1;
        } elif p.vote is not None {
            p.vote.excess_return = result;
            p.vote.scored_at = stamp;
            if result is None {
                found.unscorable += 1;
            } else {
                found.scored += 1;
            }
        }
    }
    return found;
}

"""What one screen-scoring pass did."""
obj ScreenScoring {
    has scored: int = 0,
        waiting: int = 0,
        unscorable: int = 0;

    def line -> str {
        return f"{self.scored} screens scored, {self.unscorable} without prices, {self.waiting} still open";
    }
}

"""Score the screen of every run on `portfolio` whose ten-session window has closed by `now`:
the mean excess return over SPY of the names the screen shortlisted, and of every other S&P 500
member that day with prices for the window. A run whose screen shortlisted nothing, or that has
no prices to compare, is marked scored with no figures, so it is never retried; one whose members
cannot be read now is tried again the next evening."""
def score_screens(portfolio: Portfolio, now: datetime, history: History = History()) -> ScreenScoring {
    found = ScreenScoring();
    runs = [r for r in [portfolio ->:Ran:->[?:Run]] if not r.screen_scored_at and r.status in (RunStatus.NORMAL, RunStatus.FALLBACK)];
    if not runs {
        return found;
    }
    first = min(r.run_date for r in runs);
    sessions = history.read_sessions((date.fromisoformat(first) - timedelta(days=10)).isoformat(), now.date().isoformat());
    final = [s for s in sessions if bars_final(s, now)];
    stamp = now.isoformat();
    for run in sorted(runs, key=lambda (r: Run) { r.run_date; }) {
        window = vote_window(sessions, run.run_date, DEFAULT_HORIZON_DAYS);
        if window is None or not final or window[1] > final[-1] {
            found.waiting += 1;
            continue;
        }
        picks = sorted({c.ticker for c in [run ->:Covers:->[?:Coverage]] if c.reason == CoverageReason.SCREEN});
        if not picks {
            run.screen_scored_at = stamp;
            found.unscorable += 1;
            continue;
        }
        members = history.read_members(run.run_date);
        if not members {
            found.waiting += 1;
            continue;
        }
        run.screen_scored_at = stamp;
        symbols = sorted(set(members) | set(picks) | {BENCHMARK});
        bars = history.read_bars(symbols, window[0], window[1]);
        closes = {t: {day: b.close for (day, b) in found_.items()} for (t, found_) in bars.items()};
        chosen = [x for x in [excess_return(closes, t, window[0], window[1]) for t in picks] if x is not None];
        rest = [x for x in [excess_return(closes, t, window[0], window[1]) for t in sorted(set(members) - set(picks))] if x is not None];
        if not chosen or not rest {
            found.unscorable += 1;
            continue;
        }
        run.screen_picks_excess = statistics.fmean(chosen);
        run.screen_rest_excess = statistics.fmean(rest);
        run.screen_names = len(chosen);
        found.scored += 1;
    }
    return found;
}
