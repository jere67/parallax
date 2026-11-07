"""A stock's price over a chosen range, drawn with TradingView's Lightweight Charts, with each range's
change on its button. Comparing against peers turns the chart into percent lines from the range's
start, so stocks at different prices share one axis. Volume sits along the bottom in the price view."""
import from react { useEffect }
import from "lightweight-charts" {
    AreaSeries,
    CandlestickSeries,
    ColorType,
    CrosshairMode,
    HistogramSeries,
    LineSeries,
    LineStyle,
    LineType,
    createChart
}
import from dashboard.market.ranges { RANGES, bars_for, range_base, range_change }
import from dashboard.ui.format { compact, day_short, money, signed_pct, tone }
import from dashboard.ui.theme { THEME_EVENT, css_var }
import from models.market { BarView as Bar }

# In fixed order: the stock itself, then each peer in the order it was added.
glob COMPARE_TOKENS: list[str] = ["--compare-1", "--compare-2", "--compare-3", "--compare-4"];
glob:pub MAX_COMPARE: int = 3;
glob TIME_TICK: int = 3;

"""A #rrggbb token at `alpha`, as rgba() for the chart's canvas."""
def tint(hex: str, alpha: float) -> str {
    h = hex.strip().lstrip("#");
    if len(h) != 6 {
        return hex;
    }
    return "rgba(" + str(int(h[0:2], 16)) + ", " + str(int(h[2:4], 16)) + ", " + str(int(h[4:6], 16)) + ", " + str(alpha) + ")";
}

"""An intraday bar's Unix time as New York's clock; a daily bar's time is already its date."""
def time_text(time: any, intraday: bool) -> str {
    if not intraday {
        return day_short(str(time));
    }
    moment = new(Date, time * 1000);  # jac:ignore[E1053]
    return moment.toLocaleString("en-US", {"timeZone": "America/New_York", "month": "short", "day": "numeric", "hour": "numeric", "minute": "2-digit"});  # jac:ignore[E1030]
}

def tick_text(time: any, as_clock: bool) -> str {
    moment = new(Date, time * 1000);  # jac:ignore[E1053]
    if as_clock {
        return moment.toLocaleTimeString("en-US", {"timeZone": "America/New_York", "hour": "numeric", "minute": "2-digit"});  # jac:ignore[E1030]
    }
    return moment.toLocaleDateString("en-US", {"timeZone": "America/New_York", "month": "short", "day": "numeric"});  # jac:ignore[E1030]
}

"""Each compared stock, for the legend and the lines."""
obj:pub CompareLine {
    has symbol: str,
        daily: list[Bar],
        intraday: list[Bar];
}

