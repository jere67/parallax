"""The crypto screener: every pair Alpaca trades against the dollar, in one sortable table with filter
pills and tabs of columns, as the stock screener has. The screen lives in the address the same way
(dashboard/market/screen_url.jac), under /app/screener/crypto."""
import from "@jac/runtime" { Link, useLocation, useNavigate }
import from "lucide-react" { ArrowDown, ArrowUp, Plus, RefreshCw, RotateCcw, Search, Star }
import from react { useEffect }
import from dashboard.market.ScreenerPage { AssetSwitch, FieldPicker, FilterCard, ICON_BUTTON, PILL, PILL_OFF, PILL_ON, bound_text, query_pairs }
import from dashboard.market.columns { COIN_COLUMN_SETS, COIN_DEFAULT_FILTERS, COIN_FIELD_BY_KEY, COIN_FIELDS, coin_column_set, coin_path, coin_tone, show_coin }
import from dashboard.market.saved { toggle_watch, watched }
import from dashboard.market.screen_url { Bound, Screen, read_screen, request_filter, write_screen }
import from dashboard.ui.format { action_label, count, day_short, qty, stamp_et, ticker_path }
import from dashboard.ui.parts { ActionBadge, Empty, ErrorBox, FROZEN_CELL, FROZEN_HEAD, ROW, TD, TD_NUM, TH, TH_NUM }
import from dashboard.ui.rpc { screen_coins }
import from models.market { ScreenerView as ScreenerData }

glob COIN_PAGE_ROWS: int = 100;
glob COIN_SEARCH_WAIT_MS: int = 250;
glob BASE: str = "/app/screener/crypto";

def coin_address(screen: Screen) -> str {
    pairs = write_screen(screen);
    text = str(new(URLSearchParams, pairs));  # jac:ignore[E1053]
    return BASE + ("?" + text if text else "");
}

def copy_of(screen: Screen) -> Screen {
    return Screen(
        tab=screen.tab,
        sort=screen.sort,
        ascending=screen.ascending,
        search=screen.search,
        watch_only=screen.watch_only,
        filters={**screen.filters},
        added=list(screen.added),
        columns=list(screen.columns)
    );
}

def coin_label(key: str) -> str {
    field = COIN_FIELD_BY_KEY.get(key);
    return field.label if field else key;
}

def coin_pills(screen: Screen) -> list[str] {
    pills = list(COIN_DEFAULT_FILTERS);
    for key in screen.added + list(Object.keys(screen.filters)) {
        if key not in pills and key in COIN_FIELD_BY_KEY {
            pills.append(key);
        }
    }
    return pills;
}

def CoinHead(key_: str, active: bool, descending: bool, sort: Callable[[str], None]) -> JsxElement {
    field = COIN_FIELD_BY_KEY.get(key_);
    <th scope="col" className={TH_NUM} aria-sort={("descending" if descending else "ascending") if active else "none"} title={field.hint if field else ""}>
        <button type="button" className={"inline-flex items-center gap-1 uppercase tracking-[0.05em] hover:text-text " + ("text-text" if active else "")} onClick={lambda { sort(key_); }}>
            {coin_label(key_)}
            {<ArrowDown size={11} strokeWidth={2} aria-hidden="true"/> if active and descending else (<ArrowUp size={11} strokeWidth={2} aria-hidden="true"/> if active else <></>)}
        </button>
    </th>
}

