"""A replay applies a policy to what a run stored: held stocks are the team's that morning, the
Arbiter's downgrades carry over, and a buy it never reviewed is marked."""
import from action.fixtures { Call, finished_run, team }
import from models.graph { Concluded, ConsensusResult, Coverage, Covers, Decision, Decided, Holds, OpenedBy, Portfolio, Position, Run, TradeAction }
import from models.policy { Condition, Op, Policy, PolicyRule, RuleEffect }
import from models.policy_views { ReplayRow, ReplayView }
import from policy.replay { StoredRun, held_on, replay, replay_team_run, stored_run }

glob DAY: str = "2026-11-03";

def coverage_of(run: Run, ticker: str) -> Coverage {
    return [c for c in [run ->:Covers:->[?:Coverage]] if c.ticker == ticker][0];
}

"""Store the panel's figures for `ticker`, with the action the team's own thresholds drew."""
def conclude(run: Run, ticker: str, score: float, agreement: float, draft: TradeAction) {
    cov = coverage_of(run, ticker);
    cov +>:Concluded():+> ConsensusResult(ticker=ticker, score=score, agreement=agreement, ci_low=score - 0.1, ci_high=score + 0.1, draft_action=draft, specialist_scores={"technical": score, "news": -0.5});
}

def decision_of(run: Run, ticker: str) -> Decision {
    return [d for d in [coverage_of(run, ticker) ->:Decided:->[?:Decision]]][0];
}

def stored(portfolio: Portfolio, day: str = DAY) -> StoredRun {
    found = stored_run(portfolio, day);
    assert found is not None;
    return found;
}

def row_of(view: ReplayView, ticker: str) -> ReplayRow {
    return [r for r in view.rows if r.ticker == ticker][0];
}

"""A team that bought HLD at 80 a week ago, and a run covering HLD, NEW, and WAT."""
def seeded -> tuple[Portfolio, Run] {
    portfolio = team();
    portfolio +>:Holds:+> Position(ticker="HLD", sector="Energy", qty=10, avg_entry_price=80.0, opened_at="2026-10-27T13:45:00+00:00");
    run = finished_run(portfolio, DAY, [
        Call(ticker="HLD", action=TradeAction.HOLD, sector="Energy", close=100.0),
        Call(ticker="NEW", action=TradeAction.BUY, sector="Utilities", close=50.0),
        Call(ticker="WAT", action=TradeAction.NO_ACTION, sector="Financials", close=20.0)
    ]);
    conclude(run, "HLD", 0.1, 0.6, TradeAction.HOLD);
    conclude(run, "NEW", 0.5, 0.8, TradeAction.BUY);
    conclude(run, "WAT", 0.3, 0.45, TradeAction.NO_ACTION);
    return (portfolio, run);
}

test "the defaults reproduce the run's decisions" {
    (portfolio, _) = seeded();
    view = replay(Policy(), stored(portfolio));
    assert view.run_date == DAY and view.differs == 0;
    assert view.counts == view.team_counts == {"HOLD": 1, "BUY": 1, "NO_ACTION": 1};
}

test "a looser bar buys what the team did not, marked as never reviewed by the Arbiter" {
    (portfolio, _) = seeded();
    view = replay(Policy(buy_agreement=0.4), stored(portfolio));
    wat = row_of(view, "WAT");
    assert wat.action == "BUY" and wat.changed and wat.unreviewed;
    assert view.differs == 1 and view.rows[0].ticker == "WAT";
    assert not row_of(view, "NEW").unreviewed;
}

test "a rule reads the stored figures, and an unknown metric is skipped, not guessed" {
    (portfolio, run) = seeded();
    coverage_of(run, "NEW").rsi_14 = 75.0;
    avoid = PolicyRule(id="R1", effect=RuleEffect.AVOID_BUY, conditions=[Condition(metric="rsi_14", op=Op.GT, number=70.0)]);
    exit_rule = PolicyRule(id="R2", effect=RuleEffect.SELL, conditions=[Condition(metric="return_since_entry", op=Op.GE, number=0.2)]);
    unknown = PolicyRule(id="R3", effect=RuleEffect.TRIM, conditions=[Condition(metric="momentum_20", op=Op.GT, number=0.1)]);
    view = replay(Policy(rules=[avoid, exit_rule, unknown]), stored(portfolio));
    new = row_of(view, "NEW");
    assert new.action == "NO_ACTION" and new.changed and any("R1" in n or "RSI" in n for n in new.notes);
    held = row_of(view, "HLD");
    assert held.held and held.action == "SELL" and any("25" in n for n in held.notes);
    assert view.differs == 2;
    # R3's momentum was not stored for this run: R2 sold first, so nothing is said of R3 here.
    trim_only = replay(Policy(rules=[unknown]), stored(portfolio));
    assert row_of(trim_only, "HLD").action == "HOLD" and row_of(trim_only, "HLD").skipped;
}

