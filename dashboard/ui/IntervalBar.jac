"""The consensus score on its -1 to +1 scale: the confidence interval as a band, the score as a
dot, and a tick at zero. Green leans buy and red leans sell."""

def:pub IntervalBar(score: float | None, low: float | None, high: float | None, width: int = 112) -> JsxElement {
    if score is None {
        return <span className="text-faint">-</span>;
    }
    h = 14;
    mid = h / 2;
    pad = 4;
    span = width - 2 * pad;
    lo = low if low is not None else score;
    hi = high if high is not None else score;
    color = "var(--up)" if score > 0 else ("var(--down)" if score < 0 else "var(--muted)");
    soft = "var(--up-soft)" if score > 0 else ("var(--down-soft)" if score < 0 else "var(--panel-2)");
    <svg
        width={width}
        height={h}
        viewBox={"0 0 " + str(width) + " " + str(h)}
        className="block shrink-0"
        role="img"
        aria-label={"Score " + str(round(score, 2)) + ", interval " + str(round(lo, 2)) + " to " + str(round(hi, 2))}
    >
        <line x1={pad} x2={width - pad} y1={mid} y2={mid} stroke="var(--line-strong)" strokeWidth="1"/>
        <line x1={pad + span / 2} x2={pad + span / 2} y1={2} y2={h - 2} stroke="var(--line-strong)" strokeWidth="1"/>
        <rect
            x={pad + (lo + 1) / 2 * span}
            y={mid - 3}
            width={max((hi - lo) / 2 * span, 2)}
            height={6}
            rx={3}
            fill={soft}
            stroke={color}
            strokeOpacity="0.35"
        />
        <circle cx={pad + (score + 1) / 2 * span} cy={mid} r={3.25} fill={color}/>
    </svg>
}
