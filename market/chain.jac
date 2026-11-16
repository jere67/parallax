"""A stock's option chain for its page, read when the page asks, as market/ondemand.jac reads its
history: the listed calls and puts expiring within CHAIN_DAYS with strikes within CHAIN_BAND of the
price, and, for one expiry at a time, each contract's latest quote, trade, volume, implied
volatility, and delta from the free indicative feed. Answers are held in memory for a while for
any reader, and every page shares the on-demand allowance, so a busy page retries."""
import json;
import math;
import random;
import from datetime { date, timedelta }
import from market.ondemand { ALLOWANCE, ANSWERS, on_demand_client }
import from research.alpaca { alpaca_data_client, alpaca_trading_client }
import from research.collector { run_budget }
import from research.options { CALL, ContractQuery, OptionContract, PUT, SNAPSHOTS_PER_REQUEST, option_contracts }
import from research.sources { DATASETS }

glob CHAIN_DAYS: int = 120;
glob CHAIN_BAND: float = 0.3;
glob CONTRACTS_SECONDS: float = 3600.0;
glob QUOTES_SECONDS: float = 60.0;

"""One contract's side of a strike: its symbol and what the feed says about it."""
obj ChainQuote {
    has symbol: str;
    has bid: float | None = None,
        ask: float | None = None,
        last: float | None = None,
        volume: float | None = None,
        open_interest: float | None = None,
        iv: float | None = None,
        delta: float | None = None;
}

"""One strike's call and put for an expiry."""
obj ChainRow {
    has strike: float;
    has call: ChainQuote | None = None,
        put: ChainQuote | None = None;
}

"""The listed contracts near the money: calls and puts expiring within CHAIN_DAYS of `today`, with
strikes within CHAIN_BAND of `price`. Two contract lists, held for an hour."""
def listed_contracts(symbol: str, price: float, today: date) -> list[OptionContract] {
    key = f"chain:{symbol}:{today.isoformat()}";
    found = ANSWERS.get(key, CONTRACTS_SECONDS);
    if found is not None {
        return found;
    }
    contracts: list[OptionContract] = [];
    for kind in [CALL, PUT] {
        ALLOWANCE.take();
        query = ContractQuery(
            underlying=symbol,
            kind=kind,
            expiry_from=today.isoformat(),
            expiry_to=(today + timedelta(days=CHAIN_DAYS)).isoformat(),
            strike_low=price * (1.0 - CHAIN_BAND),
            strike_high=price * (1.0 + CHAIN_BAND)
        );
        contracts.extend(option_contracts(query, run_budget(), on_demand_client(alpaca_trading_client())));
    }
    ANSWERS.put(key, contracts);
    return contracts;
}

def number_or_none(value: object) -> float | None {
    if isinstance(value, (int, float)) and math.isfinite(float(value)) {
        return float(value);
    }
    return None;
}

"""Each of `symbols`' latest quote, trade, day's volume, implied volatility, and delta, held for a
minute. A contract the feed has nothing on is left out."""
def chain_quotes(symbols: list[str]) -> dict[str, ChainQuote] {
    wanted = sorted(set(symbols));
    key = "quotes:" + ",".join(wanted);
    found = ANSWERS.get(key, QUOTES_SECONDS);
    if found is not None {
        return found;
    }
    client = on_demand_client(alpaca_data_client());
    quotes: dict[str, ChainQuote] = {};
    for i in range(0, len(wanted), SNAPSHOTS_PER_REQUEST) {
        ALLOWANCE.take();
        chunk = wanted[i:i + SNAPSHOTS_PER_REQUEST];
        fetched = client.get(DATASETS["alpaca.option_snapshots"], "/v1beta1/options/snapshots", run_budget(), params={"symbols": ",".join(chunk), "feed": "indicative"});
        snapshots = json.loads(fetched.body).get("snapshots") or {};
        for symbol in chunk {
            snap = snapshots.get(symbol);
            if not isinstance(snap, dict) {
                continue;
            }
            quote = snap.get("latestQuote") or {};
            trade = snap.get("latestTrade") or {};
            day = snap.get("dailyBar") or {};
            greeks = snap.get("greeks") or {};
            quotes[symbol] = ChainQuote(
                symbol=symbol,
                bid=number_or_none(quote.get("bp")),
                ask=number_or_none(quote.get("ap")),
                last=number_or_none(trade.get("p")),
                volume=number_or_none(day.get("v")),
                iv=number_or_none(snap.get("impliedVolatility")),
                delta=number_or_none(greeks.get("delta"))
            );
        }
    }
    ANSWERS.put(key, quotes);
    return quotes;
}

