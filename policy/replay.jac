"""A stored run replayed under any policy (TDD §7, policy): plain code over what the run stored,
so it costs no model request, places no order, and answers as fast as a slider moves.

A run stores each ticker's consensus, figures, and decision. `run_facts` reads them once, and
the read is cached, since a finished run does not change; `replay` then applies a policy to
them. "Held" means the team held the stock that morning, so a replay answers "what if the team
ran these rules today". The Arbiter reviewed only the action the team's own rule proposed, so
a replay honors a downgrade of a buy, and marks a buy the Arbiter never saw as unreviewed.
"""
import from analysis.consensus { Consensus }
import from analysis.policy { Facts, describe, evaluate, rule_sentence, validate }
import from dashboard.api { find_team, runs_by_day, view_key }
import from dashboard.cache { VIEWS }
import from models.graph { Concluded, ConsensusResult, Coverage, Covers, Decided, Decision, HasMacro, Holds, InsightCard, MacroRecord, OpenedBy, Portfolio, Position, Run, TradeAction }
import from models.policy { Policy }
import from models.policy_views { ReplayRow, ReplayView }
import from policy.facts { Entry, MarketFacts, add_panel, stock_facts, stock_from_coverage }

glob BUYS: tuple[TradeAction, TradeAction] = (TradeAction.BUY, TradeAction.ADD);
glob REVIEWED_DOWNGRADE: dict[TradeAction, TradeAction] = {TradeAction.BUY: TradeAction.NO_ACTION, TradeAction.ADD: TradeAction.HOLD};

"""What a run stored about one ticker, in the form a policy reads."""
obj StoredTicker {
    has ticker: str,
        sector: str,
        held: bool,
        facts: Facts,
        team_action: TradeAction;
    has panel: Consensus | None = None,
        exit_due: bool = False,
        forced: bool = False,
        team_draft: TradeAction | None = None,
        downgrade_reason: str = "";
}

"""What one run stored about every ticker it covered."""
obj StoredRun {
    has run_date: str;
    has previous_day: str = "",
        next_day: str = "",
        demo: bool = False,
        version: int = 0,
        tickers: list[StoredTicker] = [];
}

"""The team's positions open on the morning of `day`, by ticker."""
def held_on(portfolio: Portfolio, day: str) -> dict[str, Position] {
    found: dict[str, Position] = {};
    for p in [portfolio ->:Holds:->[?:Position]] {
        if p.opened_at[:10] < day and (not p.closed_at or p.closed_at[:10] >= day) {
            found[p.ticker] = p;
        }
    }
    return found;
}

def position_time_stop(p: Position) -> str {
    if p.time_stop {
        return p.time_stop;
    }
    for d in [p ->:OpenedBy:->[?:Decision]] {
        return d.time_stop;
    }
    return "";
}

"""What `run` stored, by ticker, sorted by ticker."""
def read_run(portfolio: Portfolio, run: Run, days: list[str]) -> StoredRun {
    at = days.index(run.run_date);
    found = StoredRun(
        run_date=run.run_date,
        previous_day=days[at - 1] if at > 0 else "",
        next_day=days[at + 1] if at + 1 < len(days) else "",
        demo=portfolio.demo,
        version=run.policy_version
    );
    positions = held_on(portfolio, run.run_date);
    market = MarketFacts();
    for m in [run ->:HasMacro:->[?:MacroRecord]] {
        market = MarketFacts(regime=m.body.regime.value, inputs=m.inputs);
    }
    for cov in [run ->:Covers:->[?:Coverage]] {
        decided = [d for d in [cov ->:Decided:->[?:Decision]]];
        if not decided {
            continue;
        }
        d = decided[0];
        position = positions.get(cov.ticker);
        held = position is not None or cov.reason.value == "held";
        entry_of = Entry(avg_entry_price=position.avg_entry_price, opened_day=position.opened_at[:10]) if position is not None else None;
        facts = stock_facts(stock_from_coverage(cov), market, entry_of, run.run_date);
        concluded = [c for c in [cov ->:Concluded:->[?:ConsensusResult]]];
        panel: Consensus | None = None;
        draft: TradeAction | None = None;
        if concluded {
            c = concluded[0];
            draft = c.draft_action;
            panel = Consensus(score=c.score, agreement=c.agreement, ci_low=c.ci_low, ci_high=c.ci_high, specialist_scores=c.specialist_scores, weights=c.weights);
        }
        add_panel(facts, panel);
        stop = position_time_stop(position) if position is not None else "";
        found.tickers.append(StoredTicker(
            ticker=cov.ticker,
            sector=cov.sector,
            held=held,
            facts=facts,
            team_action=d.action,
            panel=panel,
            exit_due=bool(stop) and stop <= run.run_date,
            forced=bool(d.forced_hold_reason),
            team_draft=draft,
            downgrade_reason=d.downgrade_reason
        ));
    }
    found.tickers.sort(key=lambda (t: StoredTicker) { t.ticker; });
    return found;
}

