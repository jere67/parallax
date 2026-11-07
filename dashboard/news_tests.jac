"""The news feed's headlines, source lists, filters, and ordering, over graphs built here."""
import from action.fixtures { Call, finished_run, team }
import from dashboard.news {
    NewsEntry,
    NewsFilter,
    first_sentence,
    headline_and_body,
    in_feed_order,
    news_index,
    select,
    sources_of,
    story_view
}
import from models.agents { Domain, Evidence, ResearchReport, Stance }
import from models.graph { CoverageReason, Coverage, Covers, Portfolio, PortfolioMode, Ran, Researched, ResearchRecord, Run, RunStatus, TradeAction }
import from models.views { NewsItem }

def item(ticker: str, desk: str = "news", as_of: str = "2026-11-06T13:00:00+00:00", lean: str = "flat", confidence: float = 0.5, day: str = "2026-11-06") -> NewsItem {
    return NewsItem(id=f"{day}/{ticker}/{desk}/0", day=day, desk=desk, as_of=as_of, headline=f"{ticker} headline", view="HOLD", lean=lean, confidence=confidence, ticker=ticker);
}

def line_of(ticker: str, text: str = "", desk: str = "news", lean: str = "flat", day: str = "2026-11-06") -> NewsEntry {
    return NewsEntry(item=item(ticker, desk=desk, lean=lean, day=day), text=(ticker + " " + text).lower());
}

def note(summary: str, view: Stance = Stance.HOLD, evidence: list[Evidence] = []) -> ResearchReport {
    return ResearchReport(summary=summary, view=view, confidence=0.6, evidence=evidence);
}

test "the first sentence runs past abbreviations and decimals" {
    assert first_sentence("Sales in the U.S. Market rose 1.5% vs. last year. Margins fell.") == "Sales in the U.S. Market rose 1.5% vs. last year.";
    assert first_sentence("No period at the end") == "No period at the end";
    assert first_sentence("Closed at $29.45. RSI is 54.") == "Closed at $29.45.";
}

test "a headline is the first clause, and the body carries on from it" {
    (head, body) = headline_and_body("Pfizer reported Q3 2026 results on 2026-11-03: revenue of $16.6 billion was flat. It raised guidance.", "", "x");
    assert head == "Pfizer reported Q3 2026 results on 2026-11-03";
    assert body == "Revenue of $16.6 billion was flat. It raised guidance.";
}

test "a headline drops an as-of opening and keeps a whole sentence without a clause break" {
    (head, body) = headline_and_body("As of 2026-11-06, the stock is in an uptrend. RSI is neutral.", "", "x");
    assert head == "The stock is in an uptrend";
    assert body == "RSI is neutral.";
}

test "a colon inside parentheses or too early does not cut the headline" {
    (head, _) = headline_and_body("Revenue rose sharply (segment: cloud, up 39%) in the quarter. More.", "", "x");
    assert head == "Revenue rose sharply (segment: cloud, up 39%) in the quarter";
    (early, _) = headline_and_body("Short: this clause is too early to stand alone as a headline. More.", "", "x");
    assert early == "Short: this clause is too early to stand alone as a headline";
}

test "a sentence too long for a headline is cut, and the body keeps every word" {
    words = "word " * 80;
    summary = words.strip() + ". Next.";
    (head, body) = headline_and_body(summary, "", "x");
    assert len(head) <= 201 and head.endswith("…");
    assert body == summary;
}

test "a follow-up's headline is its question, and its body the whole answer" {
    (head, body) = headline_and_body("Yes. The view rests on momentum.", "Is the view momentum?", "x");
    assert head == "Is the view momentum?" and body == "Yes. The view rests on momentum.";
}

test "an empty summary falls back to the desk's name" {
    assert headline_and_body("  ", "", "News research on AAPL") == ("News research on AAPL", "");
}

