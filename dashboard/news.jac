"""The news feed (TDD §10, News): every note the research desks wrote, newest first, as headlines
a reader can filter, with each note and its sources one click away.

A note is a ResearchRecord or a run's MacroRecord, so nothing here calls a model or a data source.
The notes hold no headline, so one is cut from the summary's first sentence, and the rest of the
summary becomes the body, so a story never says the same thing twice.

A finished run's notes never change, so their lines are kept for good by the run's id, and the
minute's rebuild only walks the runs and reads the notes it has not seen. Filters then run over
those lines in memory, which keeps a search instant however long the record grows. A reader's
report keeps its own one-run portfolio on root.shared, and its notes join the feed marked as
requested; its macro brief does not, since the morning run's is the market's.
"""
import re;
import from urllib.parse { urlsplit }
import from dashboard.api { find_team, first_of, portfolio_view, runs_by_day, view_key }
import from dashboard.cache { VIEWS }
import from models.agents { Domain, Evidence }
import from models.graph {
    Coverage,
    Covers,
    Decided,
    Decision,
    HasMacro,
    MacroRecord,
    Portfolio,
    Ran,
    Researched,
    ResearchRecord,
    Run,
    RunStatus
}
import from models.views { NewsFeed, NewsItem, NewsSource, NewsStory, PortfolioView }

glob PAGE: int = 50;
glob MAX_PAGE: int = 100;
# Beyond this a headline is cut at a word, and the body keeps the whole summary.
glob MAX_HEADLINE: int = 200;
# A clause shorter than this says too little to stand as a headline.
glob MIN_CLAUSE: int = 24;
glob REPORT_PREFIX: str = "report:";
# The address of the market's own note, which has no ticker.
glob MARKET: str = "market";
glob DESK_ORDER: list[str] = ["market", "fundamentals", "news", "macro"];
glob LEANS: dict[str, str] = {"STRONG_BUY": "up", "BUY": "up", "RISK_ON": "up", "SELL": "down", "STRONG_SELL": "down", "RISK_OFF": "down"};
glob DESK_NAMES: dict[str, str] = {"market": "Market", "fundamentals": "Fundamentals", "news": "News", "macro": "Macro"};
# Words whose period does not end a sentence.
glob ABBREVIATIONS: set[str] = {"u.s", "u.k", "e.g", "i.e", "vs", "inc", "corp", "co", "ltd", "no", "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec", "mr", "ms", "dr"};
glob SENTENCE_END: re.Pattern[str] = re.compile(r"[.!?](?=\s+[A-Z$(\"'“]|\s*$)");
glob AS_OF: re.Pattern[str] = re.compile(r"^As of [^,:]{4,30}, ");
glob ISO_DAY: re.Pattern[str] = re.compile(r"^\d{4}-\d{2}-\d{2}");
glob TRIM: str = " \t\n.:;,-–—";
glob PROVIDERS: dict[str, str] = {
    "www.sec.gov": "SEC EDGAR",
    "data.sec.gov": "SEC EDGAR",
    "data.alpaca.markets": "Alpaca",
    "paper-api.alpaca.markets": "Alpaca",
    "finnhub.io": "Finnhub",
    "en.wikipedia.org": "Wikipedia"
};
# Data APIs: an address here answers only with the project's keys, so it is not a page to open.
glob API_PREFIXES: list[str] = [
    "https://data.alpaca.markets/",
    "https://paper-api.alpaca.markets/",
    "https://data.sec.gov/api/",
    "https://finnhub.io/api/v1/"
];

"""A line of the feed, with the note's text for searching. The text stays on the server."""
obj NewsEntry {
    has item: NewsItem,
        text: str;
}

"""What a reader asked the feed for."""
obj NewsFilter {
    has words: list[str] = [],
        ticker: str = "",
        desk: str = "",
        lean: str = "",
        day: str = "",
        held_only: bool = False;
}

# --- Headlines -----------------------------------------------------------------------------

def capitalized(text: str) -> str {
    return text[0:1].upper() + text[1:];
}

"""The text up to the end of its first sentence, past periods in abbreviations and initials."""
def first_sentence(text: str) -> str {
    for found in SENTENCE_END.finditer(text) {
        words = text[0:found.start()].split();
        last = words[-1].lstrip("(").lower() if words else "";
        if last not in ABBREVIATIONS and len(last) > 1 {
            return text[0:found.end()];
        }
    }
    return text;
}