"""The first column: the pair, the coin's name, the watchlist star, and the agent's latest decision
on it, which opens that decision's trail."""
def CoinCell(row: dict[str, float | str | None], starred: bool, star: Callable[[str], None], action: str = "", day: str = "") -> JsxElement {
    symbol = str(row["symbol"]);
    <td className={TD + FROZEN_CELL + " max-w-[136px] sm:max-w-[300px]"}>
        <div className="flex items-center gap-2">
            <button
                type="button"
                aria-pressed={starred}
                aria-label={("Remove " if starred else "Add ") + symbol + (" from the watchlist" if starred else " to the watchlist")}
                className={"press -m-1 grid size-7 shrink-0 place-items-center rounded " + ("text-accent" if starred else "text-faint hover:text-text")}
                onClick={lambda { star(symbol); }}
            >
                <Star size={14} strokeWidth={1.75} fill={"currentColor" if starred else "none"} aria-hidden="true"/>
            </button>
            <div className="flex min-w-0 flex-1 flex-col items-start gap-1 sm:flex-row sm:items-center sm:gap-2">
                <Link to={coin_path(symbol)} className="group/link flex min-w-0 max-w-full flex-col sm:flex-row sm:items-baseline sm:gap-2">
                    <span className="font-semibold text-text group-hover/link:text-accent">{symbol}</span>
                    <span className="truncate text-[11px] leading-4 text-muted sm:text-[12px]">{str(row.get("name") or "")}</span>
                </Link>
                {if action and day {
                    <Link
                        to={"/app/runs/" + day + "/" + ticker_path(symbol)}
                        data-testid="screener-decision"
                        className="shrink-0 rounded-full hover:opacity-80 sm:ml-auto"
                        title={"Your agent's decision on " + symbol + ", " + day_short(day) + ": " + action_label(action) + ". Open the decision trail."}
                        aria-label={"Decision trail for " + symbol + " on " + day_short(day)}
                    >
                        <ActionBadge action={action}/>
                    </Link>
                }}
            </div>
        </div>
    </td>
}

