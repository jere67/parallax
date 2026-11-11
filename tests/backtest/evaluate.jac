"""Run the historical harness (tests/backtest/harness.jac) on the cached history
(tests/backtest/fetch.jac) and write docs/evaluation/backtest.json.

The tuning was fixed before any result was seen (TDD §13; GAP-02 to GAP-05):

- Train on 2016-01-04 to 2022-12-30, validate on 2023-01-03 to 2026-10-30.
- Screen variants: V0 today's screen; V1 every z clipped to plus or minus 3; V2 log(1 + x) of
  news_3 and rvol_5 before z, every z clipped; V3 V2 without the news term; V4 V2 without the
  volatility penalty.
- Gate variants: the protective stop at 1.5, 2, or 3 ATRs, everything else unchanged.
- On train, take the screen with the highest mean spread, then, with it, the stop with the
  highest equal-weight Sharpe. Adopt each only if on validation it is at least as good as
  today's setting by point estimate (spread for the screen, Sharpe for the stop, under the
  chosen screen).

    TRADING_AGENT_RUN_BACKTEST=1 BACKTEST_CACHE=/path/to/cache BACKTEST_OUT=docs/evaluation/backtest.json \
        jac run --no-takeover tests/backtest/evaluate.jac

BACKTEST_THROUGH=YYYY-MM-DD stops the decision days early, for a quick check.
"""
import json;
import os;
import from datetime { datetime, timezone }
import from pathlib { Path }
import from action.gate { GateConfig }
import from models.graph { Run }
import from research.screener { SCREEN_VERSION, ScreenConfig, Shortlist, screen }
import from tests.backtest.data {
    BARS_START,
    current_members,
    earnings_dates,
    membership,
    news,
    past_tables,
    bars,
    say,
    sec_tickers,
    sessions
}
import from tests.backtest.fetch { BARS_END, FIRST_DAY, LAST_DAY, ever_members }
import from tests.backtest.harness {
    BENCHMARK,
    DayHit,
    LAST_HOLDINGS,
    Morning,
    Universe,
    daily_returns,
    day_hit,
    mean_interval,
    morning,
    news_index,
    performance,
    picked,
    prices_of,
    run_of,
    sharpe_gap_interval,
    simulate_benchmark,
    simulate_shortlist
}

glob RUN_ENV: str = "TRADING_AGENT_RUN_BACKTEST";
glob TRAIN: tuple[str, str] = ("2016-01-04", "2022-12-30");
glob VALIDATION: tuple[str, str] = ("2023-01-03", "2026-10-30");
glob CLIP: float = 3.0;
glob LOGGED: list[str] = ["news_3", "rvol_5"];
glob CURRENT_STOP: float = 2.0;
glob STOPS: list[float] = [1.5, 2.0, 3.0];
glob CURVE_EVERY: int = 5;

"""The pre-registered screen variants, by name, with what each changes."""
def screen_variants -> dict[str, tuple[ScreenConfig, dict[str, any]]] {
    base = ScreenConfig().weights;
    return {
        "V0": (ScreenConfig(), {"z_clip": None, "log_terms": [], "weights": base}),
        "V1": (ScreenConfig(z_clip=CLIP), {"z_clip": CLIP, "log_terms": [], "weights": base}),
        "V2": (ScreenConfig(z_clip=CLIP, log_terms=LOGGED), {"z_clip": CLIP, "log_terms": LOGGED, "weights": base}),
        "V3": (ScreenConfig(z_clip=CLIP, log_terms=LOGGED, weights={**base, "news_3": 0.0}), {"z_clip": CLIP, "log_terms": LOGGED, "weights": {**base, "news_3": 0.0}}),
        "V4": (ScreenConfig(z_clip=CLIP, log_terms=LOGGED, weights={**base, "vol_20": 0.0}), {"z_clip": CLIP, "log_terms": LOGGED, "weights": {**base, "vol_20": 0.0}})
    };
}

