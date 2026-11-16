"""One coin's page: its latest price and a year of daily bars, what those bars say, what the reader's
agent last decided about it, and the research notes its desks wrote on it. A coin has no filings or
analysts, so those sections a stock's page has are left out."""
import from "@jac/runtime" { Link, useParams }
import from "lucide-react" { ChevronRight, Star }
import from react { useEffect }
import from dashboard.market.PriceChart { PriceChart }
import from dashboard.market.columns { show_coin }
import from dashboard.market.saved { toggle_watch, watched }
import from dashboard.ui.format { day_long, day_short, num, pct, price, signed_money, signed_pct, stamp_et, ticker_from_path, tone }
import from dashboard.ui.parts { ActionBadge, Delta, Empty, ErrorBox, Loading, Overline, Panel, Stat }
import from dashboard.ui.rpc { get_coin, get_news_feed }
import from models.market { CoinView as CoinData }
import from models.views { NewsItem as NoteData }

glob NOTE_DESKS: dict[str, str] = {"market": "Market", "fundamentals": "Fundamentals", "news": "News", "macro": "Macro"};
glob NOTE_LIMIT: int = 12;

def number_of(coin: CoinData, key_: str) -> float | None {
    value = coin.values.get(key_);
    return value if isinstance(value, (int, float)) else None;
}

def CoinFigure(label: str, value: str, hint: str = "", value_tone: str = "text-text") -> JsxElement {
    <div className="min-w-0 bg-panel px-4 py-3.5">
        <Stat label={label} value={value} hint={hint} tone={value_tone}/>
    </div>
}

def CoinHeader(coin: CoinData, starred: bool, star: Callable[[], None]) -> JsxElement {
    now = number_of(coin, "price");
    change = number_of(coin, "change");
    change_pct = number_of(coin, "change_pct");
    at = str(coin.values.get("price_at") or "");
    <header className="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
        <div className="min-w-0">
            <div className="flex min-w-0 items-center gap-3">
                <span className="grid size-12 shrink-0 place-items-center rounded-md bg-panel-2 text-[18px] font-medium text-muted" aria-hidden="true">{coin.symbol[0:1]}</span>
                <div className="min-w-0">
                    <h1 className="display truncate text-[30px] leading-9 text-text">{coin.name}</h1>
                    <p className="flex flex-wrap items-center gap-x-1.5 text-[12px] text-muted">
                        <span className="font-semibold text-text">{coin.symbol}</span>
                        <span>Crypto · trades around the clock</span>
                    </p>
                </div>
                <button
                    type="button"
                    aria-pressed={starred}
                    aria-label={("Remove " + coin.symbol + " from the watchlist") if starred else ("Add " + coin.symbol + " to the watchlist")}
                    className={"press grid size-8 shrink-0 place-items-center rounded-md hover:bg-hover " + ("text-accent" if starred else "text-faint hover:text-text")}
                    onClick={lambda { star(); }}
                >
                    <Star size={16} strokeWidth={1.75} fill={"currentColor" if starred else "none"} aria-hidden="true"/>
                </button>
            </div>
            <div className="mt-3 flex flex-wrap items-center gap-x-2.5 gap-y-1">
                <span className="display text-[40px] leading-[44px] text-text">{price(now)}</span>
                <span className="text-[11px] text-muted">USD</span>
                <Delta text={signed_pct(change_pct)} value={change_pct}/>
                <span className={"num text-[13px] font-medium " + tone(change)}>{signed_money(change, 2 if now is None or now >= 1.0 else 4)}</span>
            </div>
            <p className="num mt-1 text-[12px] text-muted">{("Latest trade " + stamp_et(at) if "T" in at else "Last close") + " · change since midnight UTC"}</p>
        </div>
        {if coin.committee.run_day or coin.committee.held {
            <div className="flex flex-col gap-1.5 rounded-md border border-line bg-panel px-4 py-3 lg:min-w-64">
                <Overline>The committee</Overline>
                <div className="flex flex-wrap items-center gap-2 text-[13px] text-text">
                    {if coin.committee.action {
                        <ActionBadge action={coin.committee.action}/>
                    }}
                    {if coin.committee.held {
                        <span>{"Holds " + num(float(coin.committee.held_qty or 0), 4)}</span>
                    }}
                    {if coin.committee.trail {
                        <Link to={coin.committee.trail} className="text-accent hover:underline">{"Decision of " + day_short(coin.committee.run_day)}</Link>
                    }}
                </div>
            </div>
        }}
    </header>
}

