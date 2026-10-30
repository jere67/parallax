"""Batched follow-ups (#72): overlap, admission limits, stable history, and failure isolation.
MockLLM supplies initial reports; the overlap test uses a barrier, never a real model."""
import threading;
import from concurrent.futures { ThreadPoolExecutor }
import from jaclang.byllm.types { Tool }
import run.guard as guard_module;
import from agents.research { ResearchResult }
import from analysis.consensus { ConsensusConfig }
import from models.agents { Domain, Evidence, ResearchReport, Stance }
import from research.briefs { Brief }
import from run.analysis { TickerAnalysis }
import from run.guard { Followup, MAX_QUESTION_CHARS, RunLimits, RunSession }
import from run.stubs { RUN_DAY, SOURCE, Stubs, collection }

def ready(stubs: Stubs) -> RunSession {
    s = RunSession(run_day=RUN_DAY, collection=collection(stubs.symbols, []), holdings={}, config=ConsensusConfig(), limits=RunLimits(), run_requests=600);
    s.dispatch_research(s.tickers(), ["market", "fundamentals", "news"]);
    return s;
}

def answer(b: Brief, question: str) -> ResearchResult {
    return ResearchResult(
        ticker=b.ticker, domain=b.domain, model="test-followup", cited=1,
        body=ResearchReport(summary=f"{b.ticker}: {question}", view=Stance.HOLD, confidence=0.5,
            evidence=[Evidence(claim="A recorded fact.", source_url=SOURCE, published="2026-10-15")])
    );
}

test "follow-ups overlap on the pool and record answers in input order" {
    stubs = Stubs();
    stubs.install();
    barrier = threading.Barrier(2);
    second_done = threading.Event();
    finished: list[str] = [];
    def concurrent_answer(b: Brief, question: str) -> ResearchResult {
        barrier.wait(timeout=5);
        if b.ticker == "AAPL" {
            assert second_done.wait(timeout=5), "MSFT did not finish while AAPL was running";
        }
        finished.append(b.ticker);
        if b.ticker == "MSFT" {
            second_done.set();
        }
        return answer(b, question);
    }
    try {
        s = ready(stubs);
        with ThreadPoolExecutor(max_workers=2) as workers {
            stubs._swap(guard_module, "NETWORK", workers);
            stubs._swap(guard_module, "research", concurrent_answer);
            reply = s.request_followup([
                Followup(ticker=" aapl ", domain=" NEWS ", question="x" * 800),
                Followup(ticker="MSFT", domain="fundamentals", question="Are margins sustainable?")
            ]);
        }
    } finally {
        stubs.restore();
    }
    assert finished == ["MSFT", "AAPL"];
    assert reply.index("AAPL news: complete") < reply.index("MSFT fundamentals: complete");
    assert s.followups == {"AAPL": 1, "MSFT": 1};
    assert len(s.history["AAPL"][-1][1]) == MAX_QUESTION_CHARS;
    assert s.history["MSFT"][-1][1] == "Are margins sustainable?";
    assert s.latest["AAPL"][Domain.NEWS].model == "test-followup";
    assert s.latest["MSFT"][Domain.FUNDAMENTALS].model == "test-followup";
}

test "a batch reserves the ticker cap before launching any questions" {
    stubs = Stubs();
    stubs.install();
    try {
        s = ready(stubs);
        response = s.request_followup([
            Followup(ticker="AAPL", domain="news", question="First?"),
            Followup(ticker="AAPL", domain="news", question="Second?"),
            Followup(ticker="AAPL", domain="market", question="Third?"),
            Followup(ticker="MSFT", domain="market", question="Trend confirmed?")
        ]);
        assert "Refused: AAPL: already had 2 follow-ups." in response;
        assert s.followups == {"AAPL": 2, "MSFT": 1};
        assert [q for (_, q) in s.history["AAPL"] if q] == ["First?", "Second?"];
        assert s.request_followup([Followup(ticker="AAPL", domain="news", question="Another batch?")]) == "Refused: AAPL: already had 2 follow-ups.";
    } finally {
        stubs.restore();
    }
}

test "a batch cannot admit more initial calls than the remaining run budget" {
    stubs = Stubs();
    stubs.install();
    try {
        s = ready(stubs);
        s.run_requests = 1;
        reply = s.request_followup([
            Followup(ticker="AAPL", domain="news", question="First?"),
            Followup(ticker="MSFT", domain="news", question="Second?"),
            Followup(ticker="AAPL", domain="market", question="Third?")
        ]);
        assert reply.startswith("AAPL news: complete");
        assert reply.count("Refused: the run's request budget is spent.") == 2;
        assert s.followups == {"AAPL": 1};
        assert len(s.history["MSFT"]) == 3;
    } finally {
        stubs.restore();
    }
}

