"""The News page (TDD §10): every note the research desks wrote, as a flow of headlines beside the
note the reader picked. On a wide screen the feed and the story scroll side by side and the newest
story opens by itself. On a narrower one the feed fills the page and a story slides over it, so
going back returns to the same place in the feed.

The filters live in the address, as does the story, so any view of the feed can be shared and the
back button works. The server filters, since the record outgrows what a page should download."""
import from "@jac/runtime" { Link, useLocation, useNavigate }
import from "react" { useEffect, useRef }
import from "lucide-react" { Check, ChevronDown, ChevronLeft, ExternalLink, Link2, Search, X }
import from dashboard.ui.rpc { get_news_feed, get_news_story }
import from dashboard.ui.format { count, day_long, day_short, money, pct, stamp_et, time_et }
import from dashboard.ui.parts {
    PILL_BASE,
    SEGMENTS,
    TAP_QUIET,
    TONE_ACCENT,
    TONE_DOWN,
    TONE_QUIET,
    TONE_UP,
    ActionBadge,
    Empty,
    ErrorBox,
    Loading,
    Overline,
    Segment
}
# Aliased: the endpoint bridge declares the wire classes under their own names.
import from models.views {
    NewsFeed as FeedData,
    NewsItem as ItemData,
    NewsSource as SourceData,
    NewsStory as StoryData
}

glob WIDE: str = "(min-width: 1024px)";
glob PAGE: int = 50;
glob SEARCH_PAUSE_MS: int = 250;
glob DESKS: list[tuple[str, str]] = [("market", "Market"), ("fundamentals", "Fundamentals"), ("news", "News"), ("macro", "Macro")];
glob DESK_NAMES: dict[str, str] = {"market": "Market", "fundamentals": "Fundamentals", "news": "News", "macro": "Macro"};
glob VIEWS: dict[str, str] = {"STRONG_BUY": "Strong buy", "BUY": "Buy", "HOLD": "Hold", "SELL": "Sell", "STRONG_SELL": "Strong sell", "RISK_ON": "Risk on", "NEUTRAL": "Neutral", "RISK_OFF": "Risk off"};
glob LEAN_TONES: dict[str, str] = {"up": TONE_UP, "down": TONE_DOWN, "flat": TONE_QUIET};
glob LEANS: list[tuple[str, str]] = [("up", "Bullish"), ("flat", "Neutral"), ("down", "Bearish")];
glob FILTER_KEYS: list[str] = ["q", "ticker", "desk", "lean", "day", "held"];
# A filter's control: a thumb's height on a phone, the bar's on a wide screen.
glob CONTROL: str = "min-h-11 md:min-h-8 md:text-[12px] rounded-md border bg-panel text-[16px] text-text transition-colors duration-150";

"""The parts of a story's address: day/ticker/desk/n, then "requested" for a reader's report."""
obj StoryRef {
    has day: str,
        ticker: str,
        desk: str,
        n: int,
        requested: bool;
}

def parse_ref(id: str) -> StoryRef | None {
    parts = id.split("/");
    if len(parts) < 4 or not parts[3].isdigit() {
        return None;
    }
    return StoryRef(day=parts[0], ticker=parts[1], desk=parts[2], n=int(parts[3]), requested=len(parts) > 4);
}

def is_wide -> bool {
    return window.matchMedia(WIDE).matches;  # jac:ignore[E1030,E1002]
}

def to_story(id: str, search: str) -> str {
    return "/app/news/" + id + search;
}

"""The model's short name: "openrouter/nvidia/nemotron-3.5-super-vl:free" reads "nemotron-3.5-super-vl"."""
def model_name(model: str) -> str {
    return model.split("/")[-1].split(":")[0];
}

"""4:30 PM, for the feed's Time column, whose heading names the time zone."""
def clock_only(iso: str) -> str {
    return time_et(iso).replace(" ET", "");
}