def:pub CoinScreenerPage -> JsxElement {
    has view: ScreenerData | None = None,
        rows: list[dict[str, float | str | None]] = [],
        loading: bool = True,
        more: bool = False,
        error: str = "",
        open: str = "",
        typed: str | None = None,
        stars: list[str] = watched(),
        reload: int = 0;

    location = useLocation();
    nav = useNavigate();
    screen = read_screen(query_pairs(location.search));
    tab = coin_column_set(screen.tab);
    shown = [c for c in screen.columns if c in COIN_FIELD_BY_KEY] or tab.columns;
    sort_key = screen.sort if screen.sort in COIN_FIELD_BY_KEY else tab.sort;
    descending = not screen.ascending;
    coin_stars = [s for s in stars if "/" in s];
    stars_key = ",".join(coin_stars) if screen.watch_only else "";

    async def request(offset: int) -> any {
        return await screen_coins(
            filters=[request_filter(k, screen.filters[k], COIN_FIELD_BY_KEY) for k in Object.keys(screen.filters) if k in COIN_FIELD_BY_KEY],
            search=screen.search,
            symbols=coin_stars if screen.watch_only else [],
            sort=sort_key,
            descending=descending,
            columns=shown,
            offset=offset,
            limit=COIN_PAGE_ROWS
        );
    }

    useEffect(
        lambda {
            active = True;
            async def load {
                loading = True;
                error = "";
                try {
                    fresh = await request(0);
                    if active and fresh is not None {
                        view = fresh;
                        rows = fresh.rows;
                    }
                } except Exception as e {
                    if active {
                        error = str(e);
                    }
                }
                if active {
                    loading = False;
                }
            }
            load();
            return lambda {
                active = False;
            };
        },
        [location.search, stars_key, reload]
    );

    useEffect(
        lambda {
            if typed is None {
                return;
            }
            wanted: str = typed or "";
            timer = setTimeout(
                lambda {
                    next = copy_of(screen);
                    next.search = wanted;
                    nav(coin_address(next), {"replace": True});
                },
                COIN_SEARCH_WAIT_MS
            );
            return lambda {
                clearTimeout(timer);
            };
        },
        [typed]
    );

    def go(next: Screen) {
        nav(coin_address(next));
    }

    async def load_more {
        more = True;
        try {
            fresh = await request(len(rows));
            if fresh is not None {
                rows = rows + fresh.rows;
            }
        } except Exception as e {
            error = str(e);
        }
        more = False;
    }

    def sort_by(key: str) {
        next = copy_of(screen);
        next.ascending = (not screen.ascending) if key == sort_key else key in ["symbol", "name"];
        next.sort = key;
        go(next);
    }

    def pick_tab(name: str) {
        next = copy_of(screen);
        next.tab = name;
        next.sort = "";
        next.ascending = False;
        next.columns = [];
        open = "";
        go(next);
    }

    def set_filter(key: str, bound: Bound | None) {
        next = copy_of(screen);
        kept: dict[str, Bound] = {};
        for k in Object.keys(screen.filters) {
            if k != key {
                kept[k] = screen.filters[k];
            }
        }
        if bound is not None {
            kept[key] = bound;
        }
        next.filters = kept;
        go(next);
    }

    def add_filter(key: str) {
        next = copy_of(screen);
        if key not in coin_pills(screen) {
            next.added = next.added + [key];
        }
        open = key;
        go(next);
    }

    def toggle_watch_only {
        next = copy_of(screen);
        next.watch_only = not screen.watch_only;
        go(next);
    }

    def reset {
        open = "";
        typed = None;
        nav(BASE);
    }

    open_field = COIN_FIELD_BY_KEY.get(open) if open and open != "add" else None;
    dirty = len(Object.keys(screen.filters)) > 0 or screen.search != "" or screen.watch_only or len(screen.added) > 0;
    total = view.total if view is not None else 0;
    search_text = typed if typed is not None else screen.search;

    <div className="flex flex-col gap-3">
        <header>
            <div className="flex flex-wrap items-center gap-x-4 gap-y-2">
                <h1 className="display text-[30px] leading-9 text-text">Screener</h1>
                <AssetSwitch current="Crypto"/>
            </div>
            <p className="mt-0.5 text-[13px] text-muted">Every coin Alpaca trades against the dollar, around the clock.</p>
        </header>

        <div className="flex flex-wrap items-center gap-1.5" role="group" aria-label="Filters">
            <label className="relative block w-full sm:w-52">
                <Search size={13} strokeWidth={1.75} className="pointer-events-none absolute left-2.5 top-1/2 -translate-y-1/2 text-faint" aria-hidden="true"/>
                <input
                    type="search"
                    aria-label="Search by pair or coin"
                    placeholder="Search pair or coin"
                    className="h-7 w-full rounded-full border border-line bg-panel pl-7 pr-3 text-[16px] text-text placeholder:text-faint sm:text-[12px]"
                    value={search_text}
                    onChange={lambda (e: ChangeEvent) { typed = e.target.value; }}
                />
            </label>
            <div className="scroll-x -mx-4 flex w-screen gap-1.5 px-4 pb-1 sm:contents">
                <button type="button" aria-pressed={screen.watch_only} className={PILL + " " + (PILL_ON if screen.watch_only else PILL_OFF)} onClick={toggle_watch_only}>
                    <Star size={12} strokeWidth={1.75} fill={"currentColor" if screen.watch_only else "none"} aria-hidden="true"/>
                    {"Watchlist" + (" " + str(len(coin_stars)) if len(coin_stars) > 0 else "")}
                </button>
                {for key in coin_pills(screen) {
                    <button
                        key={key}
                        type="button"
                        aria-expanded={open == key}
                        className={PILL + " " + (PILL_ON if key in screen.filters or open == key else PILL_OFF)}
                        onClick={lambda { open = "" if open == key else key; }}
                    >
                        {coin_label(key)}
                        {if key in screen.filters {
                            <span className="num font-normal">{bound_text(COIN_FIELD_BY_KEY[key], screen.filters[key])}</span>
                        }}
                    </button>
                }}
                <button type="button" aria-label="Add a filter" aria-expanded={open == "add"} className={PILL + " " + (PILL_ON if open == "add" else PILL_OFF)} onClick={lambda { open = "" if open == "add" else "add"; }}>
                    <Plus size={13} strokeWidth={1.75} aria-hidden="true"/>
                    Filter
                </button>
                {if dirty {
                    <button type="button" className={PILL + " " + PILL_OFF} onClick={reset}>
                        <RotateCcw size={12} strokeWidth={1.75} aria-hidden="true"/>
                        Reset
                    </button>
                }}
            </div>
        </div>

        {if open_field is not None {
            <FilterCard
                key={open_field.key}
                field={open_field}
                bound={screen.filters.get(open_field.key)}
                choices={[]}
                apply={lambda (bound: Bound | None) { set_filter(open, bound); }}
                close={lambda { open = ""; }}
            />
        }}
        {if open == "add" {
            <FieldPicker title="Add a filter" fields={[f for f in COIN_FIELDS if f.filter]} chosen={coin_pills(screen)} pick={add_filter} close={lambda { open = ""; }}/>
        }}

        <div className="flex items-center justify-between gap-3 border-b border-line">
            <div className="scroll-x -mb-px flex min-w-0 flex-1 items-center gap-4" role="tablist" aria-label="Column sets">
                {for set_ in COIN_COLUMN_SETS {
                    <button
                        key={set_.name}
                        type="button"
                        role="tab"
                        aria-selected={tab.name == set_.name}
                        className={"h-9 shrink-0 whitespace-nowrap border-b-2 text-[13px] font-medium transition-colors duration-150 " + ("border-accent text-text" if tab.name == set_.name else "border-transparent text-muted hover:text-text")}
                        onClick={lambda { pick_tab(set_.name); }}
                    >{set_.name}</button>
                }}
            </div>
            <div className="flex shrink-0 items-center gap-1.5 pb-1">
                <button type="button" aria-label="Refresh" title="Refresh" className={ICON_BUTTON} onClick={lambda { reload = reload + 1; }}>
                    <RefreshCw size={13} strokeWidth={1.75} className={"animate-spin" if loading else ""} aria-hidden="true"/>
                </button>
            </div>
        </div>

        {if error {
            <ErrorBox message={error}/>
        }}

        {if view is not None and not view.ready {
            <Empty title="The coin data is on its way">
                The server reads the list of coins Alpaca trades, then their prices and a year of daily bars. They arrive within a few minutes of starting up.
            </Empty>
        } elif view is None and not error {
            <div className="h-96 animate-pulse rounded-md border border-line bg-panel-2" aria-busy="true" aria-label="Loading the screener"></div>
        } elif view is not None and total == 0 and not loading {
            <Empty title={"Your watchlist has no coins" if screen.watch_only and len(coin_stars) == 0 else "No coins match"}>
                {"Star a coin in the table to add it here." if screen.watch_only and len(coin_stars) == 0 else "Try widening a filter or resetting the screen."}
            </Empty>
        } elif view is not None {
            <section className={"overflow-hidden rounded-md border border-line bg-panel transition-opacity duration-150 " + ("opacity-60" if loading else "")} aria-label="Matching coins">
                <div className="max-h-[78dvh] overflow-auto overscroll-x-contain">
                    <table className="w-full border-separate border-spacing-0">
                        <thead>
                            <tr>
                                <th scope="col" className={TH + FROZEN_HEAD} aria-sort={("descending" if descending else "ascending") if sort_key == "symbol" else "none"}>
                                    <button type="button" className={"inline-flex items-center gap-1 uppercase tracking-[0.05em] hover:text-text " + ("text-text" if sort_key == "symbol" else "")} onClick={lambda { sort_by("symbol"); }}>
                                        {"Pair " + qty(total)}
                                    </button>
                                </th>
                                {for key in shown {
                                    <CoinHead key={key} key_={key} active={sort_key == key} descending={descending} sort={sort_by}/>
                                }}
                            </tr>
                        </thead>
                        <tbody>
                            {for row in rows {
                                <tr key={str(row["symbol"])} className={ROW + " group"}>
                                    <CoinCell
                                        row={row}
                                        starred={str(row["symbol"]) in stars}
                                        star={lambda (symbol: str) { stars = toggle_watch(symbol); }}
                                        action={view.decisions.get(str(row["symbol"]), "")}
                                        day={view.decided_day}
                                    />
                                    {for key in shown {
                                        <td key={key} className={TD_NUM + " " + coin_tone(key, row.get(key))}>{show_coin(key, row.get(key))}</td>
                                    }}
                                </tr>
                            }}
                        </tbody>
                    </table>
                </div>
                {if len(rows) < total {
                    <div className="flex items-center justify-between gap-3 border-t border-line px-4 py-2">
                        <span className="num text-[12px] text-muted">{qty(len(rows)) + " of " + count(total, "coin")}</span>
                        <button type="button" disabled={more} className={ICON_BUTTON + " disabled:opacity-50"} onClick={load_more}>{"Loading" if more else "Show " + str(min(COIN_PAGE_ROWS, total - len(rows))) + " more"}</button>
                    </div>
                }}
            </section>
        }}
        {if view is not None and view.ready {
            <p className="mt-3 max-w-3xl text-[12px] text-muted">
                {"Prices are the latest trade on Alpaca" + (", last read " + stamp_et(view.as_of) if view.as_of else "") + ". "}
                {"Daily figures run through the close of " + day_short(view.quote_day) + " UTC, and a day's change counts from midnight UTC. " if view.quote_day else ""}
                {"Coins are compared with Bitcoin. None of this is advice."}
            </p>
        }}
    </div>
}
