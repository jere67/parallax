"""The demo history (dashboard/demo.jac): a consistent record that the dashboard can show, made
by the project's own consensus, sizing, gate, baseline, and scoring code."""
import from datetime { date }
import from analysis.consensus { abstains }
import from analysis.evaluation { latest_evaluation }
import from action.baselines { baselines_of, sim_marks }
import from action.fixtures { team }
import from action.reconcile { marks_of }
import from dashboard.api { performance_view, portfolio_view, run_summaries, run_view, trail_view }
import from dashboard.demo { DEMO_SESSIONS, DemoSim, seed_demo, weekdays_before }
import from models.agents { Specialist }
import from models.graph { Coverage, Covers, Decided, Decision, Holds, Order, PortfolioMode, Position, Ran, Run, Sent, VoteRecord, Voted }

glob TODAY: date = date(2026, 10, 22);

test "weekdays end the day before and skip weekends" {
    assert weekdays_before(date(2026, 10, 26), 3) == ["2026-10-21", "2026-10-22", "2026-10-23"];
    assert weekdays_before(date(2026, 10, 26), 1, 2) == ["2026-10-23", "2026-10-26", "2026-10-27"];
}

test "the demo history is consistent, and every page's view can be built from it" {
    portfolio = team(PortfolioMode.INSIGHT, 0.0);
    sim = DemoSim(portfolio=portfolio, today=TODAY);
    sim.run();
    marks = marks_of(portfolio);
    assert len(marks) == DEMO_SESSIONS and max(marks) == "2026-10-21" and portfolio.demo;
    assert all(not m.drift and not m.bypasses for m in marks.values());
    last = marks[max(marks)];
    held = [p for p in [portfolio ->:Holds:->[?:Position]] if p.open()];
    assert abs(last.equity - (sim.cash + sum(p.qty * p.last_price for p in held))) < 1e-6 and sim.cash > 0;
    runs = [r for r in [portfolio ->:Ran:->[?:Run]]];
    assert len(runs) == DEMO_SESSIONS and {r.status.value for r in runs} == {"normal", "fallback"};
    actions = {d.action.value for r in runs for c in [r ->:Covers:->[?:Coverage]] for d in [c ->:Decided:->[?:Decision]]};
    assert {"BUY", "SELL", "NO_ACTION"} <= actions;
    orders = [o for o in [portfolio ->:Sent:->[?:Order]]];
    assert {o.purpose.value for o in orders} >= {"entry", "stop", "exit"};
    votes = [v for r in runs for c in [r ->:Covers:->[?:Coverage]] for v in [c ->:Voted:->[?:VoteRecord]]];
    assert 0 < len([v for v in votes if v.excess_return is not None]) < len(votes);
    for b in baselines_of(portfolio).values() {
        assert len(sim_marks(b)) == DEMO_SESSIONS;
    }
    # The evening review's evaluation covers every session, both baselines, the screens and
    # decisions whose windows closed, and every run as complete.
    found = latest_evaluation(portfolio);
    assert found is not None and found.sessions == DEMO_SESSIONS and [c.baseline for c in found.comparisons] == ["equal_weight", "spy"];
    assert found.demo and len(found.snapshot) == 8;
    assert 0 < found.screen.runs < DEMO_SESSIONS and len(found.specialists) == 5 and found.reliability.share == 1.0;
    decisions = [d for r in runs for c in [r ->:Covers:->[?:Coverage]] for d in [c ->:Decided:->[?:Decision]]];
    assert 0 < len([d for d in decisions if d.excess_return is not None]) < len(decisions);

    view = portfolio_view(portfolio);
    assert view.started and view.demo and view.sessions == DEMO_SESSIONS and view.closed;
    assert len(performance_view(portfolio).series) == 3 and len(run_summaries(portfolio)) == DEMO_SESSIONS;
    latest = run_view(portfolio, "");
    assert latest is not None and latest.rows;
    trail = trail_view(portfolio, latest.run_date, latest.rows[0].ticker);
    assert trail is not None and len(trail.specialists) == 5 and len(trail.research) == 3;
    # Every cited position names evidence in the packet the specialist read.
    assert all(x.sources and len(x.sources) == len(x.cited) for s in trail.specialists for x in s.samples if not x.abstained);
    # Some Flow samples abstain on the supplied gap, as live runs do, and no other specialist does.
    assert any(abstains(v.body) for v in votes if v.specialist == Specialist.FLOW);
    assert not any(abstains(v.body) for v in votes if v.specialist != Specialist.FLOW);
}

test "the seed writes into an empty team portfolio once, and never over history" {
    first = seed_demo(TODAY);
    assert first.startswith("demo: wrote 23 sessions");
    assert seed_demo(TODAY) == "demo: the team portfolio already has history; nothing written";
}