def ViewPill(item: ItemData) -> JsxElement {
    <span className={PILL_BASE + " " + LEAN_TONES.get(item.lean, TONE_QUIET)}>{VIEWS.get(item.view, item.view)}</span>
}

# --- The filters ---------------------------------------------------------------------------

"""A filter as a labeled dropdown: the phone's own picker, with brass around a value in use."""
def Picker(label: str, value: str, pick: Callable[[str], None], children: any = None) -> JsxElement {
    <label className="relative block shrink-0">
        <span className="sr-only">{label}</span>
        <select
            value={value}
            onChange={lambda (e: ChangeEvent) { pick(e.target.value); }}
            className={CONTROL + " appearance-none truncate py-0 pl-3 pr-7 " + ("border-accent/60 text-accent" if value else "border-line hover:border-line-strong")}
        >
            {children}
        </select>
        <ChevronDown size={14} className="pointer-events-none absolute right-2 top-1/2 -translate-y-1/2 text-faint" aria-hidden="true"/>
    </label>
}

def Filters(feed: FeedData, filters: dict[str, str], text: str, type_text: Callable[[str], None], set_filter: Callable[[str, str], None], clear: Callable[[], None]) -> JsxElement {
    total = 0;
    for name in feed.desks {
        total += feed.desks[name];
    }
    active = any(filters[k] for k in FILTER_KEYS);
    held_on = filters["held"] == "1";

    <div className="flex flex-col gap-2.5">
        <div className="flex flex-wrap items-center gap-2.5">
            <div className={SEGMENTS} role="group" aria-label="Desk">
                <Segment label="All" count={total} active={not filters["desk"]} pick={lambda { set_filter("desk", ""); }}/>
                {for (key, label) in DESKS {
                    <Segment key={key} label={label} count={feed.desks.get(key, 0)} active={filters["desk"] == key} pick={lambda { set_filter("desk", key); }}/>
                }}
            </div>
            {if active {
                <button type="button" onClick={lambda { clear(); }} className="press inline-flex min-h-11 items-center gap-1 rounded-md px-2 text-[12px] text-muted hover:bg-hover hover:text-text md:min-h-8">
                    <X size={13} aria-hidden="true"/>
                    Clear filters
                </button>
            }}
        </div>
        <div className="flex flex-col gap-2 md:flex-row">
            <label className="relative block min-w-0 md:flex-1">
                <span className="sr-only">Search the research</span>
                <Search size={14} className="pointer-events-none absolute left-2.5 top-1/2 -translate-y-1/2 text-faint" aria-hidden="true"/>
                <input
                    type="search"
                    value={text}
                    onChange={lambda (e: ChangeEvent) { type_text(e.target.value); }}
                    placeholder="Search headlines, notes, and sources"
                    className={CONTROL + " news-search w-full py-0 pl-8 pr-9 placeholder:text-faint " + ("border-accent/60" if text else "border-line hover:border-line-strong")}
                />
                {if text {
                    <button type="button" aria-label="Clear the search" onClick={lambda { type_text(""); }} className="press absolute right-0 top-0 grid h-full w-10 place-items-center text-faint hover:text-text md:w-8">
                        <X size={14} aria-hidden="true"/>
                    </button>
                }}
            </label>
            <div className="scroll-x -mx-4 flex gap-2 px-4 md:mx-0 md:overflow-visible md:px-0">
            <Picker label="Instrument" value={filters["ticker"]} pick={lambda (v: str) { set_filter("ticker", v); }}>
                <option value="">All instruments</option>
                {for t in feed.tickers {
                    <option key={t} value={t}>{t}</option>
                }}
            </Picker>
            <Picker label="View" value={filters["lean"]} pick={lambda (v: str) { set_filter("lean", v); }}>
                <option value="">Any view</option>
                {for (key, label) in LEANS {
                    <option key={key} value={key}>{label}</option>
                }}
            </Picker>
            <Picker label="Date" value={filters["day"]} pick={lambda (v: str) { set_filter("day", v); }}>
                <option value="">All dates</option>
                {for d in feed.days {
                    <option key={d} value={d}>{day_short(d)}</option>
                }}
            </Picker>
            <button
                type="button"
                aria-pressed={held_on}
                disabled={feed.held == 0 and not held_on}
                title={"Only what the team holds now" if feed.held > 0 else "The team holds nothing the desks have covered"}
                onClick={lambda { set_filter("held", "" if held_on else "1"); }}
                className={"press inline-flex min-h-11 shrink-0 items-center justify-center gap-1.5 rounded-md border px-3 text-[13px] disabled:cursor-default disabled:opacity-50 md:min-h-8 md:text-[12px] " + ("border-accent/60 bg-accent-soft text-accent" if held_on else "border-line text-muted hover:border-line-strong hover:text-text")}
            >
                Holdings
                <span className="num text-[11px] text-faint">{str(feed.held)}</span>
            </button>
            </div>
        </div>
    </div>
}

