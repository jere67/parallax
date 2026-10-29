"""Demo history for local development (#105): a few weeks of made-up trading in the team graph,
so the dashboard can be built and checked before the forward test stores real data.

The prices are a seeded random walk, and the research and votes are templates, but every
number after them comes from the project's own rules: the consensus engine and decision rule
turn the votes into draft actions, the sizing and the risk gate turn decisions into orders,
the baselines are simulated by action/baselines.jac, and the votes are scored by
analysis/scoring.jac. Orders fill at each session's open, stops fire on its low, and the
portfolio is marked at its close, the way the executor and reconciliation record them.

It runs only inside a local server started with TRADING_AGENT_DEMO=1, from a scheduled job,
since only the server's own context reaches the team graph on root.shared. It writes nothing
when the team portfolio has any run, mark, or baseline, and flags the portfolio it fills as
`demo`, so the dashboard says the numbers are made up. Never set the variable on a deployed
server.
"""
import logging;
import math;
import os;
import random;
import statistics;
import threading;
import from datetime { date, datetime, time, timedelta, timezone }
import from action.baselines { SimDay, baselines_of, simulate_equal_weight, simulate_spy }
import from action.executor { limit_price, order_id_for, run_regime, stop_id_for }
import from action.gate { Book, BookPosition, GATE_VERSION, GateConfig, GateResult, Instrument, Proposal, check_orders }
import from action.insights { publish_card }
import from action.sizing { SizingCandidate, size_positions }
import from agents.models { FALLBACK_MODEL, PRIMARY_MODEL }
import from agents.specialists { packet }
import from analysis.consensus { CONSENSUS_VERSION, consensus, draft_action }
import from analysis.history { bar }
import from dashboard.ui.format { count }
import from analysis.scoring { BENCHMARK, excess_return, vote_window }
import from models.agents { Domain, Evidence, MacroReport, ResearchReport, RiskRegime, Specialist, Stance, Vote }
import from models.graph {
    Baseline,
    BaselineKind,
    Benchmarks,
    CheckedBy,
    Concluded,
    ConsensusResult,
    Coverage,
    CoverageReason,
    Covers,
    DailyMark,
    Decided,
    Decision,
    Fill,
    FilledBy,
    HasMacro,
    Holds,
    MacroRecord,
    Marked,
    OpenedBy,
    Order,
    OrderPurpose,
    OrderSide,
    Placed,
    Portfolio,
    PortfolioMode,
    Position,
    Ran,
    Researched,
    ResearchRecord,
    RiskCheck,
    Run,
    RunStatus,
    Sent,
    StoppedBy,
    TradeAction,
    VoteRecord,
    Voted
}
import from models.research { RegimeInputs }
import from research.alpaca { Bar }
import from run.analysis { DEFAULT_HORIZON_DAYS, trading_day_after }
import from run.guard { NEW_YORK, TEAM_PORTFOLIO }
import from run.public { public }

glob DEMO_ENV: str = "TRADING_AGENT_DEMO";
glob LOG: logging.Logger = logging.getLogger("trading_agent.demo");
glob _SEEDING: threading.Lock = threading.Lock();
glob NOTHING_WRITTEN: str = "demo: the team portfolio already has history; nothing written";
# Sessions of history, ending with the last weekday before the day it is seeded.
glob DEMO_SESSIONS: int = 23;
# Sessions of prices before the first run, for the 20-day figures the first run reads.
glob WARMUP_SESSIONS: int = 30;
glob STARTING_CASH: float = 100000.0;
glob SHORTLIST: int = 6;
glob SAMPLES: int = 3;
# Which session (counting from the first) the Orchestrator ran out of budget on.
glob FALLBACK_SESSION: int = 9;

"""A stock in the demo universe: its sector, its first price, and its daily drift and
volatility. `cik` names its SEC filer, for the research's source links."""
obj DemoStock {
    has ticker: str,
        name: str,
        sector: str,
        price: float,
        drift: float,
        vol: float,
        cik: str,
        volume: float;
}

