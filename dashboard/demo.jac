"""Demo history for local development (#105): a few weeks of made-up trading in the team graph,
so the dashboard can be built and checked before the forward test stores real data.

The prices are a seeded random walk, and the research and votes are templates, but every
number after them comes from the project's own rules: the consensus engine and decision rule
turn the votes into draft actions, the sizing and the risk gate turn decisions into orders,
the baselines are simulated by action/baselines.jac, and the votes are scored by
analysis/scoring.jac. Orders fill at each session's open, stops fire on its low, and the
portfolio is marked at its close, the way the executor and reconciliation record them.

The agent trades every asset class (models/assets.jac). Coins trade every day, so weekends have
runs of their own that cover the coins alone and trade them at 9:45, with nothing marked or
scored, as a live weekend does. Calls and puts are bought on the panel's views and sold by the
rules of action/options.jac, priced by Black-Scholes on the stock's own volatility.

It runs only inside a local server started with TRADING_AGENT_DEMO=1, from a scheduled job,
since only the server's own context reaches the team graph on root.shared. It writes nothing
when the team portfolio has any run, mark, or baseline, and flags the portfolio it fills as
`demo`, so the dashboard says the numbers are made up. Never set the variable on a deployed
server.
"""
import logging;
import math;
import random;
import statistics;
import threading;
import from datetime { date, datetime, time, timedelta, timezone }
import from accounts.assets { save_team_classes }
import from action.baselines { SimDay, baselines_of, simulate_equal_weight, simulate_spy }
import from action.executor { CRYPTO_STOP_SLIPPAGE, MarketView, limit_price, order_id_for, run_regime, stop_id_for, stop_round }
import from action.gate { Book, BookPosition, GATE_VERSION, GateConfig, GateResult, Instrument, Proposal, breaker_peak, check_orders }
import from action.insights { publish_card }
import from action.options { OPTIONS_VERSION, OptionsConfig, exit_reason, latest_decisions, option_views, to_tick }
import from action.sizing { SizingCandidate, size_positions }
import from agents.models { FALLBACK_MODEL, PRIMARY_MODEL }
import from agents.specialists { packet }
import from analysis.consensus { CONSENSUS_VERSION, consensus, draft_action }
import from analysis.evaluation { evaluate, record_evaluation }
import from analysis.history { History, bar }
import from research.indicators { momentum, range_position, relative_strength, rsi, sma }
import from dashboard.ui.format { count }
import from analysis.scoring { BENCHMARK, score_screens, score_votes as score_all }
import from models.assets { ASSET_CLASSES, CRYPTO, OPTIONS, STOCKS }
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
    RiskOutcome,
    RuleResult,
    Run,
    RunStatus,
    Sent,
    StoppedBy,
    TradeAction,
    VoteRecord,
    Voted
}
import from models.research { RegimeInputs, Stamp }
import from research.crypto { CRYPTO_BENCHMARK, CRYPTO_SECTOR, is_crypto }
import from research.options { CALL, CONTRACT_SIZE, ContractQuery, OccParts, OptionContract, OptionQuote, choose_contract, describe_option, expiry_window, parse_occ }
import from research.alpaca { Bar }
import from run.analysis { DEFAULT_HORIZON_DAYS, specialists_for, trading_day_after }
import from run.switches { demo_mode }
import from run.guard { NEW_YORK, TEAM_PORTFOLIO }
import from run.public { public }

glob LOG: logging.Logger = logging.getLogger("trading_agent.demo");
glob _SEEDING: threading.Lock = threading.Lock();
glob NOTHING_WRITTEN: str = "demo: the team portfolio already has history; nothing written";
# The version of the history below. Bump it with any change to what the history holds, so a server
# whose demo account holds an older one writes it again (accounts/demo.jac). 2: every asset class.
glob DEMO_VERSION: int = 2;
# Sessions of history, ending with the last weekday before the day it is seeded.
glob DEMO_SESSIONS: int = 23;
# Sessions of prices before the first run, for the 20-day figures the first run reads.
glob WARMUP_SESSIONS: int = 30;
glob STARTING_CASH: float = 100000.0;
glob SHORTLIST: int = 6;
glob SAMPLES: int = 3;
# The fundamentals gap that leaves Flow no view, and the share of reports that carry it. Live
# runs on November 2 to 4, 2026 abstained on most Flow samples for want of insider data.
glob FLOW_GAP: str = "No insider transactions or institutional holdings were reported in the window.";
glob FLOW_GAP_SHARE: float = 0.4;
# Every third run, counting back from the latest, the News specialist fails every sample on the
# run's first screened ticker, as a live run does when the free model is rate limited, so the
# decision trail can show a failed specialist beside the others.
glob FAILURE_EVERY: int = 3;
glob FAILED_SPECIALIST: Specialist = Specialist.NEWS;
glob FAILURE_ERROR: str = "RateLimitError: the free model answered 429 Too Many Requests, and its retry did too";
# Which session (counting from the first) the Orchestrator ran out of budget on.
glob FALLBACK_SESSION: int = 9;

