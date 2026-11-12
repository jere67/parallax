"""Vote scoring (analysis/scoring.jac): each vote's window, its excess return over SPY, and
scoring once, after the window's last close is final."""
import from datetime { datetime }
import from action.fixtures { Call, finished_run, team }
import from analysis.history { History, bar }
import from analysis.scoring { excess_return, hit, records, score_screens, score_votes, tally_votes, vote_window }
import from research.alpaca { Bar }
import from models.agents { Specialist, Stance, Vote }
import from models.graph { Coverage, CoverageReason, Covers, Decided, Decision, Run, RunStatus, TradeAction, VoteRecord, Voted }
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
    # The run's stored tally counts every vote, and only scored directional ones as scored.
    assert run.specialist_tallies == {"technical": [3, 2, 1], "macro": [1, 0, 0], "news": [1, 0, 0]};
    tally = records([right, wrong, neutral, later, unpriced]);
    assert list(tally) == ["technical"] and tally["technical"].scored == 2 and tally["technical"].hit_rate() == 0.5;
    # A second pass has nothing new to score and fetches nothing.
    again = score_votes(portfolio, ny("2026-10-22T16:45:00"), sources(closes, asked));
    assert (again.scored, again.unscorable, again.waiting) == (0, 0, 1) and len(asked) == 1;
    # Friday: Thursday's close settles the two-session vote, a miss.
    last = score_votes(portfolio, ny("2026-10-23T16:30:00"), sources(closes, asked));
    assert (last.scored, last.waiting) == (1, 0) and later.excess_return is not None and abs(later.excess_return + 0.02) < 1e-12 and hit(later) is False;
    assert run.specialist_tallies["news"] == [1, 1, 0] and run.specialist_tallies == tally_votes([right, wrong, neutral, later, unpriced]);
}

# Fourteen sessions; a ten-session window from 2026-10-21 ends on 2026-11-03.
glob LONG: list[str] = ["2026-10-19", "2026-10-20", "2026-10-21", "2026-10-22", "2026-10-23", "2026-10-26", "2026-10-27", "2026-10-28", "2026-10-29", "2026-10-30", "2026-11-02", "2026-11-03", "2026-11-04", "2026-11-05"];

"""History over LONG, `closes` (flat at 100 where a symbol has none for a day), and `members`."""
def long_history(closes: dict[str, dict[str, float]], members: list[str], asked: list[list[str]]) -> History {
    def read(symbols: list[str], start: str, end: str) -> dict[str, dict[str, Bar]] {
        asked.append(symbols);
        return {s: {d: bar(d, closes.get(s, {}).get(d, 100.0)) for d in LONG if start <= d <= end} for s in symbols if s in closes or s in members};
    }
    return History(bars=read, sessions=lambda (start: str, end: str) { [s for s in LONG if start <= s <= end]; }, members=lambda (day: str) { members; });
}

test "every decision is scored over ten sessions, whatever its action, once that window closes" {
    portfolio = team();
    run = finished_run(portfolio, "2026-10-21", [Call(ticker="AAA", action=TradeAction.NO_ACTION), Call(ticker="BBB", action=TradeAction.BUY)]);
    closes = {"AAA": {"2026-10-20": 100.0, "2026-11-03": 90.0}, "BBB": {"2026-10-20": 100.0, "2026-11-03": 110.0}, "SPY": {"2026-10-20": 500.0, "2026-11-03": 500.0}};
    asked: list[list[str]] = [];
    early = score_votes(portfolio, ny("2026-11-02T21:00:00"), long_history(closes, [], asked));
    assert early.decisions == 0 and asked == [];
    found = score_votes(portfolio, ny("2026-11-03T21:00:00"), long_history(closes, [], asked));
    assert found.decisions == 2;
    by_ticker = {d.ticker: d for c in [run ->:Covers:->[?:Coverage]] for d in [c ->:Decided:->[?:Decision]]};
    assert abs(by_ticker["AAA"].excess_return + 0.1) < 1e-12 and abs(by_ticker["BBB"].excess_return - 0.1) < 1e-12;
    assert by_ticker["AAA"].scored_at and score_votes(portfolio, ny("2026-11-03T21:05:00"), long_history(closes, [], asked)).decisions == 0;
}

test "a run's screen is scored against every other member once its window closes, and only once" {
    portfolio = team();
    run = finished_run(portfolio, "2026-10-21", [Call(ticker="AAA", action=TradeAction.HOLD), Call(ticker="BBB", action=TradeAction.HOLD)]);
    held = [c for c in [run ->:Covers:->[?:Coverage]] if c.ticker == "BBB"][0];
    held.reason = CoverageReason.HELD;
    closes = {"AAA": {"2026-10-20": 100.0, "2026-11-03": 106.0}, "CCC": {"2026-10-20": 100.0, "2026-11-03": 98.0}, "SPY": {"2026-10-20": 500.0, "2026-11-03": 505.0}};
    asked: list[list[str]] = [];
    members = ["AAA", "BBB", "CCC", "DDD"];
    assert score_screens(portfolio, ny("2026-11-02T21:00:00"), long_history(closes, members, asked)).waiting == 1 and not run.screen_scored_at;
    found = score_screens(portfolio, ny("2026-11-03T21:00:00"), long_history(closes, members, asked));
    assert found.scored == 1 and run.screen_names == 1;
    # The held name is not a pick, so it joins the rest: BBB and DDD flat, CCC down 2%, each less SPY's 1%.
    assert abs(run.screen_picks_excess - 0.05) < 1e-12;
    assert abs(run.screen_rest_excess - ((0.0 - 0.01) * 2 + (-0.02 - 0.01)) / 3) < 1e-12;
    assert score_screens(portfolio, ny("2026-11-03T21:05:00"), long_history(closes, members, asked)).scored == 0 and len(asked) == 1;
}

test "a screen with no members to compare waits, and a run that shortlisted nothing or failed is never scored" {
    portfolio = team();
    run = finished_run(portfolio, "2026-10-21", [Call(ticker="AAA", action=TradeAction.HOLD)]);
    empty = finished_run(portfolio, "2026-10-22", []);
    failed = finished_run(portfolio, "2026-10-23", [Call(ticker="AAA", action=TradeAction.HOLD)], status=RunStatus.FAILED);
    asked: list[list[str]] = [];
    found = score_screens(portfolio, ny("2026-11-04T21:00:00"), long_history({}, [], asked));
    assert not run.screen_scored_at and empty.screen_scored_at and not failed.screen_scored_at;
    assert found.waiting >= 1 and found.unscorable == 1 and asked == [];
}
