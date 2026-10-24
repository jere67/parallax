"""Contract tests for the specialist panel with MockLLM standing in for the role models (TDD
§14): packets, shuffled evidence, cited indices mapped back, the retry path, and dropped
samples. Run serially, since concurrent calls would take scripted outputs in random order."""
import json;
import agents.specialists as specialists_module;
import from jaclang.byllm.lib { MockError, MockLLM, MockRawResponse }
import from agents.models { retry_llm, specialist_llm }
import from agents.specialists { Packet, VoteResult, packet, sample_vote }
import from models.agents { Domain, Evidence, MacroReport, ResearchReport, RiskRegime, Specialist, Stance }

def evidence(tag: str, n: int) -> list[Evidence] {
    return [Evidence(claim=f"{tag} fact {i}.", source_url=f"https://example.com/{tag}/{i}", published="2026-10-14") for i in range(n)];
}

def reports -> dict[Domain, ResearchReport] {
    return {
        Domain.MARKET: ResearchReport(summary="Uptrend above all averages.", view=Stance.STRONG_BUY, confidence=0.9, evidence=evidence("market", 3), risks=["Overbought."], data_gaps=["No intraday data."]),
        Domain.FUNDAMENTALS: ResearchReport(summary="Margins expanding; two insiders sold.", view=Stance.BUY, confidence=0.7, evidence=evidence("funda", 4)),
        Domain.NEWS: ResearchReport(summary="Quiet week.", view=Stance.HOLD, confidence=0.4, evidence=evidence("news", 2))
    };
}

def macro -> MacroReport {
    return MacroReport(summary="Calm, rising market.", regime=RiskRegime.RISK_ON, confidence=0.6, evidence=evidence("macro", 2));
}

def vote_json(cited: list[int], stance: str = "BUY", confidence: float = 0.7) -> str {
    return json.dumps({"stance": stance, "confidence": confidence, "horizon_days": 10, "rationale": "Margins are expanding.", "cited_evidence": cited});
}

"""Run `sample_vote` with mock role models scripted with `primary` and `retry` outputs."""
def with_mocks(p: Packet, sample: int, primary: list[object], retry: list[object]) -> tuple[VoteResult, MockLLM, MockLLM] {
    main = MockLLM(model_name="mock-specialist", config={"outputs": primary});
    backup = MockLLM(model_name="mock-retry", config={"outputs": retry});
    saved = (specialists_module.specialist_llm, specialists_module.retry_llm);
    setattr(specialists_module, "specialist_llm", main);
    setattr(specialists_module, "retry_llm", backup);
    try {
        return (sample_vote(p, sample), main, backup);
    } finally {
        setattr(specialists_module, "specialist_llm", saved[0]);
        setattr(specialists_module, "retry_llm", saved[1]);
    }
}

def funda_packet -> Packet {
    return packet(Specialist.FUNDAMENTALS, "AAPL", "2026-10-16", reports(), macro());
}

test "each specialist reads its own reports, with no research view or confidence" {
    funda = funda_packet();
    assert [e.source_url for e in funda.evidence] == [f"https://example.com/funda/{i}" for i in range(4)];
    assert "Margins expanding" in funda.research and "Uptrend" not in funda.research;
    assert "BUY" not in funda.research and "0.7" not in funda.research;
    technical = packet(Specialist.TECHNICAL, "AAPL", "2026-10-16", reports(), macro());
    assert "Risks: Overbought." in technical.research and "Data gaps: No intraday data." in technical.research;
    # Macro reads the run's macro report and the stock's market report, in that order.
    sector = packet(Specialist.MACRO, "AAPL", "2026-10-16", reports(), macro());
    assert [e.source_url.split("/")[3] for e in sector.evidence] == ["macro", "macro", "market", "market", "market"];
    assert "not this stock" in sector.research;
    positioning = packet(Specialist.FLOW, "AAPL", "2026-10-16", reports(), macro());
    assert [e.source_url for e in positioning.evidence] == [e.source_url for e in funda.evidence];
}

test "a missing report is named and adds no evidence" {
    found = reports();
    del found[Domain.MARKET];
    sector = packet(Specialist.MACRO, "AAPL", "2026-10-16", found, None);
    assert sector.evidence == [];
    assert "Missing research: macro, market." in sector.research;
}

test "each sample shows the evidence in its own fixed order" {
    p = packet(Specialist.MACRO, "AAPL", "2026-10-16", reports(), macro());
    orders = [p.order(k) for k in range(5)];
    assert all(sorted(o) == list(range(5)) for o in orders);
    assert len({tuple(o) for o in orders}) > 1;
    assert orders[2] == p.order(2);
    shown = p.render_evidence(orders[0]).split("\n");
    assert shown[0].startswith("[1] ") and shown[4].startswith("[5] ");
    assert p.evidence[orders[0][0]].claim in shown[0];
}

test "a valid vote cites the packet's own indices, mapped from the numbers it was shown" {
    p = funda_packet();
    shown = p.order(1);
    (result, main, _) = with_mocks(p, 1, [MockRawResponse(content=vote_json([2, 1]))], []);
    assert not result.retried and result.model == "mock-specialist";
    cast = result.vote;
    assert cast is not None;
    assert cast.cited_evidence == sorted([shown[1], shown[0]]);
    assert (cast.stance, cast.confidence, cast.horizon_days) == (Stance.BUY, 0.7, 10);
    prompt = main.seen_prompts[0];
    assert "Fundamentals: valuation, growth" in prompt and "2026-10-16" in prompt;
    assert f"[1] {p.evidence[shown[0]].claim}" in prompt;
}