# --- The feed ------------------------------------------------------------------------------

def FeedRow(item: ItemData, selected: bool, search: str) -> JsxElement {
    <li>
        <Link
            to={to_story(item.id, search)}
            state={{"from_feed": True}}
            aria-current={"true" if selected else None}
            className={"news-row border-b border-line/60 px-4 py-2.5 transition-colors duration-150 " + ("news-row-selected bg-accent-soft" if selected else "hover:bg-hover")}
        >
            <span className="news-time num text-[12px] text-faint" title={stamp_et(item.as_of)}>{clock_only(item.as_of)}</span>
            <span className="news-ticker num text-[12px] font-semibold tracking-[0.02em] text-text">{item.ticker or "Market"}</span>
            <span className="news-head min-w-0">
                <span className="line-clamp-3 text-[13px] leading-[18px] text-pretty text-text">{item.headline}</span>
                {if item.followup or item.requested {
                    <span className="mt-1 flex flex-wrap gap-1">
                        {if item.followup {
                            <span className={PILL_BASE + " " + TONE_QUIET}>Follow-up</span>
                        }}
                        {if item.requested {
                            <span className={PILL_BASE + " " + TONE_ACCENT}>Requested</span>
                        }}
                    </span>
                }}
            </span>
            <span className="news-view flex items-center gap-1.5 md:flex-col md:items-start md:gap-0.5">
                <ViewPill item={item}/>
                <span className="num text-[11px] text-faint" title="The desk's confidence">{pct(item.confidence, 0)}</span>
            </span>
            <span className="news-desk text-[12px] leading-4 text-muted">
                {DESK_NAMES.get(item.desk, item.desk)}
                <span className="num hidden text-[11px] text-faint md:block">{count(item.sources, "source")}</span>
            </span>
        </Link>
    </li>
}

"""The feed's lines under a heading for each run's day."""
def FeedList(items: list[ItemData], selected: str, search: str) -> JsxElement {
    days: list[str] = [];
    for item in items {
        if item.day not in days {
            days.append(item.day);
        }
    }
    <>
        {for day in days {
            <section key={day} aria-label={day_long(day)}>
                <h2 className="news-day border-b border-line bg-panel-2 px-4 py-1.5 text-[11px] font-medium uppercase tracking-[0.05em] text-muted">{day_long(day)}</h2>
                <ul>
                    {for item in items {
                        if item.day == day {
                            <FeedRow key={item.id} item={item} selected={item.id == selected} search={search}/>
                        }
                    }}
                </ul>
            </section>
        }}
    </>
}

# --- A story -------------------------------------------------------------------------------

