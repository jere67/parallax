"""Plots on the -1 to +1 signed scale (TDD §10: disagreement is visible). Green leans buy and
red leans sell. Marks are positioned in percent, so a plot fills whatever width its column has."""

glob TICKS: list[float] = [-1.0, -0.5, 0.0, 0.5, 1.0];

def tone_of(x: float) -> str {
    return "bg-up" if x > 0.0001 else ("bg-down" if x < -0.0001 else "bg-muted");
}

def at_percent(v: float) -> str {
    return str((max(-1.0, min(1.0, v)) + 1.0) / 2.0 * 100.0) + "%";
}

"""One specialist's samples: each sample is a dot, the specialist's mean a short bar."""
def:pub DotPlot(values: list[float], mean: float | None = None) -> JsxElement {
    <div
        className="relative mx-1.5 h-[22px]"
        role="img"
        aria-label={"Samples " + ", ".join([str(round(v, 2)) for v in values]) + ("; mean " + str(round(mean, 2)) if mean is not None else "")}
    >
        <div className="absolute inset-x-0 top-1/2 h-px bg-line-strong"></div>
        {for t in TICKS {
            <div
                key={str(t)}
                className={"absolute top-1/2 w-px -translate-y-1/2 bg-line-strong " + ("h-2.5" if t == 0.0 else "h-1")}
                style={{"left": at_percent(t)}}
            ></div>
        }}
        {if mean is not None {
            <div
                className={"absolute top-1/2 h-4 w-0.5 -translate-x-1/2 -translate-y-1/2 rounded-full opacity-50 " + tone_of(mean)}
                style={{"left": at_percent(mean)}}
            ></div>
        }}
        {for (i, v) in enumerate(values) {
            <div
                key={str(i)}
                className={"absolute top-1/2 size-2 -translate-x-1/2 -translate-y-1/2 rounded-full opacity-85 ring-[1.5px] ring-panel " + tone_of(v)}
                style={{"left": at_percent(v)}}
            ></div>
        }}
    </div>
}

"""The consensus score as a dot inside its confidence interval, over a labelled axis."""
def:pub ScoreScale(score: float, low: float, high: float) -> JsxElement {
    soft = "bg-up-soft border-up/40" if score > 0.0001 else ("bg-down-soft border-down/40" if score < -0.0001 else "bg-panel-2 border-line-strong");
    <div role="img" aria-label={"Score " + str(round(score, 2)) + ", interval " + str(round(low, 2)) + " to " + str(round(high, 2))}>
        <div className="relative mx-1.5 h-[22px]">
            <div className="absolute inset-x-0 top-1/2 h-px bg-line-strong"></div>
            {for t in TICKS {
                <div
                    key={str(t)}
                    className={"absolute top-1/2 w-px -translate-y-1/2 bg-line-strong " + ("h-3" if t == 0.0 else "h-1.5")}
                    style={{"left": at_percent(t)}}
                ></div>
            }}
            <div
                className={"absolute top-1/2 h-2.5 min-w-1 -translate-y-1/2 rounded-full border " + soft}
                style={{"left": at_percent(low), "width": str((max(-1.0, min(1.0, high)) - max(-1.0, min(1.0, low))) / 2.0 * 100.0) + "%"}}
            ></div>
            <div
                className={"absolute top-1/2 size-2.5 -translate-x-1/2 -translate-y-1/2 rounded-full ring-2 ring-panel " + tone_of(score)}
                style={{"left": at_percent(score)}}
            ></div>
        </div>
        <div className="num mt-1 flex justify-between text-[11px] text-faint">
            <span>-1 sell</span><span>0</span><span>+1 buy</span>
        </div>
    </div>
}
