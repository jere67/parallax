"""The report catalog a demo server keeps (reports/worker.jac, `refresh_catalog`)."""
import from action.fixtures { Call, finished_run, team }
import from models.graph { PortfolioMode, TradeAction }
import from reports.worker { refresh_catalog }

test "a demo catalog offers the stocks of the newest run that covered stocks, not a weekend's coins" {
    portfolio = team(PortfolioMode.AUTO, 100000.0);
    portfolio.demo = True;
    finished_run(portfolio, "2026-11-13", [Call(ticker="AAPL", action=TradeAction.BUY, conviction=0.6), Call(ticker="BTC/USD", action=TradeAction.HOLD, conviction=0.2)]);
    finished_run(portfolio, "2026-11-14", [Call(ticker="ETH/USD", action=TradeAction.BUY, conviction=0.5)]);
    found = refresh_catalog(portfolio);
    assert found.demo and found.trading_date == "2026-11-13" and found.symbols == ["AAPL"], (found.trading_date, found.symbols);
}
