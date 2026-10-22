"""Formatting and chart-coordinate helpers shared by dashboard pages."""

def:pub money(value: float | None) -> str {
    return f"${value:,.2f}" if value is not None else "—";
}

def:pub percent(value: float | None) -> str {
    return f"{value:+.2%}" if value is not None else "—";
}

def:pub ratio(value: float | None) -> str {
    return f"{value:.2f}" if value is not None else "—";
}

"""Map sorted metric values to an SVG polyline inside a width × height view box."""
def:pub chart_points(values: list[float], width: float, height: float) -> str {
    if not values {
        return "";
    }
    low = min(values);
    high = max(values);
    span = high - low if high > low else 1.0;
    last = len(values) - 1;
    points: list[str] = [];
    for (i, value) in enumerate(values) {
        x = width * float(i) / float(last) if last > 0 else width / 2.0;
        y = height * (1.0 - (value - low) / span);
        points.append(f"{x:.1f},{y:.1f}");
    }
    return " ".join(points);
}
