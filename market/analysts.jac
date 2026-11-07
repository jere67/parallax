"""What the market pages take from Finnhub for a stock, reduced by the license's rule (TDD §6):
derived results, not its raw data. Analyst counts become one score and label, an EPS estimate
becomes a beat or a miss, and a market cap becomes a share count that the delayed price turns back
into a live market cap. The IPO date and website are public facts.
"""
import from research.collector { RunBudget, SourceClient }
import from research.finnhub { EpsSurprise, RecommendationTrend, company_profile, eps_surprises, recommendation_trends }

"""One reported quarter against the consensus, as how far it beat or missed."""
obj Surprise {
    has period: str,
        surprise_pct: float | None;
}

"""One month's analyst consensus."""
obj RatingPoint {
    has period: str,
        score: float,
        analysts: int;
}

"""A stock's Finnhub record. `implied_shares` is the market cap divided by the price that day, in
the units of this line's price, which is right for share classes and ADRs alike. It is None when
Finnhub's market cap is in another currency."""
obj AnalystRecord {
    has symbol: str,
        checked: str,
        implied_shares: float | None = None,
        ipo: str = "",
        website: str = "",
        score: float | None = None,
        analysts: int = 0,
        buy_share: float | None = None,
        trend: list[RatingPoint] = [],
        surprises: list[Surprise] = [];
}

"""The analysts' consensus from -1 (all strong sells) to 1 (all strong buys), or None with no
ratings."""
def consensus_score(trend: RecommendationTrend) -> float | None {
    total = trend.strong_buy + trend.buy + trend.hold + trend.sell + trend.strong_sell;
    if total == 0 {
        return None;
    }
    return (2 * trend.strong_buy + trend.buy - trend.sell - 2 * trend.strong_sell) / (2.0 * total);
}

"""The newest month's consensus and the month-by-month score, oldest first."""
def rating_of(record: AnalystRecord, trends: list[RecommendationTrend]) {
    points: list[RatingPoint] = [];
    for trend in trends[:12] {
        score = consensus_score(trend);
        if score is not None {
            points.append(RatingPoint(period=trend.period, score=score, analysts=trend.strong_buy + trend.buy + trend.hold + trend.sell + trend.strong_sell));
        }
    }
    record.trend = list(reversed(points));
    if trends and points {
        newest = trends[0];
        total = newest.strong_buy + newest.buy + newest.hold + newest.sell + newest.strong_sell;
        record.score = consensus_score(newest);
        record.analysts = total;
        record.buy_share = (newest.strong_buy + newest.buy) / total if total else None;
    }
}

"""A fresh record for `symbol`, three calls, with `price` to turn the market cap into shares."""
def analyst_record(symbol: str, price: float | None, today: str, budget: RunBudget, client: SourceClient | None = None) -> AnalystRecord {
    record = AnalystRecord(symbol=symbol, checked=today);
    profile = company_profile(symbol, budget, client);
    if profile is not None {
        record.ipo = profile.ipo;
        record.website = profile.website;
        if profile.currency == "USD" and profile.market_cap and price {
            record.implied_shares = profile.market_cap * 1e6 / price;
        }
    }
    rating_of(record, recommendation_trends(symbol, budget, client));
    found: list[EpsSurprise] = eps_surprises(symbol, budget, client);
    record.surprises = [Surprise(period=s.period, surprise_pct=s.surprise_percent) for s in reversed(found)];
    return record;
}
