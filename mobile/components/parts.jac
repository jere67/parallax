"""Small pieces the screens share: an action pill, a figure with its label, a notice, a
section heading, and a tappable row."""

import from "@jac/mobui" { View, Text, Pressable }
import from ..theme { C, S, R, F, styles }
import from ..format { action_lean, action_word }
import from .Icon { Icon }

"""A trading action as a pill: green for buys and adds, red for sells and trims, outlined for no action."""
def:pub ActionPill(action: str) -> JsxElement {
    lean = action_lean(action);
    tone = C.up if lean == "up" else (C.down if lean == "down" else C.faint);
    fill = C.upSoft if lean == "up" else (C.downSoft if lean == "down" else "transparent");
    <View style={{"paddingHorizontal": S.sm, "paddingVertical": 3, "borderRadius": R.pill, "backgroundColor": fill, "borderWidth": 1, "borderColor": fill if lean != "flat" else C.lineStrong, "borderStyle": "solid" if lean != "flat" else "dashed"}}>
        <Text style={{"color": tone, "fontSize": F.xs, "fontWeight": "600", "letterSpacing": 0.3}}>{action_word(action)}</Text>
    </View>
}

"""A status pill: up, warn, or down."""
def:pub StatusPill(label: str, tone: str) -> JsxElement {
    color = C.up if tone == "up" else (C.warn if tone == "warn" else C.down);
    fill = C.upSoft if tone == "up" else (C.warnSoft if tone == "warn" else C.downSoft);
    <View style={{"flexDirection": "row", "alignItems": "center", "gap": 6, "paddingHorizontal": S.sm, "paddingVertical": 3, "borderRadius": R.pill, "backgroundColor": fill}}>
        <View style={{"width": 6, "height": 6, "borderRadius": 3, "backgroundColor": color}}/>
        <Text style={{"color": color, "fontSize": F.xs, "fontWeight": "600"}}>{label}</Text>
    </View>
}

"""A figure with its label beneath, colored by sign when `lean` is up or down."""
def:pub Figure(label: str, value: str, lean: str = "") -> JsxElement {
    color = C.up if lean == "up" else (C.down if lean == "down" else C.text);
    <View style={{"width": "47%", "gap": 2}}>
        <Text style={[styles.num, {"color": color, "fontSize": F.lg}]}>{value}</Text>
        <Text style={styles.faint}>{label}</Text>
    </View>
}

"""A notice across the top of a screen: demo data, a failed call, or a new run."""
def:pub Notice(text: str, tone: str = "warn", onPress: Callable[[], None] | None = None) -> JsxElement {
    color = C.warn if tone == "warn" else (C.down if tone == "down" else C.accent);
    fill = C.warnSoft if tone == "warn" else (C.downSoft if tone == "down" else C.accentSoft);
    <Pressable onPress={onPress} disabled={onPress is None} style={{"flexDirection": "row", "alignItems": "flex-start", "gap": S.sm, "padding": S.md, "borderRadius": R.md, "backgroundColor": fill}}>
        <Icon name={"bell" if tone == "accent" else "alert"} size={18} color={color}/>
        <Text style={{"flex": 1, "color": color, "fontSize": F.sm, "lineHeight": 20}}>{text}</Text>
    </Pressable>
}

"""A section's heading with an optional note on its right."""
def:pub SectionHead(title: str, note: str = "") -> JsxElement {
    <View style={styles.between}>
        <Text style={styles.sectionTitle}>{title}</Text>
        {(<Text style={styles.faint}>{note}</Text>) if note else None}
    </View>
}

"""A row that opens something: content on the left, a chevron on the right."""
def:pub Tappable(onPress: Callable[[], None], children: any = None) -> JsxElement {
    <Pressable onPress={onPress} style={lambda (state: any) { return [{"flexDirection": "row", "alignItems": "center", "gap": S.md, "paddingVertical": S.md}, {"opacity": 0.6 if state.pressed else 1.0}]; }}>
        <View style={{"flex": 1, "gap": 4}}>{children}</View>
        <Icon name="next" size={18} color={C.faint}/>
    </Pressable>
}