"""A stock or coin in the demo universe: its sector, its first price, and its daily drift and
volatility. `cik` names a stock's SEC filer, for the research's source links, and `name` its
Wikipedia page. A coin trades in multiples of `increment`, at least `min_qty` at a time."""
obj DemoStock {
    has ticker: str,
        name: str,
        sector: str,
        price: float,
        drift: float,
        vol: float,
        cik: str,
        volume: float;
    has increment: float = 1.0,
        min_qty: float = 0.0;
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

# The coins a live run covers: the five most traded pairs (run/research.jac, `crypto_size`). Their
# volume is in coins, and their bars come every calendar day.
glob COINS: list[DemoStock] = [
    DemoStock(ticker="BTC/USD", name="Bitcoin", sector=CRYPTO_SECTOR, price=96500.0, drift=0.0004, vol=0.021, cik="", volume=2.4e4, increment=1e-6, min_qty=0.0001),
    DemoStock(ticker="ETH/USD", name="Ethereum", sector=CRYPTO_SECTOR, price=3350.0, drift=0.0003, vol=0.029, cik="", volume=3.3e5, increment=1e-6, min_qty=0.001),
    DemoStock(ticker="SOL/USD", name="Solana_(blockchain_platform)", sector=CRYPTO_SECTOR, price=188.0, drift=0.0005, vol=0.038, cik="", volume=3.9e6, increment=1e-4, min_qty=0.01),
    DemoStock(ticker="XRP/USD", name="XRP_Ledger", sector=CRYPTO_SECTOR, price=2.28, drift=0.0001, vol=0.041, cik="", volume=1.1e9, increment=0.01, min_qty=1.0),
    DemoStock(ticker="DOGE/USD", name="Dogecoin", sector=CRYPTO_SECTOR, price=0.3712, drift=-0.0004, vol=0.048, cik="", volume=2.6e9, increment=1.0, min_qty=1.0)
];
# How much of Bitcoin's daily move each other coin follows.
glob COIN_BETA: float = 0.8;
# Options: the risk-free rate Black-Scholes discounts at, how far implied volatility sits above
# the stock's realized volatility, the floor under it, and half the quoted spread, as a share of
# the mid.
glob OPTION_RATE: float = 0.04;
glob IV_PREMIUM: float = 1.15;
glob IV_FLOOR: float = 0.18;
glob OPTION_HALF_SPREAD: float = 0.035;

"""Seeds the demo history once a minute is up, when the server runs with TRADING_AGENT_DEMO=1.
Static jobs reach root.shared, which a standalone script cannot (it sees the super root). A seed
takes about a minute and commits only when its job ends, so the next minute's job skips while
one is running rather than find an empty graph and seed a second team portfolio."""
@schedule(trigger=ScheduleTrigger.STATIC, cron="* * * * *")
def demo_job {
    if not demo_mode() or not _SEEDING.acquire(blocking=False) {
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
    # The history trades every class, so Settings shows the team's agent trading them all.
    save_team_classes(list(ASSET_CLASSES));
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

"""Every calendar day from `first` through the day before `today`: a coin's sessions."""
def every_day(first: str, today: date) -> list[str] {
    found: list[str] = [];
    day = date.fromisoformat(first);
    while day < today {
        found.append(day.isoformat());
        day += timedelta(days=1);
    }
    return found;
}

"""A price rounded the way it is quoted: to the cent at $1 and above, and finer below."""
def px(price: float) -> float {
    return stop_round(price);
}

"""A Black-Scholes price for a European option on a stock at `spot`."""
def black_scholes(spot: float, strike: float, years: float, vol: float, kind: str) -> float {
    if years <= 0.0 or vol <= 0.0 {
        return max(0.0, spot - strike) if kind == CALL else max(0.0, strike - spot);
    }
    spread = vol * math.sqrt(years);
    d1 = (math.log(spot / strike) + (OPTION_RATE + vol * vol / 2.0) * years) / spread;
    d2 = d1 - spread;
    def cdf(x: float) -> float {
        return 0.5 * (1.0 + math.erf(x / math.sqrt(2.0)));
    }
    discount = strike * math.exp(-OPTION_RATE * years);
    if kind == CALL {
        return spot * cdf(d1) - discount * cdf(d2);
    }
    return discount * cdf(-d2) - spot * cdf(-d1);
}

"""The OCC symbol of a contract: "AAPL261218C00230000"."""
def occ_symbol(underlying: str, expiry: str, kind: str, strike: float) -> str {
    day = date.fromisoformat(expiry);
    return f"{underlying}{day.strftime('%y%m%d')}{'C' if kind == CALL else 'P'}{int(round(strike * 1000)):08d}";
}

"""The parts of one of the demo's own contract symbols, which always parse."""
def contract(symbol: str) -> OccParts {
    found = parse_occ(symbol);
    if found is None {
        raise ValueError(f"not an option symbol: {symbol}");
    }
    return found;
}

"""The gap between listed strikes for a stock at `price`."""
def strike_step(price: float) -> float {
    if price < 50.0 {
        return 1.0;
    }
    if price < 150.0 {
        return 2.5;
    }
    return 5.0 if price < 500.0 else 10.0;
}

"""The contracts listed for `query`: weekly Friday expiries and strikes on the stock's step."""
def demo_contracts(query: ContractQuery) -> list[OptionContract] {
    found: list[OptionContract] = [];
    step = strike_step((query.strike_low + query.strike_high) / 2.0);
    day = date.fromisoformat(query.expiry_from);
    end = date.fromisoformat(query.expiry_to);
    while day <= end {
        if day.weekday() == 4 {
            strike = math.ceil(query.strike_low / step) * step;
            while strike <= query.strike_high {
                expiry = day.isoformat();
                found.append(OptionContract(symbol=occ_symbol(query.underlying, expiry, query.kind, strike), underlying=query.underlying, kind=query.kind, strike=strike, expiry=expiry, tradable=True, open_interest=1200.0));
                strike += step;
            }
        }
        day += timedelta(days=1);
    }
    return found;
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

# What a coin's panel says: Technical as for a stock, News and Macro in the coin's terms.
glob COIN_RATIONALE: dict[Specialist, dict[int, str]] = {
    Specialist.TECHNICAL: RATIONALE[Specialist.TECHNICAL],
    Specialist.NEWS: {
        1: "Coverage this week leaned positive, led by fund inflows and network growth, with no exchange or enforcement trouble.",
        0: "News flow was light and mixed, with nothing that changes the outlook for the coin.",
        -1: "Recent coverage leans negative, with fund outflows and regulatory worries in several articles."
    },
    Specialist.MACRO: {
        1: "A risk-on tape and easing yields tend to lift coins along with growth stocks.",
        0: "The macro backdrop is neutral for coins; rates and risk appetite roughly offset.",
        -1: "Rising yields and a defensive tape usually weigh on coins first."
    }
};
glob COIN_RISKS: list[str] = ["A broad crypto sell-off.", "A regulatory headline.", "Thin weekend liquidity.", "Fund outflows."];

"""A price for the reader: cents at $1 and above, four places below, where a coin can trade."""
def money(price: float) -> str {
    return f"{price:,.2f}" if abs(price) >= 1.0 else f"{price:.4f}";
}

"""The simulation: a price tape, then one session at a time, the morning run, the 9:45
execution, the day's stops, the close's mark, and the evening's baselines."""
obj DemoSim {
    has portfolio: Portfolio,
        today: date;
    has rng: random.Random = random.Random(0),
        coin_rng: random.Random = random.Random(0),
        sessions: list[str] = [],
        days: list[str] = [],
        coin_days: list[str] = [],
        run_days: list[str] = [],
        calendar: list[str] = [],
        bars: dict[str, dict[str, Bar]] = {},
        stocks: dict[str, DemoStock] = {},
        bias: dict[str, float] = {},
        cash: float = STARTING_CASH,
        peak: float = STARTING_CASH,
        closes: list[float] = [],
        decisions: int = 0,
        orders: int = 0,
        macro_body: MacroReport | None = None;

    def postinit {
        self.rng = random.Random(449);
        # The coins draw from their own sequence, so the stocks' tape is the same with them or without.
        self.coin_rng = random.Random(293);
        self.stocks = {s.ticker: s for s in UNIVERSE + COINS};
        self.bias = {s.ticker: self.rng.gauss(0.15, 0.25) for s in UNIVERSE};
        for s in COINS {
            self.bias[s.ticker] = self.coin_rng.gauss(0.1, 0.25);
        }
        self.sessions = weekdays_before(self.today, WARMUP_SESSIONS + DEMO_SESSIONS);
        self.days = self.sessions[WARMUP_SESSIONS:];
        self.calendar = weekdays_before(self.today, WARMUP_SESSIONS + DEMO_SESSIONS, 60);
        self.coin_days = every_day(self.sessions[0], self.today);
        weekends = [d for d in self.coin_days if d >= self.days[0] and date.fromisoformat(d).weekday() >= 5];
        self.run_days = sorted(self.days + weekends);
    }

    def run {
        self.make_tape();
        p = self.portfolio;
        start = self.days[0];
        p.demo = True;
        p.demo_version = DEMO_VERSION;
        p.mode = PortfolioMode.AUTO;
        p.starting_cash = STARTING_CASH;
        p.opened_at = at(start, "09:00");
        p.peak_equity = STARTING_CASH;
        for kind in [BaselineKind.EQUAL_WEIGHT, BaselineKind.SPY] {
            public(p +>:Benchmarks:+> Baseline(kind=kind, starting_cash=STARTING_CASH, start_day=start, cash=STARTING_CASH, peak_equity=STARTING_CASH));
        }
        for day in self.run_days {
            if day in self.days {
                run = self.morning(self.days.index(day), day);
                log = self.execute(run, day);
                log.extend(self.open_options(run, day));
                log.extend(self.manage_options(day));
                log.extend(self.stops(day));
                log.extend(self.close(run, day));
            } else {
                # A weekend: coins alone, and nothing marked, reconciled, or scored.
                run = self.morning(-1, day);
                log = self.execute(run, day);
                log.extend(self.stops(day));
                run.day_orders_closed_at = at(day, "15:50");
                log.append("15:50 close: no stock session today, so nothing is reconciled or scored");
            }
            # In the order the steps happened, as the jobs append them.
            run.action_log = sorted(log, key=lambda (line: str) { line[:5]; });
        }
        self.evening_review();
    }

    def weekend(day: str) -> bool {
        return day not in self.days;
    }

    """Daily bars for every stock and SPY: a market factor plus each stock's own move. Then a bar
    every calendar day for each coin: Bitcoin's move, which the other coins partly follow, plus
    each coin's own."""
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
        coins = {s.ticker: s.price for s in COINS};
        btc = COINS[0].vol;
        for day in self.coin_days {
            market = self.coin_rng.gauss(0.0, btc);
            for s in COINS {
                beta = 1.0 if s.ticker == CRYPTO_BENCHMARK else COIN_BETA;
                alone = math.sqrt(max(s.vol * s.vol - (beta * btc) ** 2, 0.004 ** 2));
                move = s.drift + beta * market + self.coin_rng.gauss(0.0, alone);
                coins[s.ticker] = self.add_bar(s.ticker, day, coins[s.ticker], move, self.coin_rng.gauss(0.0, 0.002), s.vol / 2, self.coin_rng);
            }
        }
    }

    def add_bar(ticker: str, day: str, before: float, move: float, gap: float, wick: float, rng: random.Random | None = None) -> float {
        draw = rng or self.rng;
        o = px(before * (1.0 + gap));
        c = px(before * (1.0 + move));
        low = px(min(o, c) * (1.0 - abs(draw.gauss(0.0, wick))));
        high = px(max(o, c) * (1.0 + abs(draw.gauss(0.0, wick))));
        self.bars.setdefault(ticker, {})[day] = bar(day, c, open=o, low=low, high=high);
        return c;
    }

    def close_of(ticker: str, day: str) -> float {
        return self.bars[ticker][day].close;
    }

    """The days `ticker` trades: every calendar day for a coin, weekdays for a stock."""
    def days_of(ticker: str) -> list[str] {
        return self.coin_days if is_crypto(ticker) else self.sessions;
    }

    """The last `n` of `ticker`'s sessions before `day` (a stock's, when no ticker is given)."""
    def before(day: str, n: int, ticker: str = "") -> list[str] {
        return [s for s in self.days_of(ticker) if s < day][-n:];
    }

    """The latest close of `ticker` on or before `day`."""
    def mark(ticker: str, day: str) -> float {
        found = self.bars[ticker].get(day);
        return found.close if found is not None else self.close_of(ticker, self.before(day, 1, ticker)[0]);
    }

    def realized_vol(ticker: str, day: str) -> float {
        closes = [self.close_of(ticker, s) for s in self.before(day, 21, ticker)];
        returns = [b / a - 1.0 for (a, b) in zip(closes, closes[1:])];
        return statistics.stdev(returns) * math.sqrt(365 if is_crypto(ticker) else 252);
    }

    def atr(ticker: str, day: str) -> float {
        days = self.before(day, 15, ticker);
        ranges = [max(self.bars[ticker][d].high, self.bars[ticker][p].close) - min(self.bars[ticker][d].low, self.bars[ticker][p].close) for (p, d) in zip(days, days[1:])];
        return statistics.fmean(ranges);
    }

    """The stock's return over the next five sessions less SPY's, or a coin's over the next week
    less Bitcoin's: what a good panel would sense. The votes lean on it, so their hit rate ends
    up a little better than a coin flip."""
    def outlook(ticker: str, day: str) -> float {
        coin = is_crypto(ticker);
        ahead = [s for s in self.days_of(ticker) if s >= day][:7 if coin else 5];
        last = self.before(day, 1, ticker)[0];
        end = ahead[-1];
        mine = self.close_of(ticker, end) / self.close_of(ticker, last) - 1.0;
        bench = CRYPTO_BENCHMARK if coin else BENCHMARK;
        other = 0.0 if ticker == bench else self.close_of(bench, end) / self.close_of(bench, last) - 1.0;
        return (mine - other) / max(self.stocks[ticker].vol * 2.2, 0.01);
    }

    """Open stock and coin positions."""
    def held -> dict[str, Position] {
        return {p.ticker: p for p in [self.portfolio ->:Holds:->[?:Position]] if p.open() and p.asset_class != OPTIONS};
    }

    def held_options -> dict[str, Position] {
        return {p.ticker: p for p in [self.portfolio ->:Holds:->[?:Position]] if p.open() and p.asset_class == OPTIONS};
    }

    """Every open position at `day`'s close: options at their Black-Scholes mid."""
    def positions_value(day: str) -> float {
        stocks = sum(p.qty * self.mark(t, day) for (t, p) in self.held().items());
        return stocks + sum(p.qty * p.multiplier * self.option_mid(t, day, False) for (t, p) in self.held_options().items());
    }

    """What the portfolio is worth at `day`'s open, options at their last mark."""
    def equity_at_open(day: str) -> float {
        def opening(t: str) -> float {
            found = self.bars[t].get(day);
            return found.open if found is not None else self.mark(t, day);
        }
        return self.cash + sum(p.qty * opening(t) for (t, p) in self.held().items()) + self.options_value();
    }

    def options_value -> float {
        return sum(p.qty * p.multiplier * p.last_price for p in self.held_options().values());
    }

    """A contract's Black-Scholes value at `day`'s open or close, on its stock's realized volatility
    with a premium, as the market would quote it."""
    def option_mid(symbol: str, day: str, at_open: bool) -> float {
        parts = contract(symbol);
        b = self.bars[parts.underlying][day];
        years = max(0, (date.fromisoformat(parts.expiry) - date.fromisoformat(day)).days) / 365.0;
        vol = max(IV_FLOOR, self.realized_vol(parts.underlying, day) * IV_PREMIUM);
        return black_scholes(b.open if at_open else b.close, parts.strike, years, vol, parts.kind);
    }

    def option_quote(symbol: str, day: str, at_open: bool) -> OptionQuote {
        mid = self.option_mid(symbol, day, at_open);
        half = max(0.01, mid * OPTION_HALF_SPREAD);
        when = at(day, "09:45" if at_open else "16:00");
        url = f"https://data.alpaca.markets/v1beta1/options/snapshots?symbols={symbol}&feed=indicative";
        return OptionQuote(
            symbol=symbol,
            bid=max(0.0, round(mid - half, 2)),
            ask=round(mid + half, 2),
            at=when,
            stamp=Stamp(source="alpaca_data", dataset="alpaca.option_snapshots", source_url=url, published_at=when, fetched_at=when)
        );
    }
    # --- Morning run ---------------------------------------------------------------------

    """The morning run of session `i` on `day`. A weekend run (`i` below zero) covers the coins
    alone, as a live one does when the stock market is closed."""
    def morning(i: int, day: str) -> Run {
        weekend = self.weekend(day);
        fallback = i == FALLBACK_SESSION;
        held = self.held();
        requests = self.rng.randint(24, 38) if weekend else self.rng.randint(58, 92);
        run = public(self.portfolio +>:Ran():+> Run(
            run_date=day,
            started_at=at(day, "07:30"),
            status=RunStatus.FALLBACK if fallback else RunStatus.NORMAL,
            finished_at=at(day, f"08:{self.rng.randint(31, 58):02d}"),
            model_versions={"primary": PRIMARY_MODEL, "fallback": FALLBACK_MODEL, "consensus": CONSENSUS_VERSION, "gate": GATE_VERSION},
            model_requests=requests,
            prompt_tokens=requests * self.rng.randint(2600, 3400),
            completion_tokens=requests * self.rng.randint(380, 520),
            asset_classes=list(ASSET_CLASSES)
        ));
        self.macro(run, day);
        covered: list[Coverage] = [];
        picks: list[str] = [];
        held_stocks = sorted(t for t in held if not is_crypto(t));
        if not weekend {
            others = [s.ticker for s in UNIVERSE if s.ticker not in held];
            self.rng.shuffle(others);
            picks = sorted(others[:SHORTLIST]);
            scores = sorted([round(self.rng.uniform(0.52, 0.94), 3) for _ in picks], reverse=True);
            for (t, score) in zip(picks, scores) {
                covered.append(self.cover(run, t, day, CoverageReason.SCREEN, score, ""));
            }
            for t in held_stocks {
                covered.append(self.cover(run, t, day, CoverageReason.HELD, 0.0, "open position"));
            }
        }
        coins = sorted(COINS, key=lambda (s: DemoStock) { -s.volume * self.mark(s.ticker, self.before(day, 1, s.ticker)[0]); });
        for s in coins {
            covered.append(self.cover(run, s.ticker, day, CoverageReason.SCREEN, 0.0, f"Among the {len(COINS)} most traded coins by 20-day dollar volume"));
        }
        ordered = sorted(covered, key=lambda (c: Coverage) { -self.outlook(c.ticker, day); });
        failing = covered[0].ticker if not weekend and covered and (len(self.days) - 1 - i) % FAILURE_EVERY == 0 else "";
        for c in covered {
            self.analyze(c, day, held.get(c.ticker), FAILED_SPECIALIST if c.ticker == failing else None);
            publish_card(c, day, PortfolioMode.AUTO.value, run.finished_at);
        }
        buys = len([c for c in covered if self.action_of(c) in (TradeAction.BUY, TradeAction.ADD)]);
        sells = len([c for c in covered if self.action_of(c) in (TradeAction.SELL, TradeAction.TRIM)]);
        lead = ordered[0].ticker if ordered else "";
        trades = f"{count(buys, 'buy or add', 'buys or adds')} and {count(sells, 'sell or trim', 'sells or trims')} went to the risk gate; the rest hold.";
        if weekend {
            run.summary = f"Weekend run. The stock market is closed, so the panel covered the {len(coins)} most traded coins alone and was strongest on {lead}. {trades}";
        } elif fallback {
            run.summary = f"Fallback run. The Orchestrator stopped at iteration 9 with the request budget spent, and the Run Guard finished research and the panel in fixed order. {count(len(covered), 'ticker')} covered: {count(buys, 'buy or add', 'buys or adds')}, {count(sells, 'sell or trim', 'sells or trims')}.";
            run.reduced_mode = False;
        } else {
            run.summary = f"Covered {count(len(covered), 'ticker')} ({len(picks)} from the screen, {len(held_stocks)} held, {count(len(coins), 'coin')}). The panel was strongest on {lead}. {trades}";
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
        coin = is_crypto(ticker);
        last = self.before(day, 1, ticker)[0];
        # A coin has no earnings.
        earnings = None if coin else self.rng.choice([1, 2, 6, 11, 17, 24, 33, 41, None]);
        # The indicators a policy's rules read, from the bars before the run, as a live run
        # computes them; the tape is too short for the 200-day figures.
        past = [self.bars[ticker][d] for d in self.before(day, len(self.coin_days), ticker)];
        spy = [self.bars[BENCHMARK][d] for d in self.before(day, len(self.sessions))];
        closes = [b.close for b in past];
        return public(run +>:Covers():+> Coverage(
            ticker=ticker,
            sector=s.sector,
            reason=reason,
            screen_score=score,
            reason_note=note,
            last_close=self.close_of(ticker, last),
            atr_14=round(self.atr(ticker, day), 6 if coin else 4),
            realized_vol_20=round(self.realized_vol(ticker, day), 4),
            volume_20=s.volume * (self.coin_rng if coin else self.rng).uniform(0.85, 1.15),
            sessions_to_earnings=earnings,
            rsi_14=rsi(closes),
            momentum_20=momentum(closes, 20),
            momentum_60=momentum(closes, 60),
            sma_50=sma(closes, 50),
            sma_200=sma(closes, 200),
            range_52w_position=range_position([b.high for b in past], [b.low for b in past], closes[-1]),
            rs_spy_20=relative_strength(past, spy, 20),
            asset_class=CRYPTO if coin else STOCKS
        ));
    }

    """The research a live run writes on `c`: market, fundamentals, and news for a stock, and
    market and news for a coin, which has no filings. Each is (summary, evidence, data gaps)."""
    def research_for(c: Coverage, day: str, signal: float) -> dict[Domain, tuple[str, list[Evidence], list[str]]] {
        t = c.ticker;
        s = self.stocks[t];
        last = self.before(day, 1, t)[0];
        start = self.before(day, 21, t)[0];
        month = self.close_of(t, last) / self.close_of(t, start) - 1.0;
        avg30 = statistics.fmean(self.close_of(t, d) for d in self.before(day, 30, t));
        tone = "mostly positive" if signal > 0.15 else ("mixed" if signal > -0.15 else "mostly negative");
        articles = self.rng.randint(4, 19);
        wiki = Evidence(claim="Background and history.", source_url=f"https://en.wikipedia.org/wiki/{s.name}", published=last);
        if is_crypto(t) {
            btc = self.close_of(CRYPTO_BENCHMARK, last) / self.close_of(CRYPTO_BENCHMARK, start) - 1.0;
            bars_url = f"https://data.alpaca.markets/v1beta3/crypto/us/bars?symbols={t}&timeframe=1Day&start={start}";
            news_url = f"https://data.alpaca.markets/v1beta1/news?symbols={t.replace('/', '')}";
            versus = "" if t == CRYPTO_BENCHMARK else f", against {btc:+.1%} for {CRYPTO_BENCHMARK}";
            return {
                Domain.MARKET: (
                    f"{t} closed at {money(self.close_of(t, last))}, {month:+.1%} over 20 days{versus}, and {self.close_of(t, last) / avg30 - 1.0:+.1%} against its 30-day average. ATR(14) is {money(c.atr_14 or 0.0)} and 20-day realized volatility {c.realized_vol_20:.0%}, annualized over every calendar day, since it trades around the clock. Volume is near its 20-day average of {c.volume_20:,.0f} coins.",
                    [Evidence(claim=f"Closed at {money(self.close_of(t, last))} on {last}, {month:+.1%} over 20 days.", source_url=bars_url, published=last)],
                    []
                ),
                Domain.NEWS: (
                    f"Coverage was {tone} across {articles} articles this week, led by fund flows and on-chain activity. No exchange failure or new enforcement action appeared.",
                    [Evidence(claim="Headlines from the past seven days.", source_url=news_url, published=last), wiki],
                    [f"{t} is a coin: it has no earnings, company filings, or scheduled releases"]
                )
            };
        }
        bars_url = f"https://data.alpaca.markets/v2/stocks/bars?symbols={t}&timeframe=1Day&start={start}";
        return {
            Domain.MARKET: (
                f"{t} closed at {self.close_of(t, last):.2f}, {month:+.1%} over 20 sessions and {self.close_of(t, last) / avg30 - 1.0:+.1%} against its 30-day average. ATR(14) is {c.atr_14:.2f} and 20-day realized volatility {c.realized_vol_20:.0%}. Volume is near its 20-day average of {c.volume_20 / 1e6:.1f}M shares.",
                [Evidence(claim=f"Closed at {self.close_of(t, last):.2f} on {last}, {month:+.1%} over 20 sessions.", source_url=bars_url, published=last)],
                ["No intraday data."] if self.rng.random() < 0.2 else []
            ),
            Domain.FUNDAMENTALS: (
                f"The latest 10-Q shows revenue {self.rng.uniform(-3, 18):+.1f}% year over year and an operating margin of {self.rng.uniform(12, 42):.0f}%. Guidance was {self.rng.choice(['raised', 'reaffirmed', 'trimmed'])}. The balance sheet carries {self.rng.choice(['net cash', 'modest net debt', 'net debt near 1.5x EBITDA'])}.",
                [
                    Evidence(claim="Quarterly revenue and margins from the latest 10-Q.", source_url=f"https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&CIK={s.cik}&type=10-Q", published=self.before(day, 25)[0]),
                    Evidence(claim="Reported financial facts from XBRL company facts.", source_url=f"https://data.sec.gov/api/xbrl/companyfacts/CIK{s.cik.zfill(10)}.json", published=self.before(day, 25)[0])
                ],
                [FLOW_GAP] if self.rng.random() < FLOW_GAP_SHARE else []
            ),
            Domain.NEWS: (
                f"Coverage was {tone} across {articles} articles this week. No new legal or regulatory matter appeared. Earnings are {'due in ' + str(c.sessions_to_earnings) + ' sessions' if c.sessions_to_earnings is not None else 'not scheduled within the calendar'}.",
                [Evidence(claim="Headlines from the past seven days.", source_url=f"https://data.alpaca.markets/v1beta1/news?symbols={t}", published=last), wiki],
                []
            )
        };
    }

    """Research, votes, consensus, and the Arbiter's decision for one coverage. Every sample of
    the `failed` specialist fails: its votes are drawn, so the random sequence stays the same, but
    not stored, and the coverage records why each was dropped, as run/analysis.jac does. A coin's
    panel is the specialists who read prices, news, and the macro backdrop."""
    def analyze(c: Coverage, day: str, position: Position | None, failed: Specialist | None = None) {
        t = c.ticker;
        coin = is_crypto(t);
        signal = self.bias[t] + 0.3 * self.outlook(t, day) + self.rng.gauss(0.0, 0.25);
        bodies: dict[Domain, ResearchReport] = {};
        for (domain, (summary, evidence, gaps)) in self.research_for(c, day, signal).items() {
            view = signal + self.rng.gauss(0.0, 0.3);
            bodies[domain] = ResearchReport(
                summary=summary,
                view=stance_for(view),
                confidence=round(self.rng.uniform(0.5, 0.8), 2),
                evidence=evidence,
                risks=[self.rng.choice(COIN_RISKS if coin else ["A broad market pullback.", "Valuation compresses if rates rise.", "A guidance cut at the next report.", "Sector rotation away from the group."])],
                data_gaps=gaps
            );
            public(c +>:Researched():+> ResearchRecord(ticker=t, domain=domain, as_of=at(day, "07:50"), model=PRIMARY_MODEL, body=bodies[domain]));
        }
        no_flow = Domain.FUNDAMENTALS in bodies and FLOW_GAP in bodies[Domain.FUNDAMENTALS].data_gaps;

        votes: dict[Specialist, list[Vote]] = {};
        for spec in specialists_for(t) {
            # Cite positions in the packet the specialist would read, as a real vote does.
            shown = len(packet(spec, t, day, bodies, self.macro_body).evidence);
            lean = signal + self.rng.gauss(0.0, 0.18);
            mine: list[Vote] = [];
            for k in range(SAMPLES) {
                x = lean + self.rng.gauss(0.0, 0.12);
                stance = stance_for(x);
                direction = 1 if x > 0.14 else (-1 if x < -0.14 else 0);
                if spec == Specialist.FLOW and no_flow {
                    # No flow data, so Flow abstains on the supplied gap, as a live run does.
                    v = Vote(stance=Stance.HOLD, confidence=0.5, horizon_days=DEFAULT_HORIZON_DAYS, rationale="No insider or institutional flow data is available, so there is no view.", cited_gaps=[FLOW_GAP]);
                    mine.append(v);
                    public(c +>:Voted():+> VoteRecord(ticker=t, specialist=spec, sample=k, model=PRIMARY_MODEL, body=v));
                    continue;
                }
                v = Vote(
                    stance=stance,
                    confidence=round(min(0.92, max(0.45, 0.62 + abs(x) * 0.3 + self.rng.gauss(0.0, 0.05))), 2),
                    horizon_days=self.rng.choice([5, DEFAULT_HORIZON_DAYS, DEFAULT_HORIZON_DAYS]),
                    rationale=(COIN_RATIONALE if coin else RATIONALE)[spec][direction],
                    cited_evidence=sorted(self.rng.sample(range(shown), min(shown, self.rng.randint(1, 3))))
                );
                mine.append(v);
                if spec == failed {
                    c.analysis_errors = c.analysis_errors + [f"{spec.value} sample {k}: {FAILURE_ERROR}"];
                    continue;
                }
                public(c +>:Voted():+> VoteRecord(ticker=t, specialist=spec, sample=k, model=PRIMARY_MODEL, body=v));
            }
            if spec != failed {
                votes[spec] = mine;
            }
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
            samples_used=found.samples_used,
            samples_dropped=len(c.analysis_errors)
        ));
        action = draft;
        verdict = "CONFIRM";
        reason = "";
        if draft in (TradeAction.BUY, TradeAction.ADD) and found.agreement < 0.75 and self.rng.random() < 0.35 {
            action = TradeAction.HOLD if draft == TradeAction.ADD else TradeAction.NO_ACTION;
            verdict = "DOWNGRADE";
            reason = self.rng.choice([
                "the technical and news specialists disagree on the near-term catalyst, and the interval sits close to zero",
                "the panel's case rests on momentum that a broad sell-off would undo",
                "two specialists cite the same single source, so the agreement overstates the evidence"
            ] if coin else [
                "the fundamentals and news specialists disagree on the near-term catalyst, and the interval sits close to zero",
                "earnings are near and the panel's case rests on momentum that a miss would undo",
                "two specialists cite the same single source, so the agreement overstates the evidence"
            ]);
        }
        bullish = action in (TradeAction.BUY, TradeAction.ADD, TradeAction.HOLD);
        leaning = "positive" if found.score > 0 else "negative";
        if action in (TradeAction.BUY, TradeAction.ADD) {
            thesis = f"{t} is among the most traded coins and the panel leans {leaning}: price momentum and news flow point the same way over about two weeks." if coin else f"{t} screens well and the panel leans {leaning}: technical momentum and {'steady' if bullish else 'softening'} fundamentals point the same way over about two weeks.";
        } elif exit_due {
            thesis = f"The time stop on {t} has come due, so the position is closed whatever the panel says.";
        } else {
            thesis = f"The panel's case on {t} is not strong enough to act on: score {found.score:+.2f} with agreement {found.agreement:.0%}.";
        }
        risks = ["A broad crypto sell-off would take it down with Bitcoin.", "A regulatory headline could move every coin at once.", "Weekend liquidity is thin, so prices can gap.", "Fund outflows could reverse the trend quickly."] if coin else ["A broad market pullback would hit it with the rest.", "Valuation leaves little room for a miss.", "Rising yields could rotate money out of the sector.", "A guidance cut at the next report would break the thesis.", "Crowded positioning could unwind quickly."];
        self.decisions += 1;
        public(c +>:Decided():+> Decision(
            ticker=t,
            action=action,
            conviction=found.conviction(),
            thesis=thesis,
            risks=self.rng.sample(risks, 2),
            exit_condition=f"A close below {money(c.last_close - 2.0 * (c.atr_14 or 0.0))} (two ATRs under the last close), or the panel turning negative.",
            time_stop=trading_day_after(self.calendar, day, DEFAULT_HORIZON_DAYS) if action == TradeAction.BUY else (position.time_stop if position is not None else ""),
            downgrade_reason=reason,
            arbiter_verdict=verdict,
            model=PRIMARY_MODEL
        ));
    }
    # --- Execution ----------------------------------------------------------------------

    """Size and gate the run's decisions at 9:45, then fill the approved orders near the open
    and place each position's stop, as the executor does. On a weekend only coins trade."""
    def execute(run: Run, day: str) -> list[str] {
        log: list[str] = [];
        now = at(day, "09:45");
        weekend = self.weekend(day);
        held = self.held();
        decided: dict[str, tuple[Coverage, Decision]] = {};
        for c in [run ->:Covers:->[?:Coverage]] {
            for d in [c ->:Decided:->[?:Decision]] {
                decided[c.ticker] = (c, d);
            }
        }
        prices = {t: px(self.bars[t][day].open * (1.0 + self.rng.gauss(0.0, 0.0015))) for t in decided};
        def price_of(t: str) -> float {
            return prices.get(t) or self.mark(t, self.before(day, 1, t)[0]);
        }
        options = self.options_value();
        equity = self.cash + sum(p.qty * price_of(t) for (t, p) in held.items()) + options;
        candidates = [
            SizingCandidate(ticker=t, action=d.action, conviction=d.conviction, price=prices[t], realized_vol_20=c.realized_vol_20, current_qty=held[t].qty if t in held else 0, increment=self.stocks[t].increment)
            for (t, (c, d)) in sorted(decided.items())
        ];
        plan = size_positions(candidates, equity);
        proposals = [Proposal(ticker=p.ticker, action=c.action, side=p.side, qty=abs(p.share_delta), conviction=c.conviction) for (p, c) in zip(plan.positions, candidates) if p.side is not None and p.share_delta != 0];
        instruments = {
            t: Instrument(
                ticker=t,
                price=prices[t],
                sector=c.sector,
                tradable=True,
                trade_age_minutes=0.2,
                atr_14=c.atr_14,
                volume_20=c.volume_20,
                sessions_to_earnings=c.sessions_to_earnings,
                increment=self.stocks[t].increment,
                min_qty=self.stocks[t].min_qty,
                crypto=is_crypto(t),
                enabled=True
            )
            for (t, (c, d)) in decided.items()
        };
        gate = GateConfig();
        book = Book(
            equity=equity,
            peak_equity=max(breaker_peak(STARTING_CASH, self.closes, gate.drawdown_window), equity),
            positions={t: BookPosition(ticker=t, qty=p.qty, price=price_of(t), sector=p.sector) for (t, p) in held.items()},
            other_value=options
        );
        results = check_orders(proposals, book, instruments, run_regime(run), gate);
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
                gate_version=GATE_VERSION,
                asset_class=CRYPTO if is_crypto(r.ticker) else STOCKS
            ));
            if r.approved_qty > 0 {
                approved += 1;
                log.append(f"09:45 execute: {self.trade(rc, r, run.run_date, day, held.get(r.ticker))}");
            } else {
                log.append(f"09:45 execute: {r.ticker} {r.side.value} {r.requested_qty:g} refused by {r.rejected_by()}");
            }
        }
        run.executed_at = now;
        run.execution_note = f"{len(results)} checks, {approved} approved";
        log.insert(0, f"09:45 execute: {run.execution_note}");
        for (t, p) in self.held().items() {
            if weekend and not is_crypto(t) {
                continue;
            }
            if not [o for o in [p ->:StoppedBy:->[?:Order]] if o.status == "new"] {
                log.append(f"09:47 stop: {self.place_stop(p, day)}");
            }
        }
        return log;
    }

    """Send and fill one approved order. A position's working stop is canceled first. A coin's
    entry is a GTC limit, since Alpaca takes no DAY order for crypto."""
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
        coin = is_crypto(rc.ticker);
        price = rc.price;
        partial = not coin and r.side == OrderSide.BUY and self.rng.random() < 0.08;
        qty = r.approved_qty;
        filled = max(1, int(qty * 0.3)) if partial else qty;
        fill_price = px(price * (1.0 + (0.0004 if r.side == OrderSide.BUY else -0.0004)));
        self.orders += 1;
        order = Order(
            client_order_id=order_id_for(run_day, rc.ticker, r.purpose),
            purpose=r.purpose,
            side=r.side,
            qty=qty,
            order_type="limit",
            time_in_force="gtc" if coin else "day",
            submitted_at=at(day, "09:45"),
            alpaca_order_id=f"demo-{self.orders:05d}",
            limit_price=limit_price(r.side, price),
            status="canceled" if partial else "filled",
            ticker=rc.ticker,
            filled_qty=filled,
            filled_avg_price=fill_price,
            updated_at=at(day, "15:50") if partial else at(day, "09:46"),
            asset_class=CRYPTO if coin else STOCKS
        );
        public(rc +>:Placed():+> order);
        self.portfolio +>:Sent():+> order;
        public(order +>:FilledBy():+> Fill(qty=filled, price=fill_price, filled_at=at(day, "09:46")));
        if r.side == OrderSide.SELL {
            self.cash += filled * fill_price;
            if position is not None {
                position.qty = round(position.qty - filled, 12) if coin else position.qty - filled;
                if position.qty <= 0 {
                    position.qty = 0;
                    position.closed_at = at(day, "09:46");
                    position.exit_price = fill_price;
                    return f"{rc.ticker} sold {filled:g} @ {money(fill_price)}: closed ({r.purpose.value})";
                }
            }
            return f"{rc.ticker} sold {filled:g} @ {money(fill_price)} ({r.purpose.value})";
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
                stop_price=stop_round(fill_price - rc.stop_distance),
                time_stop=decided[0].time_stop if decided else "",
                last_price=fill_price,
                priced_at=at(day, "09:46"),
                asset_class=CRYPTO if coin else STOCKS
            ));
            if decided {
                position +>:OpenedBy():+> decided[0];
            }
        } else {
            position.avg_entry_price = (position.avg_entry_price * position.qty + fill_price * filled) / (position.qty + filled);
            position.qty = round(position.qty + filled, 12) if coin else position.qty + filled;
            position.stop_price = max(position.stop_price, stop_round(fill_price - rc.stop_distance));
        }
        note = f", {qty - filled:g} canceled at 15:50" if partial else "";
        return f"{rc.ticker} bought {filled:g} of {qty:g} @ {money(fill_price)}{note}";
    }

    """Place a position's protective stop: a GTC stop for a stock, and for a coin a GTC
    stop-limit a little under the stop, since Alpaca has no plain stop for crypto."""
    def place_stop(position: Position, day: str) -> str {
        coin = is_crypto(position.ticker);
        position.stops_placed += 1;
        self.orders += 1;
        order = Order(
            client_order_id=stop_id_for(position, position.stops_placed),
            purpose=OrderPurpose.STOP,
            side=OrderSide.SELL,
            qty=position.qty,
            order_type="stop_limit" if coin else "stop",
            time_in_force="gtc",
            submitted_at=at(day, "09:47"),
            alpaca_order_id=f"demo-{self.orders:05d}",
            stop_price=position.stop_price,
            limit_price=stop_round(position.stop_price * (1.0 - CRYPTO_STOP_SLIPPAGE)) if coin else 0.0,
            status="new",
            ticker=position.ticker,
            updated_at=at(day, "09:47"),
            asset_class=CRYPTO if coin else STOCKS
        );
        position.stop_order_id = order.alpaca_order_id;
        public(position +>:StoppedBy():+> order);
        self.portfolio +>:Sent():+> order;
        return f"{position.ticker}: stop for {position.qty:g} at {money(position.stop_price)}: new";
    }

    """Fire every working stop the day's low reached, at the stop or a lower open; a coin's
    stop-limit fills no lower than its limit. On a weekend only coins trade."""
    def stops(day: str) -> list[str] {
        log: list[str] = [];
        for (t, p) in sorted(self.held().items()) {
            b = self.bars[t].get(day);
            if b is None or p.stop_price <= 0.0 or b.low > p.stop_price {
                continue;
            }
            price = px(min(b.open, p.stop_price));
            if is_crypto(t) {
                price = max(price, stop_round(p.stop_price * (1.0 - CRYPTO_STOP_SLIPPAGE)));
            }
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
            log.append(f"13:15 fill: {t}: closed @ {money(price)} (stop)");
            p.qty = 0;
            p.closed_at = at(day, "13:12");
            p.exit_price = price;
            p.stop_order_id = "";
        }
        return log;
    }

    # --- Options ------------------------------------------------------------------------

    """Buy calls and puts on the run's views by action/options.jac's rules (its views, contract
    choice, spread and premium limits, and daily cap), on the demo's listed contracts and quotes.
    Each entry fills at its limit."""
    def open_options(run: Run, day: str) -> list[str] {
        config = OptionsConfig();
        now = at(day, "09:46");
        run.options_at = now;
        equity = self.equity_at_open(day);
        spent = self.options_value();
        underlyings = {contract(t).underlying for t in self.held_options()};
        peak = max(breaker_peak(STARTING_CASH, self.closes, GateConfig().drawdown_window), equity);
        drawn_down = equity <= peak * (1.0 - GateConfig().drawdown_halt);
        lines: list[str] = [];
        opened = 0;
        for v in option_views(run, set(self.held()), MarketView(), config) {
            if v.ticker in underlyings {
                continue;
            }
            rules: list[RuleResult] = [];
            def refuse(rule: str, detail: str) -> str {
                rules.append(RuleResult(rule=rule, passed=False, detail=detail));
                self.option_check(v.decision, v.ticker, 0, 0.0, rules, now, RiskOutcome.REJECTED);
                return f"09:46 options: {v.ticker} {v.kind}: {detail}";
            }
            if drawn_down {
                lines.append(refuse("drawdown breaker", f"equity is {1 - equity / peak:.1%} below its peak; no new options"));
                continue;
            }
            if opened >= config.new_per_day {
                lines.append(refuse("new options per day", f"{config.new_per_day} new options a day, kept for higher conviction"));
                continue;
            }
            spot = self.bars[v.ticker][day].open;
            (start, end) = expiry_window(day, config.min_days, config.max_days);
            listed = demo_contracts(ContractQuery(underlying=v.ticker, kind=v.kind, expiry_from=start, expiry_to=end, strike_low=spot * (1.0 - config.strike_band), strike_high=spot * (1.0 + config.strike_band)));
            chosen = choose_contract(listed, spot, v.kind, day, config.min_days, config.max_days, config.target_days);
            if chosen is None {
                lines.append(refuse("contract", f"no tradable {v.kind} {config.min_days} to {config.max_days} days out near ${spot:,.2f}"));
                continue;
            }
            rules.append(RuleResult(rule="contract", passed=True, detail=f"{describe_option(chosen.symbol)}, strike nearest the money on the side of the view"));
            quote = self.option_quote(chosen.symbol, day, True);
            if quote.mid() <= 0.0 {
                lines.append(refuse("quote", f"no two-sided quote for {chosen.symbol}"));
                continue;
            }
            if quote.spread() > config.max_spread {
                lines.append(refuse("spread", f"the spread is {quote.spread():.0%} of the mid, above {config.max_spread:.0%}"));
                continue;
            }
            rules.append(RuleResult(rule="spread", passed=True, detail=f"bid {quote.bid:.2f}, ask {quote.ask:.2f}"));
            limit = min(to_tick(quote.mid() + 0.25 * (quote.ask - quote.bid), True), to_tick(quote.ask, True));
            cost = limit * CONTRACT_SIZE;
            room = min(config.position_premium * equity, config.total_premium * equity - spent);
            qty = int(math.floor(room / cost)) if cost > 0 else 0;
            if qty < 1 {
                lines.append(refuse("premium budget", f"one contract costs ${cost:,.0f}; the room is ${max(0.0, room):,.0f} ({config.position_premium:.0%} of equity each, {config.total_premium:.0%} in all)"));
                continue;
            }
            rules.append(RuleResult(rule="premium budget", passed=True, detail=f"{qty} contract{'s' if qty != 1 else ''} at ${limit:.2f} costs ${qty * cost:,.0f}", qty_before=qty, qty_after=qty));
            rc = self.option_check(v.decision, chosen.symbol, qty, limit, rules, now, RiskOutcome.APPROVED);
            order = self.option_order(rc, f"{run.run_date}-{chosen.symbol}-entry", OrderSide.BUY, qty, limit);
            position = public(self.portfolio +>:Holds():+> Position(
                ticker=chosen.symbol,
                sector=self.stocks[v.ticker].sector,
                qty=qty,
                avg_entry_price=limit,
                opened_at=order.updated_at,
                last_price=limit,
                priced_at=order.updated_at,
                asset_class=OPTIONS,
                multiplier=CONTRACT_SIZE
            ));
            position +>:OpenedBy():+> v.decision;
            self.cash -= qty * cost;
            spent += qty * cost;
            opened += 1;
            underlyings.add(v.ticker);
            lines.append(f"09:46 options: {describe_option(chosen.symbol)} buy {qty} @ {limit:.2f}: filled");
        }
        return lines;
    }

    """Sell each option an exit rule of action/options.jac calls for, at its bid, at 10:00."""
    def manage_options(day: str) -> list[str] {
        config = OptionsConfig();
        now = at(day, "10:00");
        latest = latest_decisions(self.portfolio);
        lines: list[str] = [];
        for (symbol, p) in sorted(self.held_options().items()) {
            if p.opened_at >= at(day, "00:00") {
                continue;
            }
            quote = self.option_quote(symbol, day, True);
            reason = exit_reason(p, day, quote, latest.get(contract(symbol).underlying), config);
            if not reason {
                continue;
            }
            limit = to_tick(quote.bid, False) if quote.bid > 0.0 else 0.01;
            qty = int(p.qty);
            rc = public(self.portfolio ++> RiskCheck(
                outcome=RiskOutcome.APPROVED,
                approved_qty=qty,
                checked_at=now,
                rules=[RuleResult(rule="option exit", passed=True, detail=reason, qty_before=qty, qty_after=qty)],
                ticker=symbol,
                side=OrderSide.SELL,
                purpose=OrderPurpose.EXIT,
                requested_qty=qty,
                price=limit,
                gate_version=OPTIONS_VERSION,
                asset_class=OPTIONS
            ));
            p.stops_placed += 1;
            self.option_order(rc, f"{day}-{symbol}-exit{p.stops_placed}", OrderSide.SELL, qty, limit);
            self.cash += qty * limit * p.multiplier;
            p.qty = 0;
            p.closed_at = at(day, "10:01");
            p.exit_price = limit;
            p.last_price = limit;
            p.priced_at = at(day, "10:01");
            lines.append(f"10:00 options: {describe_option(symbol)} sell {qty} @ {limit:.2f}: filled ({reason})");
        }
        return lines;
    }

    def option_check(decision: Decision, symbol: str, qty: int, price: float, rules: list[RuleResult], now: str, outcome: RiskOutcome) -> RiskCheck {
        return public(decision +>:CheckedBy():+> RiskCheck(
            outcome=outcome,
            approved_qty=qty,
            checked_at=now,
            rules=list(rules),
            ticker=symbol,
            side=OrderSide.BUY,
            purpose=OrderPurpose.ENTRY,
            requested_qty=qty,
            price=price,
            gate_version=OPTIONS_VERSION,
            asset_class=OPTIONS
        ));
    }

    """A DAY limit order for a contract, filled in full at its limit a minute after it is sent."""
    def option_order(rc: RiskCheck, client_id: str, side: OrderSide, qty: int, limit: float) -> Order {
        sent = rc.checked_at;
        filled_at = (datetime.fromisoformat(sent) + timedelta(minutes=1)).isoformat();
        self.orders += 1;
        order = Order(
            client_order_id=client_id,
            purpose=OrderPurpose.ENTRY if side == OrderSide.BUY else OrderPurpose.EXIT,
            side=side,
            qty=qty,
            order_type="limit",
            time_in_force="day",
            submitted_at=sent,
            alpaca_order_id=f"demo-{self.orders:05d}",
            limit_price=limit,
            status="filled",
            ticker=rc.ticker,
            filled_qty=qty,
            filled_avg_price=limit,
            updated_at=filled_at,
            asset_class=OPTIONS
        );
        public(rc +>:Placed():+> order);
        self.portfolio +>:Sent():+> order;
        public(order +>:FilledBy():+> Fill(qty=qty, price=limit, filled_at=filled_at));
        return order;
    }

    # --- Close and evening --------------------------------------------------------------

    def close(run: Run, day: str) -> list[str] {
        marked = at(day, "16:30");
        for (t, p) in self.held().items() {
            p.last_price = self.close_of(t, day);
            p.priced_at = marked;
        }
        for (t, p) in self.held_options().items() {
            p.last_price = round(self.option_mid(t, day, False), 2);
            p.priced_at = marked;
        }
        value = sum(p.qty * p.last_price for p in self.held().values()) + self.options_value();
        equity = self.cash + value;
        self.peak = max(self.peak, equity);
        self.closes.append(equity);
        self.portfolio.peak_equity = self.peak;
        drawdown = 1.0 - equity / self.peak;
        open_count = len(self.held()) + len(self.held_options());
        public(self.portfolio +>:Marked():+> DailyMark(day=day, equity=equity, cash=self.cash, positions_value=value, peak_equity=self.peak, marked_at=marked, drawdown=drawdown, open_positions=open_count));
        run.day_orders_closed_at = at(day, "15:50");
        run.reconciled_at = marked;
        run.votes_scored_at = marked;
        run.baselines_at = marked;
        lines = [f"16:30 reconcile: equity {equity:,.2f}, {open_count} positions, drawdown {drawdown:.1%}, 0 drift, 0 bypasses"];
        sim = SimDay(day=day, bars=self.bars, sessions=self.calendar, now=datetime.fromisoformat(marked));
        for (kind, b) in sorted(baselines_of(self.portfolio).items(), key=lambda (kv: tuple[BaselineKind, Baseline]) { kv[0].value; }) {
            done = simulate_spy(b, sim) if kind == BaselineKind.SPY else simulate_equal_weight(b, sim, run);
            b.trade_log = b.trade_log + done;
            lines.extend(f"16:30 baseline: {kind.value} {line}" for line in done);
        }
        return lines;
    }
    """The last evening's review, through the real scorers and evaluation on the demo's own bars
    and calendar, with the demo's stocks as the whole index: every vote, decision, and screen whose
    window closed by the last session is scored, and the evaluation is stored."""
    def evening_review {
        def read_bars(symbols: list[str], start: str, end: str) -> dict[str, dict[str, Bar]] {
            return {t: {d: b for (d, b) in self.bars[t].items() if start <= d <= end} for t in symbols if t in self.bars};
        }
        def read_sessions(start: str, end: str) -> list[str] {
            return [s for s in self.sessions if start <= s <= end];
        }
        def read_members(_day: str) -> list[str] {
            return [s.ticker for s in UNIVERSE];
        }
        history = History(bars=read_bars, sessions=read_sessions, members=read_members);
        now = datetime.fromisoformat(at(self.days[-1], "20:30"));
        score_all(self.portfolio, now, history);
        score_screens(self.portfolio, now, history);
        record_evaluation(self.portfolio, evaluate(self.portfolio, self.sessions, now));
    }
}
