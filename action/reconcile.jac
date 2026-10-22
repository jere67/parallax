"""Reconciliation and the daily mark (TDD §8, reconciliation; TDD §13, risk-gate bypasses).

After each close, the record is brought in line with Alpaca, which holds the truth about
shares and cash:

- every working order is refreshed and its fills recorded;
- a position on record that Alpaca no longer holds is closed, one Alpaca holds that the
  record lacks is adopted with a protective stop, and a share count that differs is
  corrected, each listed as drift; every held position records Alpaca's current price;
- every order Alpaca saw since the last mark is traced to an Order the executor sent, and
  every Order the executor sent to a risk-gate approval or a position's stop; anything
  else is a gate bypass;
- the portfolio is marked to market as one DailyMark per trading day, and the peak equity
  the drawdown breaker measures from moves up.

Drift and bypasses must stay empty; the Action exit criterion counts bypasses.
"""
import from datetime { datetime }
import from action.broker { Broker }
import from action.executor { open_positions, sync_orders }
import from models.graph {
    Coverage,
    Covers,
    DailyMark,
    Holds,
    Marked,
    Order,
    OrderPurpose,
    Placed,
    Portfolio,
    Position,
    Ran,
    RiskCheck,
    RiskOutcome,
    Run,
    Sent,
    StoppedBy
}
import from run.public { public }

# An adopted position's stop is 2 ATR below its entry when a run recorded an ATR for it, and
# this fraction below otherwise.
glob FALLBACK_STOP_FRACTION: float = 0.10;
glob STOP_ATR_MULTIPLE: float = 2.0;

def marks_of(portfolio: Portfolio) -> dict[str, DailyMark] {
    return {m.day: m for m in [portfolio ->:Marked:->[?:DailyMark]]};
}

"""The newest ATR(14) any run recorded for `ticker`, or None."""
def latest_atr(portfolio: Portfolio, ticker: str) -> float | None {
    runs = sorted([r for r in [portfolio ->:Ran:->[?:Run]]], key=lambda (r: Run) { r.run_date; }, reverse=True);
    for run in runs {
        for cov in [run ->:Covers:->[?:Coverage]] {
            if cov.ticker == ticker and cov.atr_14 {
                return cov.atr_14;
            }
        }
    }
    return None;
}

"""Orders that bypassed the risk gate: an Order sent without an approving RiskCheck (or, for
a stop, without its position), and any order Alpaca accepted since `since` that the
executor never sent."""
def audit_orders(portfolio: Portfolio, broker: Broker, since: str) -> list[str] {
    problems: list[str] = [];
    sent: dict[str, Order] = {o.client_order_id: o for o in [portfolio ->:Sent:->[?:Order]]};
    for o in sent.values() {
        if o.status == "rejected" and not o.alpaca_order_id {
            continue;
        }
        if o.purpose == OrderPurpose.STOP {
            if not [o <-:StoppedBy:<-[?:Position]] {
                problems.append(f"{o.client_order_id}: a stop with no position");
            }
            continue;
        }
        checks = [rc for rc in [o <-:Placed:<-[?:RiskCheck]]];
        if not checks or checks[0].outcome == RiskOutcome.REJECTED or checks[0].approved_qty < o.qty {
            problems.append(f"{o.client_order_id}: {o.side.value} {o.qty} {o.ticker} without a risk-gate approval for it");
        }
    }
    for seen in broker.orders("all", after=since) {
        for o in [seen] + seen.legs {
            if o.client_order_id not in sent {
                problems.append(f"{o.client_order_id or o.id}: {o.side} {o.qty} {o.symbol} placed outside the executor");
            }
        }
    }
    return problems;
}

"""Bring the record in line with Alpaca and mark the portfolio for trading day `day` (New
York date). Returns the day's DailyMark; a second call the same day updates it."""
def reconcile(portfolio: Portfolio, broker: Broker, now: datetime, day: str) -> DailyMark {
    sync_orders(portfolio, broker, now);
    held = broker.positions();
    positions = open_positions(portfolio);
    drift: list[str] = [];
    for (ticker, p) in sorted(positions.items()) {
        at = held.get(ticker);
        if at is None or at.qty <= 0 {
            drift.append(f"{ticker}: {p.qty} shares on record, none at Alpaca; closed on the record");
            p.qty = 0;
            p.closed_at = now.isoformat();
        } else {
            if at.qty != p.qty {
                drift.append(f"{ticker}: {p.qty} shares on record, {at.qty} at Alpaca; record corrected");
                p.qty = at.qty;
            }
            p.last_price = at.current_price;
            p.priced_at = now.isoformat();
        }
    }
    for (ticker, at) in sorted(held.items()) {
        if ticker in positions or at.qty <= 0 {
            continue;
        }
        atr = latest_atr(portfolio, ticker);
        stop = at.avg_entry_price - STOP_ATR_MULTIPLE * atr if atr else at.avg_entry_price * (1.0 - FALLBACK_STOP_FRACTION);
        public(portfolio +>:Holds():+> Position(ticker=ticker, sector="", qty=at.qty, avg_entry_price=at.avg_entry_price, opened_at=now.isoformat(), stop_price=round(max(0.01, stop), 2), last_price=at.current_price, priced_at=now.isoformat()));
        drift.append(f"{ticker}: {at.qty} shares at Alpaca not on record; adopted with a stop at {stop:.2f}");
    }

    marks = marks_of(portfolio);
    earlier = sorted(d for d in marks if d < day);
    since = marks[earlier[-1]].marked_at if earlier else portfolio.opened_at;
    bypasses = audit_orders(portfolio, broker, since);
    account = broker.account();
    portfolio.peak_equity = max(portfolio.peak_equity, account.equity);
    mark = marks.get(day);
    if mark is None {
        mark = public(portfolio +>:Marked():+> DailyMark(day=day, equity=0.0, cash=0.0, positions_value=0.0, peak_equity=0.0, marked_at=""));
    }
    mark.equity = account.equity;
    mark.cash = account.cash;
    mark.positions_value = sum(p.market_value for p in held.values());
    mark.peak_equity = portfolio.peak_equity;
    mark.drawdown = 1.0 - account.equity / portfolio.peak_equity if portfolio.peak_equity > 0 else 0.0;
    mark.open_positions = len([p for p in held.values() if p.qty > 0]);
    mark.drift = drift;
    mark.bypasses = bypasses;
    mark.marked_at = now.isoformat();
    return mark;
}
