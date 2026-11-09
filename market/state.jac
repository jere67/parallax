"""The market pages' data, held in memory and kept on disk under `.jac/market/`.

The graph loads one node per query, so six thousand rows there would take seconds to read and
would mix a rebuildable market cache with the team's record. Plain JSON files suit this better.
Each domain is one file, replaced atomically when it changes, so a crash leaves the last good
version; a company's detailed record is its own file, read when its page opens. `.jac/` is also the
one folder the dev server's hot reload does not watch, unlike `storage/`.
"""
import json;
import logging;
import os;
import threading;
import from pathlib { Path }
import from market.analysts { AnalystRecord, RatingPoint, Surprise }
import from market.companies { CompanyProfile, CompanyRecord, FilingLink, Period }
import from market.listings { Listing }
import from market.prices { PriceStats, Quote }

glob DATA_DIR_ENV: str = "MARKET_DATA_DIR";
glob LOG: logging.Logger = logging.getLogger("trading_agent.market");

"""A scheduled or reported earnings date for a stock."""
obj EarningsDates {
    has last_day: str = "",
        next_day: str = "",
        next_hour: str = "";
}

"""A company's figures and class for its row, without the period tables."""
obj CompanySummary {
    has cik: str,
        checked: str = "",
        facts_filed: str = "",
        report_filed: str = "",
        period_end: str = "",
        sic: int = 0,
        sic_description: str = "",
        values: dict[str, float] = {};
}

"""The data behind every market page. `version` rises with each change, which tells the row cache
to rebuild. `demo` marks a state of invented data that is never written to disk."""
obj MarketState {
    has base: Path | None = None,
        listings: dict[str, Listing] = {},
        quotes: dict[str, Quote] = {},
        stats: dict[str, PriceStats] = {},
        companies: dict[str, CompanySummary] = {},
        analysts: dict[str, AnalystRecord] = {},
        earnings: dict[str, EarningsDates] = {},
        meta: dict[str, str] = {},
        version: int = 0,
        demo: bool = False,
        details: dict[str, CompanyRecord] = {},
        loaded: bool = False;

    def directory -> Path {
        return self.base or Path(os.environ.get(DATA_DIR_ENV) or ".jac/market");
    }

    def changed {
        self.version += 1;
    }

    """Read every domain from disk, once."""
    def load {
        if self.loaded or self.demo {
            return;
        }
        self.loaded = True;
        self.listings = {k: Listing(**v) for (k, v) in self._read("listings").items()};
        self.quotes = {k: Quote(**v) for (k, v) in self._read("quotes").items()};
        self.stats = {k: PriceStats(**v) for (k, v) in self._read("stats").items()};
        self.companies = {k: CompanySummary(**v) for (k, v) in self._read("companies").items()};
        self.analysts = {k: analyst_from(v) for (k, v) in self._read("analysts").items()};
        self.earnings = {k: EarningsDates(**v) for (k, v) in self._read("earnings").items()};
        self.meta = self._read("meta");
        self.changed();
    }

    def _read(name: str) -> dict[str, any] {
        path = self.directory() / f"{name}.json";
        try {
            return json.loads(path.read_text());
        } except (OSError, ValueError) {
            return {};
        } except TypeError as e {
            LOG.warning("market: ignoring %s: %s", path, e);
            return {};
        }
    }

    """Write one domain atomically. A demo state is never written."""
    def save(name: str) {
        self.changed();
        if self.demo {
            return;
        }
        self._write(self.directory() / f"{name}.json", jsonable(getattr(self, name)));
    }

    def _write(path: Path, value: object) {
        path.parent.mkdir(parents=True, exist_ok=True);
        temporary = path.with_name(f"{path.name}.{threading.get_ident()}.tmp");
        temporary.write_text(json.dumps(value, separators=(",", ":")));
        os.replace(temporary, path);
    }

    """A company's detailed record, from memory in a demo or from its own file."""
    def company(cik: str) -> CompanyRecord | None {
        if self.demo {
            return self.details.get(cik);
        }
        path = self.directory() / "company" / f"{cik}.json";
        try {
            return company_from(json.loads(path.read_text()));
        } except (OSError, ValueError, TypeError) {
            return None;
        }
    }

    def save_company(record: CompanyRecord) {
        if self.demo {
            self.details[record.cik] = record;
        } else {
            self._write(self.directory() / "company" / f"{record.cik}.json", jsonable(record));
        }
    }
}

"""A value as plain JSON: objs become dicts, however deep."""
def jsonable(value: object) -> object {
    if isinstance(value, dict) {
        return {k: jsonable(v) for (k, v) in value.items()};
    }
    if isinstance(value, list) {
        return [jsonable(v) for v in value];
    }
    if hasattr(value, "__dict__") {
        return {k: jsonable(v) for (k, v) in vars(value).items() if not k.startswith("_")};
    }
    return value;
}

def analyst_from(row: dict[str, any]) -> AnalystRecord {
    return AnalystRecord(**{
        **row,
        "trend": [RatingPoint(**p) for p in row.get("trend") or []],
        "surprises": [Surprise(**s) for s in row.get("surprises") or []]
    });
}

def company_from(row: dict[str, any]) -> CompanyRecord {
    return CompanyRecord(**{
        **row,
        "profile": CompanyProfile(**(row.get("profile") or {})),
        "annual": [Period(**p) for p in row.get("annual") or []],
        "quarterly": [Period(**p) for p in row.get("quarterly") or []],
        "filings": [FilingLink(**f) for f in row.get("filings") or []]
    });
}

"""The summary a company's row reads, from its full record."""
def summary_of(record: CompanyRecord) -> CompanySummary {
    return CompanySummary(
        cik=record.cik,
        checked=record.checked,
        facts_filed=record.facts_filed,
        report_filed=record.report_filed,
        period_end=record.period_end,
        sic=record.profile.sic,
        sic_description=record.profile.sic_description,
        values=record.values
    );
}

glob STATE: MarketState = MarketState();