"""The run for `run_date`, or the newest run that decided anything; None when there is none."""
def stored_run(portfolio: Portfolio, run_date: str = "") -> StoredRun | None {
    runs = runs_by_day(portfolio);
    days = sorted(runs);
    if run_date {
        return read_run(portfolio, runs[run_date], days) if run_date in runs else None;
    }
    for day in reversed(days) {
        found = read_run(portfolio, runs[day], days);
        if found.tickers {
            return found;
        }
    }
    return None;
}

"""One ticker under `policy`."""
def replay_ticker(policy: Policy, t: StoredTicker) -> ReplayRow {
    outcome = evaluate(policy, t.facts, t.held, t.panel, t.exit_due, t.forced);
    action = outcome.action;
    notes = [s.detail for s in outcome.steps];
    unreviewed = False;
    if action in BUYS {
        if t.downgrade_reason and t.team_draft in BUYS {
            action = REVIEWED_DOWNGRADE[action];
            notes.append(f"The Arbiter downgraded the team's buy: {t.downgrade_reason}");
        } elif t.team_draft not in BUYS {
            unreviewed = True;
        }
    }
    return ReplayRow(
        ticker=t.ticker,
        team_action=t.team_action.value,
        action=action.value,
        sector=t.sector,
        held=t.held,
        score=t.panel.score if t.panel is not None else None,
        agreement=t.panel.agreement if t.panel is not None else None,
        conviction=t.panel.conviction() if t.panel is not None else 0.0,
        changed=action != t.team_action,
        notes=notes,
        skipped=outcome.skipped,
        unreviewed=unreviewed
    );
}

"""`run` under `policy`: changed tickers first, then by conviction."""
def replay(policy: Policy, run: StoredRun) -> ReplayView {
    rows = sorted([replay_ticker(policy, t) for t in run.tickers], key=lambda (r: ReplayRow) { (not r.changed, -r.conviction, r.ticker); });
    view = ReplayView(run_date=run.run_date, previous_day=run.previous_day, next_day=run.next_day, demo=run.demo, team_version=run.version, rows=rows, differs=len([r for r in rows if r.changed]));
    for r in rows {
        view.counts[r.action] = view.counts.get(r.action, 0) + 1;
        view.team_counts[r.team_action] = view.team_counts.get(r.team_action, 0) + 1;
    }
    return view;
}

"""What the team's run for `run_date` (or the newest) stored, through the read cache."""
def team_run(run_date: str = "") -> StoredRun | None {
    team = find_team();
    if team is None {
        return None;
    }
    return VIEWS.get(view_key(team, "policy-run", run_date), stored_run, team, run_date);
}

"""The team's run for `run_date` (or the newest) under `policy`. An invalid draft gets its
problems back instead of a replay."""
def replay_team_run(policy: Policy, run_date: str = "") -> ReplayView {
    problems = validate(policy);
    if problems {
        return ReplayView(problems=problems);
    }
    found = team_run(run_date);
    view = replay(policy, found) if found is not None else ReplayView();
    view.sentences = describe(policy);
    view.rule_sentences = [rule_sentence(r) for r in policy.rules];
    return view;
}

"""A report's card under `policy`. A card stores the panel's figures and little else, so a rule
on any other metric is skipped and says so. A report is not a holding, so nothing here is held,
and a buy the Arbiter downgraded stays downgraded."""
def replay_card(policy: Policy, card: InsightCard) -> ReplayRow {
    facts = Facts();
    facts.put_word("ticker", card.ticker);
    panel: Consensus | None = None;
    if card.score is not None and card.agreement is not None and card.ci_low is not None {
        panel = Consensus(score=card.score, agreement=card.agreement, ci_low=card.ci_low, ci_high=card.ci_high if card.ci_high is not None else card.score, specialist_scores={t.specialist: t.score for t in card.specialists});
    }
    add_panel(facts, panel);
    outcome = evaluate(policy, facts, False, panel);
    action = outcome.action;
    notes = [s.detail for s in outcome.steps];
    downgraded = "Downgraded by the Arbiter" in card.note;
    if action in BUYS and downgraded {
        action = REVIEWED_DOWNGRADE[action];
        notes.append("The Arbiter downgraded this buy.");
    }
    return ReplayRow(
        ticker=card.ticker,
        team_action=card.action.value,
        action=action.value,
        score=card.score,
        agreement=card.agreement,
        conviction=card.conviction,
        changed=action != card.action,
        notes=notes,
        skipped=outcome.skipped,
        unreviewed=action in BUYS and card.action not in BUYS
    );
}