glob UNIVERSE: list[DemoStock] = [
    DemoStock(ticker="AAPL", name="Apple_Inc.", sector="Information Technology", price=228.0, drift=0.0006, vol=0.014, cik="320193", volume=5.2e7),
    DemoStock(ticker="MSFT", name="Microsoft", sector="Information Technology", price=418.0, drift=0.0005, vol=0.013, cik="789019", volume=2.1e7),
    DemoStock(ticker="NVDA", name="Nvidia", sector="Information Technology", price=138.0, drift=0.0012, vol=0.028, cik="1045810", volume=2.4e8),
    DemoStock(ticker="AVGO", name="Broadcom", sector="Information Technology", price=172.0, drift=0.0009, vol=0.024, cik="1730168", volume=2.6e7),
    DemoStock(ticker="AMZN", name="Amazon_(company)", sector="Consumer Discretionary", price=186.0, drift=0.0007, vol=0.018, cik="1018724", volume=4.1e7),
    DemoStock(ticker="HD", name="Home_Depot", sector="Consumer Discretionary", price=395.0, drift=0.0002, vol=0.012, cik="354950", volume=3.4e6),
    DemoStock(ticker="GOOGL", name="Alphabet_Inc.", sector="Communication Services", price=165.0, drift=0.0006, vol=0.017, cik="1652044", volume=2.6e7),
    DemoStock(ticker="JPM", name="JPMorgan_Chase", sector="Financials", price=214.0, drift=0.0005, vol=0.012, cik="19617", volume=9.1e6),
    DemoStock(ticker="XOM", name="ExxonMobil", sector="Energy", price=117.0, drift=-0.0004, vol=0.014, cik="34088", volume=1.5e7),
    DemoStock(ticker="LLY", name="Eli_Lilly_and_Company", sector="Health Care", price=905.0, drift=0.0003, vol=0.019, cik="59478", volume=3.2e6),
    DemoStock(ticker="UNH", name="UnitedHealth_Group", sector="Health Care", price=560.0, drift=-0.0008, vol=0.016, cik="731766", volume=3.6e6),
    DemoStock(ticker="COST", name="Costco", sector="Consumer Staples", price=890.0, drift=0.0004, vol=0.010, cik="909832", volume=1.9e6),
    DemoStock(ticker="CAT", name="Caterpillar_Inc.", sector="Industrials", price=352.0, drift=0.0003, vol=0.016, cik="18230", volume=2.4e6),
    DemoStock(ticker="NEE", name="NextEra_Energy", sector="Utilities", price=79.0, drift=0.0002, vol=0.013, cik="753308", volume=1.0e7)
];
glob SPY_START: float = 575.0;

"""Seeds the demo history once a minute is up, when the server runs with TRADING_AGENT_DEMO=1.
Static jobs reach root.shared, which a standalone script cannot (it sees the super root). A seed
takes about a minute and commits only when its job ends, so the next minute's job skips while
one is running rather than find an empty graph and seed a second team portfolio."""
@schedule(trigger=ScheduleTrigger.STATIC, cron="* * * * *")
def demo_job {
    if os.environ.get(DEMO_ENV, "").strip() != "1" or not _SEEDING.acquire(blocking=False) {
        return;
    }
    try {
        done = seed_demo(datetime.now(NEW_YORK).date());
        if done != NOTHING_WRITTEN {
            LOG.warning("%s", done);
        }
    } finally {
        _SEEDING.release();
    }
}

"""Fill the team graph with demo history ending the last weekday before `today`, unless the
team portfolio already holds anything. Returns what it did."""
def seed_demo(today: date) -> str {
    found = [p for p in [root.shared -->[?:Portfolio]] if p.name == TEAM_PORTFOLIO];
    if found and (found[0].demo or [found[0] ->:Ran:->] or [found[0] ->:Marked:->] or [found[0] ->:Benchmarks:->]) {
        return NOTHING_WRITTEN;
    }
    portfolio = found[0] if found else public(root.shared ++> Portfolio(name=TEAM_PORTFOLIO, mode=PortfolioMode.AUTO, starting_cash=STARTING_CASH, opened_at=""));
    sim = DemoSim(portfolio=portfolio, today=today);
    sim.run();
    return f"demo: wrote {len(sim.days)} sessions, {sim.decisions} decisions, {sim.orders} orders; equity {sim.cash + sim.positions_value(sim.days[-1]):,.2f}";
}

"""`n` weekdays ending the last weekday before `today`, then `ahead` weekdays after it."""
def weekdays_before(today: date, n: int, ahead: int = 0) -> list[str] {
    found: list[str] = [];
    day = today - timedelta(days=1);
    while len(found) < n {
        if day.weekday() < 5 {
            found.append(day.isoformat());
        }
        day -= timedelta(days=1);
    }
    found.reverse();
    day = today;
    extra = 0;
    while extra < ahead {
        if day.weekday() < 5 {
            found.append(day.isoformat());
            extra += 1;
        }
        day += timedelta(days=1);
    }
    return found;
}

"""A New York wall-clock time on `day`, as an ISO timestamp in UTC."""
def at(day: str, hhmm: str) -> str {
    local = datetime.combine(date.fromisoformat(day), time.fromisoformat(hhmm), NEW_YORK);
    return local.astimezone(timezone.utc).isoformat();
}

def stance_for(x: float) -> Stance {
    if x > 0.5 {
        return Stance.STRONG_BUY;
    }
    if x > 0.14 {
        return Stance.BUY;
    }
    if x > -0.14 {
        return Stance.HOLD;
    }
    return Stance.SELL if x > -0.5 else Stance.STRONG_SELL;
}

