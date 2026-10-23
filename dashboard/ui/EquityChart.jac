"""The equity curves: the team portfolio and its baselines as cumulative return since the
start, drawn with TradingView's Lightweight Charts. Colors are the theme's series tokens, so
the chart repaints when the reader switches theme or the system does."""
import from react { useEffect }
import from "lightweight-charts" { createChart, ColorType, CrosshairMode, LineSeries, LineType }
import from models.views { Series }
import from dashboard.ui.format { signed_pct }
import from dashboard.ui.theme { THEME_EVENT, css_var }

glob SERIES_COLORS: dict[str, str] = {
    "team": "--series-team",
    "equal_weight": "--series-ew",
    "spy": "--series-spy"
};

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

def:pub EquityChart(series: list[Series], starting_cash: float, height: int = 300) -> JsxElement {
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
                        "fontSize": 11,
                        "attributionLogo": False
                    },
                    "grid": {
                        "vertLines": {"visible": False},
                        "horzLines": {"color": css_var("--line")}
                    },
                    "rightPriceScale": {
                        "borderVisible": False,
                        "scaleMargins": {"top": 0.12, "bottom": 0.08}
                    },
                    "timeScale": {
                        "borderVisible": False,
                        "fixLeftEdge": True,
                        "fixRightEdge": True,
                        "lockVisibleTimeRangeOnResize": True
                    },
                    "crosshair": {
                        "mode": CrosshairMode.Normal,
                        "vertLine": {"color": css_var("--line-strong"), "labelBackgroundColor": css_var("--muted")},
                        "horzLine": {"color": css_var("--line-strong"), "labelBackgroundColor": css_var("--muted")}
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
            for s in series {
                line = chart.addSeries(
                    LineSeries,
                    {
                        "color": css_var(SERIES_COLORS.get(s.key, "--series-spy")),
                        "lineWidth": 2 if s.key == "team" else 1,
                        "lineType": LineType.Simple,
                        "priceLineVisible": False,
                        "lastValueVisible": True,
                        "crosshairMarkerRadius": 3
                    }
                );
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

    <div>
        <div className="mb-3 flex flex-wrap items-center gap-x-5 gap-y-1 text-[12px]">
            {for s in series {
                <span key={s.key} className="inline-flex items-center gap-2">
                    <span
                        className="inline-block h-0.5 w-3 rounded-full"
                        style={{"background": "var(" + SERIES_COLORS.get(s.key, "--series-spy") + ")"}}
                    ></span>
                    <span className="text-muted">{s.label}</span>
                    <span className="num font-medium">{signed_pct(shown.get(s.key))}</span>
                </span>
            }}
        </div>
        <div ref={box} style={{"height": str(height) + "px"}}></div>
    </div>
}
