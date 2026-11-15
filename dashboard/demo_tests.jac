"""The demo history (dashboard/demo.jac): a consistent record that the dashboard can show, made
by the project's own consensus, sizing, gate, baseline, and scoring code."""
import from datetime { date }
import from analysis.consensus { abstains }
import from analysis.evaluation { latest_evaluation }
import from action.baselines { baselines_of, sim_marks }
import from action.fixtures { team }
import from action.reconcile { marks_of }
import from dashboard.api { performance_view, portfolio_view, run_summaries, run_view, trail_view }
import from dashboard.demo { DEMO_SESSIONS, DemoSim, black_scholes, contract, every_day, seed_demo, weekdays_before }
import from models.agents { Specialist }
import from models.assets { ASSET_CLASSES, CRYPTO, OPTIONS, STOCKS }
import from models.graph { CheckedBy, Coverage, Covers, Decided, Decision, Holds, OpenedBy, Order, Placed, PortfolioMode, Position, Ran, RiskCheck, RiskOutcome, Run, Sent, VoteRecord, Voted }
import from research.options { CALL, PUT }

glob TODAY: date = date(2026, 10, 22);

test "weekdays end the day before and skip weekends" {
    assert weekdays_before(date(2026, 10, 26), 3) == ["2026-10-21", "2026-10-22", "2026-10-23"];
    assert weekdays_before(date(2026, 10, 26), 1, 2) == ["2026-10-23", "2026-10-26", "2026-10-27"];
    assert every_day("2026-10-23", date(2026, 10, 26)) == ["2026-10-23", "2026-10-24", "2026-10-25"];
}

test "options are priced by Black-Scholes" {
    # A one-year at-the-money call at 20% volatility and a 4% rate, and put-call parity.
    call = black_scholes(100.0, 100.0, 1.0, 0.2, CALL);
    put = black_scholes(100.0, 100.0, 1.0, 0.2, PUT);
    assert abs(call - 9.925) < 0.01;
    assert abs((call - put) - (100.0 - 100.0 * 2.718281828 ** -0.04)) < 1e-6;
    assert black_scholes(120.0, 100.0, 0.0, 0.2, CALL) == 20.0 and black_scholes(120.0, 100.0, 0.0, 0.2, PUT) == 0.0;
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
    assert abs(last.equity - (sim.cash + sum(p.qty * p.multiplier * p.last_price for p in held))) < 1e-6 and sim.cash > 0;
    runs = [r for r in [portfolio ->:Ran:->[?:Run]]];
    weekends = [r for r in runs if date.fromisoformat(r.run_date).weekday() >= 5];
    assert len(runs) == len(sim.run_days) == DEMO_SESSIONS + len(weekends) and len(weekends) >= 6;
    assert {r.status.value for r in runs} == {"normal", "fallback"} and all(r.asset_classes == ASSET_CLASSES for r in runs);
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
    assert len(performance_view(portfolio).series) == 3 and len(run_summaries(portfolio)) == len(runs);
    latest = run_view(portfolio, "");
    assert latest is not None and latest.rows;
    stock = [row.ticker for row in latest.rows if "/" not in row.ticker][0];
    trail = trail_view(portfolio, latest.run_date, stock);
    assert trail is not None and len(trail.specialists) == 5 and len(trail.research) == 3;
    # Every cited position names evidence in the packet the specialist read.
    assert all(x.sources and len(x.sources) == len(x.cited) for s in trail.specialists for x in s.samples if not x.abstained);
    # Some Flow samples abstain on the supplied gap, as live runs do, and no other specialist does.
    assert any(abstains(v.body) for v in votes if v.specialist == Specialist.FLOW);
    assert not any(abstains(v.body) for v in votes if v.specialist != Specialist.FLOW);

    # The latest run shows the trail's harder states: its first screened ticker's News specialist
    # failed every sample, another ticker's Flow specialist abstained, and somewhere in the
    # history the gate blocked an order, which left no Order behind.
    trails = [t for row in latest.rows for t in [trail_view(portfolio, latest.run_date, row.ticker)] if t is not None];
    assert {"voted", "failed", "abstained"} <= {s.status for t in trails for s in t.specialists};
    failed = [s for t in trails for s in t.specialists if s.status == "failed"];
    assert len(failed) == 1 and failed[0].specialist == "news" and len(failed[0].errors) == 3 and failed[0].samples == [];
    blocked = [rc for d in decisions for rc in [d ->:CheckedBy:->[?:RiskCheck]] if rc.outcome == RiskOutcome.REJECTED];
    assert blocked and all([rc ->:Placed:->] == [] for rc in blocked);
}

