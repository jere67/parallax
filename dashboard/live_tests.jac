"""The live portfolio overlay (dashboard/live.jac): totals and positions as Alpaca values them, the
cached close view left alone, and Alpaca asked at most once a minute per portfolio."""
import time;
import from action.broker { Account, BrokerError, BrokerPosition }
import from dashboard.live { Reading, live_view, reading_for, with_live }
import from models.graph { Portfolio, PortfolioMode }
import from models.views { PortfolioView, PositionView }

"""The 2026-11-11 morning as the page showed it: marked at the Nov 10 close with nothing invested,
and two positions opened at 9:46 at their fill prices."""
def marked_view -> PortfolioView {
    return PortfolioView(
        name="agent",
        mode="auto",
        started=True,
        starting_cash=100000.0,
        last_day="2026-11-10",
        equity=99999.96,
        cash=99999.96,
        positions_value=0.0,
        peak_equity=99999.96,
        drawdown=0.0,
        gross_exposure=0.0,
        positions=[
            PositionView(ticker="AMZN", sector="Consumer", qty=2, avg_entry_price=269.31, opened_at="2026-11-11T14:46:00Z", stop_price=250.38, last_price=269.31),
            PositionView(ticker="FOXA", sector="Media", qty=16, avg_entry_price=66.82, opened_at="2026-11-11T14:46:00Z", stop_price=61.77, last_price=66.82)
        ]
    );
}

def reading(equity: float = 100010.0) -> Reading {
    return Reading(
        at="2026-11-11T16:00:00+00:00",
        read_at=time.monotonic(),
        account=Account(number="PA1", status="ACTIVE", equity=equity, cash=98391.5, buying_power=0.0, last_equity=99999.96, trading_blocked=False),
        held={
            "AMZN": BrokerPosition(symbol="AMZN", qty=2, qty_available=0, avg_entry_price=269.31, current_price=272.0, market_value=544.0),
            "FOXA": BrokerPosition(symbol="FOXA", qty=16, qty_available=0, avg_entry_price=66.82, current_price=67.13, market_value=1074.08)
        }
    );
}

test "the live view values the account and each position as Alpaca does now" {
    view = marked_view();
    live = with_live(view, reading());
    assert live.live_at == "2026-11-11T16:00:00+00:00" and live.equity == 100010.0 and live.cash == 98391.5;
    assert abs(live.positions_value - 1618.08) < 1e-9 and abs(live.gross_exposure - 1618.08 / 100010.0) < 1e-12;
    assert abs(live.day_pnl - 10.04) < 1e-9 and abs(live.total_return - 0.0001) < 1e-12;
    assert [p.ticker for p in live.positions] == ["FOXA", "AMZN"];
    amzn = [p for p in live.positions if p.ticker == "AMZN"][0];
    assert amzn.last_price == 272.0 and abs(amzn.pnl - 5.38) < 1e-9 and abs(amzn.market_value - 544.0) < 1e-9;
    assert abs(amzn.stop_distance - (1.0 - 250.38 / 272.0)) < 1e-12;
    # The cached close view is untouched.
    assert view.live_at == "" and view.equity == 99999.96 and view.positions[0].last_price == 269.31;
}

test "a drop below the highest close shows as drawdown, and a new high as none" {
    assert abs(with_live(marked_view(), reading(equity=95000.0)).drawdown - (1.0 - 95000.0 / 99999.96)) < 1e-12;
    assert with_live(marked_view(), reading(equity=101000.0)).drawdown == 0.0;
}

test "Alpaca is asked once a minute per portfolio, and a failure is not retried at once" {
    calls: list[str] = [];
    def good(_p: Portfolio) -> Reading {
        calls.append("good");
        return reading();
    }
    def down(_p: Portfolio) -> Reading {
        calls.append("down");
        raise BrokerError(path="/v2/account", detail="unreachable");
    }
    portfolio = Portfolio(name="agent", mode=PortfolioMode.AUTO, starting_cash=100000.0, opened_at="2026-11-09T00:00:00Z");
    key = f"live-test-{time.monotonic()}";
    assert reading_for(key, portfolio, good).account is not None;
    assert reading_for(key, portfolio, good).account is not None and calls == ["good"];
    other = key + "-down";
    assert reading_for(other, portfolio, down).failed and reading_for(other, portfolio, down).failed;
    assert calls == ["good", "down"];
}

test "a demo portfolio and one not yet started are shown as marked" {
    view = marked_view();
    demo = Portfolio(name="team", mode=PortfolioMode.AUTO, starting_cash=100000.0, opened_at="2026-11-09T00:00:00Z", demo=True);
    assert live_view("live-test-demo", view, demo) is view;
    fresh = PortfolioView(name="agent", mode="insight", started=False);
    real = Portfolio(name="agent", mode=PortfolioMode.INSIGHT, starting_cash=0.0, opened_at="2026-11-09T00:00:00Z");
    assert live_view("live-test-fresh", fresh, real) is fresh;
}
