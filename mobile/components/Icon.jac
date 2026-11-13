"""Icons - WEB variant (Lucide via lucide-react). `Icon.native.jac` is the phone's; keep the
two maps' keys the same."""

import from "lucide-react" { ArrowLeft, Bell, ChartLine, Check, ChevronRight, CircleAlert, LogOut, RefreshCw, Server, Sunrise, X }

glob LUCIDE = {"back": ArrowLeft, "bell": Bell, "chart": ChartLine, "check": Check, "next": ChevronRight, "alert": CircleAlert, "out": LogOut, "refresh": RefreshCw, "server": Server, "sunrise": Sunrise, "x": X};

def:pub Icon(name: str, size: int = 20, color: str = "#ece6d8") -> JsxElement {
    Glyph = LUCIDE[name];
    <Glyph size={size} color={color} strokeWidth={1.75}/>
}