"""Where a sentence's first main clause ends: at a colon, semicolon, or spaced dash outside any
parentheses, far enough in to say something. None when there is no such place."""
def clause_end(sentence: str) -> int | None {
    depth = 0;
    for (i, c) in enumerate(sentence) {
        if c == "(" {
            depth += 1;
        } elif c == ")" {
            depth = max(0, depth - 1);
        } elif depth == 0 and i >= MIN_CLAUSE {
            pair = sentence[i:i + 2];
            spaced = sentence[i:i + 3] in [" - ", " – ", " — "];
            if pair in [": ", "; "] or spaced {
                return i;
            }
        }
    }
    return None;
}

"""A note's headline and body. A follow-up's headline is the question it answers, and its summary
is the answer. Otherwise the headline is the summary's first sentence, or that sentence's first
clause, and the body is what follows it. A sentence too long for a headline is cut at a word, and
then the body keeps all of the summary, so no words are lost either way."""
def headline_and_body(summary: str, question: str, fallback: str) -> tuple[str, str] {
    clean = summary.strip();
    if question.strip() {
        return (question.strip(), clean);
    }
    if not clean {
        return (fallback, "");
    }
    found = AS_OF.match(clean);
    if found is not None {
        clean = capitalized(clean[found.end():]);
    }
    sentence = first_sentence(clean);
    end = clause_end(sentence);
    if end is None {
        end = len(sentence);
    }
    if end > MAX_HEADLINE {
        cut = clean[0:MAX_HEADLINE].rsplit(" ", 1)[0].rstrip(TRIM);
        return (cut + "…", clean);
    }
    return (clean[0:end].rstrip(TRIM), capitalized(clean[end:].lstrip(TRIM)));
}

# --- Sources -------------------------------------------------------------------------------

def provider_of(url: str) -> str {
    host = urlsplit(url).hostname or "";
    return PROVIDERS.get(host, host[4:] if host.startswith("www.") else host);
}

"""A note's evidence grouped by source, newest source first, with repeated claims dropped."""
def sources_of(evidence: list[Evidence]) -> list[NewsSource] {
    found: dict[str, NewsSource] = {};
    for e in evidence {
        source = found.get(e.source_url);
        if source is None {
            source = NewsSource(
                label=provider_of(e.source_url),
                url=e.source_url,
                claims=[],
                day=e.published[0:10] if ISO_DAY.match(e.published) else "",
                link=not any(e.source_url.startswith(p) for p in API_PREFIXES)
            );
            found[e.source_url] = source;
        }
        if e.claim not in source.claims {
            source.claims.append(e.claim);
        }
    }
    return sorted(found.values(), key=lambda (s: NewsSource) { s.day; }, reverse=True);
}

# --- The feed's lines ----------------------------------------------------------------------

def note_id(day: str, ticker: str, desk: str, n: int, requested: bool) -> str {
    path = f"{day}/{ticker or MARKET}/{desk}/{n}";
    return path + "/requested" if requested else path;
}

def entry_of(day: str, cov: Coverage, r: ResearchRecord, n: int, requested: bool) -> NewsEntry {
    (headline, _) = headline_and_body(r.body.summary, r.followup_question, f"{DESK_NAMES[r.domain.value]} research on {cov.ticker}");
    return NewsEntry(
        item=NewsItem(
            id=note_id(day, cov.ticker, r.domain.value, n, requested),
            day=day,
            desk=r.domain.value,
            as_of=r.as_of,
            headline=headline,
            view=r.body.view.value,
            lean=LEANS.get(r.body.view.value, "flat"),
            confidence=r.body.confidence,
            ticker=cov.ticker,
            sector=cov.sector,
            sources=len(set(e.source_url for e in r.body.evidence)),
            followup=bool(r.followup_question),
            requested=requested
        ),
        text=" ".join([cov.ticker, cov.sector, r.followup_question, r.body.summary] + [e.claim for e in r.body.evidence]).lower()
    );
}

def macro_entry(day: str, m: MacroRecord) -> NewsEntry {
    (headline, _) = headline_and_body(m.body.summary, "", "The market's macro brief");
    return NewsEntry(
        item=NewsItem(
            id=note_id(day, "", Domain.MACRO.value, 0, False),
            day=day,
            desk=Domain.MACRO.value,
            as_of=m.as_of,
            headline=headline,
            view=m.body.regime.value,
            lean=LEANS.get(m.body.regime.value, "flat"),
            confidence=m.body.confidence,
            sources=len(set(e.source_url for e in m.body.evidence))
        ),
        text=" ".join([m.body.summary] + [e.claim for e in m.body.evidence]).lower()
    );
}

