"""Design tokens for Parallax on a phone: the web dashboard's dark palette (dashboard/theme.css),
so the two read as one product. Colors are `obj` fields, so `C.up` is a checked attribute read."""

import from "@jac/mobui" { StyleSheet }
import from .fonts { SERIF }

obj Palette {
    has bg: str = "#0c0b09",
        raised: str = "#13120f",
        hover: str = "#1a1814",
        line: str = "#2a2721",
        lineStrong: str = "#3a362e",
        text: str = "#ece6d8",
        muted: str = "#a39d8e",
        faint: str = "#857f70",
        accent: str = "#d4ad62",
        accentSoft: str = "rgba(212, 173, 98, 0.13)",
        up: str = "#4cb796",
        upSoft: str = "rgba(76, 183, 150, 0.12)",
        down: str = "#e5655c",
        downSoft: str = "rgba(229, 101, 92, 0.12)",
        warn: str = "#e8893a",
        warnSoft: str = "rgba(232, 137, 58, 0.12)",
        spy: str = "#7f9cc0",
        onAccent: str = "#0c0b09";
}

obj Spacing {
    has xs: int = 4,
        sm: int = 8,
        md: int = 12,
        lg: int = 16,
        xl: int = 24,
        xxl: int = 32;
}

obj Radius {
    has sm: int = 6,
        md: int = 10,
        lg: int = 14,
        pill: int = 999;
}

obj FontSize {
    has xs: int = 12,
        sm: int = 14,
        md: int = 16,
        lg: int = 20,
        xl: int = 28,
        hero: int = 48;
}

glob:pub C: Palette = Palette(),
     S: Spacing = Spacing(),
     R: Radius = Radius(),
     F: FontSize = FontSize();

glob:pub styles = StyleSheet.create(
         {
             "screen": {"flex": 1, "backgroundColor": C.bg},
             "scroll": {"flex": 1},
             "content": {
                 "width": "100%",
                 "maxWidth": 560,
                 "alignSelf": "center",
                 "paddingHorizontal": S.lg,
                 "paddingTop": S.lg,
                 "paddingBottom": S.xxl * 3,
                 "gap": S.xl
             },
             "eyebrow": {"color": C.muted, "fontSize": F.sm},
             "title": {"color": C.text, "fontFamily": SERIF, "fontSize": F.xl, "lineHeight": 34},
             "hero": {
                 "color": C.text,
                 "fontFamily": SERIF,
                 "fontSize": F.hero,
                 "lineHeight": 54,
                 "fontVariant": ["tabular-nums"]
             },
             "body": {"color": C.text, "fontSize": F.md, "lineHeight": 23},
             "note": {"color": C.muted, "fontSize": F.sm, "lineHeight": 20},
             "faint": {"color": C.faint, "fontSize": F.xs, "lineHeight": 17},
             "num": {"color": C.text, "fontSize": F.md, "fontVariant": ["tabular-nums"]},
             "section": {"gap": S.md},
             "sectionTitle": {"color": C.text, "fontFamily": SERIF, "fontSize": F.lg},
             "card": {
                 "backgroundColor": C.raised,
                 "borderWidth": 1,
                 "borderColor": C.line,
                 "borderRadius": R.lg,
                 "padding": S.lg,
                 "gap": S.sm
             },
             "rule": {"height": 1, "backgroundColor": C.line},
             "row": {"flexDirection": "row", "alignItems": "center", "gap": S.sm},
             "between": {"flexDirection": "row", "alignItems": "center", "justifyContent": "space-between", "gap": S.md}
         }
     );
