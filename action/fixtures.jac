"""Builders for the Action layer's tests and its exit run: a team portfolio, a finished run
with decisions, a market view, and a broker client on the fake broker, so nothing reaches
Alpaca.

They build project types, so they live beside the action modules: `jac build` seals
`tests/fakes/` as a separate dependency, and a type built there is a different type to the
checker (the fake broker itself speaks only HTTP)."""
import uuid;
import from datetime { datetime }
import from action.broker { Broker }
import from action.executor { MarketView }
import from models.agents { MacroReport, RiskRegime }
import from models.graph {
    Coverage,
    CoverageReason,
    Covers,
    Decided,
    Decision,
    HasMacro,
    MacroRecord,
    Portfolio,
    PortfolioMode,
    Ran,
    Run,
    RunStatus,
    TradeAction
}
import from models.research { RegimeInputs, Stamp }
import from research.alpaca { Asset, LatestTrade }
import from research.collector { TokenBucket }
import from run.public { public }
import from tests.fakes.broker_server { FakeBroker }

glob CALM: RegimeInputs = RegimeInputs(spy_close=500.0, spy_sma_200=450.0, spy_vol_20=0.15, spy_as_of="2026-10-20");
glob TEST_KEYS: dict[str, str] = {"APCA-API-KEY-ID": "test-key", "APCA-API-SECRET-KEY": "test-secret"};

"""One covered ticker's decision and the market figures the run stored with it."""
obj Call {
    has ticker: str,
        action: TradeAction;
    has conviction: float = 0.5,
        sector: str = "Information Technology",
        close: float = 100.0,
        atr: float | None = 2.0,
        vol: float | None = 0.2,
        volume: float | None = 1000000.0,
        earnings_in: int | None = None,
        time_stop: str = "";
}

def stamp(at: str) -> Stamp {
    return Stamp(source="alpaca_data", dataset="alpaca.latest_trade", source_url="https://data.alpaca.markets/v2/stocks/trades/latest", published_at=at, fetched_at=at);
}

"""A fresh team portfolio under `root`, in auto mode unless asked otherwise."""
def team(mode: PortfolioMode = PortfolioMode.AUTO, starting_cash: float = 100000.0) -> Portfolio {
    found = Portfolio(name=f"test-{uuid.uuid4()}", mode=mode, starting_cash=starting_cash, opened_at="2026-10-01T00:00:00+00:00");
    root ++> found;
    return found;
}

"""A finished run for `run_day` on `portfolio` with one coverage and decision per call."""
def finished_run(portfolio: Portfolio, run_day: str, calls: list[Call], regime: RegimeInputs | None = CALM, status: RunStatus = RunStatus.NORMAL) -> Run {
    run = public(portfolio +>:Ran():+> Run(run_date=run_day, started_at=f"{run_day}T11:30:00+00:00", status=status, finished_at=f"{run_day}T13:00:00+00:00"));
    public(run +>:HasMacro():+> MacroRecord(as_of=run.finished_at, model="mock", body=MacroReport(summary="Calm.", regime=RiskRegime.NEUTRAL, confidence=0.5), inputs=regime));
    for c in calls {
        cov = public(run +>:Covers():+> Coverage(
            ticker=c.ticker,
            sector=c.sector,
            reason=CoverageReason.SCREEN,
            last_close=c.close,
            atr_14=c.atr,
            realized_vol_20=c.vol,
            volume_20=c.volume,
            sessions_to_earnings=c.earnings_in
        ));
        public(cov +>:Decided():+> Decision(ticker=c.ticker, action=c.action, conviction=c.conviction, thesis=f"{c.ticker} thesis.", risks=["Rates.", "Valuation."], exit_condition="A close below the 50-day average.", time_stop=c.time_stop));
    }
    return run;
}

"""Latest trades at `prices`, traded at `now`, and an asset list where every stock but the
`untradable` ones can trade."""
def market(prices: dict[str, float], now: datetime, untradable: set[str] | None = None) -> MarketView {
    at = now.isoformat();
    closed = untradable or set();
    return MarketView(
        trades={t: LatestTrade(symbol=t, price=p, size=100.0, at=at, exchange="V", stamp=stamp(at)) for (t, p) in prices.items()},
        assets={t: Asset(symbol=t, name=t, exchange="NYSE", tradable=t not in closed, fractionable=True, shortable=True, easy_to_borrow=True, stamp=stamp(at)) for t in prices}
    );
}

"""A broker client on a started fake broker, with no rate-limit waits."""
def broker_for(fake: FakeBroker) -> Broker {
    return Broker(base_url=fake.start(), headers=TEST_KEYS, bucket=TokenBucket(per_minute=60000.0, burst=1000), backoff_s=0.0);
}