def SourceRow(source: SourceData) -> JsxElement {
    label = source.label + (" · " + day_short(source.day) if source.day else "");
    <li className="border-t border-line/60 py-2.5 first:border-t-0">
        {if source.link {
            <a href={source.url} target="_blank" rel="noreferrer" className="group inline-flex items-center gap-1.5 text-[12px] font-medium text-accent hover:underline">
                {label}
                <ExternalLink size={12} aria-hidden="true"/>
            </a>
        } else {
            <span className="text-[12px] font-medium text-muted" title="A data feed the desk read with the project's keys, not a page to open">{label}</span>
        }}
        <ul className="mt-1 flex flex-col gap-1 text-[13px] leading-[19px] text-muted">
            {for (i, claim) in enumerate(source.claims) {
                <li key={str(i)}>{claim}</li>
            }}
        </ul>
    </li>
}

def SourceList(sources: list[SourceData]) -> JsxElement {
    if len(sources) == 0 {
        return <></>;
    }
    <section className="mt-6">
        <Overline>Sources</Overline>
        <ul className="mt-1">
            {for source in sources {
                <SourceRow key={source.url} source={source}/>
            }}
        </ul>
    </section>
}

def NoteList(heading: str, notes: list[str]) -> JsxElement {
    if len(notes) == 0 {
        return <></>;
    }
    <section className="mt-6">
        <Overline>{heading}</Overline>
        <ul className="mt-2 flex list-disc flex-col gap-1.5 pl-4 text-[13px] leading-[19px] text-muted marker:text-faint">
            {for (i, note) in enumerate(notes) {
                <li key={str(i)}>{note}</li>
            }}
        </ul>
    </section>
}

"""What the note fed into: the panel's decision that morning, with the trail behind it."""
def Outcome(story: StoryData) -> JsxElement {
    item = story.item;
    if not story.trail {
        return <></>;
    }
    if not item.ticker {
        return <Link to={"/app/runs/" + item.day} className="mt-5 inline-block text-[13px] font-medium text-accent hover:underline">See the morning's run</Link>;
    }
    <div className="mt-5 flex flex-wrap items-center justify-between gap-x-4 gap-y-2 rounded-md border border-line bg-panel-2 px-3 py-2.5">
        <span className="flex items-center gap-2 text-[13px] text-muted">
            {"The panel's decision on " + item.ticker}
            {if story.action {
                <ActionBadge action={story.action}/>
            } else {
                <span className="text-faint">not recorded</span>
            }}
        </span>
        <Link to={"/app/runs/" + item.day + "/" + item.ticker} className="text-[13px] font-medium text-accent hover:underline">See the decision trail</Link>
    </div>
}

def CopyLink(id: str) -> JsxElement {
    has copied: bool = False;

    def copy {
        address = window.location.origin + "/app/news/" + id;
        window.navigator.clipboard.writeText(address).then(lambda (_d: any) {
            copied = True;
            window.setTimeout(lambda { copied = False; }, 1600);
        }).catch(lambda (_e: any) { None; });
    }

    <button
        type="button"
        onClick={copy}
        aria-label={"Link copied" if copied else "Copy a link to this story"}
        title={"Link copied" if copied else "Copy link"}
        className="press grid size-11 place-items-center rounded-md text-muted hover:bg-hover hover:text-text lg:size-8"
    >
        {<Check size={16} strokeWidth={1.75} className="text-up" aria-hidden="true"/> if copied else <Link2 size={16} strokeWidth={1.75} aria-hidden="true"/>}
    </button>
}

