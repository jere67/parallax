"""The stock page's small charts, drawn in SVG and HTML with the theme's tokens: a rating gauge,
bars by reporting period, the steps from revenue to profit, beats and misses, and returns by month.
Every value a mark stands for is also in a tooltip or beside it, and no chart has two axes: a margin
gets its own row of numbers rather than a second scale."""
import from react { useState }
import from dashboard.market.columns { big_money }
import from dashboard.ui.format { MISSING, day_short, pct, signed, signed_pct }
import from models.market { PeriodView as Period, RatingPointView as RatingPoint, SeasonView as Season, SurpriseView as Surprise }

glob MONTH_NAMES: list[str] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
glob GAUGE_ZONES: list[str] = ["Strong sell", "Sell", "Neutral", "Buy", "Strong buy"];
glob ZONE_COLORS: list[str] = ["var(--down)", "var(--down)", "var(--line-strong)", "var(--up)", "var(--up)"];
glob ZONE_OPACITY: list[float] = [1.0, 0.45, 1.0, 0.45, 1.0];
# Where each zone starts and ends on the -1 to 1 score, matching market/prices.jac.
glob ZONE_EDGES: list[float] = [-1.0, -0.5, -0.1, 0.1, 0.5, 1.0];

"""A series in a bar chart: the period value's key, what it is called, and its color."""
obj:pub BarSeriesSpec {
    has key: str,
        label: str,
        color: str;
}

def arc_point(score: float, radius: float) -> tuple[float, float] {
    angle = 3.141592653589793 * (1.0 - (score + 1.0) / 2.0);
    return (60.0 + radius * Math.cos(angle), 62.0 - radius * Math.sin(angle));
}

def arc_path(low: float, high: float, radius: float) -> str {
    a = arc_point(low, radius);
    b = arc_point(high, radius);
    return "M " + str(a[0]) + " " + str(a[1]) + " A " + str(radius) + " " + str(radius) + " 0 0 1 " + str(b[0]) + " " + str(b[1]);
}

"""A half-dial from strong sell to strong buy, with the rating in words under the needle, so the
reading never rests on color alone."""
def:pub Gauge(title: str, score: float | None, rating: str, caption: str = "") -> JsxElement {
    needle = arc_point(score, 38.0) if score is not None else None;
    <div className="min-w-0">
        <h3 className="text-[13px] font-medium text-text">{title}</h3>
        {if score is None {
            <p className="mt-3 text-[13px] text-muted">No reading yet for this stock.</p>
        } else {
            <div className="mx-auto mt-2 max-w-[240px]">
                <svg viewBox="0 0 120 72" role="img" aria-label={title + ": " + rating}>
                    {for i in range(5) {
                        <path key={GAUGE_ZONES[i]} d={arc_path(ZONE_EDGES[i] + 0.012, ZONE_EDGES[i + 1] - 0.012, 50.0)} fill="none" stroke={ZONE_COLORS[i]} strokeOpacity={ZONE_OPACITY[i]} strokeWidth="7" strokeLinecap="butt"/>
                    }}
                    <line x1="60" y1="62" x2={needle[0]} y2={needle[1]} stroke="var(--text)" strokeWidth="1.6" strokeLinecap="round"/>
                    <circle cx="60" cy="62" r="2.6" fill="var(--text)"/>
                </svg>
                <div className="-mt-1 text-center">
                    <div className="display text-[22px] leading-7 text-text">{rating}</div>
                    {if caption {
                        <div className="num text-[11px] text-muted">{caption}</div>
                    }}
                </div>
            </div>
        }}
    </div>
}

"""The legend every chart of two or more series carries."""
def:pub Legend(series: list[BarSeriesSpec]) -> JsxElement {
    <div className="flex flex-wrap gap-x-4 gap-y-1 text-[11px] text-muted">
        {for s in series {
            <span key={s.key} className="inline-flex items-center gap-1.5">
                <span className="size-2 rounded-[2px]" style={{"background": s.color}} aria-hidden="true"></span>
                {s.label}
            </span>
        }}
    </div>
}

