"""Alpaca option contracts and quotes, for the agent's long calls and puts (action/options.jac).

- Contracts come from the trading API's contract list: one stock's calls or puts within an
  expiry window and a strike band.
- Quotes come from the free indicative feed's snapshots: the latest bid and ask per contract.
- An option is named by its OCC symbol, such as "AAPL261218C00200000": the underlying, the expiry
  (YYMMDD), C or P, and the strike in thousandths of a dollar. `parse_occ` reads one back, so a
  position Alpaca reports carries everything the record needs.

One contract covers 100 shares, so a contract's cost is its premium times 100. Keys go in
headers, which the cache and recorded fixtures never keep.
"""
import json;
import math;
import re;
import from datetime { date, timedelta }
import from urllib.parse { urlencode }
import from models.research { Stamped }
import from research.alpaca { alpaca_data_client, alpaca_trading_client }
import from research.collector { RunBudget, SourceClient }
import from research.sources { DATASETS, SOURCES }

glob OPTION_CLASS: str = "us_option";
glob CONTRACT_SIZE: float = 100.0;
glob CALL: str = "call";
glob PUT: str = "put";
glob OCC_PATTERN: re.Pattern[str] = re.compile(r"^([A-Z][A-Z0-9.]{0,5})(\d{6})([CP])(\d{8})$");
glob CONTRACTS_PER_PAGE: int = 1000;
glob SNAPSHOTS_PER_REQUEST: int = 100;

"""What an OCC option symbol says."""
obj OccParts {
    has underlying: str,
        expiry: str,
        kind: str,
        strike: float;
}

"""The parts of an OCC option symbol, or None when `symbol` is not one."""
def parse_occ(symbol: str) -> OccParts | None {
    found = OCC_PATTERN.match(symbol.strip().upper());
    if found is None {
        return None;
    }
    raw = found.group(2);
    try {
        expiry = date(2000 + int(raw[0:2]), int(raw[2:4]), int(raw[4:6])).isoformat();
    } except ValueError {
        return None;
    }
    return OccParts(underlying=found.group(1), expiry=expiry, kind=CALL if found.group(3) == "C" else PUT, strike=int(found.group(4)) / 1000.0);
}

"""True for an OCC option symbol."""
def is_option(symbol: str) -> bool {
    return parse_occ(symbol) is not None;
}

"""How a reader sees a contract: "AAPL $200 call, Dec 18, 2026"."""
def describe_option(symbol: str) -> str {
    found = parse_occ(symbol);
    if found is None {
        return symbol;
    }
    day = date.fromisoformat(found.expiry);
    strike = f"{found.strike:,.2f}".rstrip("0").rstrip(".");
    return f"{found.underlying} ${strike} {found.kind}, {day.strftime('%b')} {day.day}, {day.year}";
}

"""One listed contract."""
obj OptionContract {
    has symbol: str,
        underlying: str,
        kind: str,
        strike: float,
        expiry: str,
        tradable: bool;
    has open_interest: float = 0.0,
        close_price: float = 0.0;
}

"""Which contracts to list: `underlying`'s `kind` ("call" or "put") expiring from `expiry_from`
through `expiry_to` (ISO dates) with strikes from `strike_low` through `strike_high`."""
obj ContractQuery {
    has underlying: str,
        kind: str,
        expiry_from: str,
        expiry_to: str,
        strike_low: float,
        strike_high: float;
}

"""The listed contracts `query` asks for."""
def option_contracts(query: ContractQuery, budget: RunBudget, client: SourceClient | None = None) -> list[OptionContract] {
    (underlying, kind) = (query.underlying, query.kind);
    trading = client or alpaca_trading_client();
    params: dict[str, str | int | float] = {
        "underlying_symbols": underlying,
        "type": kind,
        "status": "active",
        "expiration_date_gte": query.expiry_from,
        "expiration_date_lte": query.expiry_to,
        "strike_price_gte": f"{max(0.0, query.strike_low):.2f}",
        "strike_price_lte": f"{max(0.0, query.strike_high):.2f}",
        "limit": CONTRACTS_PER_PAGE
    };
    found: list[OptionContract] = [];
    token = "";
    while True {
        asked = dict(params);
        if token {
            asked["page_token"] = token;
        }
        fetched = trading.get(DATASETS["alpaca.option_contracts"], "/v2/options/contracts", budget, params=asked, symbol=underlying, check=_check_keyed("option_contracts"));
        page = json.loads(fetched.body);
        for row in page.get("option_contracts") or [] {
            symbol = str(row.get("symbol") or "");
            strike = _number(row.get("strike_price"));
            if not symbol or strike <= 0.0 {
                continue;
            }
            found.append(OptionContract(
                symbol=symbol,
                underlying=str(row.get("underlying_symbol") or underlying),
                kind=str(row.get("type") or kind),
                strike=strike,
                expiry=str(row.get("expiration_date") or ""),
                tradable=bool(row.get("tradable")),
                open_interest=_number(row.get("open_interest")),
                close_price=_number(row.get("close_price"))
            ));
        }
        token = page.get("next_page_token") or "";
        if not token {
            break;
        }
    }
    return found;
}