test "numbers out of range are ignored, and a vote with none in range is dropped" {
    p = funda_packet();
    (partly, _, _) = with_mocks(p, 0, [MockRawResponse(content=vote_json([3, 9, 0]))], []);
    kept = partly.vote;
    assert kept is not None and kept.cited_evidence == [p.order(0)[2]];
    (dropped, _, _) = with_mocks(p, 0, [MockRawResponse(content=vote_json([9, 0]))], []);
    assert not dropped.valid() and dropped.error == "cited no evidence item in range: [9, 0]";
}

test "a vote that cites nothing is retried with feedback, then through the retry model" {
    uncited = MockRawResponse(content=vote_json([]));
    (result, main, backup) = with_mocks(funda_packet(), 0, [uncited, uncited], [MockRawResponse(content=vote_json([1]))]);
    assert result.valid() and result.retried and result.model == "mock-retry";
    assert "cited_evidence must list at least one evidence number" in main.seen_prompts[1];
    assert len(backup.seen_prompts) == 1;
}

test "a second failure, or a provider error, drops the sample" {
    bad = MockRawResponse(content="no json");
    (failed, _, _) = with_mocks(funda_packet(), 0, [bad, bad], [bad, bad]);
    assert not failed.valid() and failed.retried and failed.error.startswith("OutputConversionError");
    (down, _, backup) = with_mocks(funda_packet(), 0, [MockError(error=ConnectionError("provider down"))], [MockRawResponse(content=vote_json([1]))]);
    assert not down.valid() and not down.retried and down.error == "ConnectionError: provider down";
    assert backup.seen_prompts == [];
}

test "a packet with no evidence makes no model request" {
    empty = packet(Specialist.MACRO, "AAPL", "2026-10-16", {}, None);
    (result, main, _) = with_mocks(empty, 0, [MockRawResponse(content=vote_json([1]))], []);
    assert not result.valid() and result.error == "no evidence to judge";
    assert main.seen_prompts == [];
}

test "the specialist and retry roles are the shared limited instances" {
    assert specialists_module.specialist_llm is specialist_llm and specialists_module.retry_llm is retry_llm;
}

test "Flow may HOLD on an exact supplied gap without inventing factual evidence" {
    gap = "SEC insider transaction data is unavailable.";
    p = Packet(specialist=Specialist.FLOW, ticker="AAPL", as_of="2026-10-16", research="Insider inputs missing.", evidence=[], data_gaps=[gap]);
    response = json.dumps({"stance": "HOLD", "confidence": 0.3, "horizon_days": 10, "rationale": "Missing inputs prevent a directional view.", "cited_evidence": [], "cited_gaps": [gap]});
    (result, main, backup) = with_mocks(p, 0, [MockRawResponse(content=response)], []);
    assert result.valid() and not result.retried;
    assert result.vote is not None and result.vote.cited_evidence == [];
    assert result.vote.cited_gaps == [gap] and result.vote.stance == Stance.HOLD;
    assert gap in main.seen_prompts[0];
    assert len(main.seen_prompts) == 1 and backup.seen_prompts == [];
}

test "invented gaps and gaps offered to another specialist cannot validate a vote" {
    gap = "No insider data.";
    response = json.dumps({"stance": "HOLD", "confidence": 0.2, "horizon_days": 10, "rationale": "Missing data.", "cited_evidence": [], "cited_gaps": [gap]});
    flow_packet = funda_packet();
    flow_packet.specialist = Specialist.FLOW;
    flow_packet.data_gaps = ["Some other gap."];
    (invented, _, _) = with_mocks(flow_packet, 0, [MockRawResponse(content=response)], []);
    assert not invented.valid();
    funda = funda_packet();
    funda.data_gaps = [gap];
    (wrong_role, _, _) = with_mocks(funda, 0, [MockRawResponse(content=response)], []);
    assert not wrong_role.valid();
}

test "Flow packet gaps remain distinct from sourced evidence and survive on the vote" {
    found = reports();
    found[Domain.FUNDAMENTALS].data_gaps = ["No insider data."];
    p = packet(Specialist.FLOW, "AAPL", "2026-10-16", found, None);
    assert p.data_gaps == ["No insider data."];
    assert len(p.evidence) == 4 and all("No insider data" not in e.claim for e in p.evidence);
}

test "a dropped sample preserves the whole validation error from both role attempts" {
    primary = "primary " + "x" * 600 + " missing citation at the end";
    retry = "retry " + "y" * 600 + " invalid horizon at the end";
    import from jaclang.byllm.lib { OutputConversionError }
    (result, _, _) = with_mocks(funda_packet(), 0, [MockError(error=OutputConversionError(primary))] * 2, [MockError(error=OutputConversionError(retry))] * 2);
    assert not result.valid() and result.retried;
    assert "missing citation at the end" in result.error;
    assert "invalid horizon at the end" in result.error;
}