test "invalid items consume neither ticker slots nor a valid item's budget slot" {
    stubs = Stubs();
    stubs.install();
    try {
        s = ready(stubs);
        s.run_requests = 1;
        del s.latest["AAPL"][Domain.MARKET];
        reply = s.request_followup([
            Followup(ticker="NVDA", domain="news", question="Not covered?"),
            Followup(ticker="AAPL", domain="options", question="Not a domain?"),
            Followup(ticker="AAPL", domain="market", question="No first report?"),
            Followup(ticker="AAPL", domain="news", question="  "),
            Followup(ticker="MSFT", domain="news", question="A valid question?")
        ]);
        assert "NVDA: not covered in this run" in reply;
        assert "options: not a research domain" in reply;
        assert "AAPL market: dispatch research first" in reply;
        assert "a follow-up needs a question" in reply;
        assert "MSFT news: complete" in reply;
        assert s.followups == {"MSFT": 1};
        assert len(s.history["AAPL"]) == 3;
    } finally {
        stubs.restore();
    }
}

test "missing collected inputs do not prevent another ticker's follow-up" {
    stubs = Stubs();
    stubs.install();
    try {
        s = ready(stubs);
        s.run_requests = 1;
        s.collection.tickers = [t for t in s.collection.tickers if t.pick.symbol != "AAPL"];
        reply = s.request_followup([
            Followup(ticker="AAPL", domain="news", question="Missing inputs?"),
            Followup(ticker="MSFT", domain="news", question="Valid inputs?")
        ]);
        assert reply.startswith("Refused: AAPL has no collected data.");
        assert "MSFT news: complete" in reply and s.followups == {"MSFT": 1};
    } finally {
        stubs.restore();
    }
}

test "a failed worker keeps its history without replacing good research or losing other answers" {
    stubs = Stubs();
    stubs.install();
    def sometimes_fails(b: Brief, question: str) -> ResearchResult {
        if b.ticker == "AAPL" {
            raise RuntimeError("unexpected worker failure");
        }
        return answer(b, question);
    }
    try {
        s = ready(stubs);
        original = s.latest["AAPL"][Domain.NEWS];
        stubs._swap(guard_module, "research", sometimes_fails);
        reply = s.request_followup([
            Followup(ticker="AAPL", domain="news", question="Fails?"),
            Followup(ticker="MSFT", domain="news", question="Succeeds?")
        ]);
        assert "AAPL news: incomplete" in reply and "MSFT news: complete" in reply;
        assert s.latest["AAPL"][Domain.NEWS] is original;
        assert not s.history["AAPL"][-1][0].ok;
        assert s.history["AAPL"][-1][0].error == "RuntimeError: unexpected worker failure";
        assert s.history["AAPL"][-1][1] == "Fails?";
        assert s.followups == {"AAPL": 1, "MSFT": 1};
    } finally {
        stubs.restore();
    }
}

test "follow-ups cannot change a ticker after its panel or a submitted decision set" {
    stubs = Stubs();
    stubs.install();
    try {
        s = ready(stubs);
        s.analyses["AAPL"] = TickerAnalysis(ticker="AAPL", held=False);
        assert s.request_followup([Followup(ticker="AAPL", domain="news", question="Too late?")]) == "Refused: AAPL: the panel has already ruled.";
        s.submitted = True;
        assert s.request_followup([Followup(ticker="MSFT", domain="news", question="Too late?")]) == "Refused: decisions are already submitted.";
        assert s.followups == {};
        assert len(s.history["AAPL"]) == len(s.history["MSFT"]) == 3;
    } finally {
        stubs.restore();
    }
}

test "an empty follow-up batch is a no-op" {
    stubs = Stubs();
    stubs.install();
    try {
        s = ready(stubs);
        before = list(s.actions);
        assert s.request_followup([]) == "Nothing to run.";
        assert s.actions == before and s.followups == {};
        assert len(s.history["AAPL"]) == len(s.history["MSFT"]) == 3;
    } finally {
        stubs.restore();
    }
}

test "the bound tool parses JSON items into typed follow-ups before executing" {
    stubs = Stubs();
    stubs.install();
    try {
        s = ready(stubs);
        tool = Tool(s.request_followup);
        parsed = tool.parse_arguments({"followups": [{"ticker": "AAPL", "domain": "news", "question": "Why?"}]});
        items = parsed["followups"] as list[Followup];
        assert isinstance(items[0], Followup) and items[0].question == "Why?";
        assert tool(**parsed).startswith("AAPL news: complete");
        assert s.followups == {"AAPL": 1};
        with testraises(ValueError) {
            tool.parse_arguments({"followups": [{"ticker": "MSFT", "domain": "news"}]});
        }
        assert "MSFT" not in s.followups;
    } finally {
        stubs.restore();
    }
}
