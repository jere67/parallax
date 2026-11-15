"""The asset classes an agent can trade, by Alpaca's names, and which one a symbol is.

A crypto pair holds a slash ("BTC/USD") and an option is an OCC symbol ("AAPL261218C00200000");
every other symbol is a stock or fund. Each agent opts into the classes it trades
(accounts/assets.jac); stocks are the default.
"""
import re;

glob STOCKS: str = "us_equity";
glob CRYPTO: str = "crypto";
glob OPTIONS: str = "us_option";
glob ASSET_CLASSES: list[str] = [STOCKS, CRYPTO, OPTIONS];
glob ASSET_LABELS: dict[str, str] = {STOCKS: "Stocks and ETFs", CRYPTO: "Crypto", OPTIONS: "Options"};
glob DEFAULT_CLASSES: list[str] = [STOCKS];
glob _OCC: re.Pattern[str] = re.compile(r"^[A-Z][A-Z0-9.]{0,5}\d{6}[CP]\d{8}$");

"""The asset class `symbol` belongs to."""
def asset_class_of(symbol: str) -> str {
    if "/" in symbol {
        return CRYPTO;
    }
    return OPTIONS if _OCC.match(symbol) else STOCKS;
}

"""`classes` as a clean list in the canonical order, without unknown or repeated names."""
def clean_classes(classes: list[str]) -> list[str] {
    wanted = {str(c).strip() for c in classes};
    return [c for c in ASSET_CLASSES if c in wanted];
}
