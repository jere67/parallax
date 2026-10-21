"""Vote scoring (analysis/scoring.jac): each vote's window, its excess return over SPY, and
scoring once, after the window's last close is final."""
import from datetime { datetime }
import from action.fixtures { Call, finished_run, team }
import from analysis.history { History, bar }
import from analysis.scoring { excess_return, hit, records, score_votes, vote_window }
import from research.alpaca { Bar }
import from models.agents { Specialist, Stance, Vote }
import from models.graph { Coverage, Covers, Run, TradeAction, VoteRecord, Voted }
import from run.guard { NEW_YORK }

glob SESSIONS: list[str] = ["2026-10-16", "2026-10-19", "2026-10-20", "2026-10-21", "2026-10-22", "2026-10-23", "2026-10-26"];

def ny(stamp: str) -> datetime {
    return datetime.fromisoformat(stamp).replace(tzinfo=NEW_YORK);
}

def vote(cov: Coverage, specialist: Specialist, sample: int, stance: Stance, horizon: int) -> VoteRecord {
    found = VoteRecord(ticker=cov.ticker, specialist=specialist, sample=sample, model="m", body=Vote(stance=stance, confidence=0.8, horizon_days=horizon, rationale="r", cited_evidence=[1]));
    cov +>:Voted():+> found;
    return found;
}

def coverage(run: Run, ticker: str) -> Coverage {
    return [c for c in [run ->:Covers:->[?:Coverage]] if c.ticker == ticker][0];
}

"""History over SESSIONS and `closes`, recording each bars request."""
def sources(closes: dict[str, dict[str, float]], asked: list[tuple[list[str], str, str]]) -> History {
    def read(symbols: list[str], start: str, end: str) -> dict[str, dict[str, Bar]] {
        asked.append((symbols, start, end));
        return {s: {d: bar(d, c) for (d, c) in closes[s].items()} for s in symbols if s in closes};
    }
    return History(bars=read, sessions=lambda (start: str, end: str) { [s for s in SESSIONS if start <= s <= end]; });
}

test "a window runs from the last close before the run date to the H-th session counting it" {
    assert vote_window(SESSIONS, "2026-10-21", 1) == ("2026-10-20", "2026-10-21");
    assert vote_window(SESSIONS, "2026-10-21", 3) == ("2026-10-20", "2026-10-23");
    # A run on a weekend counts from the next session, against Friday's close.
    assert vote_window(SESSIONS, "2026-10-24", 1) == ("2026-10-23", "2026-10-26");
    assert vote_window(SESSIONS, "2026-10-21", 5) is None and vote_window(SESSIONS, "2026-10-16", 1) is None;
}

test "the excess return is the stock's return minus SPY's, and a missing close gives none" {
    closes = {"AAA": {"a": 100.0, "b": 105.0}, "SPY": {"a": 500.0, "b": 505.0}};
    assert abs(excess_return(closes, "AAA", "a", "b") - 0.04) < 1e-12;
    assert excess_return(closes, "BBB", "a", "b") is None and excess_return(closes, "AAA", "a", "c") is None;
}

test "votes are scored once their window's close is final, and HOLD votes are never hits" {
    portfolio = team();
    run = finished_run(portfolio, "2026-10-21", [Call(ticker="AAA", action=TradeAction.BUY), Call(ticker="BBB", action=TradeAction.HOLD)]);
    aaa = coverage(run, "AAA");
    right = vote(aaa, Specialist.TECHNICAL, 0, Stance.BUY, 1);
    wrong = vote(aaa, Specialist.TECHNICAL, 1, Stance.SELL, 1);
    neutral = vote(aaa, Specialist.MACRO, 0, Stance.HOLD, 1);
    later = vote(aaa, Specialist.NEWS, 0, Stance.STRONG_BUY, 2);
    unpriced = vote(coverage(run, "BBB"), Specialist.TECHNICAL, 0, Stance.BUY, 1);
    closes = {"AAA": {"2026-10-20": 100.0, "2026-10-21": 105.0, "2026-10-22": 98.0}, "SPY": {"2026-10-20": 500.0, "2026-10-21": 505.0, "2026-10-22": 500.0}};
    asked: list[tuple[list[str], str, str]] = [];
    # Thursday afternoon: Wednesday's bars are final, Thursday's are not yet.
    found = score_votes(portfolio, ny("2026-10-22T16:30:00"), sources(closes, asked));
    assert (found.scored, found.unscorable, found.waiting) == (3, 1, 1);
    assert asked == [(["AAA", "BBB", "SPY"], "2026-10-20", "2026-10-21")];
    assert right.excess_return is not None and abs(right.excess_return - 0.04) < 1e-12 and wrong.excess_return == right.excess_return;
    assert (hit(right), hit(wrong), hit(neutral), hit(unpriced)) == (True, False, None, None);
    assert unpriced.scored_at and later.scored_at == "" and later.excess_return is None;
    tally = records([right, wrong, neutral, later, unpriced]);
    assert list(tally) == ["technical"] and tally["technical"].scored == 2 and tally["technical"].hit_rate() == 0.5;
    # A second pass has nothing new to score and fetches nothing.
    again = score_votes(portfolio, ny("2026-10-22T16:45:00"), sources(closes, asked));
    assert (again.scored, again.unscorable, again.waiting) == (0, 0, 1) and len(asked) == 1;
    # Friday: Thursday's close settles the two-session vote, a miss.
    last = score_votes(portfolio, ny("2026-10-23T16:30:00"), sources(closes, asked));
    assert (last.scored, last.waiting) == (1, 0) and later.excess_return is not None and abs(later.excess_return + 0.02) < 1e-12 and hit(later) is False;
}
