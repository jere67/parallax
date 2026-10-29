"""The equity curves: the team portfolio and its baselines as cumulative return since the
start, drawn with TradingView's Lightweight Charts. The team is a brass line over a fading
fill; the baselines are dashed, so the eye follows the committee first. Colors are the
theme's series tokens, so the chart repaints when the reader switches theme or the system
does."""
import from react { useEffect }
import from "lightweight-charts" { createChart, AreaSeries, ColorType, CrosshairMode, LineSeries, LineStyle, LineType }
import from models.views { Series }
import from dashboard.ui.format { signed_pct }
import from dashboard.ui.theme { THEME_EVENT, css_var }

glob SERIES_COLORS: dict[str, str] = {
    "team": "--series-team",
    "equal_weight": "--series-ew",
    "spy": "--series-spy"
};
# A baseline's dash, as Lightweight Charts styles and as the legend's swatch.
glob DASHES: dict[str, int] = {"equal_weight": LineStyle.SparseDotted, "spy": LineStyle.Dashed};
glob SWATCH_DASHES: dict[str, str] = {"equal_weight": "1 3", "spy": "4 3"};

"""A #rrggbb token at `alpha`, as rgba() for the chart's canvas."""
def tint(hex: str, alpha: float) -> str {
    h = hex.strip().lstrip("#");
    if len(h) != 6 {
        return hex;
    }
    return "rgba(" + str(int(h[0:2], 16)) + ", " + str(int(h[2:4], 16)) + ", " + str(int(h[4:6], 16)) + ", " + str(alpha) + ")";
}

"""Each series' return at `day`, or at its last point when `day` is empty or missing."""
def returns_at(series: list[Series], start: float, day: str) -> dict[str, float] {
    out: dict[str, float] = {};
    for s in series {
        if len(s.points) == 0 {
            continue;
        }
        value = s.points[len(s.points) - 1].equity;
        for p in s.points {
            if p.day == day {
                value = p.equity;
            }
        }
        out[s.key] = value / start - 1.0;
    }
    return out;
}

"""The legend's short line in a series' color, dashed for a baseline."""
def Swatch(series_key: str) -> JsxElement {
    color = "var(" + SERIES_COLORS.get(series_key, "--series-spy") + ")";
    <svg viewBox="0 0 14 2" className="h-0.5 w-3.5 shrink-0" aria-hidden="true">
        <line
            x1="0"
            y1="1"
            x2="14"
            y2="1"
            stroke={color}
            strokeWidth="2"
            strokeLinecap="round"
            strokeDasharray={SWATCH_DASHES.get(series_key, "")}
        />
    </svg>
}

"""`height` is the chart's least height; inside a filling panel it grows to the panel."""
def:pub EquityChart(series: list[Series], starting_cash: float, height: int = 280) -> JsxElement {
    has box: Ref[HTMLDivElement] = Ref(),
        hover_day: str = "",
        repaint: int = 0;

    # Repaint on a theme change, whether the reader's or the system's.
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

    useEffect(
        lambda {
            el = box.current;
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
                    "grid": {
                        "vertLines": {"visible": False},
                        "horzLines": {"color": tint(css_var("--line"), 0.7)}
                    },
                    "rightPriceScale": {
                        "borderVisible": False,
                        "entireTextOnly": True,
                        "scaleMargins": {"top": 0.14, "bottom": 0.06}
                    },
                    "timeScale": {
                        "borderVisible": False,
                        "fixLeftEdge": True,
                        "fixRightEdge": True,
                        "lockVisibleTimeRangeOnResize": True
                    },
                    "crosshair": {
                        "mode": CrosshairMode.Magnet,
                        "vertLine": {"color": css_var("--line-strong"), "width": 1, "style": LineStyle.Solid, "labelBackgroundColor": css_var("--panel-2")},
                        "horzLine": {"color": css_var("--line-strong"), "width": 1, "style": LineStyle.Dashed, "labelBackgroundColor": css_var("--panel-2")}
                    },
                    "handleScroll": False,
                    "handleScale": False,
                    "localization": {
                        "priceFormatter": lambda (v: float) -> str {
                            return signed_pct(v / 100.0);
                        }
                    }
                }
            );
            # Baselines first, so the team's line and fill draw over them.
            ordered = [s for s in series if s.key != "team"] + [s for s in series if s.key == "team"];
            for s in ordered {
                color = css_var(SERIES_COLORS.get(s.key, "--series-spy"));
                if s.key == "team" {
                    line = chart.addSeries(
                        AreaSeries,
                        {
                            "lineColor": color,
                            "topColor": tint(color, 0.22),
                            "bottomColor": tint(color, 0.0),
                            "lineWidth": 2,
                            "lineType": LineType.Simple,
                            "priceLineVisible": False,
                            "lastValueVisible": True,
                            "crosshairMarkerRadius": 4,
                            "crosshairMarkerBorderColor": css_var("--panel"),
                            "crosshairMarkerBorderWidth": 2
                        }
                    );
                    line.createPriceLine(
                        {
                            "price": 0,
                            "color": css_var("--line-strong"),
                            "lineWidth": 1,
                            "lineStyle": LineStyle.Dashed,
                            "axisLabelVisible": False,
                            "title": "Start"
                        }
                    );
                } else {
                    line = chart.addSeries(
                        LineSeries,
                        {
                            "color": color,
                            "lineWidth": 2,
                            "lineStyle": DASHES.get(s.key, LineStyle.Dashed),
                            "lineType": LineType.Simple,
                            "priceLineVisible": False,
                            "lastValueVisible": True,
                            "crosshairMarkerRadius": 3,
                            "crosshairMarkerBorderColor": css_var("--panel"),
                            "crosshairMarkerBorderWidth": 2
                        }
                    );
                }
                line.setData(
                    [
                        {"time": p.day, "value": (p.equity / starting_cash - 1.0) * 100.0}
                        for p in s.points
                    ]
                );
            }
            chart.timeScale().fitContent();
            chart.subscribeCrosshairMove(
                lambda (param: any) {
                    hover_day = str(param.time) if param.time else "";
                }
            );
            return lambda {
                chart.remove();
            };
        },
        [series, starting_cash, repaint]
    );

    shown = returns_at(series, starting_cash, hover_day);

    <div className="flex flex-1 flex-col">
        <div className="mb-3 flex flex-wrap items-center gap-x-5 gap-y-1.5 text-[11px]">
            {for s in series {
                <span key={s.key} className="inline-flex items-center gap-2">
                    <Swatch series_key={s.key}/>
                    <span className="text-muted">{s.label}</span>
                    <span className={"num text-[12px] font-medium " + ("text-accent" if s.key == "team" else "text-text")}>{signed_pct(shown.get(s.key))}</span>
                </span>
            }}
        </div>
        <div ref={box} className="flex-1" style={{"minHeight": str(height) + "px"}}></div>
    </div>
}
