"""One company's public record from EDGAR: who it is, its recent filings, and its reported figures
over time. SEC data is public, so unlike the licensed sources the pages may show it as it is.

`company_record` keeps what the market pages read, a few kilobytes out of the megabytes EDGAR
serves for a large filer. Only U.S. GAAP figures in dollars are read; a foreign filer reporting
under IFRS or in another currency has a profile and filings but no figures.
"""
import json;
import from datetime { date, timedelta }
import from research.collector { RunBudget, SourceClient }
import from research.sec {
    FLOW_CONCEPTS,
    INSTANT_CONCEPTS,
    Fact,
    QUARTER_DAYS,
    YEAR_DAYS,
    _days,
    _latest_quarter,
    _series,
    _trailing_year,
    padded_cik,
    sec_data_client
}
import from research.sources { DATASETS }

glob ARCHIVES: str = "https://www.sec.gov";
glob ANNUAL_PERIODS: int = 6;
glob QUARTER_PERIODS: int = 8;
glob FILINGS_KEPT: int = 25;
# A company with nothing newer than this is no longer reporting under these tags.
glob STALE_DAYS: int = 500;
# Nine months, to derive the fourth quarter that a 10-K never reports on its own.
glob NINE_MONTH_DAYS: tuple[int, int] = (250, 290);
glob SHOWN_FORMS: set[str] = {"10-K", "10-K/A", "10-Q", "10-Q/A", "8-K", "8-K/A", "20-F", "20-F/A", "40-F", "6-K", "DEF 14A", "S-1", "S-3", "424B4"};
# Forms that bring new XBRL figures, so company facts are worth asking for again.
glob REPORT_FORMS: set[str] = {"10-K", "10-K/A", "10-Q", "10-Q/A", "20-F", "20-F/A", "40-F", "40-F/A"};
glob EXTRA_FLOWS: dict[str, list[str]] = {
    "interest_expense": ["InterestExpense", "InterestExpenseNonoperating"],
    "research": ["ResearchAndDevelopmentExpense"]
};
glob EXTRA_INSTANTS: dict[str, list[str]] = {
    "current_assets": ["AssetsCurrent"],
    "current_liabilities": ["LiabilitiesCurrent"],
    "debt": ["LongTermDebt", "DebtInstrumentCarryingAmount", "LongTermDebtNoncurrent"]
};
glob EPS_CONCEPTS: list[str] = ["EarningsPerShareDiluted", "EarningsPerShareBasicAndDiluted", "EarningsPerShareBasic"];
glob DIVIDEND_CONCEPTS: list[str] = ["CommonStockDividendsPerShareDeclared", "CommonStockDividendsPerShareCashPaid"];
glob SHARE_CONCEPTS: list[str] = ["CommonStockSharesOutstanding", "WeightedAverageNumberOfDilutedSharesOutstanding"];

"""A reported period's figures for the financials charts. `label` is FY2025 or Q3 2026."""
obj Period {
    has end: str,
        label: str,
        values: dict[str, float];
}

"""A filing, linked to its page on EDGAR."""
obj FilingLink {
    has form: str,
        filed: str,
        report_date: str,
        url: str;
}

"""Who a company is, from its SEC submissions."""
obj CompanyProfile {
    has name: str = "",
        sic: int = 0,
        sic_description: str = "",
        city: str = "",
        region: str = "",
        incorporated: str = "",
        fiscal_year_end: str = "",
        ein: str = "",
        filer_category: str = "";
}

"""What the market pages keep for one company. `values` are the latest figures, and `report_filed`
is the newest report seen, so the sweep can ask for company facts only when it changes."""
obj CompanyRecord {
    has cik: str,
        checked: str,
        report_filed: str = "",
        facts_filed: str = "",
        period_end: str = "",
        profile: CompanyProfile = CompanyProfile(),
        values: dict[str, float] = {},
        annual: list[Period] = [],
        quarterly: list[Period] = [],
        filings: list[FilingLink] = [];
}

def submissions(cik: str, budget: RunBudget, client: SourceClient | None = None) -> dict[str, any] {
    return json.loads((client or sec_data_client()).get(DATASETS["sec.market_submissions"], f"/submissions/CIK{padded_cik(cik)}.json", budget, check=_check_keys("filings", "name")).body);
}

"""The company's XBRL facts, or None when it files none. SEC answers some such filers, closed-end
funds among them, with an empty object instead of a 404."""
def company_facts(cik: str, budget: RunBudget, client: SourceClient | None = None) -> dict[str, any] | None {
    body = (client or sec_data_client()).get(DATASETS["sec.market_companyfacts"], f"/api/xbrl/companyfacts/CIK{padded_cik(cik)}.json", budget, check=_check_facts).body;
    parsed = json.loads(body);
    return parsed if parsed else None;
}