test "sources group by address, newest first, name their provider, and link only real pages" {
    found = sources_of([
        Evidence(claim="Close was 10.", source_url="https://data.alpaca.markets/v2/stocks/bars?symbols=A", published="2026-11-05"),
        Evidence(claim="Revenue rose.", source_url="https://www.sec.gov/Archives/x.htm", published="2026-11-03"),
        Evidence(claim="Margin fell.", source_url="https://www.sec.gov/Archives/x.htm", published="2026-11-03"),
        Evidence(claim="Margin fell.", source_url="https://www.sec.gov/Archives/x.htm", published="2026-11-03"),
        Evidence(claim="Downgraded.", source_url="https://www.benzinga.com/a", published="2026-11-06T11:32:00Z"),
        Evidence(claim="Metrics.", source_url="https://finnhub.io/api/v1/stock/metric?symbol=A", published="sometime")
    ]);
    assert [s.label for s in found] == ["benzinga.com", "Alpaca", "SEC EDGAR", "Finnhub"];
    assert [s.day for s in found] == ["2026-11-06", "2026-11-05", "2026-11-03", ""];
    assert [s.link for s in found] == [True, False, True, False];
    assert found[2].claims == ["Revenue rose.", "Margin fell."];
}

test "the feed is newest first, then what takes a side, then the most confident" {
    ordered = in_feed_order([
        NewsEntry(item=item("A", confidence=0.9), text=""),
        NewsEntry(item=item("B", lean="up", confidence=0.6), text=""),
        NewsEntry(item=item("C", lean="down", confidence=0.7), text=""),
        NewsEntry(item=item("D", as_of="2026-11-06T14:00:00+00:00"), text=""),
        NewsEntry(item=item("E", as_of="2026-11-05T13:00:00+00:00", lean="up", confidence=0.9, day="2026-11-05"), text="")
    ]);
    assert [e.item.ticker for e in ordered] == ["D", "C", "B", "A", "E"];
}

test "filters combine, and a desk's count ignores only the desk filter" {
    entries = [
        line_of("AAPL", "guidance raised", desk="news", lean="up"),
        line_of("AAPL", "moving averages", desk="market"),
        line_of("MSFT", "guidance cut", desk="news", lean="down", day="2026-11-05"),
        line_of("", "treasury funds", desk="macro")
    ];
    everything = select(entries, NewsFilter(), set());
    assert everything.total == 4 and everything.next_offset is None;
    assert everything.tickers == ["AAPL", "MSFT"] and everything.days == ["2026-11-06", "2026-11-05"];
    assert everything.desks == {"market": 1, "fundamentals": 0, "news": 2, "macro": 1};

    apple_news = select(entries, NewsFilter(ticker="AAPL", desk="news"), set());
    assert [i.ticker for i in apple_news.items] == ["AAPL"] and apple_news.desks["market"] == 1;
    assert apple_news.tickers == ["AAPL", "MSFT"];

    assert select(entries, NewsFilter(words=["guidance", "cut"]), set()).total == 1;
    assert select(entries, NewsFilter(words=["guidance", "absent"]), set()).total == 0;
    assert select(entries, NewsFilter(lean="up"), set()).total == 1;
    assert select(entries, NewsFilter(day="2026-11-05"), set()).total == 1;
}

test "the holdings filter keeps only tickers held now" {
    entries = [line_of("AAPL"), line_of("MSFT"), line_of("", desk="macro")];
    held = select(entries, NewsFilter(held_only=True), {"MSFT", "NVDA"});
    assert [i.ticker for i in held.items] == ["MSFT"] and held.held == 1;
}

test "pages walk the whole feed and clamp a bad request" {
    entries = [line_of(f"T{i}") for i in range(5)];
    first = select(entries, NewsFilter(), set(), 0, 2);
    assert len(first.items) == 2 and first.next_offset == 2 and first.total == 5;
    last = select(entries, NewsFilter(), set(), 4, 2);
    assert len(last.items) == 1 and last.next_offset is None;
    assert len(select(entries, NewsFilter(), set(), -3, 0).items) == 1;
    assert select(entries, NewsFilter(), set(), 0, 100000).total == 5;
}

"""A run with one covered ticker that has a report and a follow-up on the news desk."""
def covered_run(portfolio: Portfolio, day: str, status: RunStatus = RunStatus.NORMAL) -> tuple[Run, Coverage] {
    run = finished_run(portfolio, day, [Call(ticker="AAPL", action=TradeAction.BUY, conviction=0.6)], status=status);
    cov = [c for c in [run ->:Covers:->[?:Coverage]]][0];
    cov +>:Researched():+> ResearchRecord(ticker="AAPL", domain=Domain.NEWS, as_of=f"{day}T13:00:00+00:00", model="mock", body=note("Apple raised its guidance for the year: sales rose 12%.", Stance.BUY, [Evidence(claim="Sales rose 12%.", source_url="https://www.sec.gov/a.htm", published=day)]));
    cov +>:Researched():+> ResearchRecord(ticker="AAPL", domain=Domain.NEWS, as_of=f"{day}T13:00:00+00:00", model="mock", body=note("It does. Sales outran the sector."), followup_question="Does the raise beat the sector?");
    return (run, cov);
}