"""A coverage's notes on one desk, the first report before its follow-ups, so a note's place in
this list is its stable number in its address."""
def notes_on(cov: Coverage) -> dict[str, list[ResearchRecord]] {
    found: dict[str, list[ResearchRecord]] = {};
    records = sorted([r for r in [cov ->:Researched:->[?:ResearchRecord]]], key=lambda (r: ResearchRecord) { (bool(r.followup_question), r.as_of); });
    for r in records {
        found.setdefault(r.domain.value, []).append(r);
    }
    return found;
}

def run_entries(run: Run, requested: bool) -> list[NewsEntry] {
    found: list[NewsEntry] = [];
    if not requested {
        macro = first_of([m for m in [run ->:HasMacro:->[?:MacroRecord]]]);
        if macro is not None {
            found.append(macro_entry(run.run_date, macro));
        }
    }
    for cov in [run ->:Covers:->[?:Coverage]] {
        for (desk, records) in notes_on(cov).items() {
            for (n, r) in enumerate(records) {
                found.append(entry_of(run.run_date, cov, r, n, requested));
            }
        }
    }
    return found;
}

"""The lines of each finished run, by the run's id. A run still writing is read afresh."""
glob FINISHED: dict[str, list[NewsEntry]] = {};

def entries_of(run: Run, requested: bool) -> list[NewsEntry] {
    key = jid(run);
    kept = FINISHED.get(key);
    if kept is not None {
        return kept;
    }
    found = run_entries(run, requested);
    if run.status != RunStatus.RUNNING {
        FINISHED[key] = found;
    }
    return found;
}

"""Newest first by the note's time, and within one time (a run stores its notes together) those
that take a side before those that do not, then the most confident."""
def in_feed_order(entries: list[NewsEntry]) -> list[NewsEntry] {
    def rank(e: NewsEntry) -> tuple[int, float, str, int] {
        item = e.item;
        return (0 if item.lean != "flat" else 1, 0.0 - item.confidence, item.ticker, DESK_ORDER.index(item.desk));
    }
    return sorted(sorted(entries, key=rank), key=lambda (e: NewsEntry) { (e.item.day, e.item.as_of); }, reverse=True);
}

"""Every line in the feed: the team's runs, then each reader's report on root.shared."""
def news_index(team: Portfolio, reports: list[Portfolio]) -> list[NewsEntry] {
    found: list[NewsEntry] = [];
    for run in [team ->:Ran:->[?:Run]] {
        found.extend(entries_of(run, False));
    }
    for portfolio in reports {
        for run in [portfolio ->:Ran:->[?:Run]] {
            found.extend(entries_of(run, True));
        }
    }
    return in_feed_order(found);
}

def report_portfolios -> list[Portfolio] {
    return [p for p in [root.shared -->[?:Portfolio]] if p.name.startswith(REPORT_PREFIX)];
}

def held_tickers(team: Portfolio) -> set[str] {
    view: PortfolioView = VIEWS.get(view_key(team, "portfolio"), portfolio_view, team);
    return set(p.ticker for p in view.positions);
}

# --- Filters -------------------------------------------------------------------------------

def matches(e: NewsEntry, f: NewsFilter, held: set[str], any_desk: bool = False) -> bool {
    item = e.item;
    return (not f.ticker or item.ticker == f.ticker)
        and (any_desk or not f.desk or item.desk == f.desk)
        and (not f.lean or item.lean == f.lean)
        and (not f.day or item.day == f.day)
        and (not f.held_only or item.ticker in held)
        and all(w in e.text for w in f.words);
}

"""One page of the lines that match, and what the filters offer."""
def select(entries: list[NewsEntry], f: NewsFilter, held: set[str], offset: int = 0, limit: int = PAGE) -> NewsFeed {
    start = max(0, offset);
    size = min(MAX_PAGE, max(1, limit));
    found = [e.item for e in entries if matches(e, f, held)];
    desks: dict[str, int] = {desk: 0 for desk in DESK_ORDER};
    for e in entries {
        if matches(e, f, held, any_desk=True) {
            desks[e.item.desk] += 1;
        }
    }
    known = set(e.item.ticker for e in entries);
    return NewsFeed(
        items=found[start:start + size],
        total=len(found),
        next_offset=start + size if start + size < len(found) else None,
        desks=desks,
        tickers=sorted(t for t in known if t),
        days=sorted(set(e.item.day for e in entries), reverse=True),
        held=len(known & held)
    );
}

