"""Insight cards (action/insights.jac), rendered from a stored coverage with no model request."""
import from action.insights { DISCLAIMER, MAX_SOURCES, publish_card, render_card }
import from models.agents { Domain, Evidence, ResearchReport, Specialist, Stance, Vote }
import from models.graph {
    Concluded,
    ConsensusResult,
    Coverage,
    CoverageReason,
    Decided,
    Decision,
    InsightCard,
    Published,
    Researched,
    ResearchRecord,
    TradeAction,
    VoteRecord,
    Voted
}

def findings(claims: list[tuple[str, str]]) -> ResearchReport {
    return ResearchReport(summary="Fine.", view=Stance.BUY, confidence=0.6, evidence=[Evidence(claim=c, source_url=u, published="2026-10-20") for (c, u) in claims]);
}

def covered -> Coverage {
    cov = Coverage(ticker="AAA", sector="Information Technology", reason=CoverageReason.SCREEN);
    root ++> cov;
    cov +>:Decided():+> Decision(ticker="AAA", action=TradeAction.BUY, conviction=0.42, thesis="Demand is turning.", risks=["Valuation.", "Rates.", "A third risk."], exit_condition="A close below 95.", time_stop="2026-11-04");
    cov +>:Concluded():+> ConsensusResult(ticker="AAA", score=0.45, agreement=0.8, ci_low=0.2, ci_high=0.6, draft_action=TradeAction.BUY);
    for (s, k, stance, conf) in [(Specialist.TECHNICAL, 1, Stance.BUY, 0.8), (Specialist.TECHNICAL, 0, Stance.STRONG_BUY, 0.9), (Specialist.MACRO, 0, Stance.HOLD, 0.5)] {
        cov +>:Voted():+> VoteRecord(ticker="AAA", specialist=s, sample=k, model="m", body=Vote(stance=stance, confidence=conf, horizon_days=10, rationale="r", cited_evidence=[1]));
    }
    cov +>:Researched():+> ResearchRecord(ticker="AAA", domain=Domain.NEWS, as_of="t", model="m", body=findings([("A product launch.", "https://news.example.com/a"), ("Same link.", "https://data.alpaca.markets/bars")]));
    cov +>:Researched():+> ResearchRecord(ticker="AAA", domain=Domain.MARKET, as_of="t", model="m", body=findings([("Above its 50-day average.", "https://data.alpaca.markets/bars")]));
    return cov;
}

test "a card carries the decision, the vote breakdown, the consensus, and market sources first" {
    card = render_card(covered(), "2026-10-21", "auto", "2026-10-21T13:00:00+00:00");
    assert card.action == TradeAction.BUY and card.conviction == 0.42 and card.mode == "auto" and card.run_date == "2026-10-21";
    assert card.thesis == "Demand is turning." and card.risks == ["Valuation.", "Rates."] and card.exit_condition == "A close below 95." and card.time_stop == "2026-11-04";
    assert (card.score, card.agreement, card.ci_low, card.ci_high) == (0.45, 0.8, 0.2, 0.6);
    assert [(t.specialist, t.stances) for t in card.specialists] == [("technical", ["STRONG_BUY", "BUY"]), ("macro", ["HOLD"])];
    assert abs(card.specialists[0].score - (0.9 + 0.4) / 2) < 1e-12 and card.specialists[1].score == 0.0;
    assert [s.url for s in card.sources] == ["https://data.alpaca.markets/bars", "https://news.example.com/a"];
    assert card.sources[1].domain == "news.example.com" and card.disclaimer == DISCLAIMER and card.note == "";
}

test "a forced hold explains itself, and a card is published once" {
    cov = Coverage(ticker="BBB", sector="", reason=CoverageReason.HELD);
    root ++> cov;
    cov +>:Decided():+> Decision(ticker="BBB", action=TradeAction.HOLD, conviction=0.0, thesis="No panel decision: insufficient data.", forced_hold_reason="insufficient data: no complete news research");
    first = publish_card(cov, "2026-10-21", "insight", "t1");
    again = publish_card(cov, "2026-10-21", "insight", "t2");
    assert again is first and len([cov ->:Published:->[?:InsightCard]]) == 1;
    assert first.note == "insufficient data: no complete news research" and first.score is None and first.specialists == [];
}

test "sources are capped, deduplicated, and labels are clipped" {
    cov = covered();
    many = [(f"Claim {i} " + "x" * 300, f"https://example.com/{i % 12}") for i in range(30)];
    cov +>:Researched():+> ResearchRecord(ticker="AAA", domain=Domain.FUNDAMENTALS, as_of="t", model="m", body=findings(many));
    card = render_card(cov, "2026-10-21", "auto", "t");
    assert len(card.sources) == MAX_SOURCES and len({s.url for s in card.sources}) == MAX_SOURCES;
    assert all(len(s.label) <= 160 for s in card.sources);
}