"""A company's profile from its submissions."""
def profile_of(found: dict[str, any]) -> CompanyProfile {
    address = (found.get("addresses") or {}).get("business") or {};
    region = address.get("stateOrCountryDescription") or address.get("stateOrCountry") or "";
    try {
        sic = int(found.get("sic") or 0);
    } except ValueError {
        sic = 0;
    }
    return CompanyProfile(
        name=str(found.get("name") or ""),
        sic=sic,
        sic_description=str(found.get("sicDescription") or ""),
        city=str(address.get("city") or "").title(),
        region=str(region),
        incorporated=str(found.get("stateOfIncorporationDescription") or found.get("stateOfIncorporation") or ""),
        fiscal_year_end=str(found.get("fiscalYearEnd") or ""),
        ein=str(found.get("ein") or ""),
        filer_category=str(found.get("category") or "")
    );
}

"""The recent filings a reader would look for, newest first, and the newest report's date."""
def filings_of(cik: str, found: dict[str, any]) -> tuple[list[FilingLink], str] {
    recent: dict[str, list[str]] = (found.get("filings") or {}).get("recent") or {};
    forms = recent.get("form") or [];
    kept: list[FilingLink] = [];
    report_filed = "";
    for i in range(len(forms)) {
        form = forms[i];
        filed = recent["filingDate"][i];
        if form in REPORT_FORMS and filed > report_filed {
            report_filed = filed;
        }
        if form in SHOWN_FORMS and len(kept) < FILINGS_KEPT {
            accession = recent["accessionNumber"][i];
            document = recent["primaryDocument"][i] or "";
            folder = f"{ARCHIVES}/Archives/edgar/data/{int(cik)}/{accession.replace('-', '')}";
            kept.append(FilingLink(
                form=form,
                filed=filed,
                report_date=recent["reportDate"][i] or "",
                url=f"{folder}/{document}" if document else f"{folder}/{accession}-index.html"
            ));
        }
    }
    return (kept, report_filed);
}

"""The latest figures and the period tables from company facts. Nothing when the newest period
is older than STALE_DAYS as of `today`, since those figures no longer describe the company."""
def figures_of(facts: dict[str, dict], today: str) -> tuple[dict[str, float], list[Period], list[Period], str, str] {
    gaap: dict[str, dict] = facts.get("us-gaap") or {};
    values: dict[str, float] = {};
    annual: dict[str, dict[str, float]] = {};
    quarterly: dict[str, dict[str, float]] = {};
    latest: list[Fact] = [];

    flows: dict[str, list[str]] = {**FLOW_CONCEPTS, **EXTRA_FLOWS};
    for (name, concepts) in flows.items() {
        series = _series(gaap, concepts, "USD", instant=False, widest=name == "revenue");
        if not series {
            continue;
        }
        trailing = _trailing_year(series);
        if trailing {
            values[f"{name}_ttm"] = trailing[0];
            latest.append(trailing[1]);
        }
        (quarter, prior) = _latest_quarter(series);
        if quarter and prior and prior.value {
            # Against the prior value's size, so a smaller loss is growth.
            values[f"{name}_growth"] = (quarter.value - prior.value) / abs(prior.value);
        }
        for fact in series {
            days = fact.days();
            if YEAR_DAYS[0] <= days <= YEAR_DAYS[1] {
                annual.setdefault(fact.end, {})[name] = fact.value;
            } elif QUARTER_DAYS[0] <= days <= QUARTER_DAYS[1] {
                quarterly.setdefault(fact.end, {})[name] = fact.value;
            }
        }
        _fourth_quarters(name, series, quarterly);
    }
    instants: dict[str, list[str]] = {**INSTANT_CONCEPTS, **EXTRA_INSTANTS};
    for (name, concepts) in instants.items() {
        series = _series(gaap, concepts, "USD", instant=True);
        if not series {
            continue;
        }
        newest_fact = max(series, key=lambda (f: Fact) { (f.end, f.filed); });
        values[name] = newest_fact.value;
        latest.append(newest_fact);
        for fact in series {
            if fact.end in annual {
                annual[fact.end][name] = fact.value;
            }
            if fact.end in quarterly {
                quarterly[fact.end][name] = fact.value;
            }
        }
    }
    _per_share(gaap, values);
    _shares(facts, gaap, values, today);
    newest = max([f.end for f in latest] + [""]);
    filed = max([f.filed for f in latest] + [""]);
    if not newest or _days(newest, today) > STALE_DAYS {
        return ({}, [], [], "", filed);
    }
    if "operating_cash_flow_ttm" in values and "capital_expenditure_ttm" in values {
        values["free_cash_flow_ttm"] = values["operating_cash_flow_ttm"] - values["capital_expenditure_ttm"];
    }
    for (end, row) in annual.items() {
        if "operating_cash_flow" in row and "capital_expenditure" in row {
            row["free_cash_flow"] = row["operating_cash_flow"] - row["capital_expenditure"];
        }
    }
    years = sorted(annual)[-ANNUAL_PERIODS:];
    quarters = sorted(quarterly)[-QUARTER_PERIODS:];
    newest_year = years[-1] if years else "";
    if newest_year {
        for name in ("revenue", "net_income") {
            if name in annual[newest_year] {
                values[f"{name}_fy"] = annual[newest_year][name];
            }
        }
    }
    return (
        values,
        [Period(end=e, label=f"FY{_fiscal_year(e)}", values=annual[e]) for e in years],
        [Period(end=e, label=_quarter_label(e), values=quarterly[e]) for e in quarters],
        newest,
        filed
    );
}

