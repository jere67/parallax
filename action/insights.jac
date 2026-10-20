"""Insight cards (TDD §8, insight mode; FR-11): each covered ticker's decision as a reader sees
it, rendered from what the run stored, with no model request.

A card holds the action and conviction, each specialist's samples and mean score, the
consensus score, agreement, and 90% interval, the Arbiter's thesis, the two key risks, the
exit condition and time stop, links to the research's sources, and the disclaimer. The
morning run publishes one per coverage, in both portfolio modes: in auto mode the card sits
beside the orders, and in insight mode it is the run's only output. On-demand reports reuse
`render_card`.
"""
import statistics;
import from urllib.parse { urlsplit }
import from analysis.consensus { signed_score }
import from models.agents { Domain, Specialist }
import from models.graph {
    Concluded,
    ConsensusResult,
    Coverage,
    Decided,
    Decision,
    InsightCard,
    Published,
    Researched,
    ResearchRecord,
    SourceLink,
    SpecialistTally,
    VoteRecord,
    Voted
}
import from run.public { public }

glob DISCLAIMER: str = "An educational student project trading simulated money. Nothing here is investment advice, and past simulated performance does not predict future results.";
glob MAX_SOURCES: int = 8;
glob MAX_LABEL_CHARS: int = 160;
# Sources are listed in this order, so a card leads with the evidence nearest the price.
glob DOMAIN_ORDER: list[Domain] = [Domain.MARKET, Domain.FUNDAMENTALS, Domain.NEWS, Domain.MACRO];

"""The card for `coverage`'s decision in the run for `run_day`, not yet attached."""
def render_card(coverage: Coverage, run_day: str, mode: str, published_at: str) -> InsightCard {
    decided = [d for d in [coverage ->:Decided:->[?:Decision]]];
    if not decided {
        raise ValueError(f"{coverage.ticker}: no decision to render");
    }
    d = decided[0];
    found = [c for c in [coverage ->:Concluded:->[?:ConsensusResult]]];
    c = found[0] if found else None;
    card = InsightCard(
        ticker=coverage.ticker,
        action=d.action,
        conviction=d.conviction,
        published_at=published_at,
        run_date=run_day,
        mode=mode,
        thesis=d.thesis,
        risks=d.risks[:2],
        exit_condition=d.exit_condition,
        time_stop=d.time_stop,
        score=c.score if c is not None else None,
        agreement=c.agreement if c is not None else None,
        ci_low=c.ci_low if c is not None else None,
        ci_high=c.ci_high if c is not None else None,
        specialists=tallies([v for v in [coverage ->:Voted:->[?:VoteRecord]]]),
        sources=sources([r for r in [coverage ->:Researched:->[?:ResearchRecord]]]),
        note=d.forced_hold_reason or (f"Downgraded by the Arbiter: {d.downgrade_reason}" if d.downgrade_reason else ""),
        disclaimer=DISCLAIMER
    );
    return card;
}

"""Each specialist's samples in panel order, and their mean signed score."""
def tallies(votes: list[VoteRecord]) -> list[SpecialistTally] {
    found: list[SpecialistTally] = [];
    for s in list(Specialist) {
        mine = sorted([v for v in votes if v.specialist == s], key=lambda (v: VoteRecord) { v.sample; });
        if mine {
            found.append(SpecialistTally(
                specialist=s.value,
                score=statistics.fmean(signed_score(v.body) for v in mine),
                stances=[v.body.stance.value for v in mine],
                confidences=[v.body.confidence for v in mine]
            ));
        }
    }
    return found;
}

"""Up to MAX_SOURCES distinct sources the research cited, market first. A follow-up's
report comes after the first report of its domain."""
def sources(records: list[ResearchRecord]) -> list[SourceLink] {
    seen: set[str] = set();
    links: list[SourceLink] = [];
    for domain in DOMAIN_ORDER {
        for r in [r for r in records if r.domain == domain] {
            for e in r.body.evidence {
                if e.source_url in seen or len(links) >= MAX_SOURCES {
                    continue;
                }
                seen.add(e.source_url);
                label = " ".join(e.claim.split());
                links.append(SourceLink(
                    label=label if len(label) <= MAX_LABEL_CHARS else label[:MAX_LABEL_CHARS - 1].rstrip() + "…",
                    url=e.source_url,
                    published=e.published,
                    domain=urlsplit(e.source_url).hostname or ""
                ));
            }
        }
    }
    return links;
}

"""Publish `coverage`'s card, once: a second call returns the card already published."""
def publish_card(coverage: Coverage, run_day: str, mode: str, published_at: str) -> InsightCard {
    for existing in [coverage ->:Published:->[?:InsightCard]] {
        return existing;
    }
    return public(coverage +>:Published():+> render_card(coverage, run_day, mode, published_at));
}