"""The story's frame: its desk, the way back, and its first lines, which the feed already knows,
so a story opens at once and fills in. `story` is None until the note arrives."""
def StoryPane(item: ItemData | None, story: StoryData | None, missing: bool, id: str, close: Callable[[], None], heading: any = None) -> JsxElement {
    shown = story.item if story is not None else item;
    <article className="px-4 pb-8 pt-2 lg:px-5">
        <header className="-mr-1.5 flex min-h-11 items-center justify-between gap-2 lg:min-h-9">
            <button type="button" onClick={lambda { close(); }} className="press -ml-2 inline-flex min-h-11 items-center gap-1 rounded-md pl-1 pr-2 text-[13px] text-muted hover:bg-hover hover:text-text lg:hidden">
                <ChevronLeft size={16} aria-hidden="true"/>
                All research
            </button>
            <Overline className="hidden lg:block">{(DESK_NAMES.get(shown.desk, shown.desk) + " desk") if shown is not None else "Research"}</Overline>
            <div className="flex items-center">
                {if shown is not None {
                    <CopyLink id={id}/>
                }}
                <button type="button" onClick={lambda { close(); }} aria-label="Close the story" title="Close" className="press hidden size-8 place-items-center rounded-md text-muted hover:bg-hover hover:text-text lg:grid">
                    <X size={16} strokeWidth={1.75} aria-hidden="true"/>
                </button>
            </div>
        </header>
        {if missing {
            <p className="mt-6 text-[13px] text-muted">This note could not be found. It may belong to a run that is no longer stored.</p>
        } elif shown is None {
            <div className="mt-4 flex flex-col gap-3" aria-busy="true" aria-label="Loading the story">
                <div className="h-14 animate-pulse rounded-md bg-panel-2"></div>
                <div className="h-40 animate-pulse rounded-md bg-panel-2"></div>
            </div>
        } else {
            <h2 ref={heading} tabIndex={-1} className="news-story-head display mt-1 text-[24px] leading-[30px] text-pretty text-text">{shown.headline}</h2>
            <p className="num mt-2 text-[12px] leading-[18px] text-faint">
                {stamp_et(shown.as_of)}
                {(" · " + model_name(story.model)) if story is not None and story.model else ""}
                {" · " + count(shown.sources, "source")}
            </p>
            <div className="mt-3 flex flex-wrap items-center gap-1.5">
                {if shown.ticker {
                    <Link
                        to={"/app/news?ticker=" + shown.ticker}
                        title={"All research on " + shown.ticker}
                        className={PILL_BASE + " num " + TONE_QUIET + " font-semibold text-text hover:border-accent/60"}
                    >
                        {shown.ticker}
                        {if story is not None and story.last_close is not None {
                            <span className="font-normal text-muted">{money(story.last_close)}</span>
                        }}
                    </Link>
                }}
                <ViewPill item={shown}/>
                <span className="num text-[12px] text-faint">{pct(shown.confidence, 0) + " confident"}</span>
                {if shown.followup {
                    <span className={PILL_BASE + " " + TONE_QUIET}>Follow-up</span>
                }}
                {if shown.requested {
                    <span className={PILL_BASE + " " + TONE_ACCENT}>Requested by a reader</span>
                }}
                {if shown.sector {
                    <span className="text-[12px] text-faint">{shown.sector}</span>
                }}
            </div>
            if story is None {
                <div className="mt-5 flex flex-col gap-3" aria-busy="true" aria-label="Loading the note">
                    <div className="h-32 animate-pulse rounded-md bg-panel-2"></div>
                    <div className="h-24 animate-pulse rounded-md bg-panel-2"></div>
                </div>
            } else {
                if story.body {
                    <p className="mt-4 text-[14px] leading-[22px] text-pretty text-text">{story.body}</p>
                }
                <Outcome story={story}/>
                <SourceList sources={story.sources}/>
                <NoteList heading="What could prove this wrong" notes={story.risks}/>
                <NoteList heading="What was missing" notes={story.data_gaps}/>
            }
        }}
    </article>
}

# --- The page ------------------------------------------------------------------------------

