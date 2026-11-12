"""The Screener: every U.S.-listed stock in one sortable table, narrowed by filter pills, with tabs
of columns for each way of looking at a company. The screen lives in the address, so it can be
reloaded or sent, and back and forward undo and redo a change. Filtering happens on the server, and
the page holds only the rows it has asked for."""
import from "@jac/runtime" { Link, useLocation, useNavigate }
import from "lucide-react" { ArrowDown, ArrowUp, Bookmark, Check, Columns3, Plus, RefreshCw, RotateCcw, Search, Star, X }
import from react { useEffect }
import from dashboard.market.columns { COLUMN_SETS, FIELD_BY_KEY, FIELDS, Field, RATINGS, show, tone_of }
import from dashboard.market.saved { delete_screen, save_screen, saved_screens, toggle_watch, watched }
import from dashboard.market.screen_url {
    Bound,
    Screen,
    columns_of,
    descending_of,
    pills_of,
    read_screen,
    request_filter,
    sort_of,
    write_screen
}
import from dashboard.ui.format { action_label, count, day_short, num, qty, stamp_et }
import from dashboard.ui.parts { ActionBadge, Empty, ErrorBox, FROZEN_CELL, FROZEN_HEAD, ROW, TD, TD_NUM, TH, TH_NUM }
import from dashboard.ui.rpc { screen_stocks }
import from models.market { CoverageView as CoverageData, ScreenerView as ScreenerData }

glob PAGE_ROWS: int = 100;
glob SEARCH_WAIT_MS: int = 250;
glob PILL: str = "press inline-flex h-7 shrink-0 items-center gap-1.5 rounded-full border px-2.5 text-[12px] font-medium";
glob PILL_OFF: str = "border-line bg-panel text-muted hover:bg-hover hover:text-text";
glob PILL_ON: str = "border-accent/40 bg-accent/15 text-accent";
glob ICON_BUTTON: str = "press inline-flex h-7 shrink-0 items-center gap-1.5 rounded-md border border-line bg-panel px-2 text-[12px] font-medium text-muted hover:bg-hover hover:text-text";
glob FIELD_INPUT: str = "num h-8 w-full min-w-0 rounded-md border border-line bg-bg px-2 text-[16px] text-text placeholder:text-faint sm:text-[13px]";

def query_pairs(search: str) -> dict[str, str] {
    pairs: dict[str, str] = {};
    params: any = new(URLSearchParams, search);  # jac:ignore[E1053]
    params.forEach(lambda (value: str, key: str) { pairs[key] = value; });  # jac:ignore[E1030]
    return pairs;
}

def address_of(screen: Screen) -> str {
    pairs = write_screen(screen);
    text = str(new(URLSearchParams, pairs));  # jac:ignore[E1053]
    return "/app/screener" + ("?" + text if text else "");
}