# --- A note in full ------------------------------------------------------------------------

def macro_story(day: str, run: Run) -> NewsStory | None {
    m = first_of([m for m in [run ->:HasMacro:->[?:MacroRecord]]]);
    if m is None {
        return None;
    }
    (_, body) = headline_and_body(m.body.summary, "", "");
    return NewsStory(
        item=macro_entry(day, m).item,
        body=body,
        sources=sources_of(m.body.evidence),
        risks=m.body.risks,
        data_gaps=m.body.data_gaps,
        model=m.model,
        trail=True
    );
}

def ticker_story(day: str, run: Run, ticker: str, desk: str, n: int, requested: bool) -> NewsStory | None {
    cov = first_of([c for c in [run ->:Covers:->[?:Coverage]] if c.ticker == ticker]);
    if cov is None {
        return None;
    }
    records = notes_on(cov).get(desk, []);
    if n < 0 or n >= len(records) {
        return None;
    }
    r = records[n];
    (_, body) = headline_and_body(r.body.summary, r.followup_question, "");
    decision: Decision | None = first_of([d for d in [cov ->:Decided:->[?:Decision]]]);
    return NewsStory(
        item=entry_of(day, cov, r, n, requested).item,
        body=body,
        sources=sources_of(r.body.evidence),
        risks=r.body.risks,
        data_gaps=r.body.data_gaps,
        model=r.model,
        followup_question=r.followup_question,
        last_close=cov.last_close or None,
        action=decision.action.value if decision is not None else "",
        trail=not requested
    );
}

def story_view(portfolio: Portfolio, day: str, ticker: str, desk: str, n: int, requested: bool) -> NewsStory | None {
    run = runs_by_day(portfolio).get(day);
    if run is None {
        return None;
    }
    if desk == Domain.MACRO.value {
        return None if n != 0 or requested else macro_story(day, run);
    }
    return ticker_story(day, run, ticker, desk, n, requested);
}

# --- Endpoints -----------------------------------------------------------------------------

"""An argument a caller left out, as the server passes it: it hands an endpoint the text of each
default ("0", "False"), so a flag left out would be true. A caller's own value is already typed."""
def as_flag(value: bool | str) -> bool {
    return str(value) == "True";
}

"""One page of the feed. `q` must appear word by word in a note's text; the others are exact, and
an empty one does not filter. `lean` is "up", "flat", or "down", and `held` keeps the tickers the
team holds now."""
def:pub get_news_feed(
    q: str = "",
    ticker: str = "",
    desk: str = "",
    lean: str = "",
    day: str = "",
    held: bool = False,
    offset: int = 0,
    limit: int = PAGE
) -> NewsFeed {
    team = find_team();
    if team is None {
        return NewsFeed(items=[], total=0);
    }
    entries: list[NewsEntry] = VIEWS.get(view_key(team, "news"), news_index, team, report_portfolios());
    wanted = NewsFilter(words=q.lower().split(), ticker=ticker.upper(), desk=desk, lean=lean, day=day, held_only=as_flag(held));
    return select(entries, wanted, held_tickers(team), int(offset), int(limit));
}

"""One note in full, by the parts of its address; None when there is no such note."""
def:pub get_news_story(day: str, ticker: str, desk: str, n: int = 0, requested: bool = False) -> NewsStory | None {
    symbol = ticker.upper();
    team = find_team();
    if team is None {
        return None;
    }
    portfolio: Portfolio | None = team;
    # Typed here, since the cache's key and the lookup below both need the real values.
    note = int(n);
    asked = as_flag(requested);
    if asked {
        name = f"{REPORT_PREFIX}{day}:{symbol}";
        portfolio = first_of([p for p in report_portfolios() if p.name == name]);
    }
    if portfolio is None {
        return None;
    }
    return VIEWS.get(view_key(team, "story", day, symbol, desk, str(note), str(asked)), story_view, portfolio, day, symbol, desk, note, asked);
}

"""Keep the feed built, so no reader waits for it (dashboard/cache.jac). A static job runs as the
system user, which reaches root.shared."""
@schedule(trigger=ScheduleTrigger.STATIC, cron="* * * * *")
def news_refresh_job {
    team = find_team();
    if team is not None {
        VIEWS.put(view_key(team, "news"), news_index(team, report_portfolios()));
    }
}