def:pub NewsPage -> JsxElement {
    has feed: FeedData | None = None,
        error: str = "",
        more_busy: bool = False,
        story: StoryData | None = None,
        story_id: str = "",
        story_missing: bool = False,
        wide: bool = is_wide(),
        closed: bool = False,
        text: str = "";

    location = useLocation();
    navigate = useNavigate();
    search: str = location.search;
    params: any = new(URLSearchParams, search);  # jac:ignore[E1053]
    filters: dict[str, str] = {k: params.get(k) or "" for k in FILTER_KEYS};
    # By position, since the news desk's own notes have "news" in their address too.
    route_id: str = location.pathname[len("/app/news"):].strip("/");
    latest = useRef(search);
    latest.current = search;
    heading = useRef(None);
    pause = useRef(0);

    # The search box follows the address, so a shared link or the back button fills it in.
    useEffect(lambda {
        text = filters["q"];
    }, [filters["q"]]);

    useEffect(lambda {
        return lambda {
            window.clearTimeout(pause.current);
        };
    }, []);

    # The feed stays where it is under a story's sheet, so going back needs no scrolling at all.
    # The browser's own restoration moved it, by a few rows, to wherever it last saved for the
    # entry, so the page turns it off while it is open.
    useEffect(lambda {
        history: any = window.history;
        before: str = history.scrollRestoration;
        history.scrollRestoration = "manual";
        return lambda {
            history.scrollRestoration = before;
        };
    }, []);

    useEffect(lambda {
        media: any = window.matchMedia(WIDE);
        def changed {
            wide = is_wide();
        }
        media.addEventListener("change", changed);
        return lambda {
            media.removeEventListener("change", changed);
        };
    }, []);

    async def load_page(offset: int) -> any {
        return await get_news_feed(filters["q"], filters["ticker"], filters["desk"], filters["lean"], filters["day"], filters["held"] == "1", offset, PAGE);
    }

    useEffect(lambda {
        active = True;
        async def load {
            fresh: FeedData | None = None;
            try {
                fresh = await load_page(0);
                if active {
                    feed = fresh;
                    error = "";
                }
            } except Exception as e {
                if active {
                    error = str(e);
                }
            }
        }
        load();
        return lambda {
            active = False;
        };
    }, [search]);

    items: list[ItemData] = feed.items if feed is not None else [];
    # A wide screen opens the newest story, until the reader closes it.
    open_id: str = route_id or (items[0].id if wide and not closed and len(items) > 0 else "");
    open_item: ItemData | None = None;
    for item in items {
        if item.id == open_id {
            open_item = item;
        }
    }

    useEffect(lambda {
        ref = parse_ref(open_id);
        if ref is None {
            story = None;
            story_id = "";
            story_missing = bool(open_id);
            return;
        }
        active = True;
        story = None;
        story_id = open_id;
        story_missing = False;
        async def load(at: StoryRef) {
            found: StoryData | None = None;
            try {
                found = await get_news_story(at.day, at.ticker, at.desk, at.n, at.requested);
                if active {
                    story = found;
                    story_missing = found is None;
                }
            } except Exception {
                if active {
                    story_missing = True;
                }
            }
        }
        load(ref);  # jac:ignore[E1053]
        return lambda {
            active = False;
        };
    }, [open_id]);

    sheet: bool = not wide and bool(open_id);

    """Close the story. A sheet opened from the feed goes back, which puts the feed where it was."""
    def close {
        closed = True;
        if not route_id {
            return;
        }
        if not wide and location.state is not None and location.state.from_feed {
            navigate(-1);
        } else {
            navigate("/app/news" + search, {"replace": not wide});
        }
    }

    # A sheet over the feed takes the focus, and Escape takes it away again.
    useEffect(lambda {
        if not sheet {
            return;
        }
        if heading.current is not None {
            heading.current.focus({"preventScroll": True});
        }
        def on_key(e: KeyboardEvent) {
            if e.key == "Escape" {
                close();
            }
        }
        window.addEventListener("keydown", on_key);
        return lambda {
            window.removeEventListener("keydown", on_key);
        };
    }, [sheet, open_id, open_item is not None, story is not None]);

    def with_filter(name: str, value: str) -> str {
        next_params: any = new(URLSearchParams, latest.current);  # jac:ignore[E1053]
        if value {
            next_params.set(name, value);
        } else {
            next_params.delete(name);
        }
        query = next_params.toString();
        return "?" + query if query else "";
    }

    def set_filter(name: str, value: str) {
        navigate("/app/news" + with_filter(name, value), {"replace": True});
    }

    def clear {
        window.clearTimeout(pause.current);
        text = "";
        navigate("/app/news", {"replace": True});
    }

    """The address changes when typing pauses, so a burst of keys makes one request."""
    def type_text(value: str) {
        text = value;
        window.clearTimeout(pause.current);
        pause.current = window.setTimeout(lambda { set_filter("q", value if value.strip() else ""); }, SEARCH_PAUSE_MS);
    }

    async def show_more {
        if feed is None or feed.next_offset is None {
            return;
        }
        asked = search;
        more_busy = True;
        fresh: FeedData | None = None;
        try {
            fresh = await load_page(feed.next_offset);
            if latest.current == asked {
                fresh.items = feed.items + fresh.items;
                feed = fresh;
            }
        } except Exception as e {
            error = str(e);
        }
        more_busy = False;
    }

    if error {
        return <ErrorBox message={error}/>;
    }
    if feed is None {
        return <Loading label="Loading the research"/>;
    }

    filtering = any(filters[k] for k in FILTER_KEYS);
    pane_open = bool(open_id);

    <>
    <div className="rise flex flex-col gap-4">
        <header className="flex flex-col gap-1">
            <Overline>Research feed</Overline>
            <div className="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
                <h1 className="display text-[36px] leading-10 text-text">News</h1>
                <span className="num text-[12px] text-faint" role="status">{count(feed.total, "note")}</span>
            </div>
            <p className="hidden text-[13px] leading-5 text-muted md:block">Every note the research desks wrote each morning, newest first, with the sources behind it.</p>
        </header>
        <Filters feed={feed} filters={filters} text={text} type_text={type_text} set_filter={set_filter} clear={clear}/>
        {if feed.total == 0 and not filtering and not pane_open {
            <Empty title="No research yet">The desks publish here once the first morning run has finished.</Empty>
        } elif feed.total == 0 and not pane_open {
            <Empty title="No research matches">
                Try fewer filters. <button type="button" onClick={lambda { clear(); }} className="text-accent hover:underline">Clear them all</button>.
            </Empty>
        } else {
            <div className={"news-split grid grid-cols-1 items-start gap-4 " + ("lg:grid-cols-[minmax(0,3fr)_minmax(0,2fr)]" if pane_open else "")}>
                <section className="news-pane rounded-md border border-line bg-panel" aria-label="Research headlines">
                    <div className="news-row news-row-head border-b border-line bg-panel-2 px-4 text-[11px] font-medium uppercase tracking-[0.05em] text-muted" aria-hidden="true">
                        <span className="news-time">Time, ET</span>
                        <span className="news-ticker">Ticker</span>
                        <span className="news-head">Headline</span>
                        <span className="news-view">View</span>
                        <span className="news-desk">Desk</span>
                    </div>
                    <FeedList items={items} selected={open_id} search={search}/>
                    {if feed.next_offset is not None {
                        <div className="px-4 py-3">
                            <button type="button" disabled={more_busy} onClick={show_more} className={TAP_QUIET + " w-full"}>
                                {"Loading…" if more_busy else "Show " + str(min(PAGE, feed.total - len(items))) + " more of " + str(feed.total - len(items))}
                            </button>
                        </div>
                    }}
                </section>
                {if pane_open and not sheet {
                    <section className="news-pane rounded-md border border-line bg-panel" aria-label="Story">
                        <StoryPane item={open_item} story={story if story_id == open_id else None} missing={story_missing} id={open_id} close={close} heading={heading}/>
                    </section>
                }}
            </div>
        }}
    </div>
    {if sheet {
        <section className="news-sheet" aria-label="Story">
            <StoryPane item={open_item} story={story if story_id == open_id else None} missing={story_missing} id={open_id} close={close} heading={heading}/>
        </section>
    }}
    </>
}