def copy_screen(screen: Screen) -> Screen {
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

"""A filter's words on its pill: the preset's name, or its bounds."""
def bound_text(field: Field, bound: Bound) -> str {
    if len(bound.one_of) > 0 {
        return bound.one_of[0] if len(bound.one_of) == 1 else bound.one_of[0] + " +" + str(len(bound.one_of) - 1);
    }
    for preset in field.presets {
        if preset.low == bound.low and preset.high == bound.high {
            return preset.label;
        }
    }
    unit = field.unit;
    if bound.low is not None and bound.high is not None {
        return num(bound.low, 2) + " to " + num(bound.high, 2) + " " + unit;
    }
    if bound.low is not None {
        return "over " + num(bound.low, 2) + " " + unit;
    }
    return "under " + num(bound.high, 2) + " " + unit;
}

def label_of(key: str) -> str {
    field = FIELD_BY_KEY.get(key);
    return field.label if field else key;
}

"""The inline card under the pills for one filter: its presets, its typed bounds, or its words. It
sits in the page's flow instead of floating, so nothing can clip it on a phone."""
def FilterCard(field: Field, bound: Bound | None, choices: list[str], apply: Callable[[Bound | None], None], close: Callable[[], None]) -> JsxElement {
    has low_text: str = str(bound.low) if bound is not None and bound.low is not None else "",
        high_text: str = str(bound.high) if bound is not None and bound.high is not None else "";

    picked: list[str] = bound.one_of if bound is not None else [];

    def toggle(word: str) {
        next = [w for w in picked if w != word] if word in picked else picked + [word];
        apply(Bound(one_of=next) if len(next) > 0 else None);
    }

    def typed(e: FormEvent) {
        e.preventDefault();
        low = float(low_text) if low_text.strip() else None;
        high = float(high_text) if high_text.strip() else None;
        apply(Bound(low=low, high=high) if low is not None or high is not None else None);
    }

    <section className="rounded-md border border-line bg-panel p-3" aria-label={field.label + " filter"}>
        <div className="flex items-start justify-between gap-3">
            <div>
                <h2 className="text-[13px] font-medium text-text">{field.label}</h2>
                {if field.hint {
                    <p className="mt-0.5 text-[12px] text-muted">{field.hint}</p>
                }}
            </div>
            <div className="flex shrink-0 items-center gap-1">
                {if bound is not None {
                    <button type="button" className="press rounded-md px-2 py-1 text-[12px] text-muted hover:bg-hover hover:text-text" onClick={lambda { apply(None); }}>Clear</button>
                }}
                <button type="button" className="press grid size-7 place-items-center rounded-md text-muted hover:bg-hover hover:text-text" aria-label="Close filter" onClick={lambda { close(); }}>
                    <X size={14} strokeWidth={1.75} aria-hidden="true"/>
                </button>
            </div>
        </div>
        {if field.filter == "choice" {
            <div className="mt-3 flex flex-wrap gap-1.5">
                {for word in choices {
                    <button key={word} type="button" aria-pressed={word in picked} className={PILL + " " + (PILL_ON if word in picked else PILL_OFF)} onClick={lambda { toggle(word); }}>
                        {<Check size={12} strokeWidth={2} aria-hidden="true"/> if word in picked else <></>}
                        {word}
                    </button>
                }}
            </div>
        } else {
            <div className="mt-3 flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
                <div className="flex flex-wrap gap-1.5">
                    {for preset in field.presets {
                        <button
                            key={preset.label}
                            type="button"
                            aria-pressed={bound is not None and bound.low == preset.low and bound.high == preset.high}
                            className={PILL + " " + (PILL_ON if bound is not None and bound.low == preset.low and bound.high == preset.high else PILL_OFF)}
                            onClick={lambda { apply(Bound(low=preset.low, high=preset.high)); }}
                        >{preset.label}</button>
                    }}
                </div>
                <form onSubmit={typed} className="flex items-end gap-2">
                    <label className="block w-24 text-[11px] text-muted">
                        {"From" + (" (" + field.unit + ")" if field.unit else "")}
                        <input type="number" step="any" inputMode="decimal" className={FIELD_INPUT + " mt-1"} value={low_text} onChange={lambda (e: ChangeEvent) { low_text = e.target.value; }}/>
                    </label>
                    <label className="block w-24 text-[11px] text-muted">
                        {"To" + (" (" + field.unit + ")" if field.unit else "")}
                        <input type="number" step="any" inputMode="decimal" className={FIELD_INPUT + " mt-1"} value={high_text} onChange={lambda (e: ChangeEvent) { high_text = e.target.value; }}/>
                    </label>
                    <button type="submit" className="press h-8 rounded-md bg-accent px-3 text-[12px] font-medium text-bg">Apply</button>
                </form>
            </div>
        }}
    </section>
}

"""The list of every field, grouped, for adding a filter or choosing columns. `chosen` are ticked."""
def FieldPicker(title: str, fields: list[Field], chosen: list[str], pick: Callable[[str], None], close: Callable[[], None], footer: any = None) -> JsxElement {
    has text: str = "";

    wanted = text.strip().lower();
    shown = [f for f in fields if not wanted or wanted in f.label.lower() or wanted in f.group.lower()];
    groups: list[str] = [];
    for f in shown {
        if f.group not in groups {
            groups.append(f.group);
        }
    }

    <section className="rounded-md border border-line bg-panel p-3" aria-label={title}>
        <div className="flex items-center justify-between gap-3">
            <h2 className="text-[13px] font-medium text-text">{title}</h2>
            <div className="flex items-center gap-1">
                {footer}
                <button type="button" className="press grid size-7 place-items-center rounded-md text-muted hover:bg-hover hover:text-text" aria-label={"Close " + title.lower()} onClick={lambda { close(); }}>
                    <X size={14} strokeWidth={1.75} aria-hidden="true"/>
                </button>
            </div>
        </div>
        <input type="search" aria-label="Find a field" placeholder="Find a field" className={FIELD_INPUT + " mt-2 max-w-xs font-sans"} value={text} onChange={lambda (e: ChangeEvent) { text = e.target.value; }}/>
        <div className="mt-3 grid max-h-72 gap-x-6 gap-y-4 overflow-y-auto sm:grid-cols-2 lg:grid-cols-4">
            {for group in groups {
                <div key={group}>
                    <h3 className="text-[11px] font-medium uppercase tracking-[0.05em] text-faint">{group}</h3>
                    <ul className="mt-1">
                        {for f in [x for x in shown if x.group == group] {
                            <li key={f.key}>
                                <button type="button" aria-pressed={f.key in chosen} title={f.hint} className="press flex w-full items-center justify-between gap-2 rounded px-1.5 py-1 text-left text-[13px] text-text hover:bg-hover" onClick={lambda { pick(f.key); }}>
                                    {f.label}
                                    {<Check size={13} strokeWidth={2} className="text-accent" aria-hidden="true"/> if f.key in chosen else <></>}
                                </button>
                            </li>
                        }}
                    </ul>
                </div>
            }}
        </div>
    </section>
}

"""A sortable column head; the arrow shows the current direction."""
def ColumnHead(key_: str, active: bool, descending: bool, sort: Callable[[str], None]) -> JsxElement {
    field = FIELD_BY_KEY.get(key_);
    is_text = field is not None and field.format in ["text", "rating", "day"];
    <th
        scope="col"
        className={TH if is_text else TH_NUM}
        aria-sort={("descending" if descending else "ascending") if active else "none"}
        title={field.hint if field else ""}
    >
        <button type="button" className={"inline-flex items-center gap-1 uppercase tracking-[0.05em] hover:text-text " + ("text-text" if active else "")} onClick={lambda { sort(key_); }}>
            {label_of(key_)}
            {<ArrowDown size={11} strokeWidth={2} aria-hidden="true"/> if active and descending else (<ArrowUp size={11} strokeWidth={2} aria-hidden="true"/> if active else <></>)}
        </button>
    </th>
}

"""The first column: the ticker, its company, the star that adds it to the watchlist, and the
agent's decision on it in its latest run (`action` on `day`), which opens that decision's trail."""
def SymbolCell(row: dict[str, float | str | None], starred: bool, star: Callable[[str], None], action: str = "", day: str = "") -> JsxElement {
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
            <Link to={"/app/stocks/" + symbol} className="group/link flex min-w-0 flex-col sm:flex-row sm:items-baseline sm:gap-2">
                <span className="font-semibold text-text group-hover/link:text-accent">{symbol}</span>
                <span className="truncate text-[11px] leading-4 text-muted sm:text-[12px]">{str(row.get("name") or "")}</span>
                {if row.get("kind") == "adr" {
                    <span className="hidden shrink-0 text-[10px] font-medium text-faint sm:inline" title="American depositary receipt">ADR</span>
                }}
            </Link>
            {if action and day {
                <Link
                    to={"/app/runs/" + day + "/" + symbol}
                    data-testid="screener-decision"
                    className="ml-auto shrink-0 rounded-full hover:opacity-80"
                    title={"Your agent's decision on " + symbol + ", " + day_short(day) + ": " + action_label(action) + ". Open the decision trail."}
                    aria-label={"Decision trail for " + symbol + " on " + day_short(day)}
                >
                    <ActionBadge action={action}/>
                </Link>
            }}
        </div>
    </td>
}

def DataCell(key_: str, value: float | str | None) -> JsxElement {
    field = FIELD_BY_KEY.get(key_);
    is_text = field is not None and field.format in ["text", "rating", "day"];
    <td className={(TD if is_text else TD_NUM) + " " + tone_of(key_, value) + (" font-medium" if field is not None and field.format == "rating" else "")}>{show(key_, value)}</td>
}

"""What the numbers cover, since a sweep of the whole market fills in over time."""
def CoverageNote(view: ScreenerData) -> JsxElement {
    cover: CoverageData = view.coverage;
    <p className="mt-3 max-w-3xl text-[12px] text-muted">
        {"Prices are delayed about 15 minutes" + (", last refreshed " + stamp_et(view.as_of) if view.as_of else "") + ". "}
        {"Company figures come from SEC filings and cover " + qty(cover.with_figures) + " of " + qty(cover.stocks) + " stocks; a foreign filer reporting under IFRS shows none. "}
        {"Analyst ratings cover " + qty(cover.with_analysts) + " so far. Technicals and analyst ratings are computed here, and none of this is advice."}
    </p>
}

"""Saving this screen, and the screens saved before, on the row with the search."""
def SavedScreens(current: str, go: Callable[[str], None]) -> JsxElement {
    has screens: dict[str, str] = saved_screens(),
        naming: bool = False,
        name: str = "";

    names = Object.keys(screens);

    def save(e: FormEvent) {
        e.preventDefault();
        if name.strip() {
            screens = save_screen(name.strip(), current);
            naming = False;
            name = "";
        }
    }

    <div className="flex flex-wrap items-center gap-1.5">
        {for saved in names {
            <span key={saved} className={"inline-flex h-7 items-center rounded-md border " + ("border-accent/40 bg-accent/15 text-accent" if screens[saved] == current else "border-line bg-panel text-muted")}>
                <button type="button" className="press h-full max-w-40 truncate pl-2 pr-1 text-[12px] font-medium" onClick={lambda { go(screens[saved]); }}>{saved}</button>
                <button type="button" className="press grid h-full w-6 place-items-center hover:text-text" aria-label={"Delete the screen " + saved} onClick={lambda { screens = delete_screen(saved); }}>
                    <X size={12} strokeWidth={1.75} aria-hidden="true"/>
                </button>
            </span>
        }}
        {if naming {
            <form onSubmit={save} className="flex items-center gap-1">
                <input autoFocus={True} aria-label="Name for this screen" placeholder="Name this screen" className={FIELD_INPUT + " h-7 w-36 font-sans"} value={name} onChange={lambda (e: ChangeEvent) { name = e.target.value; }}/>
                <button type="submit" className={ICON_BUTTON}>Save</button>
                <button type="button" className={ICON_BUTTON} onClick={lambda { naming = False; }}>Cancel</button>
            </form>
        } else {
            <button type="button" className={ICON_BUTTON} onClick={lambda { naming = True; }}>
                <Bookmark size={13} strokeWidth={1.75} aria-hidden="true"/>
                Save screen
            </button>
        }}
    </div>
}

def:pub ScreenerPage -> JsxElement {
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
    shown = columns_of(screen);
    sort_key = sort_of(screen);
    descending = descending_of(screen);
    stars_key = ",".join(stars) if screen.watch_only else "";

    async def request(offset: int) -> any {
        return await screen_stocks(
            filters=[request_filter(k, screen.filters[k]) for k in Object.keys(screen.filters)],
            search=screen.search,
            symbols=stars if screen.watch_only else [],
            sort=sort_key,
            descending=descending,
            columns=shown,
            offset=offset,
            limit=PAGE_ROWS
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

    # What a reader types goes to the address after a short pause, without filling the back button.
    useEffect(
        lambda {
            if typed is None {
                return;
            }
            wanted: str = typed or "";
            timer = setTimeout(
                lambda {
                    next = copy_screen(screen);
                    next.search = wanted;
                    nav(address_of(next), {"replace": True});
                },
                SEARCH_WAIT_MS
            );
            return lambda {
                clearTimeout(timer);
            };
        },
        [typed]
    );

    def go(next: Screen) {
        nav(address_of(next));
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
        next = copy_screen(screen);
        field = FIELD_BY_KEY.get(key);
        is_text = field is not None and field.format in ["text", "rating"];
        if key == sort_key {
            next.ascending = not screen.ascending;
        } else {
            next.ascending = is_text;
        }
        next.sort = key;
        go(next);
    }

    def pick_tab(name: str) {
        next = copy_screen(screen);
        next.tab = name;
        next.sort = "";
        next.ascending = False;
        next.columns = [];
        open = "";
        go(next);
    }

    def set_filter(key: str, bound: Bound | None) {
        next = copy_screen(screen);
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
        next = copy_screen(screen);
        if key not in pills_of(screen) {
            next.added = next.added + [key];
        }
        open = key;
        go(next);
    }

    def toggle_column(key: str) {
        next = copy_screen(screen);
        next.columns = [c for c in shown if c != key] if key in shown else shown + [key];
        go(next);
    }

    def reset {
        open = "";
        typed = None;
        nav("/app/screener");
    }

    def toggle_watch_only {
        next = copy_screen(screen);
        next.watch_only = not screen.watch_only;
        go(next);
    }

    def star(symbol: str) {
        stars = toggle_watch(symbol);
    }

    def choices_of(key: str) -> list[str] {
        if key == "sector" {
            return view.sectors if view is not None else [];
        }
        if key == "exchange" {
            return view.exchanges if view is not None else [];
        }
        if key == "sp500" {
            return ["S&P 500"];
        }
        return RATINGS;
    }

    current = str(location.search).lstrip("?");
    filterable = [f for f in FIELDS if f.filter];
    open_field = FIELD_BY_KEY.get(open) if open and open != "add" and open != "columns" else None;
    dirty = len(Object.keys(screen.filters)) > 0 or screen.search != "" or screen.watch_only or len(screen.added) > 0;
    total = view.total if view is not None else 0;
    search_text = typed if typed is not None else screen.search;

    <div className="flex flex-col gap-3">
        <header className="flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
            <div>
                <h1 className="display text-[30px] leading-9 text-text">Screener</h1>
                <p className="mt-0.5 text-[13px] text-muted">Every U.S.-listed stock, narrowed however you like.</p>
            </div>
            <SavedScreens current={current} go={lambda (query: str) { nav("/app/screener" + ("?" + query if query else "")); }}/>
        </header>

        <div className="flex flex-wrap items-center gap-1.5" role="group" aria-label="Filters">
            <label className="relative block w-full sm:w-52">
                <Search size={13} strokeWidth={1.75} className="pointer-events-none absolute left-2.5 top-1/2 -translate-y-1/2 text-faint" aria-hidden="true"/>
                <input
                    type="search"
                    aria-label="Search by symbol or company"
                    placeholder="Search symbol or company"
                    className="h-7 w-full rounded-full border border-line bg-panel pl-7 pr-3 text-[16px] text-text placeholder:text-faint sm:text-[12px]"
                    value={search_text}
                    onChange={lambda (e: ChangeEvent) { typed = e.target.value; }}
                />
            </label>
            <div className="scroll-x -mx-4 flex w-screen gap-1.5 px-4 pb-1 sm:contents">
                <button type="button" aria-pressed={screen.watch_only} className={PILL + " " + (PILL_ON if screen.watch_only else PILL_OFF)} onClick={toggle_watch_only}>
                    <Star size={12} strokeWidth={1.75} fill={"currentColor" if screen.watch_only else "none"} aria-hidden="true"/>
                    {"Watchlist" + (" " + str(len(stars)) if len(stars) > 0 else "")}
                </button>
                {for key in pills_of(screen) {
                    <button
                        key={key}
                        type="button"
                        aria-expanded={open == key}
                        className={PILL + " " + (PILL_ON if key in screen.filters or open == key else PILL_OFF)}
                        onClick={lambda { open = "" if open == key else key; }}
                    >
                        {label_of(key)}
                        {if key in screen.filters {
                            <span className="num font-normal">{bound_text(FIELD_BY_KEY[key], screen.filters[key])}</span>
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
                choices={choices_of(open_field.key)}
                apply={lambda (bound: Bound | None) { set_filter(open, bound); }}
                close={lambda { open = ""; }}
            />
        }}
        {if open == "add" {
            <FieldPicker title="Add a filter" fields={filterable} chosen={pills_of(screen)} pick={add_filter} close={lambda { open = ""; }}/>
        }}
        {if open == "columns" {
            <FieldPicker
                title="Choose columns"
                fields={[f for f in FIELDS if f.key != "symbol" and f.key != "name" and f.filter != "days"]}
                chosen={shown}
                pick={toggle_column}
                close={lambda { open = ""; }}
            />
        }}

        <div className="flex items-center justify-between gap-3 border-b border-line">
            <div className="scroll-x -mb-px flex min-w-0 flex-1 items-center gap-4" role="tablist" aria-label="Column sets">
                {for set_ in COLUMN_SETS {
                    <button
                        key={set_.name}
                        type="button"
                        role="tab"
                        aria-selected={screen.tab == set_.name}
                        className={"h-9 shrink-0 whitespace-nowrap border-b-2 text-[13px] font-medium transition-colors duration-150 " + ("border-accent text-text" if screen.tab == set_.name else "border-transparent text-muted hover:text-text")}
                        onClick={lambda { pick_tab(set_.name); }}
                    >{set_.name}</button>
                }}
            </div>
            <div className="flex shrink-0 items-center gap-1.5 pb-1">
                <button type="button" aria-label="Choose columns" aria-expanded={open == "columns"} title="Choose columns" className={ICON_BUTTON} onClick={lambda { open = "" if open == "columns" else "columns"; }}>
                    <Columns3 size={13} strokeWidth={1.75} aria-hidden="true"/>
                </button>
                <button type="button" aria-label="Refresh" title="Refresh" className={ICON_BUTTON} onClick={lambda { reload = reload + 1; }}>
                    <RefreshCw size={13} strokeWidth={1.75} className={"animate-spin" if loading else ""} aria-hidden="true"/>
                </button>
            </div>
        </div>

        {if error {
            <ErrorBox message={error}/>
        }}

        {if view is not None and not view.ready {
            <Empty title="The market data is on its way">
                The server fills this table in on its own, starting with the list of stocks, then their prices, then their filings. The first prices arrive within a few minutes of starting up.
            </Empty>
        } elif view is None and not error {
            <div className="h-96 animate-pulse rounded-md border border-line bg-panel-2" aria-busy="true" aria-label="Loading the screener"></div>
        } elif view is not None and total == 0 and not loading {
            <Empty title={"Your watchlist is empty" if screen.watch_only and len(stars) == 0 else "No stocks match"}>
                {"Star a stock in the table to add it here." if screen.watch_only and len(stars) == 0 else "Try widening a filter or resetting the screen."}
            </Empty>
        } elif view is not None {
            <section className={"overflow-hidden rounded-md border border-line bg-panel transition-opacity duration-150 " + ("opacity-60" if loading else "")} aria-label="Matching stocks">
                <div className="max-h-[78dvh] overflow-auto overscroll-x-contain">
                    <table className="w-full border-separate border-spacing-0">
                        <thead>
                            <tr>
                                <th scope="col" className={TH + FROZEN_HEAD} aria-sort={("descending" if descending else "ascending") if sort_key == "symbol" else "none"}>
                                    <button type="button" className={"inline-flex items-center gap-1 uppercase tracking-[0.05em] hover:text-text " + ("text-text" if sort_key == "symbol" else "")} onClick={lambda { sort_by("symbol"); }}>
                                        {"Symbol " + qty(total)}
                                    </button>
                                </th>
                                {for key in shown {
                                    <ColumnHead key={key} key_={key} active={sort_key == key} descending={descending} sort={sort_by}/>
                                }}
                            </tr>
                        </thead>
                        <tbody>
                            {for row in rows {
                                <tr key={str(row["symbol"])} className={ROW + " group"}>
                                    <SymbolCell
                                        row={row}
                                        starred={str(row["symbol"]) in stars}
                                        star={star}
                                        action={view.decisions.get(str(row["symbol"]), "")}
                                        day={view.decided_day}
                                    />
                                    {for key in shown {
                                        <DataCell key={key} key_={key} value={row.get(key)}/>
                                    }}
                                </tr>
                            }}
                        </tbody>
                    </table>
                </div>
                {if len(rows) < total {
                    <div className="flex items-center justify-between gap-3 border-t border-line px-4 py-2">
                        <span className="num text-[12px] text-muted">{qty(len(rows)) + " of " + count(total, "stock")}</span>
                        <button type="button" disabled={more} className={ICON_BUTTON + " disabled:opacity-50"} onClick={load_more}>{"Loading" if more else "Show " + str(min(PAGE_ROWS, total - len(rows))) + " more"}</button>
                    </div>
                }}
            </section>
        }}
        {if view is not None and view.ready {
            <CoverageNote view={view}/>
        }}
    </div>
}