"""A contract's latest bid and ask, and when they were quoted."""
obj OptionQuote(Stamped) {
    has symbol: str,
        bid: float,
        ask: float,
        at: str;

    def mid -> float {
        return (self.bid + self.ask) / 2.0 if self.bid > 0.0 and self.ask > 0.0 else 0.0;
    }

    """The spread as a share of the mid, or infinity when either side is missing."""
    def spread -> float {
        found = self.mid();
        return (self.ask - self.bid) / found if found > 0.0 else math.inf;
    }
}

"""The latest quote for each contract, and a gap for each contract without one."""
def option_quotes(symbols: list[str], budget: RunBudget, client: SourceClient | None = None) -> tuple[dict[str, OptionQuote], list[str]] {
    wanted = sorted(set(symbols));
    if not wanted {
        return ({}, []);
    }
    data = client or alpaca_data_client();
    quotes: dict[str, OptionQuote] = {};
    gaps: list[str] = [];
    for i in range(0, len(wanted), SNAPSHOTS_PER_REQUEST) {
        chunk = wanted[i:i + SNAPSHOTS_PER_REQUEST];
        fetched = data.get(
            DATASETS["alpaca.option_snapshots"],
            "/v1beta1/options/snapshots",
            budget,
            params={"symbols": ",".join(chunk), "feed": "indicative"},
            check=_check_keyed("snapshots")
        );
        found: dict[str, dict[str, dict[str, str | float]]] = json.loads(fetched.body).get("snapshots") or {};
        for symbol in chunk {
            quote = (found.get(symbol) or {}).get("latestQuote") or {};
            (bid, ask, at) = (_number(quote.get("bp")), _number(quote.get("ap")), str(quote.get("t") or ""));
            if not at or ask <= 0.0 {
                gaps.append(f"alpaca.option_snapshots: no quote for {symbol}");
                continue;
            }
            cite = SOURCES["alpaca_data"].base_url + "/v1beta1/options/snapshots?" + urlencode({"symbols": symbol, "feed": "indicative"});
            quotes[symbol] = OptionQuote(symbol=symbol, bid=bid, ask=ask, at=at, stamp=fetched.stamp(at, source_url=cite));
        }
    }
    return (quotes, gaps);
}

"""The contract to open on a view of `kind` on a stock at `price`, on `today`: among the tradable
`contracts` expiring `min_days` to `max_days` out, the expiry nearest `target_days`, then the strike
nearest the money on the far side of it (the lowest strike at or above the price for a call, the
highest at or below it for a put), so the view pays only for the move it expects. None when no
contract fits."""
def choose_contract(contracts: list[OptionContract], price: float, kind: str, today: str, min_days: int, max_days: int, target_days: int) -> OptionContract | None {
    start = date.fromisoformat(today);
    fitting: list[OptionContract] = [];
    for c in contracts {
        if not c.tradable or c.kind != kind or not c.expiry {
            continue;
        }
        days = (date.fromisoformat(c.expiry) - start).days;
        if min_days <= days <= max_days {
            fitting.append(c);
        }
    }
    if not fitting or price <= 0.0 {
        return None;
    }
    expiries = sorted({c.expiry for c in fitting}, key=lambda (e: str) { (abs((date.fromisoformat(e) - start).days - target_days), e); });
    for expiry in expiries {
        same = [c for c in fitting if c.expiry == expiry];
        if kind == CALL {
            above = sorted([c for c in same if c.strike >= price], key=lambda (c: OptionContract) { c.strike; });
            if above {
                return above[0];
            }
        } else {
            below = sorted([c for c in same if c.strike <= price], key=lambda (c: OptionContract) { -c.strike; });
            if below {
                return below[0];
            }
        }
    }
    return None;
}

"""The expiry window to look up for a view opened on `today`."""
def expiry_window(today: str, min_days: int, max_days: int) -> tuple[str, str] {
    start = date.fromisoformat(today);
    return ((start + timedelta(days=min_days)).isoformat(), (start + timedelta(days=max_days)).isoformat());
}

def _number(value: object) -> float {
    try {
        found = float(str(value)) if value is not None and str(value) != "" else 0.0;
    } except ValueError {
        return 0.0;
    }
    return found if math.isfinite(found) else 0.0;
}

def _check_keyed(key: str) -> Callable[[str], str] {
    def check(body: str) -> str {
        try {
            parsed = json.loads(body);
        } except ValueError {
            return f"not JSON: {body[:200]}";
        }
        return "" if isinstance(parsed, dict) and key in parsed else f"no {key!r} in {body[:200]}";
    }
    return check;
}