def:pub PriceChart(symbol: str, daily: list[Bar], intraday: list[Bar], compare: list[CompareLine] = [], height: int = 360) -> JsxElement {
    has box: Ref[HTMLDivElement] = Ref(),
        range: str = "1Y",
        candles: bool = False,
        hover: Bar | None = None,
        repaint: int = 0;

    useEffect(
        lambda {
            bump = lambda {
                repaint = repaint + 1;
            };
            media = window.matchMedia("(prefers-color-scheme: dark)");  # jac:ignore[E1030]
            window.addEventListener(THEME_EVENT, bump);
            media.addEventListener("change", bump);  # jac:ignore[E1030]
            return lambda {
                window.removeEventListener(THEME_EVENT, bump);
                media.removeEventListener("change", bump);  # jac:ignore[E1030]
            };
        },
        []
    );

    bars = bars_for(range, daily, intraday);
    intraday_view = range == "1D" or range == "5D";
    comparing = len(compare) > 0;

    useEffect(
        lambda {
            el = box.current;
            if el is None or len(bars) == 0 {
                return;
            }
            single = range == "1D";
            time_scale: dict[str, any] = {
                "borderVisible": False,
                "lockVisibleTimeRangeOnResize": True,
                "timeVisible": intraday_view,
                "secondsVisible": False
            };
            if intraday_view {
                # Lightweight Charts marks a new day below this kind and a time within one at it.
                time_scale["tickMarkFormatter"] = lambda (t: any, kind: any) -> str {
                    return tick_text(t, single or kind >= TIME_TICK);
                };
            }
            chart = createChart(
                el,
                {
                    "autoSize": True,
                    "layout": {
                        "background": {"type": ColorType.Solid, "color": "transparent"},
                        "textColor": css_var("--faint"),
                        "fontFamily": "'JetBrains Mono Variable', ui-monospace, monospace",
                        "fontSize": 10,
                        "attributionLogo": False
                    },
                    "grid": {"vertLines": {"visible": False}, "horzLines": {"color": tint(css_var("--line"), 0.7)}},
                    "rightPriceScale": {"borderVisible": False, "entireTextOnly": True, "scaleMargins": {"top": 0.08, "bottom": 0.2 if not comparing else 0.06}},
                    "timeScale": time_scale,
                    "crosshair": {
                        "mode": CrosshairMode.Magnet,
                        "vertLine": {"color": css_var("--line-strong"), "width": 1, "style": LineStyle.Solid, "labelBackgroundColor": css_var("--panel-2")},
                        "horzLine": {"color": css_var("--line-strong"), "width": 1, "style": LineStyle.Dashed, "labelBackgroundColor": css_var("--panel-2")}
                    },
                    "handleScroll": False,
                    "handleScale": False,
                    "localization": {
                        "priceFormatter": lambda (v: float) -> str {
                            return signed_pct(v / 100.0) if comparing else money(v);
                        },
                        "timeFormatter": lambda (t: any) -> str {
                            return time_text(t, intraday_view);
                        }
                    }
                }
            );
            color = css_var(COMPARE_TOKENS[0]);
            if comparing {
                # From the same close as the range's button, so the line ends on the button's number.
                base = range_base(range, daily) or bars[0].close;
                line = chart.addSeries(LineSeries, {"color": color, "lineWidth": 2, "priceLineVisible": False, "lastValueVisible": True, "lineType": LineType.Simple});
                line.setData([{"time": b.time, "value": (b.close / base - 1.0) * 100.0} for b in bars]);
                for (i, other) in enumerate(compare) {
                    theirs = bars_for(range, other.daily, other.intraday);
                    if len(theirs) == 0 {
                        continue;
                    }
                    start = range_base(range, other.daily) or theirs[0].close;
                    peer = chart.addSeries(LineSeries, {"color": css_var(COMPARE_TOKENS[i + 1]), "lineWidth": 2, "priceLineVisible": False, "lastValueVisible": True, "lineType": LineType.Simple});
                    peer.setData([{"time": b.time, "value": (b.close / start - 1.0) * 100.0} for b in theirs]);
                }
            } elif candles {
                body = chart.addSeries(
                    CandlestickSeries,
                    {
                        "upColor": css_var("--up"),
                        "downColor": css_var("--down"),
                        "borderVisible": False,
                        "wickUpColor": css_var("--up"),
                        "wickDownColor": css_var("--down"),
                        "priceLineVisible": False
                    }
                );
                body.setData([{"time": b.time, "open": b.open, "high": b.high, "low": b.low, "close": b.close} for b in bars]);
            } else {
                area = chart.addSeries(
                    AreaSeries,
                    {
                        "lineColor": color,
                        "topColor": tint(color, 0.22),
                        "bottomColor": tint(color, 0.0),
                        "lineWidth": 2,
                        "lineType": LineType.Simple,
                        "priceLineVisible": False,
                        "crosshairMarkerRadius": 4,
                        "crosshairMarkerBorderColor": css_var("--panel"),
                        "crosshairMarkerBorderWidth": 2
                    }
                );
                area.setData([{"time": b.time, "value": b.close} for b in bars]);
            }
            if not comparing {
                volume = chart.addSeries(HistogramSeries, {"priceFormat": {"type": "volume"}, "priceScaleId": "", "lastValueVisible": False, "priceLineVisible": False});
                volume.priceScale().applyOptions({"scaleMargins": {"top": 0.85, "bottom": 0}});
                up = tint(css_var("--up"), 0.35);
                down = tint(css_var("--down"), 0.35);
                volume.setData([{"time": b.time, "value": b.volume, "color": up if b.close >= b.open else down} for b in bars]);
            }
            chart.timeScale().fitContent();
            by_time: dict[any, Bar] = {};
            for b in bars {
                by_time[str(b.time)] = b;
            }
            chart.subscribeCrosshairMove(
                lambda (param: any) {
                    hover = by_time.get(str(param.time)) if param.time else None;
                }
            );
            return lambda {
                chart.remove();
            };
        },
        [daily, intraday, compare, range, candles, repaint]
    );

    shown = hover if hover is not None else (bars[len(bars) - 1] if len(bars) > 0 else None);

    <div>
        <div className="flex flex-wrap items-center justify-between gap-x-4 gap-y-2 px-4 pt-3">
            <div className="num min-h-5 text-[12px] text-muted">
                {if shown is not None and not comparing {
                    <span className="flex flex-wrap gap-x-3">
                        <span>{time_text(shown.time, intraday_view)}</span>
                        <span className="text-text">{money(shown.close)}</span>
                        <span>{"Vol " + compact(shown.volume)}</span>
                    </span>
                }}
                {if comparing {
                    <span className="flex flex-wrap items-center gap-x-3">
                        <span className="inline-flex items-center gap-1.5 text-text"><span className="h-0.5 w-3.5 rounded-full" style={{"background": "var(--compare-1)"}} aria-hidden="true"></span>{symbol}</span>
                        {for (i, other) in enumerate(compare) {
                            <span key={other.symbol} className="inline-flex items-center gap-1.5 text-text"><span className="h-0.5 w-3.5 rounded-full" style={{"background": "var(" + COMPARE_TOKENS[i + 1] + ")"}} aria-hidden="true"></span>{other.symbol}</span>
                        }}
                    </span>
                }}
            </div>
            {if not comparing {
                <div className="inline-flex h-7 items-center gap-0.5 rounded-md border border-line bg-panel-2 p-0.5" role="group" aria-label="Chart style">
                    <button type="button" aria-pressed={not candles} className={"press h-full rounded-[3px] px-2 text-[11px] font-medium " + ("bg-panel text-text" if not candles else "text-muted hover:text-text")} onClick={lambda { candles = False; }}>Line</button>
                    <button type="button" aria-pressed={candles} className={"press h-full rounded-[3px] px-2 text-[11px] font-medium " + ("bg-panel text-text" if candles else "text-muted hover:text-text")} onClick={lambda { candles = True; }}>Candles</button>
                </div>
            }}
        </div>
        {if len(bars) == 0 {
            <div className="grid place-items-center text-[13px] text-muted" style={{"height": str(height) + "px"}}>No price history for this range.</div>
        } else {
            <div ref={box} role="img" aria-label={symbol + " price chart, " + range} style={{"height": str(height) + "px"}}></div>
        }}
        <div className="scroll-x flex gap-1 border-t border-line px-2 py-2" role="group" aria-label="Chart range">
            {for name in RANGES {
                <button
                    key={name}
                    type="button"
                    aria-pressed={range == name}
                    className={"press flex min-w-14 shrink-0 flex-1 flex-col items-center rounded px-1.5 py-1 " + ("bg-hover" if range == name else "hover:bg-hover")}
                    onClick={lambda { range = name; hover = None; }}
                >
                    <span className={"text-[12px] font-medium " + ("text-text" if range == name else "text-muted")}>{name}</span>
                    <span className={"num text-[11px] " + tone(range_change(name, daily, intraday))}>{signed_pct(range_change(name, daily, intraday))}</span>
                </button>
            }}
        </div>
    </div>
}
