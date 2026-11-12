"""The portfolio as Alpaca values it now (dashboard, TDD §10).

The portfolio view is built from the graph, where the account is marked once a day at the
close (action/reconcile.jac). Between marks its equity, cash, and exposure stand still while
positions open and prices move. So a reader's portfolio view is overlaid with the paper
account's equity, cash, and each position's price as Alpaca reports them, read with the keys of
the agent that trades it, at most once a minute per portfolio, and never written to the graph.

The close marks stay what the performance chart, drawdown breaker, and baselines measure.
"""
import copy;
import threading;
import time;
import from datetime { datetime, timezone }
import from accounts.store { credentials_of, my_account }
import from action.broker { Account, Broker, BrokerError, BrokerPosition }
import from models.graph { Portfolio }
import from models.views { PortfolioView, PositionView }
import from research.collector { SourceError }
import from research.credentials { enter_credentials, leave_credentials }
import from accounts.vault { VaultError }
import from run.guard { TEAM_PORTFOLIO }

# How long one reading of the account serves every reader of that portfolio.
glob LIVE_TTL_S: float = 60.0;

"""One reading of a paper account: its totals and positions, when they were read, or `failed` when
Alpaca could not be asked."""
obj Reading {
    has at: str,
        read_at: float;
    has account: Account | None = None,
        held: dict[str, BrokerPosition] = {},
        failed: bool = False;
}

glob _LOCK: threading.Lock = threading.Lock();
glob _READINGS: dict[str, Reading] = {};

"""`view` with its totals and open positions valued as of `reading`. The cached view is left as it
was: the copy and its positions are new objects."""
def with_live(view: PortfolioView, reading: Reading) -> PortfolioView {
    account = reading.account;
    if account is None or account.equity <= 0.0 {
        return view;
    }
    found = copy.copy(view);
    found.live_at = reading.at;
    found.equity = account.equity;
    found.cash = account.cash;
    found.positions_value = sum(p.market_value for p in reading.held.values());
    if account.last_equity > 0.0 {
        found.day_pnl = account.equity - account.last_equity;
        found.day_return = account.equity / account.last_equity - 1.0;
    }
    if view.starting_cash > 0.0 {
        found.total_pnl = account.equity - view.starting_cash;
        found.total_return = account.equity / view.starting_cash - 1.0;
    }
    if view.peak_equity {
        # Measured from the highest close, as each daily mark measures it.
        found.drawdown = max(0.0, 1.0 - account.equity / view.peak_equity);
    }
    found.gross_exposure = found.positions_value / account.equity;
    found.positions = sorted(
        [live_position(p, reading.held.get(p.ticker), account.equity, reading.at) for p in view.positions],
        key=lambda (v: PositionView) { -(v.market_value or 0.0); }
    );
    return found;
}

"""`p` priced at `held`'s current price, or `p` itself when Alpaca does not hold it."""
def live_position(p: PositionView, held: BrokerPosition | None, equity: float, at: str) -> PositionView {
    if held is None or held.current_price <= 0.0 {
        return p;
    }
    found = copy.copy(p);
    price = held.current_price;
    found.last_price = price;
    found.priced_at = at;
    found.market_value = price * p.qty;
    found.pnl = (price - p.avg_entry_price) * p.qty;
    found.pnl_pct = price / p.avg_entry_price - 1.0 if p.avg_entry_price > 0.0 else None;
    found.weight = found.market_value / equity if equity > 0.0 else None;
    if p.stop_price {
        found.stop_distance = 1.0 - p.stop_price / price;
    }
    return found;
}

"""Read the paper account `portfolio` trades: the server's own for the team agent, its owner's
keys for anyone else's. Raises BrokerError or SourceError when Alpaca cannot be asked."""
def read_account_now(portfolio: Portfolio) -> Reading {
    token = None;
    if portfolio.name != TEAM_PORTFOLIO {
        account = my_account();
        if account is None {
            return Reading(at="", read_at=time.monotonic(), failed=True);
        }
        token = enter_credentials(credentials_of(account));
    }
    try {
        broker = Broker(max_retries=0);
        return Reading(at=datetime.now(timezone.utc).isoformat(), read_at=time.monotonic(), account=broker.account(), held=broker.positions());
    } finally {
        if token is not None {
            leave_credentials(token);
        }
    }
}

"""The latest reading of the account behind `portfolio`, fresh within LIVE_TTL_S. A failed read is
remembered for as long, so a reader is not kept waiting on Alpaca again a moment later."""
def reading_for(key: str, portfolio: Portfolio, read: Callable[[Portfolio], Reading] = read_account_now) -> Reading {
    with _LOCK {
        held = _READINGS.get(key);
    }
    if held is not None and time.monotonic() - held.read_at < LIVE_TTL_S {
        return held;
    }
    try {
        found = read(portfolio);
    } except (BrokerError, SourceError, VaultError) {
        found = Reading(at="", read_at=time.monotonic(), failed=True);
    }
    with _LOCK {
        _READINGS[key] = found;
    }
    return found;
}

"""`view` as Alpaca values `portfolio` now, or `view` unchanged for a demo portfolio, one not yet
started, or when Alpaca cannot be asked."""
def live_view(key: str, view: PortfolioView, portfolio: Portfolio) -> PortfolioView {
    if portfolio.demo or not view.started {
        return view;
    }
    reading = reading_for(key, portfolio);
    return view if reading.failed else with_live(view, reading);
}