"""Everything one screen variant produced: each day's morning picks as a run, and its hit."""
obj Track {
    has runs: dict[str, Run] = {},
        hits: dict[str, DayHit] = {};
}

def in_period(day: str, period: tuple[str, str]) -> bool {
    return period[0] <= day <= period[1];
}

"""Hit-rate figures over `period`."""
def hit_summary(track: Track, period: tuple[str, str]) -> dict[str, any] {
    found = [track.hits[d] for d in sorted(track.hits) if in_period(d, period)];
    spreads = [h.spread() for h in found];
    (mean, interval) = mean_interval(spreads);
    return {
        "days": len(found),
        "spread": mean,
        "spread_ci": list(interval) if interval else None,
        "picks_mean": sum(h.picks_mean for h in found) / len(found) if found else None,
        "rest_mean": sum(h.rest_mean for h in found) / len(found) if found else None,
        "positive_days": len([s for s in spreads if s > 0])
    };
}

"""The portfolio figures of `points` with the interval of its Sharpe minus SPY's."""
def portfolio_summary(points: list[tuple[str, float]], spy: list[tuple[str, float]]) -> dict[str, any] {
    found: dict[str, any] = dict(performance(points));
    interval = sharpe_gap_interval(daily_returns(points), daily_returns(spy));
    found["sharpe_ci_vs_spy"] = list(interval) if interval else None;
    return found;
}

"""A figure for the reason text: a signed percentage, or a ratio to two places; "n/a" for none."""
def shown(value: float | None, percent: bool = False) -> str {
    if value is None {
        return "n/a";
    }
    return f"{value:+.3%}" if percent else f"{value:.2f}";
}

def thin(points: list[tuple[str, float]]) -> list[list[object]] {
    picked_ = [p for (i, p) in enumerate(points) if i % CURVE_EVERY == 0 or i == len(points) - 1];
    return [[d, round(e, 2)] for (d, e) in picked_];
}