test "the Arbiter's downgrade of the team's buy holds in a replay" {
    (portfolio, run) = seeded();
    decided = decision_of(run, "NEW");
    decided.action = TradeAction.NO_ACTION;
    decided.downgrade_reason = "Earnings risk outweighs the setup.";
    view = replay(Policy(), stored(portfolio));
    new = row_of(view, "NEW");
    assert new.action == "NO_ACTION" and not new.changed and not new.unreviewed;
    assert any("Earnings risk" in n for n in new.notes);
}

test "a forced hold stays a hold unless an exit rule fires" {
    (portfolio, run) = seeded();
    decided = decision_of(run, "HLD");
    decided.forced_hold_reason = "insufficient data";
    assert row_of(replay(Policy(buy_score=0.05), stored(portfolio)), "HLD").action == "HOLD";
    stop = PolicyRule(id="R1", effect=RuleEffect.SELL, conditions=[Condition(metric="return_since_entry", op=Op.GT, number=0.1)]);
    assert row_of(replay(Policy(rules=[stop]), stored(portfolio)), "HLD").action == "SELL";
}

test "held means held that morning, and a passed time stop sells under the rule" {
    portfolio = team();
    portfolio +>:Holds:+> Position(ticker="OLD", sector="Energy", qty=1, avg_entry_price=10.0, opened_at="2026-10-01T13:45:00+00:00", closed_at="2026-10-20T13:45:00+00:00");
    portfolio +>:Holds:+> Position(ticker="NEXT", sector="Energy", qty=1, avg_entry_price=10.0, opened_at="2026-11-03T13:45:00+00:00");
    due = portfolio +>:Holds:+> Position(ticker="DUE", sector="Energy", qty=1, avg_entry_price=10.0, opened_at="2026-10-01T13:45:00+00:00");
    assert sorted(held_on(portfolio, DAY)) == ["DUE"];
    opener = Decision(ticker="DUE", action=TradeAction.BUY, conviction=0.5, time_stop="2026-11-02");
    due +>:OpenedBy():+> opener;
    run = finished_run(portfolio, DAY, [Call(ticker="DUE", action=TradeAction.SELL, close=11.0), Call(ticker="OLD", action=TradeAction.NO_ACTION, close=11.0)]);
    conclude(run, "DUE", 0.0, 0.5, TradeAction.SELL);
    conclude(run, "OLD", 0.0, 0.5, TradeAction.NO_ACTION);
    found = stored(portfolio);
    view = replay(Policy(), found);
    assert row_of(view, "DUE").action == "SELL" and not row_of(view, "DUE").changed;
    assert not row_of(view, "OLD").held;
    assert row_of(replay(Policy(time_stop=False), found), "DUE").action == "HOLD";
}

test "the newest run with decisions is the default, with its neighbors" {
    portfolio = team();
    finished_run(portfolio, "2026-11-02", [Call(ticker="AAA", action=TradeAction.NO_ACTION)]);
    finished_run(portfolio, "2026-11-03", [Call(ticker="BBB", action=TradeAction.NO_ACTION)]);
    finished_run(portfolio, "2026-11-04", []);
    found = stored_run(portfolio);
    assert found is not None;
    assert (found.run_date, found.previous_day, found.next_day) == ("2026-11-03", "2026-11-02", "2026-11-04");
    assert stored(portfolio, "2026-11-02").next_day == "2026-11-03";
    assert stored_run(portfolio, "2026-01-01") is None;
}

test "a draft past its limits gets its problems back, not a replay" {
    view = replay_team_run(Policy(max_position_weight=0.5));
    assert view.problems and not view.rows and "Largest position" in view.problems[0];
}
