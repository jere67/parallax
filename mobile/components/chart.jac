"""The equity chart's geometry: each series indexed to its first close and scaled into one box,
so the team and SPY share an axis, then cut into straight segments for drawing."""

import from ..views { Series }

glob:pub HEIGHT: int = 132;
glob:pub PAD: int = 6;

obj Segment {
    has left: float,
        top: float,
        length: float,
        angle: float;
}

obj Line {
    has key: str,
        label: str,
        total_return: float | None,
        segments: list[Segment] = [];
}

obj Chart {
    has lines: list[Line] = [],
        base_y: float = 0.0;
}

"""Each point's growth since the first: 1.054 for +5.4%."""
def growth(s: Series) -> list[float] {
    if len(s.points) == 0 or s.points[0].equity == 0 {
        return [];
    }
    first = s.points[0].equity;
    return [p.equity / first for p in s.points];
}

"""The smallest and largest of `values`. Written out because Jac 0.37.12 compiles `min(xs)` on a
list to `Math.min(xs)` in client code, which is NaN."""
def bounds(values: list[float]) -> tuple[float, float] {
    low = values[0];
    high = values[0];
    for v in values {
        low = v if v < low else low;
        high = v if v > high else high;
    }
    return (low, high);
}

def y_of(v: float, low: float, span: float) -> float {
    return PAD + (HEIGHT - 2 * PAD) * (1 - (v - low) / span);
}

"""The segment from (x1, y1) to (x2, y2), placed by its center so a rotation about the center
lands it on both points."""
def segment(x1: float, y1: float, x2: float, y2: float) -> Segment {
    length = ((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1)) ** 0.5;
    turn: float = Math.atan2(y2 - y1, x2 - x1);  # jac:ignore[W2001,W1051,E1001,E1032,W6001]
    return Segment(left=(x1 + x2) / 2 - length / 2, top=(y1 + y2) / 2, length=length, angle=turn * 57.29578);
}

"""The team's and SPY's lines, `width` points wide, and where the starting level sits."""
def:pub chart_of(series: list[Series], width: float) -> Chart {
    shown = [s for s in series if s.key == "team"] + [s for s in series if s.key == "spy"];
    grown = [(s, growth(s)) for s in shown];
    grown = [(s, v) for (s, v) in grown if len(v) > 1];
    if len(grown) == 0 or width <= 2 * PAD {
        return Chart();
    }
    every = [x for (_s, v) in grown for x in v] + [1.0];
    (low, high) = bounds(every);
    span = high - low;
    span = span if span > 0 else 1.0;
    count = int(bounds([float(len(v)) for (_s, v) in grown])[1]);
    step = (width - 2 * PAD) / (count - 1);
    lines: list[Line] = [];
    for (s, v) in grown {
        points = [(PAD + i * step, y_of(x, low, span)) for (i, x) in enumerate(v)];
        segments = [segment(points[i][0], points[i][1], points[i + 1][0], points[i + 1][1]) for i in range(len(points) - 1)];
        lines.append(Line(key=s.key, label=s.label, total_return=s.total_return, segments=segments));
    }
    return Chart(lines=lines, base_y=y_of(1.0, low, span));
}