test "the index holds a run's macro brief and each note, with stable addresses" {
    portfolio = team();
    covered_run(portfolio, "2026-11-06");
    items = [e.item for e in news_index(portfolio, [])];
    assert sorted(i.id for i in items) == ["2026-11-06/AAPL/news/0", "2026-11-06/AAPL/news/1", "2026-11-06/market/macro/0"];
    first = [i for i in items if i.id.endswith("news/0")][0];
    assert first.headline == "Apple raised its guidance for the year" and first.lean == "up" and first.sources == 1;
    followup = [i for i in items if i.id.endswith("news/1")][0];
    assert followup.headline == "Does the raise beat the sector?" and followup.followup is True;
    macro = [i for i in items if i.desk == "macro"][0];
    assert macro.ticker == "" and macro.view == "NEUTRAL";
}

test "a reader's report joins the feed as requested, without a macro brief" {
    portfolio = team();
    covered_run(portfolio, "2026-11-06");
    reader = Portfolio(name="report:2026-11-06:AAPL", mode=PortfolioMode.INSIGHT, starting_cash=0.0, opened_at="2026-11-06T15:00:00+00:00");
    root ++> reader;
    covered_run(reader, "2026-11-06");
    items = [e.item for e in news_index(portfolio, [reader])];
    requested = [i for i in items if i.requested];
    assert sorted(i.id for i in requested) == ["2026-11-06/AAPL/news/0/requested", "2026-11-06/AAPL/news/1/requested"];
    assert len(items) == 5;
}

test "a finished run is read once, and a running one each time" {
    portfolio = team();
    (done, cov) = covered_run(portfolio, "2026-11-05");
    (live, live_cov) = covered_run(portfolio, "2026-11-06", status=RunStatus.RUNNING);
    assert len(news_index(portfolio, [])) == 6;
    cov +>:Researched():+> ResearchRecord(ticker="AAPL", domain=Domain.MARKET, as_of="2026-11-05T13:00:00+00:00", model="mock", body=note("Ignored once finished."));
    live_cov +>:Researched():+> ResearchRecord(ticker="AAPL", domain=Domain.MARKET, as_of="2026-11-06T13:00:00+00:00", model="mock", body=note("Seen while running."));
    assert len(news_index(portfolio, [])) == 7;
}

test "a story carries the note's body, sources, and the panel's decision" {
    portfolio = team();
    covered_run(portfolio, "2026-11-06");
    story = story_view(portfolio, "2026-11-06", "AAPL", "news", 0, False);
    assert story is not None;
    assert story.item.id == "2026-11-06/AAPL/news/0" and story.body == "Sales rose 12%.";
    assert [s.label for s in story.sources] == ["SEC EDGAR"];
    assert story.action == "BUY" and story.trail is True and story.last_close == 100.0;
    followup = story_view(portfolio, "2026-11-06", "AAPL", "news", 1, False);
    assert followup is not None and followup.followup_question == "Does the raise beat the sector?" and followup.body == "It does. Sales outran the sector.";
    requested = story_view(portfolio, "2026-11-06", "AAPL", "news", 0, True);
    assert requested is not None and requested.trail is False and requested.item.requested is True;
}

test "the macro brief is a story, and an address with no note finds none" {
    portfolio = team();
    covered_run(portfolio, "2026-11-06");
    macro = story_view(portfolio, "2026-11-06", "market", "macro", 0, False);
    assert macro is not None and macro.item.desk == "macro" and macro.trail is True and macro.action == "";
    assert story_view(portfolio, "2026-11-05", "AAPL", "news", 0, False) is None;
    assert story_view(portfolio, "2026-11-06", "MSFT", "news", 0, False) is None;
    assert story_view(portfolio, "2026-11-06", "AAPL", "news", 7, False) is None;
    assert story_view(portfolio, "2026-11-06", "AAPL", "market", 0, False) is None;
}