"""Grouped bars by period, on one axis through zero. Hovering a period shows its values; `footer`
gives one number per period under its label, such as a margin."""
def:pub PeriodBars(periods: list[Period], series: list[BarSeriesSpec], footer_label: str = "", footer: Callable[[Period], str] | None = None, height: int = 180) -> JsxElement {
    (active, set_active) = useState(-1);

    values: list[float] = [];
    for p in periods {
        for s in series {
            found = p.values.get(s.key);
            if found is not None {
                values.append(found);
            }
        }
    }
    top: any = max(*(values + [0.0]));
    bottom: any = min(*(values + [0.0]));
    span = (top - bottom) or 1.0;
    zero = top / span * 100.0;

    if len(values) == 0 {
        return <p className="py-6 text-[13px] text-muted">This company reports none of these figures in U.S. GAAP.</p>;
    }

    <div>
        <Legend series={series}/>
        <div className="relative mt-3" onMouseLeave={lambda { set_active(-1); }}>
            <div className="relative flex items-stretch gap-1.5" style={{"height": str(height) + "px"}}>
                <div className="pointer-events-none absolute inset-x-0 h-px bg-line-strong" style={{"top": str(zero) + "%"}}></div>
                {for (i, p) in enumerate(periods) {
                    <button
                        key={p.end}
                        type="button"
                        className={"relative flex min-w-0 flex-1 cursor-default justify-center gap-0.5 rounded-sm " + ("bg-hover" if active == i else "")}
                        aria-label={p.label + ": " + ", ".join([s.label + " " + big_money(p.values.get(s.key)) for s in series])}
                        onMouseEnter={lambda { set_active(i); }}
                        onFocus={lambda { set_active(i); }}
                    >
                        {for s in series {
                            <span key={s.key} className="relative h-full w-full max-w-5">
                                <span
                                    className="absolute inset-x-0"
                                    style={{
                                        "background": s.color,
                                        "top": str((top - max(p.values.get(s.key) or 0.0, 0.0)) / span * 100.0) + "%",
                                        "height": str(abs(p.values.get(s.key) or 0.0) / span * 100.0) + "%",
                                        "borderRadius": "2px"
                                    }}
                                ></span>
                            </span>
                        }}
                    </button>
                }}
            </div>
            {if active >= 0 and active < len(periods) {
                <div
                    className="pointer-events-none absolute top-0 z-10 whitespace-nowrap rounded-md border border-line bg-overlay px-2.5 py-1.5 text-[11px] shadow-overlay"
                    style={{"left": str(min(78.0, (active + 0.5) / len(periods) * 100.0)) + "%", "transform": "translateX(-50%)"}}
                >
                    <div className="font-medium text-text">{periods[active].label}</div>
                    {for s in series {
                        <div key={s.key} className="num flex justify-between gap-3 text-muted"><span>{s.label}</span><span className="text-text">{big_money(periods[active].values.get(s.key))}</span></div>
                    }}
                </div>
            }}
            <div className="mt-1.5 flex gap-1.5">
                {for p in periods {
                    <div key={p.end} className="num min-w-0 flex-1 truncate text-center text-[10px] text-faint">{p.label}</div>
                }}
            </div>
            {if footer is not None {
                <div className="mt-2 border-t border-line pt-1.5">
                    <div className="text-[10px] uppercase tracking-[0.05em] text-faint">{footer_label}</div>
                    <div className="mt-0.5 flex gap-1.5">
                        {for p in periods {
                            <div key={p.end} className="num min-w-0 flex-1 truncate text-center text-[11px] text-text">{footer(p)}</div>
                        }}
                    </div>
                </div>
            }}
        </div>
    </div>
}

"""From revenue down to what is left, each step as a share of revenue: how a sale becomes profit."""
def:pub ProfitSteps(revenue: float | None, gross: float | None, operating: float | None, net: float | None) -> JsxElement {
    steps: list[tuple[str, float | None]] = [("Revenue", revenue), ("Gross profit", gross), ("Operating income", operating), ("Net income", net)];
    if not revenue or revenue <= 0 {
        return <p className="py-3 text-[13px] text-muted">This company reports no revenue in U.S. GAAP.</p>;
    }
    <div className="space-y-2.5">
        {for (name, value) in steps {
            <div key={name}>
                <div className="flex items-baseline justify-between gap-3 text-[12px]">
                    <span className="text-muted">{name}</span>
                    <span className="num text-text">
                        {big_money(value)}
                        <span className="ml-2 text-faint">{pct(value / revenue, 0) if value is not None else MISSING}</span>
                    </span>
                </div>
                <div className="mt-1 h-2 rounded-sm bg-panel-2">
                    <div className={"h-full rounded-sm " + ("bg-down" if value is not None and value < 0 else "")} style={{"width": str(min(100.0, abs(value or 0.0) / revenue * 100.0)) + "%", "background": "var(--compare-2)" if value is None or value >= 0 else "var(--down)"}}></div>
                </div>
            </div>
        }}
    </div>
}