test "the seed writes into an empty team portfolio once, and never over history" {
    first = seed_demo(TODAY);
    assert first.startswith("demo: wrote 23 sessions");
    assert seed_demo(TODAY) == "demo: the team portfolio already has history; nothing written";
}

test "the demo trades every asset class: coins on weekends too, and calls and puts" {
    portfolio = team(PortfolioMode.INSIGHT, 0.0);
    sim = DemoSim(portfolio=portfolio, today=TODAY);
    sim.run();
    runs = [r for r in [portfolio ->:Ran:->[?:Run]]];
    marked = set(marks_of(portfolio));
    for r in runs {
        covered = [c for c in [r ->:Covers:->[?:Coverage]]];
        coins = [c for c in covered if c.asset_class == CRYPTO];
        assert len(coins) == 5 and all("/" in c.ticker and c.sector == "Crypto" and c.sessions_to_earnings is None for c in coins);
        if date.fromisoformat(r.run_date).weekday() >= 5 {
            # A weekend run covers the coins alone, trades them, and marks nothing.
            assert len(covered) == 5 and r.run_date not in marked and r.executed_at and not r.reconciled_at;
            assert r.summary.startswith("Weekend run.");
        } else {
            assert len(covered) > 5 and r.options_at;
        }
        # A coin's panel is Technical, News, and Macro, on market and news research alone.
        for c in coins {
            assert {v.specialist for v in [c ->:Voted:->[?:VoteRecord]]} <= {Specialist.TECHNICAL, Specialist.NEWS, Specialist.MACRO};
        }
    }
    orders = [o for o in [portfolio ->:Sent:->[?:Order]]];
    weekend_days = {r.run_date for r in runs if date.fromisoformat(r.run_date).weekday() >= 5};
    coin_orders = [o for o in orders if o.asset_class == CRYPTO];
    assert any(o.submitted_at and o.status == "filled" and o.purpose.value != "stop" and any(o.submitted_at.startswith(d) for d in weekend_days) for o in coin_orders);
    # Fractional coins, GTC entries, and GTC stop-limits a little under the stop.
    assert any(o.qty != int(o.qty) for o in coin_orders);
    assert all(o.time_in_force == "gtc" for o in coin_orders);
    stops = [o for o in coin_orders if o.purpose.value == "stop"];
    assert stops and all(o.order_type == "stop_limit" and 0 < o.limit_price < o.stop_price for o in stops);
    assert all(o.order_type == "stop" for o in orders if o.asset_class == STOCKS and o.purpose.value == "stop");

    # Options: contracts of 100 shares opened on a decision and sold by an exit rule, both through
    # a risk check, and none left within a week of expiry.
    options = [p for p in [portfolio ->:Holds:->[?:Position]] if p.asset_class == OPTIONS];
    assert options and all(p.multiplier == 100.0 and [p ->:OpenedBy:->[?:Decision]] for p in options);
    assert {contract(p.ticker).kind for p in options} == {CALL, PUT};
    option_orders = [o for o in orders if o.asset_class == OPTIONS];
    assert {o.purpose.value for o in option_orders} == {"entry", "exit"} and all(o.status == "filled" and o.time_in_force == "day" for o in option_orders);
    assert all([o <-:Placed:<-[?:RiskCheck]] for o in option_orders);
    # Some views are refused by an option rule, and the refusal is on record with its reason.
    refused = [rc for r in runs for c in [r ->:Covers:->[?:Coverage]] for d in [c ->:Decided:->[?:Decision]] for rc in [d ->:CheckedBy:->[?:RiskCheck]] if rc.asset_class == OPTIONS and rc.outcome == RiskOutcome.REJECTED];
    assert refused and all(not rc.rules[-1].passed and rc.rules[-1].detail for rc in refused);
    last_day = sim.days[-1];
    for p in options {
        if p.open() {
            assert (date.fromisoformat(contract(p.ticker).expiry) - date.fromisoformat(last_day)).days > 7;
        }
    }
}