"""The per-share figures: EPS and dividends over the trailing year, and EPS growth."""
def _per_share(gaap: dict[str, dict], values: dict[str, float]) {
    for concept in EPS_CONCEPTS {
        series = _series(gaap, [concept], "USD/shares", instant=False);
        if not series {
            continue;
        }
        trailing = _trailing_year(series);
        if trailing {
            values["eps_ttm"] = trailing[0];
        }
        (quarter, prior) = _latest_quarter(series);
        if quarter and prior and prior.value {
            values["eps_growth"] = (quarter.value - prior.value) / abs(prior.value);
        }
        break;
    }
    dividends = _series(gaap, DIVIDEND_CONCEPTS, "USD/shares", instant=False);
    if dividends {
        trailing = _trailing_year(dividends);
        if trailing {
            values["dividends_ps_ttm"] = trailing[0];
        }
    }
}

"""Shares outstanding from the newest source within a year and a half: the cover page, the balance
sheet, then the diluted average. Share classes reported apart, and ADRs, need the Finnhub market
cap, which replaces this figure for a stock once the analyst sweep has reached it."""
def _shares(facts: dict[str, dict], gaap: dict[str, dict], values: dict[str, float], today: str) {
    cutoff = (date.fromisoformat(today) - timedelta(days=550)).isoformat();
    cover = _series(facts.get("dei") or {}, ["EntityCommonStockSharesOutstanding"], "shares", instant=True);
    candidates: list[Fact] = list(cover);
    candidates.extend(_series(gaap, ["CommonStockSharesOutstanding"], "shares", instant=True));
    if not candidates {
        candidates.extend(_series(gaap, ["WeightedAverageNumberOfDilutedSharesOutstanding"], "shares", instant=False));
    }
    fresh = [f for f in candidates if f.end >= cutoff and f.value > 0];
    if fresh {
        values["shares"] = max(fresh, key=lambda (f: Fact) { (f.end, f.filed); }).value;
    }
}

"""Fill in the fourth quarter, which only exists as the fiscal year less its first nine months."""
def _fourth_quarters(name: str, series: list[Fact], quarterly: dict[str, dict[str, float]]) {
    for year in series {
        if not YEAR_DAYS[0] <= year.days() <= YEAR_DAYS[1] or name in quarterly.get(year.end, {}) {
            continue;
        }
        for part in series {
            if part.start == year.start and NINE_MONTH_DAYS[0] <= part.days() <= NINE_MONTH_DAYS[1] {
                quarterly.setdefault(year.end, {})[name] = year.value - part.value;
                break;
            }
        }
    }
}

"""The fiscal year a period ending on `end` belongs to: January's year-end closes the year before,
the way retailers and NVIDIA name theirs."""
def _fiscal_year(end: str) -> int {
    year = int(end[:4]);
    return year - 1 if int(end[5:7]) == 1 else year;
}

"""Q3 2026 for the calendar quarter a period ended in."""
def _quarter_label(end: str) -> str {
    return f"Q{(int(end[5:7]) - 1) // 3 + 1} {end[:4]}";
}

"""A fresh record from the submissions and, when given, the company facts; without facts it keeps
the figures of `earlier`, the record it replaces."""
def company_record(cik: str, found: dict[str, any], facts: dict[str, any] | None, today: str, earlier: CompanyRecord | None = None) -> CompanyRecord {
    (filings, report_filed) = filings_of(cik, found);
    record = CompanyRecord(cik=cik, checked=today, report_filed=report_filed, profile=profile_of(found), filings=filings);
    if facts is not None {
        (values, annual, quarterly, end, filed) = figures_of(facts.get("facts") or {}, today);
        record.values = values;
        record.annual = annual;
        record.quarterly = quarterly;
        record.period_end = end;
        record.facts_filed = report_filed or filed;
    } elif earlier is not None {
        record.values = earlier.values;
        record.annual = earlier.annual;
        record.quarterly = earlier.quarterly;
        record.period_end = earlier.period_end;
        record.facts_filed = earlier.facts_filed;
    }
    return record;
}

"""Whether the sweep should ask for company facts: never fetched, or a newer report than the
one they came from."""
def wants_facts(found: dict[str, any], earlier: CompanyRecord | None) -> bool {
    if earlier is None or not earlier.facts_filed {
        return True;
    }
    (_, report_filed) = filings_of(earlier.cik, found);
    return report_filed > earlier.facts_filed;
}

def _check_facts(body: str) -> str {
    try {
        empty = json.loads(body) == {};
    } except ValueError {
        empty = False;
    }
    return "" if empty else _check_keys("facts")(body);
}

def _check_keys(*keys: str) -> Callable[[str], str] {
    def check(body: str) -> str {
        try {
            parsed = json.loads(body);
        } except ValueError {
            return f"not JSON: {body[:200]}";
        }
        return "" if isinstance(parsed, dict) and all(k in parsed for k in keys) else f"no {keys} in {body[:200]}";
    }
    return check;
}