"""One bar per reported quarter, up for a beat and down for a miss, with the percent written on it."""
def:pub SurpriseBars(surprises: list[Surprise]) -> JsxElement {
    known = [s for s in surprises if s.surprise_pct is not None];
    if len(known) == 0 {
        return <p className="py-3 text-[13px] text-muted">No earnings consensus for this stock.</p>;
    }
    reach: any = max(*([abs(s.surprise_pct or 0.0) for s in known] + [1.0]));
    <div className="flex items-stretch gap-2">
        {for s in known {
            <div key={s.period} className="min-w-0 flex-1 text-center">
                <div className="num text-[11px] text-text">{signed_pct((s.surprise_pct or 0.0) / 100.0, 1)}</div>
                <div className="relative mt-1 h-20">
                    <div className="absolute inset-x-0 top-1/2 h-px bg-line-strong"></div>
                    <div
                        className="absolute inset-x-1/4"
                        style={{
                            "background": "var(--up)" if (s.surprise_pct or 0.0) >= 0 else "var(--down)",
                            "borderRadius": "2px",
                            "top": "calc(50% - " + str(max(s.surprise_pct or 0.0, 0.0) / reach * 50.0) + "%)" ,
                            "height": str(abs(s.surprise_pct or 0.0) / reach * 50.0) + "%"
                        }}
                    ></div>
                </div>
                <div className="num mt-1 truncate text-[10px] text-faint">{day_short(s.period)}</div>
            </div>
        }}
    </div>
}

"""The analysts' consensus, month by month, as a bar each way from neutral."""
def:pub RatingBars(trend: list[RatingPoint]) -> JsxElement {
    if len(trend) == 0 {
        return <p className="py-3 text-[13px] text-muted">No analyst history for this stock.</p>;
    }
    <div className="flex items-stretch gap-1.5">
        {for p in trend {
            <div key={p.period} className="min-w-0 flex-1 text-center" title={day_short(p.period) + ": " + signed(p.score) + " from " + str(p.analysts) + " analysts"}>
                <div className="relative h-20">
                    <div className="absolute inset-x-0 top-1/2 h-px bg-line-strong"></div>
                    <div
                        className="absolute inset-x-[20%]"
                        style={{
                            "background": "var(--up)" if p.score >= 0 else "var(--down)",
                            "borderRadius": "2px",
                            "top": "calc(50% - " + str(max(p.score, 0.0) * 50.0) + "%)",
                            "height": str(abs(p.score) * 50.0) + "%"
                        }}
                    ></div>
                </div>
                <div className="num mt-1 truncate text-[10px] text-faint">{MONTH_NAMES[int(p.period[5:7]) - 1]}</div>
            </div>
        }}
    </div>
}

"""A cell's tint on the diverging scale: stronger with the size of the move, neutral at zero."""
def season_tint(value: float | None) -> str {
    if value is None {
        return "transparent";
    }
    share = min(abs(value) / 0.15, 1.0) * 40.0;
    return "color-mix(in srgb, var(--" + ("up" if value >= 0 else "down") + ") " + str(share) + "%, transparent)";
}

"""Returns by calendar month, one row per year, with each month's average along the bottom."""
def:pub SeasonTable(seasons: list[Season]) -> JsxElement {
    averages: list[float | None] = [];
    for m in range(12) {
        known = [s.months[m] for s in seasons if s.months[m] is not None];
        total = 0.0;
        for value in known {
            total = total + value;
        }
        averages.append(total / len(known) if len(known) > 0 else None);
    }
    <div className="scroll-x">
        <table className="w-full min-w-[720px] border-separate border-spacing-px text-right">
            <thead>
                <tr>
                    <th scope="col" className="px-2 py-1 text-left text-[11px] font-medium text-muted">Year</th>
                    {for name in MONTH_NAMES {
                        <th key={name} scope="col" className="px-1 py-1 text-[11px] font-medium text-muted">{name}</th>
                    }}
                    <th scope="col" className="px-2 py-1 text-[11px] font-medium text-muted">Total</th>
                </tr>
            </thead>
            <tbody>
                {for s in seasons {
                    <tr key={s.year}>
                        <th scope="row" className="num px-2 py-1 text-left text-[12px] font-medium text-text">{str(s.year)}</th>
                        {for (i, value) in enumerate(s.months) {
                            <td key={i} className="num rounded-sm px-1 py-1 text-[11px] text-text" style={{"background": season_tint(value)}}>{signed_pct(value, 1) if value is not None else ""}</td>
                        }}
                        <td className="num px-2 py-1 text-[11px] font-medium text-text">{signed_pct(s.total, 1)}</td>
                    </tr>
                }}
                <tr>
                    <th scope="row" className="px-2 py-1 text-left text-[11px] font-medium text-muted">Average</th>
                    {for (i, value) in enumerate(averages) {
                        <td key={i} className="num rounded-sm border-t border-line-strong px-1 py-1 text-[11px] font-medium text-text" style={{"background": season_tint(value)}}>{signed_pct(value, 1) if value is not None else ""}</td>
                    }}
                    <td className="border-t border-line-strong"></td>
                </tr>
            </tbody>
        </table>
    </div>
}