with entry {
    if os.environ.get(RUN_ENV) == "1" {
        started = datetime.now(timezone.utc);
        through = os.environ.get("BACKTEST_THROUGH", LAST_DAY);
        all_sessions = sessions(BARS_START, BARS_END);
        days = [d for d in all_sessions if FIRST_DAY <= d <= LAST_DAY];
        (members, member_gaps) = membership(days);
        symbols = ever_members(members);
        tables = past_tables(list(range(2016, 2026)));
        current = current_members();
        listed = sec_tickers();
        companies: dict[str, str] = {s: listed[s] for s in symbols if s in listed};
        for t in tables.values() {
            for (s, row) in t.items() {
                if row.get("cik", "").isdigit() and s not in companies {
                    companies[s] = row["cik"].zfill(10);
                }
            }
        }
        for member in current {
            if str(member["cik"]).isdigit() {
                companies[member["symbol"]] = str(member["cik"]).zfill(10);
            }
        }
        releases = earnings_dates(sorted(set(companies.values())), "2015-12-01");
        universe = Universe(
            members=members,
            sectors={y: {s: row["sector"] for (s, row) in t.items() if row.get("sector")} for (y, t) in tables.items()},
            current_sectors={c["symbol"]: c["sector"] for c in current},
            companies=companies,
            releases=releases
        );
        history = bars(symbols + [BENCHMARK], BARS_END);
        prices = {s: prices_of(s, b) for (s, b) in history.items()};
        articles = news(symbols, "2015-12-01", LAST_DAY);
        index = news_index([row for month in articles.values() for row in month]);
        say(f"loaded {len(prices)} price histories, {sum(len(v) for v in articles.values())} articles, {len(releases)} companies' releases");

        variants = screen_variants();
        tracks = {name: Track() for name in variants};
        member_days = 0;
        with_bars = 0;
        unknown_sector = 0;
        no_company = 0;
        decided: list[str] = [];
        for (k, day) in enumerate(all_sessions) {
            if day < FIRST_DAY or day > through or k < 3 {
                continue;
            }
            m = morning(k, all_sessions, universe, prices, index);
            member_days += len(m.candidates);
            with_bars += len(m.inputs);
            unknown_sector += len([s for s in m.sectors.values() if s.startswith("Unknown")]);
            no_company += len([c for c in m.candidates if c.company == c.symbol]);
            any_picks = False;
            for (name, (config, _)) in variants.items() {
                shortlist = screen(m.candidates, [], config);
                if picked(shortlist) {
                    any_picks = True;
                    tracks[name].runs[day] = run_of(m, shortlist);
                }
                hit = day_hit(day, shortlist, all_sessions, prices);
                if hit is not None {
                    tracks[name].hits[day] = hit;
                }
            }
            if any_picks {
                decided.append(day);
            }
            if len(decided) % 250 == 1 {
                say(f"screened through {day}");
            }
        }
        say(f"screened {len(decided)} decision days");

        periods = {"train": TRAIN, "validation": VALIDATION};
        sim_days = {p: [d for d in all_sessions if in_period(d, span) and d <= through] for (p, span) in periods.items()};
        spy = {p: simulate_benchmark(sim_days[p], all_sessions, prices) for p in periods};
        def run_sim(name: str, stop: float, period: str) -> list[tuple[str, float]] {
            points = simulate_shortlist(sim_days[period], tracks[name].runs, all_sessions, prices, GateConfig(stop_atr_multiple=stop));
            holdings[f"{name}:{stop}:{period}"] = dict(LAST_HOLDINGS[0]);
            return points;
        }
        holdings: dict[str, dict[str, float]] = {};
        curves: dict[str, list[tuple[str, float]]] = {};
        results: list[dict[str, any]] = [];
        screen_rows: dict[str, dict[str, any]] = {};
        for (name, (_, described)) in variants.items() {
            row: dict[str, any] = {"name": name, "kind": "screen", "config": {**described, "stop_atr_multiple": CURRENT_STOP}};
            for (period, span) in periods.items() {
                points = run_sim(name, CURRENT_STOP, period);
                curves[f"{name}:{CURRENT_STOP}:{period}"] = points;
                row[period] = {**hit_summary(tracks[name], span), "portfolio": {**portfolio_summary(points, spy[period]), **holdings.get(f"{name}:{CURRENT_STOP}:{period}", {})}};
            }
            screen_rows[name] = row;
            results.append(row);
            say(f"{name}: train spread {row['train']['spread']}, validation spread {row['validation']['spread']}");
        }
        chosen_screen = max(variants, key=lambda (n: str) { screen_rows[n]["train"]["spread"] if screen_rows[n]["train"]["spread"] is not None else -1.0; });
        gate_rows: dict[float, dict[str, any]] = {};
        for stop in STOPS {
            row: dict[str, any] = {"name": f"{chosen_screen}, stop {stop} ATR", "kind": "gate", "config": {"screen": chosen_screen, "stop_atr_multiple": stop}};
            for (period, span) in periods.items() {
                key = f"{chosen_screen}:{stop}:{period}";
                points = curves.get(key) or run_sim(chosen_screen, stop, period);
                curves[key] = points;
                row[period] = {**hit_summary(tracks[chosen_screen], span), "portfolio": {**portfolio_summary(points, spy[period]), **holdings.get(key, {})}};
            }
            gate_rows[stop] = row;
            results.append(row);
        }
        def train_sharpe(stop: float) -> float {
            found = gate_rows[stop]["train"]["portfolio"]["sharpe"];
            return found if found is not None else -99.0;
        }
        chosen_stop = max(STOPS, key=train_sharpe);
        current_spread = screen_rows["V0"]["validation"]["spread"];
        chosen_spread = screen_rows[chosen_screen]["validation"]["spread"];
        adopt_screen = chosen_screen != "V0" and chosen_spread is not None and current_spread is not None and chosen_spread >= current_spread;
        current_sharpe = gate_rows[CURRENT_STOP]["validation"]["portfolio"]["sharpe"];
        chosen_sharpe = gate_rows[chosen_stop]["validation"]["portfolio"]["sharpe"];
        adopt_stop = chosen_stop != CURRENT_STOP and chosen_sharpe is not None and current_sharpe is not None and chosen_sharpe >= current_sharpe;
        reasons: list[str] = [];
        if chosen_screen == "V0" {
            reasons.append("Today's screen (V0) had the highest train spread, so there is nothing to adopt.");
        } else {
            reasons.append(f"{chosen_screen} had the highest train spread; on validation its spread was {shown(chosen_spread, True)} against V0's {shown(current_spread, True)}, so it is {'adopted' if adopt_screen else 'not adopted'}.");
        }
        if chosen_stop == CURRENT_STOP {
            reasons.append(f"With {chosen_screen}, the 2 ATR stop had the highest train Sharpe, so the stop stays.");
        } else {
            reasons.append(f"With {chosen_screen}, a {chosen_stop} ATR stop had the highest train Sharpe; on validation its Sharpe was {shown(chosen_sharpe)} against {shown(current_sharpe)} at 2 ATR, so it is {'adopted' if adopt_stop else 'not adopted'}.");
        }
        coverage = with_bars / member_days if member_days else 0.0;
        out = {
            "generated_at": datetime.now(timezone.utc).isoformat(),
            "screen_version": SCREEN_VERSION,
            "train": list(TRAIN),
            "validation": list(VALIDATION),
            "data": {
                "symbols": len(symbols),
                "sessions": len(days),
                "decision_days": len(decided),
                "coverage": coverage,
                "missing_symbols": sorted(s for s in symbols if s not in prices),
                "news": "daily",
                "notes": [
                    f"Alpaca's daily bars start on {min(p.days[0] for p in prices.values())}, so the 60-session momentum term is missing (z = 0) until early April 2016 and no name is liquid before its 20th session.",
                    f"{coverage:.1%} of member-days had a bar on the session before the decision; the rest were untradable that morning.",
                    f"{unknown_sector / member_days:.2%} of member-days had no GICS sector in any yearly table, so the three-per-sector cap never bound them." if member_days else "",
                    f"{no_company / member_days:.2%} of member-days had no CIK, so they never got the earnings flag and their share classes were not joined." if member_days else "",
                    f"Membership is rebuilt from Wikipedia's dated changes; {len(member_gaps)} changes could not be undone exactly: " + "; ".join(member_gaps[:6]),
                    "The earnings flag reads 8-K Item 2.02 filing dates as the calendar's release dates.",
                    "Fills are at the session's open with no slippage or commissions, and a stop fills at the stop or a lower open, as the live baseline simulates."
                ]
            },
            "variants": results,
            "spy": {p: performance(spy[p]) for p in periods},
            "current": {"screen": "V0", "stop_atr_multiple": CURRENT_STOP},
            "chosen": {"screen": chosen_screen, "stop_atr_multiple": chosen_stop},
            "adopted": {"screen": adopt_screen, "stop_atr_multiple": adopt_stop},
            "reason": " ".join(reasons),
            "curves": {
                "validation": {
                    "current": thin(curves[f"V0:{CURRENT_STOP}:validation"]),
                    "chosen": thin(curves.get(f"{chosen_screen}:{chosen_stop}:validation") or []),
                    "spy": thin(spy["validation"])
                }
            },
            "runtime_s": (datetime.now(timezone.utc) - started).total_seconds()
        };
        out["data"]["notes"] = [n for n in out["data"]["notes"] if n];
        target = Path(os.environ.get("BACKTEST_OUT", "docs/evaluation/backtest.json"));
        target.parent.mkdir(parents=True, exist_ok=True);
        target.write_text(json.dumps(out, indent=1) + "\n");
        say(f"wrote {target}: chosen {chosen_screen} at {chosen_stop} ATR; adopted screen {adopt_screen}, stop {adopt_stop}");
    }
}