def CoinStats(coin: CoinData) -> JsxElement {
    keys = ["perf_1w", "perf_1m", "perf_3m", "perf_1y", "high_52w", "low_52w", "volatility", "dollar_volume", "rsi_14", "sma_50_pct", "sma_200_pct", "beta"];
    labels = {
        "perf_1w": "1 week", "perf_1m": "1 month", "perf_3m": "3 months", "perf_1y": "1 year",
        "high_52w": "52-week high", "low_52w": "52-week low", "volatility": "Volatility 30D",
        "dollar_volume": "Avg dollar volume 30D", "rsi_14": "RSI 14", "sma_50_pct": "vs. 50-day average",
        "sma_200_pct": "vs. 200-day average", "beta": "Beta vs. Bitcoin"
    };
    <div className="grid grid-cols-2 gap-px bg-line sm:grid-cols-3 lg:grid-cols-4">
        {for key in keys {
            <CoinFigure
                key={key}
                label={labels[key]}
                value={show_coin(key, coin.values.get(key))}
                value_tone={tone(number_of(coin, key)) if key.startswith("perf_") or key.endswith("_pct") else "text-text"}
            />
        }}
    </div>
}

"""The research notes the agent's desks wrote on this coin, newest first."""
def CoinNotes(notes: list[NoteData] | None) -> JsxElement {
    if notes is None {
        return <p className="text-[13px] text-muted">Loading the notes.</p>;
    }
    if len(notes) == 0 {
        return <p className="text-[13px] text-muted">Your agent has not researched this coin yet. It covers the most traded coins on days it trades crypto.</p>;
    }
    <ul className="divide-y divide-line">
        {for note in notes {
            <li key={note.id}>
                <Link to={"/app/news/" + note.id} className="group/note flex items-start justify-between gap-3 py-2.5">
                    <span className="min-w-0">
                        <span className="block text-[13px] text-text group-hover/note:text-accent">{note.headline}</span>
                        <span className="num mt-0.5 block text-[11px] text-faint">{day_long(note.day) + " · " + NOTE_DESKS.get(note.desk, note.desk) + " desk · " + pct(note.confidence, 0) + " confidence"}</span>
                    </span>
                    <span className={"num shrink-0 text-[12px] font-medium " + ("text-up" if note.lean == "up" else ("text-down" if note.lean == "down" else "text-muted"))}>{note.view}</span>
                </Link>
            </li>
        }}
    </ul>
}

def:pub CoinPage -> JsxElement {
    has coin: CoinData | None = None,
        notes: list[NoteData] | None = None,
        stars: list[str] = watched(),
        loaded: bool = False,
        error: str = "";

    params = useParams();
    symbol: str = ticker_from_path(str(params["symbol"] or "").upper());

    useEffect(
        lambda {
            active = True;
            loaded = False;
            error = "";
            coin = None;
            notes = None;
            async def load {
                try {
                    found = await get_coin(symbol);
                    if active and found is not None {
                        coin = found;
                    }
                } except Exception as e {
                    if active {
                        error = str(e);
                    }
                }
                if active {
                    loaded = True;
                }
                try {
                    feed = await get_news_feed(ticker=symbol, limit=NOTE_LIMIT);
                    if active {
                        notes = feed.items if feed is not None else [];
                    }
                } except Exception as e {
                    if active {
                        notes = [];
                    }
                }
            }
            load();
            return lambda {
                active = False;
            };
        },
        [symbol]
    );

    if error {
        return <ErrorBox message={error}/>;
    }
    if not loaded {
        return <Loading label={"Loading " + symbol}/>;
    }
    if coin is None or not coin.found {
        return (
            <Empty title={symbol + " is not on the screener"}>
                Alpaca may not trade it against the dollar, or the coin data may still be on its way. <Link to="/app/screener/crypto" className="text-accent hover:underline">Back to the crypto screener</Link>
            </Empty>
        );
    }

    <div className="rise flex flex-col gap-4">
        <div className="flex flex-col gap-3">
            <nav aria-label="Breadcrumb" className="flex flex-wrap items-center gap-1 text-[12px] text-muted">
                <Link to="/app/screener" className="hover:text-text">Screener</Link>
                <ChevronRight size={12} className="text-faint" aria-hidden="true"/>
                <Link to="/app/screener/crypto" className="hover:text-text">Crypto</Link>
                <ChevronRight size={12} className="text-faint" aria-hidden="true"/>
                <span className="text-text">{coin.symbol}</span>
            </nav>
            <CoinHeader coin={coin} starred={symbol in stars} star={lambda { stars = toggle_watch(symbol); }}/>
        </div>
        <Panel title="Chart" pad={False}>
            {if len(coin.daily) == 0 {
                <p className="px-4 py-6 text-[13px] text-muted">No daily bars for this coin yet.</p>
            } else {
                <PriceChart symbol={coin.symbol} daily={coin.daily} intraday={[]}/>
            }}
        </Panel>
        <Panel title="Key stats" aside={"Daily bars through " + day_short(coin.stats_day) + " UTC" if coin.stats_day else ""} pad={False}>
            <CoinStats coin={coin}/>
        </Panel>
        <Panel title="Research notes"><CoinNotes notes={notes}/></Panel>
    </div>
}