glob RATIONALE: dict[Specialist, dict[int, str]] = {
    Specialist.FUNDAMENTALS: {
        1: "Margins held up in the latest quarter and guidance was raised, so earnings support the price.",
        0: "Growth is steady but already priced in at this multiple; nothing in the filings moves the case either way.",
        -1: "Revenue growth is slowing and the multiple leaves little room for a miss next quarter."
    },
    Specialist.TECHNICAL: {
        1: "Price is above a rising 50-day average with momentum confirming, and volatility is contained.",
        0: "Price is chopping around its 50-day average with no clear trend in either direction.",
        -1: "Price broke below its 50-day average on rising volume, and momentum has turned down."
    },
    Specialist.NEWS: {
        1: "Coverage this week was mostly positive, led by product and demand stories, with no new legal risk.",
        0: "News flow was light and mixed, with nothing that changes the outlook.",
        -1: "Recent coverage leans negative, with regulatory and demand concerns in several articles."
    },
    Specialist.MACRO: {
        1: "A risk-on tape and easing yields favor this sector over the horizon.",
        0: "The macro backdrop is neutral for this sector; rates and growth roughly offset.",
        -1: "Rising yields and a defensive rotation are headwinds for this sector."
    },
    Specialist.FLOW: {
        1: "Volume is running above its 20-day average on up days, a sign of accumulation.",
        0: "Volume and price action show no clear accumulation or distribution.",
        -1: "Heavy volume on down days suggests distribution."
    }
};