"""The expiries the contracts list, soonest first."""
def expiries_of(contracts: list[OptionContract]) -> list[str] {
    return sorted(set(c.expiry for c in contracts if c.expiry));
}

"""The rows of one expiry, by strike, with each side's quote where the feed has one and the
contract's open interest from the list."""
def chain_rows(contracts: list[OptionContract], expiry: str, quotes: dict[str, ChainQuote]) -> list[ChainRow] {
    rows: dict[float, ChainRow] = {};
    for c in contracts {
        if c.expiry != expiry {
            continue;
        }
        row = rows.get(c.strike) or ChainRow(strike=c.strike);
        side = quotes.get(c.symbol) or ChainQuote(symbol=c.symbol);
        side.open_interest = c.open_interest if c.open_interest > 0.0 else side.open_interest;
        if c.kind == CALL {
            row.call = side;
        } else {
            row.put = side;
        }
        rows[c.strike] = row;
    }
    return [rows[k] for k in sorted(rows)];
}

"""An OCC symbol for an invented contract."""
def occ_symbol(underlying: str, expiry: str, kind: str, strike: float) -> str {
    day = date.fromisoformat(expiry);
    return f"{underlying}{day.strftime('%y%m%d')}{'C' if kind == CALL else 'P'}{int(round(strike * 1000)):08d}";
}

"""The standard normal distribution function."""
def normal_cdf(x: float) -> float {
    return 0.5 * (1.0 + math.erf(x / math.sqrt(2.0)));
}

"""An invented chain for a demo server: monthly expiries on the third Friday, strikes around the
price, and prices from Black-Scholes at a volatility that smiles, seeded by the symbol and day."""
def demo_chain(symbol: str, price: float, today: date) -> tuple[list[OptionContract], dict[str, ChainQuote]] {
    rng = random.Random(f"chain:{symbol}:{today.isoformat()}");
    base_vol = rng.uniform(0.2, 0.5);
    step = 1.0 if price < 50.0 else (5.0 if price < 300.0 else 10.0);
    first = round(price * (1.0 - CHAIN_BAND) / step) * step;
    strikes = [first + step * i for i in range(int(price * 2 * CHAIN_BAND / step) + 1) if first + step * i > 0.0];
    expiries: list[str] = [];
    month = date(today.year, today.month, 1);
    while len(expiries) < 4 {
        friday = month + timedelta(days=(4 - month.weekday()) % 7 + 14);
        if friday > today {
            expiries.append(friday.isoformat());
        }
        month = date(month.year + (1 if month.month == 12 else 0), 1 if month.month == 12 else month.month + 1, 1);
    }
    contracts: list[OptionContract] = [];
    quotes: dict[str, ChainQuote] = {};
    for expiry in expiries {
        years = max(1.0, (date.fromisoformat(expiry) - today).days) / 365.0;
        for strike in strikes {
            vol = base_vol * (1.0 + 0.8 * (math.log(strike / price)) ** 2);
            d1 = (math.log(price / strike) + 0.5 * vol * vol * years) / (vol * math.sqrt(years));
            d2 = d1 - vol * math.sqrt(years);
            for kind in [CALL, PUT] {
                value = price * normal_cdf(d1) - strike * normal_cdf(d2) if kind == CALL else strike * normal_cdf(0.0 - d2) - price * normal_cdf(0.0 - d1);
                value = max(0.01, value);
                spread = max(0.01, value * 0.04);
                symbol_ = occ_symbol(symbol, expiry, kind, strike);
                interest = float(int(rng.uniform(0.0, 4000.0) * math.exp(0.0 - abs(math.log(strike / price)) * 6.0)));
                contracts.append(OptionContract(symbol=symbol_, underlying=symbol, kind=kind, strike=strike, expiry=expiry, tradable=True, open_interest=interest));
                quotes[symbol_] = ChainQuote(
                    symbol=symbol_,
                    bid=round(max(0.0, value - spread / 2.0), 2),
                    ask=round(value + spread / 2.0, 2),
                    last=round(value * rng.uniform(0.97, 1.03), 2),
                    volume=float(int(interest * rng.uniform(0.0, 0.3))),
                    iv=vol,
                    delta=normal_cdf(d1) if kind == CALL else normal_cdf(d1) - 1.0
                );
            }
        }
    }
    return (contracts, quotes);
}
