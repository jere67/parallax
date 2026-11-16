"""Seeding the demo account's history (accounts/demo.jac): once per version, and a newer version
replaces an older one without touching any other portfolio."""
import from datetime { date }
import from accounts.demo { clear_history, needs_seed, seed_demo_account }
import from accounts.transfer { own_store }
import from accounts.store { DEMO_PORTFOLIO, demo_portfolio }
import from action.fixtures { team }
import from dashboard.demo { DEMO_VERSION }
import from models.graph { Holds, Marked, Portfolio, PortfolioMode, Position, Ran, Run, Sent }

glob TODAY: date = date(2026, 11, 16);

def history(portfolio: Portfolio) -> tuple[int, int, int, int] {
    return (len([portfolio ->:Ran:->]), len([portfolio ->:Marked:->]), len([portfolio ->:Holds:->]), len([portfolio ->:Sent:->]));
}

test "the demo account's history is written once per version, and an older one is replaced" {
    # Another portfolio with history of its own, which no reseed may touch.
    other = team(PortfolioMode.AUTO, 100000.0);
    run = other +>:Ran:+> Run(run_date="2026-11-13", started_at="2026-11-13T12:30:00+00:00");
    other +>:Holds:+> Position(ticker="AAPL", sector="Information Technology", qty=5, avg_entry_price=200.0, opened_at="2026-11-13T14:46:00+00:00");
    kept = history(other);

    first = seed_demo_account(TODAY);
    assert first.startswith("demo account: wrote 33 runs (23 sessions)"), first;
    portfolio = demo_portfolio();
    assert portfolio is not None and portfolio.name == DEMO_PORTFOLIO and portfolio.demo and portfolio.demo_version == DEMO_VERSION;
    written = history(portfolio);
    assert seed_demo_account(TODAY) == "";

    # A server that holds an older version writes the new one in its place, on the same node.
    portfolio.demo_version = DEMO_VERSION - 1;
    again = seed_demo_account(TODAY);
    assert "in place of" in again, again;
    assert demo_portfolio() is portfolio and portfolio.demo_version == DEMO_VERSION;
    assert history(portfolio) == written;
    assert history(other) == kept and [r for r in [other ->:Ran:->[?:Run]]][0] is run;
}

test "clearing a history stops at other portfolios" {
    portfolio = team(PortfolioMode.AUTO, 100000.0);
    neighbor = team(PortfolioMode.AUTO, 100000.0);
    run = portfolio +>:Ran:+> Run(run_date="2026-11-13", started_at="2026-11-13T12:30:00+00:00");
    # An edge out of the history to another portfolio must not take that portfolio with it.
    run ++> neighbor;
    neighbor +>:Ran:+> Run(run_date="2026-11-13", started_at="2026-11-13T12:30:00+00:00");
    assert clear_history(portfolio) == 1;
    assert [portfolio ->:Ran:->] == [] and len([neighbor ->:Ran:->]) == 1;
}

test "the seed job asks the database whether the demo history is due" {
    store = own_store();
    try {
        assert needs_seed(store);
        seed_demo_account(TODAY);
        commit();
        assert not needs_seed(store);
        portfolio = demo_portfolio();
        assert portfolio is not None;
        portfolio.demo_version = DEMO_VERSION - 1;
        commit();
        assert needs_seed(store);
        # A portfolio named demo that someone else made is left alone, so it is never due.
        portfolio.demo = False;
        commit();
        assert not needs_seed(store);
    } finally {
        store.close();
    }
}