"""The simulation: a price tape, then one session at a time, the morning run, the 9:45
execution, the day's stops, the close's mark, and the evening's baselines."""
obj DemoSim {
    has portfolio: Portfolio,
        today: date;
    has rng: random.Random = random.Random(0),
        sessions: list[str] = [],
        days: list[str] = [],
        calendar: list[str] = [],
        bars: dict[str, dict[str, Bar]] = {},
        stocks: dict[str, DemoStock] = {},
        bias: dict[str, float] = {},
        cash: float = STARTING_CASH,
        peak: float = STARTING_CASH,
        decisions: int = 0,
        orders: int = 0,
        macro_body: MacroReport | None = None;

    def postinit {
        self.rng = random.Random(449);
        self.stocks = {s.ticker: s for s in UNIVERSE};
        self.bias = {s.ticker: self.rng.gauss(0.15, 0.25) for s in UNIVERSE};
        self.sessions = weekdays_before(self.today, WARMUP_SESSIONS + DEMO_SESSIONS);
        self.days = self.sessions[WARMUP_SESSIONS:];
        self.calendar = weekdays_before(self.today, WARMUP_SESSIONS + DEMO_SESSIONS, 60);
    }

    def run {
        self.make_tape();
        p = self.portfolio;
        start = self.days[0];
        p.demo = True;
        p.mode = PortfolioMode.AUTO;
        p.starting_cash = STARTING_CASH;
        p.opened_at = at(start, "09:00");
        p.peak_equity = STARTING_CASH;
        for kind in [BaselineKind.EQUAL_WEIGHT, BaselineKind.SPY] {
            public(p +>:Benchmarks:+> Baseline(kind=kind, starting_cash=STARTING_CASH, start_day=start, cash=STARTING_CASH, peak_equity=STARTING_CASH));
        }
        for (i, day) in enumerate(self.days) {
            run = self.morning(i, day);
            log = self.execute(run, day);
            log.extend(self.stops(day));
            log.extend(self.close(run, day));
            run.action_log = log;
        }
        self.score_votes();
    }

    """Daily bars for every stock and SPY: a market factor plus each stock's own move."""
    def make_tape {
        prices = {s.ticker: s.price for s in UNIVERSE};
        spy = SPY_START;
        for day in self.sessions {
            market = self.rng.gauss(0.0004, 0.0085);
            gap = self.rng.gauss(0.0, 0.002);
            spy = self.add_bar(BENCHMARK, day, spy, market, gap, 0.004);
            for s in UNIVERSE {
                move = s.drift + 1.1 * market + self.rng.gauss(0.0, s.vol);
                prices[s.ticker] = self.add_bar(s.ticker, day, prices[s.ticker], move, gap + self.rng.gauss(0.0, s.vol / 4), s.vol / 2);
            }
        }
    }

    def add_bar(ticker: str, day: str, before: float, move: float, gap: float, wick: float) -> float {
        o = round(before * (1.0 + gap), 2);
        c = round(before * (1.0 + move), 2);
        low = round(min(o, c) * (1.0 - abs(self.rng.gauss(0.0, wick))), 2);
        high = round(max(o, c) * (1.0 + abs(self.rng.gauss(0.0, wick))), 2);
        self.bars.setdefault(ticker, {})[day] = bar(day, c, open=o, low=low, high=high);
        return c;
    }

    def close_of(ticker: str, day: str) -> float {
        return self.bars[ticker][day].close;
    }

    def before(day: str, n: int) -> list[str] {
        return [s for s in self.sessions if s < day][-n:];
    }

    def realized_vol(ticker: str, day: str) -> float {
        closes = [self.close_of(ticker, s) for s in self.before(day, 21)];
        returns = [b / a - 1.0 for (a, b) in zip(closes, closes[1:])];
        return statistics.stdev(returns) * math.sqrt(252);
    }

    def atr(ticker: str, day: str) -> float {
        days = self.before(day, 15);
        ranges = [max(self.bars[ticker][d].high, self.bars[ticker][p].close) - min(self.bars[ticker][d].low, self.bars[ticker][p].close) for (p, d) in zip(days, days[1:])];
        return statistics.fmean(ranges);
    }

    """The stock's return over the next five sessions less SPY's: what a good panel would
    sense. The votes lean on it, so their hit rate ends up a little better than a coin."""
    def outlook(ticker: str, day: str) -> float {
        ahead = [s for s in self.sessions if s >= day][:5];
        last = self.before(day, 1)[0];
        end = ahead[-1];
        mine = self.close_of(ticker, end) / self.close_of(ticker, last) - 1.0;
        spy = self.close_of(BENCHMARK, end) / self.close_of(BENCHMARK, last) - 1.0;
        return (mine - spy) / max(self.stocks[ticker].vol * 2.2, 0.01);
    }

    def held -> dict[str, Position] {
        return {p.ticker: p for p in [self.portfolio ->:Holds:->[?:Position]] if p.open()};
    }

    def positions_value(day: str) -> float {
        return sum(p.qty * self.close_of(t, day) for (t, p) in self.held().items());
    }

    # --- Morning run ---------------------------------------------------------------------

    def morning(i: int, day: str) -> Run {
        fallback = i == FALLBACK_SESSION;
        held = self.held();
        requests = self.rng.randint(58, 92);
        run = public(self.portfolio +>:Ran():+> Run(
            run_date=day,
            started_at=at(day, "07:30"),
            status=RunStatus.FALLBACK if fallback else RunStatus.NORMAL,
            finished_at=at(day, f"08:{self.rng.randint(31, 58):02d}"),
            model_versions={"primary": PRIMARY_MODEL, "fallback": FALLBACK_MODEL, "consensus": CONSENSUS_VERSION, "gate": GATE_VERSION},
            model_requests=requests,
            prompt_tokens=requests * self.rng.randint(2600, 3400),
            completion_tokens=requests * self.rng.randint(380, 520)
        ));
        regime = self.macro(run, day);
        others = [s.ticker for s in UNIVERSE if s.ticker not in held];
        self.rng.shuffle(others);
        picks = sorted(others[:SHORTLIST]);
        scores = sorted([round(self.rng.uniform(0.52, 0.94), 3) for _ in picks], reverse=True);
        covered: list[Coverage] = [];
        for (t, score) in zip(picks, scores) {
            covered.append(self.cover(run, t, day, CoverageReason.SCREEN, score, ""));
        }
        for t in sorted(held) {
            covered.append(self.cover(run, t, day, CoverageReason.HELD, 0.0, "open position"));
        }
        ordered = sorted(covered, key=lambda (c: Coverage) { -self.outlook(c.ticker, day); });
        for c in covered {
            self.analyze(c, day, held.get(c.ticker), regime);
            publish_card(c, day, PortfolioMode.AUTO.value, run.finished_at);
        }
        buys = len([c for c in covered if self.action_of(c) in (TradeAction.BUY, TradeAction.ADD)]);
        sells = len([c for c in covered if self.action_of(c) in (TradeAction.SELL, TradeAction.TRIM)]);
        lead = ordered[0].ticker if ordered else "";
        if fallback {
            run.summary = f"Fallback run. The Orchestrator stopped at iteration 9 with the request budget spent, and the Run Guard finished research and the panel in fixed order. {count(len(covered), 'ticker')} covered: {count(buys, 'buy or add', 'buys or adds')}, {count(sells, 'sell or trim', 'sells or trims')}.";
            run.reduced_mode = False;
        } else {
            run.summary = f"Covered {count(len(covered), 'ticker')} ({len(picks)} from the screen, {len(held)} held). The panel was strongest on {lead}. {count(buys, 'buy or add', 'buys or adds')} and {count(sells, 'sell or trim', 'sells or trims')} went to the risk gate; the rest hold.";
        }
        return run;
    }

    def action_of(c: Coverage) -> TradeAction {
        for d in [c ->:Decided:->[?:Decision]] {
            return d.action;
        }
        return TradeAction.NO_ACTION;
    }

    def macro(run: Run, day: str) -> RegimeInputs {
        last = self.before(day, 1)[0];
        spy = self.close_of(BENCHMARK, last);
        month = spy / self.close_of(BENCHMARK, self.before(day, 21)[0]) - 1.0;
        vol = self.realized_vol(BENCHMARK, day);
        inputs = RegimeInputs(spy_close=spy, spy_sma_200=round(spy * 0.935, 2), spy_vol_20=vol, spy_as_of=last);
        regime = RiskRegime.RISK_ON if month > 0.015 else (RiskRegime.RISK_OFF if month < -0.015 else RiskRegime.NEUTRAL);
        word = {RiskRegime.RISK_ON: "favor taking equity risk", RiskRegime.RISK_OFF: "argue for caution", RiskRegime.NEUTRAL: "favor neither side"}[regime];
        self.macro_body = MacroReport(
            summary=f"SPY closed at {spy:.2f}, {month:+.1%} over the past month and well above its 200-day average. Its 20-day realized volatility is {vol:.0%}. Treasury funds were steady, and the leading sectors rotated without a clear defensive tilt. Conditions {word}.",
            regime=regime,
            confidence=round(self.rng.uniform(0.55, 0.75), 2),
            evidence=[
                Evidence(claim=f"SPY closed at {spy:.2f} on {last}.", source_url=f"https://data.alpaca.markets/v2/stocks/bars?symbols=SPY&timeframe=1Day&start={last}", published=last),
                Evidence(claim="The 200-day average is computed from a year of daily closes.", source_url="https://en.wikipedia.org/wiki/Moving_average", published=last)
            ],
            risks=["A hotter inflation print could lift yields.", "Earnings season could widen single-stock dispersion."]
        );
        public(run +>:HasMacro():+> MacroRecord(as_of=at(day, "07:40"), model=PRIMARY_MODEL, body=self.macro_body, inputs=inputs));
        return inputs;
    }

    def cover(run: Run, ticker: str, day: str, reason: CoverageReason, score: float, note: str) -> Coverage {
        s = self.stocks[ticker];
        last = self.before(day, 1)[0];
        earnings = self.rng.choice([1, 2, 6, 11, 17, 24, 33, 41, None]);
        return public(run +>:Covers():+> Coverage(
            ticker=ticker,
            sector=s.sector,
            reason=reason,
            screen_score=score,
            reason_note=note,
            last_close=self.close_of(ticker, last),
            atr_14=round(self.atr(ticker, day), 4),
            realized_vol_20=round(self.realized_vol(ticker, day), 4),
            volume_20=s.volume * self.rng.uniform(0.85, 1.15),
            sessions_to_earnings=earnings
        ));
    }

    """Research, votes, consensus, and the Arbiter's decision for one coverage."""
    def analyze(c: Coverage, day: str, position: Position | None, regime: RegimeInputs) {
        t = c.ticker;
        s = self.stocks[t];
        signal = self.bias[t] + 0.3 * self.outlook(t, day) + self.rng.gauss(0.0, 0.25);
        last = self.before(day, 1)[0];
        month = self.close_of(t, last) / self.close_of(t, self.before(day, 21)[0]) - 1.0;
        avg50 = statistics.fmean(self.close_of(t, d) for d in self.before(day, 30));
        bars_url = f"https://data.alpaca.markets/v2/stocks/bars?symbols={t}&timeframe=1Day&start={self.before(day, 21)[0]}";
        reports = {
            Domain.MARKET: (
                f"{t} closed at {self.close_of(t, last):.2f}, {month:+.1%} over 20 sessions and {self.close_of(t, last) / avg50 - 1.0:+.1%} against its 30-day average. ATR(14) is {c.atr_14:.2f} and 20-day realized volatility {c.realized_vol_20:.0%}. Volume is near its 20-day average of {c.volume_20 / 1e6:.1f}M shares.",
                [Evidence(claim=f"Closed at {self.close_of(t, last):.2f} on {last}, {month:+.1%} over 20 sessions.", source_url=bars_url, published=last)]
            ),
            Domain.FUNDAMENTALS: (
                f"The latest 10-Q shows revenue {self.rng.uniform(-3, 18):+.1f}% year over year and an operating margin of {self.rng.uniform(12, 42):.0f}%. Guidance was {self.rng.choice(['raised', 'reaffirmed', 'trimmed'])}. The balance sheet carries {self.rng.choice(['net cash', 'modest net debt', 'net debt near 1.5x EBITDA'])}.",
                [
                    Evidence(claim="Quarterly revenue and margins from the latest 10-Q.", source_url=f"https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&CIK={s.cik}&type=10-Q", published=self.before(day, 25)[0]),
                    Evidence(claim="Reported financial facts from XBRL company facts.", source_url=f"https://data.sec.gov/api/xbrl/companyfacts/CIK{s.cik.zfill(10)}.json", published=self.before(day, 25)[0])
                ]
            ),
            Domain.NEWS: (
                f"{self.rng.randint(4, 19)} articles over the past week. The tone was {'mostly positive' if signal > 0.15 else ('mixed' if signal > -0.15 else 'mostly negative')}, and no new legal or regulatory matter appeared. Earnings are {'due in ' + str(c.sessions_to_earnings) + ' sessions' if c.sessions_to_earnings is not None else 'not scheduled within the calendar'}.",
                [
                    Evidence(claim="Headlines from the past seven days.", source_url=f"https://data.alpaca.markets/v1beta1/news?symbols={t}", published=last),
                    Evidence(claim="Company background and business segments.", source_url=f"https://en.wikipedia.org/wiki/{s.name}", published=last)
                ]
            )
        };
        bodies: dict[Domain, ResearchReport] = {};
        for (domain, (summary, evidence)) in reports.items() {
            view = signal + self.rng.gauss(0.0, 0.3);
            bodies[domain] = ResearchReport(
                summary=summary,
                view=stance_for(view),
                confidence=round(self.rng.uniform(0.5, 0.8), 2),
                evidence=evidence,
                risks=[self.rng.choice(["A broad market pullback.", "Valuation compresses if rates rise.", "A guidance cut at the next report.", "Sector rotation away from the group."])],
                data_gaps=["No intraday data."] if domain == Domain.MARKET and self.rng.random() < 0.2 else []
            );
            public(c +>:Researched():+> ResearchRecord(ticker=t, domain=domain, as_of=at(day, "07:50"), model=PRIMARY_MODEL, body=bodies[domain]));
        }

        votes: dict[Specialist, list[Vote]] = {};
        for spec in list(Specialist) {
            # Cite positions in the packet the specialist would read, as a real vote does.
            shown = len(packet(spec, t, day, bodies, self.macro_body).evidence);
            lean = signal + self.rng.gauss(0.0, 0.18);
            mine: list[Vote] = [];
            for k in range(SAMPLES) {
                x = lean + self.rng.gauss(0.0, 0.12);
                stance = stance_for(x);
                direction = 1 if x > 0.14 else (-1 if x < -0.14 else 0);
                v = Vote(
                    stance=stance,
                    confidence=round(min(0.92, max(0.45, 0.62 + abs(x) * 0.3 + self.rng.gauss(0.0, 0.05))), 2),
                    horizon_days=self.rng.choice([5, DEFAULT_HORIZON_DAYS, DEFAULT_HORIZON_DAYS]),
                    rationale=RATIONALE[spec][direction],
                    cited_evidence=sorted(self.rng.sample(range(shown), min(shown, self.rng.randint(1, 3))))
                );
                mine.append(v);
                public(c +>:Voted():+> VoteRecord(ticker=t, specialist=spec, sample=k, model=PRIMARY_MODEL, body=v));
            }
            votes[spec] = mine;
        }

        found = consensus(votes, f"{day}:{t}");
        if found is None {
            return;
        }
        exit_due = position is not None and bool(position.time_stop) and position.time_stop <= day;
        draft = draft_action(found, position is not None, exit_due);
        public(c +>:Concluded():+> ConsensusResult(
            ticker=t,
            score=found.score,
            agreement=found.agreement,
            ci_low=found.ci_low,
            ci_high=found.ci_high,
            draft_action=draft,
            specialist_scores=found.specialist_scores,
            weights=found.weights,
            samples_used=found.samples_used
        ));
        action = draft;
        verdict = "CONFIRM";
        reason = "";
        if draft in (TradeAction.BUY, TradeAction.ADD) and found.agreement < 0.75 and self.rng.random() < 0.35 {
            action = TradeAction.HOLD if draft == TradeAction.ADD else TradeAction.NO_ACTION;
            verdict = "DOWNGRADE";
            reason = self.rng.choice([
                "the fundamentals and news specialists disagree on the near-term catalyst, and the interval sits close to zero",
                "earnings are near and the panel's case rests on momentum that a miss would undo",
                "two specialists cite the same single source, so the agreement overstates the evidence"
            ]);
        }
        bullish = action in (TradeAction.BUY, TradeAction.ADD, TradeAction.HOLD);
        thesis = (
            f"{t} screens well and the panel leans {'positive' if found.score > 0 else 'negative'}: technical momentum and {'steady' if bullish else 'softening'} fundamentals point the same way over about two weeks."
            if action in (TradeAction.BUY, TradeAction.ADD)
            else (f"The time stop on {t} has come due, so the position is closed whatever the panel says." if exit_due else f"The panel's case on {t} is not strong enough to act on: score {found.score:+.2f} with agreement {found.agreement:.0%}.")
        );
        self.decisions += 1;
        public(c +>:Decided():+> Decision(
            ticker=t,
            action=action,
            conviction=found.conviction(),
            thesis=thesis,
            risks=self.rng.sample(["A broad market pullback would hit it with the rest.", "Valuation leaves little room for a miss.", "Rising yields could rotate money out of the sector.", "A guidance cut at the next report would break the thesis.", "Crowded positioning could unwind quickly."], 2),
            exit_condition=f"A close below {c.last_close - 2.0 * c.atr_14:.2f} (two ATRs under the last close), or the panel turning negative.",
            time_stop=trading_day_after(self.calendar, day, DEFAULT_HORIZON_DAYS) if action == TradeAction.BUY else (position.time_stop if position is not None else ""),
            downgrade_reason=reason,
            arbiter_verdict=verdict,
            model=PRIMARY_MODEL
        ));
    }

    # --- Execution ----------------------------------------------------------------------

    """Size and gate the run's decisions at 9:45, then fill the approved orders near the open
    and place each position's stop, as the executor does."""
    def execute(run: Run, day: str) -> list[str] {
        log: list[str] = [];
        now = at(day, "09:45");
        held = self.held();
        decided: dict[str, tuple[Coverage, Decision]] = {};
        for c in [run ->:Covers:->[?:Coverage]] {
            for d in [c ->:Decided:->[?:Decision]] {
                decided[c.ticker] = (c, d);
            }
        }
        prices = {t: round(self.bars[t][day].open * (1.0 + self.rng.gauss(0.0, 0.0015)), 2) for t in decided};
        equity = self.cash + sum(p.qty * prices.get(t, self.close_of(t, self.before(day, 1)[0])) for (t, p) in held.items());
        candidates = [
            SizingCandidate(ticker=t, action=d.action, conviction=d.conviction, price=prices[t], realized_vol_20=c.realized_vol_20, current_qty=held[t].qty if t in held else 0)
            for (t, (c, d)) in sorted(decided.items())
        ];
        plan = size_positions(candidates, equity);
        proposals = [Proposal(ticker=p.ticker, action=c.action, side=p.side, qty=abs(p.share_delta), conviction=c.conviction) for (p, c) in zip(plan.positions, candidates) if p.side is not None and p.share_delta != 0];
        instruments = {
            t: Instrument(ticker=t, price=prices[t], sector=c.sector, tradable=True, trade_age_minutes=0.2, atr_14=c.atr_14, volume_20=c.volume_20, sessions_to_earnings=c.sessions_to_earnings)
            for (t, (c, d)) in decided.items()
        };
        book = Book(equity=equity, peak_equity=max(self.peak, equity), positions={t: BookPosition(ticker=t, qty=p.qty, price=prices[t], sector=p.sector) for (t, p) in held.items()});
        results = check_orders(proposals, book, instruments, run_regime(run), GateConfig());
        approved = 0;
        sells = [r for r in results if r.side == OrderSide.SELL];
        for r in sells + [r for r in results if r.side == OrderSide.BUY] {
            rc = public(decided[r.ticker][1] +>:CheckedBy():+> RiskCheck(
                outcome=r.outcome(),
                approved_qty=r.approved_qty,
                checked_at=now,
                rules=r.rules,
                ticker=r.ticker,
                side=r.side,
                purpose=r.purpose,
                requested_qty=r.requested_qty,
                price=r.price,
                stop_distance=r.stop_distance,
                gate_version=GATE_VERSION
            ));
            if r.approved_qty > 0 {
                approved += 1;
                log.append(f"09:45 execute: {self.trade(rc, r, run.run_date, day, held.get(r.ticker))}");
            } else {
                log.append(f"09:45 execute: {r.ticker} {r.side.value} {r.requested_qty} refused by {r.rejected_by()}");
            }
        }
        run.executed_at = now;
        run.execution_note = f"{len(results)} checks, {approved} approved";
        log.insert(0, f"09:45 execute: {run.execution_note}");
        for (t, p) in self.held().items() {
            if not [o for o in [p ->:StoppedBy:->[?:Order]] if o.status == "new"] {
                log.append(f"09:47 stop: {self.place_stop(p, day)}");
            }
        }
        return log;
    }

    """Send and fill one approved order. A position's working stop is canceled first."""
    def trade(rc: RiskCheck, r: GateResult, run_day: str, day: str, position: Position | None) -> str {
        if position is not None {
            for o in [position ->:StoppedBy:->[?:Order]] {
                if o.status == "new" {
                    o.status = "canceled";
                    o.updated_at = at(day, "09:45");
                }
            }
            position.stop_order_id = "";
        }
        price = rc.price;
        partial = r.side == OrderSide.BUY and self.rng.random() < 0.08;
        qty = r.approved_qty;
        filled = max(1, int(qty * 0.3)) if partial else qty;
        fill_price = round(price * (1.0 + (0.0004 if r.side == OrderSide.BUY else -0.0004)), 2);
        self.orders += 1;
        order = Order(
            client_order_id=order_id_for(run_day, rc.ticker, r.purpose),
            purpose=r.purpose,
            side=r.side,
            qty=qty,
            order_type="limit",
            time_in_force="day",
            submitted_at=at(day, "09:45"),
            alpaca_order_id=f"demo-{self.orders:05d}",
            limit_price=limit_price(r.side, price),
            status="canceled" if partial else "filled",
            ticker=rc.ticker,
            filled_qty=filled,
            filled_avg_price=fill_price,
            updated_at=at(day, "15:50") if partial else at(day, "09:46")
        );
        public(rc +>:Placed():+> order);
        self.portfolio +>:Sent():+> order;
        public(order +>:FilledBy():+> Fill(qty=filled, price=fill_price, filled_at=at(day, "09:46")));
        if r.side == OrderSide.SELL {
            self.cash += filled * fill_price;
            if position is not None {
                position.qty -= filled;
                if position.qty <= 0 {
                    position.qty = 0;
                    position.closed_at = at(day, "09:46");
                    position.exit_price = fill_price;
                    return f"{rc.ticker} sold {filled} @ {fill_price:.2f}: closed ({r.purpose.value})";
                }
            }
            return f"{rc.ticker} sold {filled} @ {fill_price:.2f} ({r.purpose.value})";
        }
        self.cash -= filled * fill_price;
        if position is None {
            decided = [d for d in [rc <-:CheckedBy:<-[?:Decision]]];
            position = public(self.portfolio +>:Holds():+> Position(
                ticker=rc.ticker,
                sector=self.stocks[rc.ticker].sector,
                qty=filled,
                avg_entry_price=fill_price,
                opened_at=at(day, "09:46"),
                stop_price=round(fill_price - rc.stop_distance, 2),
                time_stop=decided[0].time_stop if decided else "",
                last_price=fill_price,
                priced_at=at(day, "09:46")
            ));
            if decided {
                position +>:OpenedBy():+> decided[0];
            }
        } else {
            position.avg_entry_price = (position.avg_entry_price * position.qty + fill_price * filled) / (position.qty + filled);
            position.qty += filled;
            position.stop_price = max(position.stop_price, round(fill_price - rc.stop_distance, 2));
        }
        note = f", {qty - filled} canceled at 15:50" if partial else "";
        return f"{rc.ticker} bought {filled} of {qty} @ {fill_price:.2f}{note}";
    }

    def place_stop(position: Position, day: str) -> str {
        position.stops_placed += 1;
        self.orders += 1;
        order = Order(
            client_order_id=stop_id_for(position, position.stops_placed),
            purpose=OrderPurpose.STOP,
            side=OrderSide.SELL,
            qty=position.qty,
            order_type="stop",
            time_in_force="gtc",
            submitted_at=at(day, "09:47"),
            alpaca_order_id=f"demo-{self.orders:05d}",
            stop_price=position.stop_price,
            status="new",
            ticker=position.ticker,
            updated_at=at(day, "09:47")
        );
        position.stop_order_id = order.alpaca_order_id;
        public(position +>:StoppedBy():+> order);
        self.portfolio +>:Sent():+> order;
        return f"{position.ticker}: stop for {position.qty} at {position.stop_price:.2f}: new";
    }

    """Fire every working stop the session's low reached, at the stop or a lower open."""
    def stops(day: str) -> list[str] {
        log: list[str] = [];
        for (t, p) in sorted(self.held().items()) {
            b = self.bars[t][day];
            if p.stop_price <= 0.0 or b.low > p.stop_price {
                continue;
            }
            price = round(min(b.open, p.stop_price), 2);
            for o in [p ->:StoppedBy:->[?:Order]] {
                if o.status == "new" {
                    o.status = "filled";
                    o.filled_qty = p.qty;
                    o.filled_avg_price = price;
                    o.updated_at = at(day, "13:12");
                    public(o +>:FilledBy():+> Fill(qty=p.qty, price=price, filled_at=at(day, "13:12")));
                }
            }
            self.cash += p.qty * price;
            log.append(f"13:15 fill: {t}: closed @ {price:.2f} (stop)");
            p.qty = 0;
            p.closed_at = at(day, "13:12");
            p.exit_price = price;
            p.stop_order_id = "";
        }
        return log;
    }

    # --- Close and evening --------------------------------------------------------------

    def close(run: Run, day: str) -> list[str] {
        marked = at(day, "16:30");
        for (t, p) in self.held().items() {
            p.last_price = self.close_of(t, day);
            p.priced_at = marked;
        }
        value = self.positions_value(day);
        equity = self.cash + value;
        self.peak = max(self.peak, equity);
        self.portfolio.peak_equity = self.peak;
        drawdown = 1.0 - equity / self.peak;
        public(self.portfolio +>:Marked():+> DailyMark(day=day, equity=equity, cash=self.cash, positions_value=value, peak_equity=self.peak, marked_at=marked, drawdown=drawdown, open_positions=len(self.held())));
        run.day_orders_closed_at = at(day, "15:50");
        run.reconciled_at = marked;
        run.votes_scored_at = marked;
        run.baselines_at = marked;
        lines = [f"16:30 reconcile: equity {equity:,.2f}, {len(self.held())} positions, drawdown {drawdown:.1%}, 0 drift, 0 bypasses"];
        sim = SimDay(day=day, bars=self.bars, sessions=self.calendar, now=datetime.fromisoformat(marked));
        for (kind, b) in sorted(baselines_of(self.portfolio).items(), key=lambda (kv: tuple[BaselineKind, Baseline]) { kv[0].value; }) {
            done = simulate_spy(b, sim) if kind == BaselineKind.SPY else simulate_equal_weight(b, sim, run);
            b.trade_log = b.trade_log + done;
            lines.extend(f"16:30 baseline: {kind.value} {line}" for line in done);
        }
        return lines;
    }

    """Score every vote whose window closed by the last session, as the evening job does."""
    def score_votes {
        closes = {t: {d: b.close for (d, b) in found.items()} for (t, found) in self.bars.items()};
        scored_at = at(self.days[-1], "16:30");
        for run in [self.portfolio ->:Ran:->[?:Run]] {
            for c in [run ->:Covers:->[?:Coverage]] {
                for v in [c ->:Voted:->[?:VoteRecord]] {
                    window = vote_window(self.sessions, run.run_date, v.body.horizon_days);
                    if window is not None {
                        v.excess_return = excess_return(closes, v.ticker, window[0], window[1]);
                        v.scored_at = scored_at;
                    }
                }
            }
        }
    }
}
