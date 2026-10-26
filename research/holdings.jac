"""Quarterly institutional holdings from SEC's bulk 13F ZIPs (#52).

The current SEC windows end in February, May, August and November, NOT at holdings
quarter ends. SUBMISSION.PERIODOFREPORT selects the holdings quarter within a window.
SourceClient reduces the ZIP to a small JSON body before caching it under the window
end: one download and one scan for all tickers, reused across runs for that quarter.

Name joins are exact after punctuation and corporate-suffix normalization. Ambiguous
names or multiple common-stock CUSIPs are gaps, never guesses about share classes.
Values are reported holdings, not ownership percentages or real-time money flows.
"""
import csv;
import io;
import json;
import math;
import re;
import zipfile;
import from datetime { date, datetime, timedelta }
import from html.parser { HTMLParser }
import from urllib.parse { urlsplit }
import from models.research { Stamped }
import from research.collector { Fetched, RunBudget, SourceClient }
import from research.sec { sec_archives_client }
import from research.sources { DATASETS }

glob INDEX_PATH: str = "/data-research/sec-markets-data/form-13f-data-sets";
glob SCHEMA: str = "13f-v1";

obj Holdings(Stamped) {
    has symbol: str,
        issuer: str,
        cusip: str,
        quarter: str,
        filing_deadline: str,
        archive_end: str,
        shares: float,
        value_usd: float,
        managers: int;
    has prior_quarter: str = "",
        prior_source_url: str = "",
        prior_archive_end: str = "",
        shares_change: float | None = None,
        value_change_usd: float | None = None,
        managers_change: int | None = None;
}

obj HoldingsBatch {
    has values: dict[str, Holdings] = {},
        gaps: dict[str, list[str]] = {};
}

obj Archive {
    has path: str,
        end: str,
        quarter: str;
}

class _Links(HTMLParser) {
    def init(self: _Links) {
        super.init(convert_charrefs=True);
        self.paths: list[str] = [];
    }

    override def handle_starttag(self: _Links, tag: str, attrs: list[tuple[str, str | None]]) {
        if tag == "a" {
            for (key, value) in attrs {
                if key == "href" and value {
                    parsed = urlsplit(value);
                    if (not parsed.netloc or parsed.netloc == "www.sec.gov") and parsed.path.startswith("/files/") {
                        self.paths.append(parsed.path);
                    }
                }
            }
        }
    }
}

