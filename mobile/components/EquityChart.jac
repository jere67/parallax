"""The portfolio's equity beside SPY's, both indexed to the start, as two thin lines on one
scale. Drawn from plain Views (one rotated hairline per segment), so the same code runs on a
phone and in a browser."""

import from "@jac/mobui" { View, Text }
import from ..theme { C, S, F, styles }
import from ..views { Series }
import from ..format { signed_percent }
import from .chart { HEIGHT, PAD, chart_of }

def Legend(color: str, label: str, value: str) -> JsxElement {
    <View style={{"flexDirection": "row", "alignItems": "center", "gap": 6}}>
        <View style={{"width": 14, "height": 2, "borderRadius": 1, "backgroundColor": color}}/>
        <Text style={styles.note}>{label}</Text>
        <Text style={[styles.num, {"fontSize": F.sm}]}>{value}</Text>
    </View>
}

def:pub EquityChart(series: list[Series]) -> JsxElement {
    has width: float = 0.0;

    chart = chart_of(series, width);
    <View style={{"gap": S.sm}}>
        <View style={{"height": HEIGHT}} onLayout={lambda (e: any) { width = e.nativeEvent.layout.width; }}>
            {(<View style={{"position": "absolute", "left": PAD, "right": PAD, "top": chart.base_y, "height": 0, "borderTopWidth": 1, "borderColor": C.lineStrong, "borderStyle": "dashed"}}/>) if len(chart.lines) > 0 else None}
            {[
                <View key={line.key} style={{"position": "absolute", "left": 0, "top": 0, "right": 0, "bottom": 0}}>
                    {[
                        <View key={str(i)} style={{"position": "absolute", "left": seg.left, "top": seg.top - 1, "width": seg.length + 0.6, "height": 2, "borderRadius": 1, "backgroundColor": C.accent if line.key == "team" else C.spy, "transform": [{"rotate": f"{seg.angle}deg"}]}}/> for (i, seg) in enumerate(line.segments)
                    ]}
                </View> for line in chart.lines
            ]}
        </View>
        <View style={{"flexDirection": "row", "gap": S.lg, "flexWrap": "wrap"}}>
            {[<Legend key={line.key} color={C.accent if line.key == "team" else C.spy} label={line.label} value={signed_percent(line.total_return)}/> for line in chart.lines]}
        </View>
    </View>
}
