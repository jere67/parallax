"""The stocks the market pages cover: every company SEC lists on a U.S. exchange that Alpaca
can trade, from one request to each.

SEC's ticker file holds operating companies but no funds, and Alpaca's asset list says what is
tradable and how each line is named. Their overlap still holds warrants, units, rights, preferred
shares, and baby bonds, which share a company's filings but are not its stock, so those are dropped
by name. S&P 500 membership and GICS classes come from the Wikipedia table the research pipeline
already reads.
"""
import json;
import re;
import from research.alpaca { Asset }
import from research.collector { RunBudget, SourceClient }
import from research.sec { padded_cik, sec_archives_client }
import from research.sources { DATASETS }
import from research.wikipedia { Constituent, alpaca_symbol }

glob EXCHANGES: set[str] = {"NASDAQ", "NYSE", "AMEX", "ARCA", "BATS"};
glob SEC_EXCHANGES: set[str] = {"Nasdaq", "NYSE", "CBOE"};
glob EXCHANGE_NAMES: dict[str, str] = {"NASDAQ": "Nasdaq", "NYSE": "NYSE", "AMEX": "NYSE American", "ARCA": "NYSE Arca", "BATS": "Cboe BZX"};
glob NOT_STOCK: re.Pattern[str] = re.compile(
    r"\b(warrants?|units?|rights?|preferred|preference|notes?|debentures?|etfs?|etns?|fund|bonds?|subordinated)\b|%|\bwts?\b"
    r"|\binterest in\b|\bop,? l\.?p\b"
    r"|\b(proshares|ishares|spdr|currencyshares|graniteshares|etracs|microsectors)\b"
    r"|\b(physical|bitcoin|ethereum|solana)\b.*\btrust\b",
    re.IGNORECASE
);
# Nasdaq's fifth letter says a line is a preferred, warrant, right, unit, or other non-common share.
glob NASDAQ_NOT_STOCK: str = "PWRUZ";
# SEC's code for commodity pools, which also holds a few operating companies by their corporate names.
glob COMMODITY_POOLS: int = 6221;
glob CORPORATE: re.Pattern[str] = re.compile(r"\b(inc|corp|corporation|ltd|limited|plc)\b", re.IGNORECASE);
glob TRUST: re.Pattern[str] = re.compile(r"\btrust\b", re.IGNORECASE);
glob DEPOSITARY: re.Pattern[str] = re.compile(r"\bdepositary\b|\badrs?\b|\bads\b", re.IGNORECASE);
# What Alpaca adds after a company's name to say which line this is.
glob LINE_SUFFIX: re.Pattern[str] = re.compile(
    r"\s*[-,]?\s*\b(american depositary (shares?|receipts?)|depositary (shares?|receipts?)|ordinary shares?|common (stock|shares?)|voting cs|class [a-z]\b.*|series [a-z]\b.*|cl [a-z]\b.*|shares? of beneficial interest)\b.*$",
    re.IGNORECASE
);

"""One stock the pages cover. `industry` is its GICS sub-industry when it is in the S&P 500; the
company sweep fills it and the sector from SEC's industry code otherwise."""
obj Listing {
    has symbol: str,
        name: str,
        cik: str,
        exchange: str,
        kind: str,
        sp500: bool = False,
        sector: str = "",
        industry: str = "";
}

"""One line of SEC's ticker file."""
obj ListedTicker {
    has symbol: str,
        cik: str,
        name: str,
        exchange: str;
}

"""Every exchange-listed ticker in SEC's file, by the symbol Alpaca writes."""
def listed_tickers(budget: RunBudget, client: SourceClient | None = None) -> dict[str, ListedTicker] {
    fetched = (client or sec_archives_client()).get(
        DATASETS["market.tickers"],
        "/files/company_tickers_exchange.json",
        budget,
        check=_check_tickers
    );
    parsed = json.loads(fetched.body);
    fields: list[str] = parsed["fields"];
    found: dict[str, ListedTicker] = {};
    for row in parsed["data"] {
        line = dict(zip(fields, row));
        symbol = alpaca_symbol(str(line["ticker"]));
        if symbol and line.get("exchange") in SEC_EXCHANGES {
            found[symbol] = ListedTicker(symbol=symbol, cik=padded_cik(line["cik"]), name=str(line["name"]), exchange=str(line["exchange"]));
        }
    }
    return found;
}

"""Whether an Alpaca asset's name is a company's stock, not its warrant, note, or fund."""
def is_stock(name: str) -> bool {
    return NOT_STOCK.search(name) is None;
}

"""Whether a Nasdaq symbol's fifth letter marks a line other than common stock."""
def is_special_line(symbol: str, exchange: str) -> bool {
    return exchange == "NASDAQ" and len(symbol) == 5 and symbol[-1] in NASDAQ_NOT_STOCK;
}

"""Whether a filer is a fund, by SEC's industry code once the sweep has read it: `sic` is None until
then. Closed-end funds have no code at all, nor do business development companies, which are stocks
and which their names tell apart."""
def is_fund(name: str, sic: int | None) -> bool {
    if sic == COMMODITY_POOLS {
        return CORPORATE.search(name) is None;
    }
    return sic == 0 and TRUST.search(name) is not None;
}

"""A line's name as a reader writes the company: without "Common Stock", in title case when
Alpaca has it in capitals."""
def company_name(name: str) -> str {
    plain = LINE_SUFFIX.sub("", name).strip().rstrip(",-").strip();
    plain = plain or name.strip();
    return " ".join(plain.split()).title() if plain.isupper() else " ".join(plain.split());
}

"""The covered stocks: the tradable lines of `assets` that SEC lists, with S&P 500 members classed
from `members`. Names come from Alpaca for every stock, since Wikipedia's are written to sort ("Lilly
(Eli)") and name a share class, which would make GOOG a peer of GOOGL."""
def build_listings(tickers: dict[str, ListedTicker], assets: dict[str, Asset], members: list[Constituent]) -> dict[str, Listing] {
    index = {m.symbol: m for m in members};
    found: dict[str, Listing] = {};
    for (symbol, asset) in assets.items() {
        ticker = tickers.get(symbol);
        if ticker is None or not asset.tradable or asset.exchange not in EXCHANGES or not is_stock(asset.name) or is_special_line(symbol, asset.exchange) {
            continue;
        }
        member = index.get(symbol);
        found[symbol] = Listing(
            symbol=symbol,
            name=company_name(asset.name),
            cik=ticker.cik,
            exchange=EXCHANGE_NAMES[asset.exchange],
            kind="adr" if DEPOSITARY.search(asset.name) else "common",
            sp500=member is not None,
            sector=member.sector if member else "",
            industry=member.sub_industry if member else ""
        );
    }
    return found;
}

def _check_tickers(body: str) -> str {
    try {
        parsed = json.loads(body);
    } except ValueError {
        return f"not JSON: {body[:200]}";
    }
    return "" if isinstance(parsed, dict) and "fields" in parsed and "data" in parsed else f"no ticker table in {body[:200]}";
}