def previous_quarter(day: str) -> str {
    d = date.fromisoformat(day);
    return (date(d.year, ((d.month - 1) // 3) * 3 + 1, 1) - timedelta(days=1)).isoformat();
}

"""45 calendar days, rolled through weekends and Washington's Birthday (the only
federal holiday that can coincide with a quarterly 13F deadline)."""
def filing_deadline(quarter: str) -> str {
    d = date.fromisoformat(quarter) + timedelta(days=45);
    while d.weekday() >= 5 or (d.month == 2 and d.weekday() == 0 and 15 <= d.day <= 21) {
        d += timedelta(days=1);
    }
    return d.isoformat();
}

def _sec_date(text: str) -> str {
    try {
        return date.fromisoformat(text).isoformat();
    } except ValueError {
        return datetime.strptime(text, "%d-%b-%Y").date().isoformat();
    }
}

"""Only closed windows are eligible; the archive itself may be posted later. Historical
runs cannot establish its exact publication day from today's listing (reported as a gap)."""
def archives(body: str, as_of: str) -> list[Archive] {
    parser = _Links();
    parser.feed(body);
    found: dict[str, Archive] = {};
    for path in parser.paths {
        matched = re.search(r"/\d{2}[a-z]{3}\d{4}-(\d{2}[a-z]{3}\d{4})_form13f\.zip$", path, re.IGNORECASE);
        if matched {
            end = datetime.strptime(matched.group(1), "%d%b%Y").date().isoformat();
            if end < as_of {
                found[end] = Archive(path=path, end=end, quarter=previous_quarter(end));
            }
        }
    }
    return sorted(found.values(), key=lambda (a: Archive) { a.end; }, reverse=True);
}

"""Stream a required UTF-8 TSV member; never extract paths from an untrusted ZIP."""
def _rows(zipped: zipfile.ZipFile, table: str, required: set[str]) -> Iterator[dict[str, str]] {
    names = [n for n in zipped.namelist() if n.rsplit("/", 1)[-1].upper() == table + ".TSV"];
    if len(names) != 1 {
        raise ValueError(f"13F archive needs one {table}.tsv");
    }
    with zipped.open(names[0]) as raw {
        with io.TextIOWrapper(raw, encoding="utf-8-sig", newline="") as text {
            reader = csv.DictReader(text, delimiter="\t");
            if not required.issubset(set(reader.fieldnames or [])) {
                raise ValueError(f"13F {table} is missing required columns");
            }
            for row in reader {
                yield {k: (v or "").strip() for (k, v) in row.items() if k is not None};
            }
        }
    }
}

"""Reduce an entire window once. Restatements replace earlier tables, additions extend
them, and a manager with an unrecognized amendment is excluded rather than double counted."""
def reduce_archive(data: bytes, quarter: str) -> str {
    with zipfile.ZipFile(io.BytesIO(data)) as zipped {
        submissions: dict[str, dict[str, str]] = {};
        for row in _rows(zipped, "SUBMISSION", {"ACCESSION_NUMBER", "CIK", "FILING_DATE", "PERIODOFREPORT", "SUBMISSIONTYPE"}) {
            if row["SUBMISSIONTYPE"] in ("13F-HR", "13F-HR/A") and _sec_date(row["PERIODOFREPORT"]) == quarter {
                row["FILING_DATE"] = _sec_date(row["FILING_DATE"]);
                submissions[row["ACCESSION_NUMBER"]] = row;
            }
        }
        covers = {
            r["ACCESSION_NUMBER"]: r
            for r in _rows(zipped, "COVERPAGE", {"ACCESSION_NUMBER", "AMENDMENTTYPE"})
            if r["ACCESSION_NUMBER"] in submissions
        };
        by_manager: dict[str, list[str]] = {};
        for (acc, row) in submissions.items() {
            by_manager.setdefault(str(int(row["CIK"])), []).append(acc);
        }
        selected: dict[str, str] = {};
        gaps: list[str] = [];
        for (manager, accessions) in by_manager.items() {
            kept: list[str] = [];
            problem = False;
            for acc in sorted(accessions, key=lambda (a: str) { (submissions[a]["FILING_DATE"], a); }) {
                amendment = covers.get(acc, {}).get("AMENDMENTTYPE", "").upper();
                if acc not in covers {
                    problem = True;
                } elif submissions[acc]["SUBMISSIONTYPE"] == "13F-HR" or amendment == "RESTATEMENT" {
                    kept = [acc];
                    problem = False;
                } elif amendment in ("NEW HOLDINGS", "ADDS NEW HOLDINGS ENTRIES") and kept {
                    kept.append(acc);
                } else {
                    problem = True;
                }
            }
            if problem or not kept {
                gaps.append(f"manager CIK {manager}: incomplete or unsupported amendment history excluded");
            } else {
                selected.update({acc: manager for acc in kept});
            }
        }
        totals: dict[str, dict] = {};
        managers: dict[str, set[str]] = {};
        shared = 0;
        for row in _rows(zipped, "INFOTABLE", {"ACCESSION_NUMBER", "CUSIP", "NAMEOFISSUER", "TITLEOFCLASS", "SSHPRNAMT", "SSHPRNAMTTYPE", "PUTCALL", "VALUE", "OTHERMANAGER"}) {
            acc = row["ACCESSION_NUMBER"];
            if acc not in selected or row["PUTCALL"] or row["SSHPRNAMTTYPE"].upper() != "SH" {
                continue;
            }
            cls = row["TITLEOFCLASS"].upper();
            if not re.search(r"\b(COM|COMMON|CL|CLASS|ORD|SHS|SHARES|ADR|CAP)\b", cls) or re.search(r"\b(PFD|PREF\w*|NOTE\w*|BOND\w*|WARR\w*|DEB\w*|UNIT\w*)\b", cls) {
                continue;
            }
            if row["OTHERMANAGER"] {
                shared += 1;
            }
            cusip = row["CUSIP"].upper();
            shares = float(row["SSHPRNAMT"]);
            value = float(row["VALUE"]);
            if not re.fullmatch(r"[A-Z0-9]{9}", cusip) or not math.isfinite(shares) or not math.isfinite(value) or min(shares, value) < 0 {
                raise ValueError("13F contains an invalid CUSIP or nonnegative finite holding");
            }
            # The unit changed on the filing date, not the holdings quarter.
            if submissions[acc]["FILING_DATE"] < "2023-01-03" {
                value *= 1000;
            }
            if cusip not in totals {
                totals[cusip] = {"names": [], "shares": 0.0, "value_usd": 0.0};
                managers[cusip] = set();
            }
            item = totals[cusip];
            if row["NAMEOFISSUER"] not in item["names"] {
                item["names"].append(row["NAMEOFISSUER"]);
            }
            item["shares"] += shares;
            item["value_usd"] += value;
            managers[cusip].add(selected[acc]);
        }
        for (cusip, item) in totals.items() {
            item["managers"] = len(managers[cusip]);
        }
        if shared {
            gaps.append(f"{shared} shared-manager rows included as filed; totals may overlap across reporting managers");
        }
        if not selected {
            raise ValueError(f"13F archive has no usable reports for quarter {quarter}");
        }
        return json.dumps({"schema": SCHEMA, "quarter": quarter, "totals": totals, "gaps": gaps});
    }
}

def normalized_name(name: str) -> str {
    words = re.sub(r"[^A-Z0-9 ]", " ", name.upper().replace("&", " AND ")).split();
    while words and words[-1] in ("INC", "INCORPORATED", "CORP", "CORPORATION", "CO", "COMPANY", "LTD", "LIMITED", "PLC") {
        words.pop();
    }
    return " ".join(words);
}

def _fetch_archive(client: SourceClient, archive: Archive, budget: RunBudget) -> Fetched {
    return client.get(
        DATASETS["sec.13f"], archive.path, budget, symbol=SCHEMA, day=archive.end,
        decode=lambda (data: bytes) { reduce_archive(data, archive.quarter); }
    );
}

"""Join the requested universe only; each unmatched ticker and ambiguous CUSIP is a gap.
The caller supplies names from SEC's ticker map or the index constituents, never an LLM."""
def join_holdings(names: dict[str, str], fetched: Fetched, archive: Archive) -> HoldingsBatch {
    parsed = json.loads(fetched.body);
    if parsed.get("schema") != SCHEMA or parsed.get("quarter") != archive.quarter {
        raise ValueError("13F cached schema or quarter does not match the requested archive");
    }
    by_name: dict[str, set[str]] = {};
    for (symbol, name) in names.items() {
        by_name.setdefault(normalized_name(name), set()).add(symbol);
    }
    candidates: dict[str, list[str]] = {};
    ambiguous: set[str] = set();
    totals: dict[str, dict] = parsed["totals"];
    for (cusip, row) in totals.items() {
        symbols: set[str] = set();
        for name in row["names"] {
            symbols.update(by_name.get(normalized_name(name), set()));
        }
        if len(symbols) > 1 {
            ambiguous.add(cusip);
        }
        for symbol in symbols {
            candidates.setdefault(symbol, []).append(cusip);
        }
    }
    result = HoldingsBatch();
    for (symbol, name) in names.items() {
        matches = candidates.get(symbol, []);
        result.gaps[symbol] = [f"sec.13f: {g}" for g in parsed["gaps"]];
        if len(matches) != 1 or len(by_name[normalized_name(name)]) != 1 or matches[0] in ambiguous {
            result.gaps[symbol].append(f"sec.13f: {symbol} ({name}) quarter {archive.quarter}: no unambiguous issuer/share-class name match; CUSIPs: {', '.join(matches) or 'none'}");
            continue;
        }
        cusip = matches[0];
        row = totals[cusip];
        result.values[symbol] = Holdings(
            symbol=symbol, issuer=name, cusip=cusip, quarter=archive.quarter,
            filing_deadline=filing_deadline(archive.quarter), archive_end=archive.end,
            shares=float(row["shares"]), value_usd=float(row["value_usd"]), managers=int(row["managers"]),
            stamp=fetched.stamp(archive.end)
        );
    }
    return result;
}

"""Latest published filing window plus its immediately preceding holdings quarter.
A failed prior archive leaves current figures intact and changes unknown, never zero."""
def institutional_holdings(names: dict[str, str], as_of: str, budget: RunBudget, client: SourceClient | None = None) -> HoldingsBatch {
    result = HoldingsBatch(gaps={s: [] for s in names});
    if not names {
        return result;
    }
    try {
        source = client or sec_archives_client();
        listing = source.get(DATASETS["sec.13f_index"], INDEX_PATH, budget, check=lambda (body: str) { "" if archives(body, "9999-12-31") else "SEC 13F listing contains no supported archive links"; });
        available = archives(listing.body, as_of);
        if not available {
            raise ValueError("no closed 13F filing window in the SEC listing");
        }
        latest = available[0];
        if (date.fromisoformat(as_of) - date.fromisoformat(latest.quarter)).days * 24 > DATASETS["sec.13f"].max_age_hours {
            raise ValueError(f"latest holdings quarter {latest.quarter} is past the freshness limit");
        }
        current = _fetch_archive(source, latest, budget);
        result = join_holdings(names, current, latest);
    } except Exception as e {
        for symbol in names {
            result.gaps[symbol].append(f"sec.13f: unavailable ({type(e).__name__}: {str(e)[:200]})");
        }
        return result;
    }
    prior_end = previous_quarter(latest.quarter);
    prior_archive = next((a for a in available if a.quarter == prior_end), None);
    try {
        if prior_archive is None {
            raise ValueError(f"no archive for prior quarter {prior_end}");
        }
        prior = join_holdings(names, _fetch_archive(source, prior_archive, budget), prior_archive);
        for (symbol, value) in result.values.items() {
            before = prior.values.get(symbol);
            if before is None or before.cusip != value.cusip {
                result.gaps[symbol].append(f"sec.13f: {symbol} prior quarter {prior_end} has no comparable CUSIP; changes unavailable");
            } else {
                value.prior_quarter = before.quarter;
                value.prior_source_url = before.stamp.source_url;
                value.prior_archive_end = before.archive_end;
                value.shares_change = value.shares - before.shares;
                value.value_change_usd = value.value_usd - before.value_usd;
                value.managers_change = value.managers - before.managers;
                result.gaps[symbol].extend(prior.gaps[symbol]);
            }
        }
    } except Exception as e {
        for symbol in result.values {
            result.gaps[symbol].append(f"sec.13f: prior quarter {prior_end} unavailable ({type(e).__name__}: {str(e)[:200]}); changes unavailable");
        }
    }
    for symbol in names {
        result.gaps[symbol].append("sec.13f: bulk windows omit later filings and confidential holdings; reported positions may overlap across managers; exact archive publication day is unavailable for historical replay");
    }
    return result;
}
