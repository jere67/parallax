"""Small pieces every page shares: panels, figures, pills, and the loading, empty, and error
states. Colors come from the theme tokens in dashboard/theme.css.

A pill is its hue three ways: the text at full strength, the fill at 15%, and the hairline at
35%, so a column of mixed pills reads at one weight."""
import from "lucide-react" { Inbox }

glob PILL_BASE: str = "inline-flex items-center gap-1 rounded-full border px-2 py-px text-[11px] font-medium leading-4 whitespace-nowrap";
glob TONE_UP: str = "border-up/35 bg-up/15 text-up";
glob TONE_DOWN: str = "border-down/35 bg-down/15 text-down";
glob TONE_WARN: str = "border-warn/35 bg-warn/15 text-warn";
glob TONE_ACCENT: str = "border-accent/40 bg-accent/15 text-accent";
glob TONE_QUIET: str = "border-line-strong bg-panel-2 text-muted";
glob ACTION_TONES: dict[str, str] = {
    "BUY": TONE_UP,
    "ADD": TONE_UP,
    "SELL": TONE_DOWN,
    "TRIM": TONE_DOWN,
    "HOLD": TONE_QUIET,
    "NO_ACTION": "border-dashed border-line-strong text-faint"
};
glob STATUS_TONES: dict[str, str] = {
    "normal": TONE_UP,
    "fallback": TONE_WARN,
    "failed": TONE_DOWN,
    "skipped": TONE_QUIET,
    "running": TONE_ACCENT,
    "approved": TONE_UP,
    "resized": TONE_WARN,
    "rejected": TONE_DOWN,
    "filled": TONE_UP,
    "partially_filled": TONE_ACCENT,
    "canceled": TONE_QUIET,
    "expired": TONE_QUIET,
    "replaced": TONE_QUIET,
    "auto": TONE_ACCENT,
    "insight": TONE_QUIET
};

"""A hairline card on the canvas, with a header row and an optional control on its right.
`fill` lets the body grow to the panel's height, for a chart beside a taller column; `anchor`
is an id to link to, which lands below the sticky top bar."""
def:pub Panel(
    title: str = "",
    aside: any = None,
    children: any = None,
    pad: bool = True,
    fill: bool = False,
    anchor: str = "",
    className: str = ""
) -> JsxElement {
    target: dict[str, str] = {"id": anchor} if anchor else {};
    <section
        {**target}
        className={"scroll-mt-16 overflow-hidden rounded-md border border-line bg-panel " + ("flex flex-col " if fill else "") + className}
    >
        {if title or aside {
            <header className="flex min-h-12 shrink-0 items-center justify-between gap-3 border-b border-line px-4 py-2">
                <h2 className="shrink-0 text-[15px] font-medium leading-5 text-text">{title}</h2>
                <div className="min-w-0 text-right text-[11px] leading-4 text-faint">{aside}</div>
            </header>
        }}
        <div className={("p-4" if pad else "") + (" flex flex-1 flex-col" if fill else "")}>{children}</div>
    </section>
}

"""A small uppercase label over a section of a panel."""
def:pub Overline(children: any = None, className: str = "") -> JsxElement {
    <div className={"text-[11px] font-medium uppercase tracking-[0.05em] text-faint " + className}>{children}</div>
}

"""One headline figure: a label, the value, and a smaller line under it."""
def:pub Stat(label: str, value: str, sub: any = None, tone: str = "text-text", hint: str = "") -> JsxElement {
    <div className="min-w-0" title={hint}>
        <Overline className="truncate">{label}</Overline>
        <div className={"num mt-1.5 truncate text-[22px] font-medium leading-7 tracking-[-0.01em] " + tone}>{value}</div>
        {if sub {
            <div className="num mt-0.5 truncate text-[12px] text-muted">{sub}</div>
        }}
    </div>
}

"""A change as a tinted pill with a small triangle: up in verdigris, down in cinnabar, and a
flat or missing value in a quiet neutral."""
def:pub Delta(text: str, value: float | None = None) -> JsxElement {
    up = value is not None and value > 0;
    down = value is not None and value < 0;
    tone = TONE_UP if up else (TONE_DOWN if down else TONE_QUIET);
    <span className={PILL_BASE + " num rounded-[4px] px-1.5 " + tone}>
        {if up or down {
            <svg viewBox="0 0 8 6" className={"size-[7px] shrink-0 " + ("rotate-180" if up else "")} aria-hidden="true">
                <path d="M4 6L0 0H8L4 6Z" fill="currentColor"/>
            </svg>
        }}
        {text}
    </span>
}

def:pub ActionBadge(action: str) -> JsxElement {
    tone = ACTION_TONES.get(action, TONE_QUIET);
    <span className={PILL_BASE + " tracking-[0.03em] " + tone}>{"No action" if action == "NO_ACTION" else action}</span>
}

"""Alpaca's names for an order still working at the broker."""
glob WORKING: list[str] = ["new", "accepted", "pending_new", "accepted_for_bidding", "held", "pending_replace", "pending_cancel"];

def:pub StatusBadge(status: str, label: str = "") -> JsxElement {
    working = status in WORKING;
    tone = STATUS_TONES.get(status, TONE_ACCENT);
    text = label or ("working" if working else status.replace("_", " "));
    <span className={PILL_BASE + " capitalize " + tone} title={status}>{text}</span>
}

"""A muted label and its value, on one line."""
def:pub Field(label: str, children: any = None) -> JsxElement {
    <div className="flex items-baseline justify-between gap-4 py-1.5 text-[13px]">
        <span className="shrink-0 text-muted">{label}</span>
        <span className="num min-w-0 text-right">{children}</span>
    </div>
}

def:pub Loading(label: str = "Loading") -> JsxElement {
    <div className="flex flex-col gap-4" aria-busy="true" aria-label={label}>
        <div className="h-24 animate-pulse rounded-md border border-line bg-panel-2"></div>
        <div className="h-72 animate-pulse rounded-md border border-line bg-panel-2"></div>
        <div className="h-48 animate-pulse rounded-md border border-line bg-panel-2"></div>
    </div>
}

def:pub Empty(title: str, children: any = None) -> JsxElement {
    <div className="flex flex-col items-center gap-2 rounded-md border border-dashed border-line-strong bg-panel px-6 py-12 text-center">
        <Inbox size={22} strokeWidth={1.5} className="text-faint" aria-hidden="true"/>
        <div className="display mt-1 text-[22px] leading-7">{title}</div>
        <div className="mx-auto max-w-md text-[13px] text-muted">{children}</div>
    </div>
}

def:pub ErrorBox(message: str) -> JsxElement {
    <div className="rounded-md border border-down/35 bg-down/10 px-4 py-3 text-[13px] text-down" role="alert">
        <span className="font-semibold">Could not load this page.</span>
        {" "}{message}
    </div>
}

"""Table cell classes, so every table lines up the same way. The header row sits on the inset
fill and sticks to the top of a scrolling table; body rows part on faint hairlines."""
glob TH: str = "sticky top-0 z-[1] bg-panel-2 whitespace-nowrap border-b border-line px-3 py-2 text-left text-[11px] font-medium uppercase tracking-[0.05em] text-muted first:pl-4 last:pr-4";
glob TH_NUM: str = "sticky top-0 z-[1] bg-panel-2 whitespace-nowrap border-b border-line px-3 py-2 text-right text-[11px] font-medium uppercase tracking-[0.05em] text-muted first:pl-4 last:pr-4";
glob TD: str = "whitespace-nowrap border-b border-line/60 px-3 py-2.5 text-[13px] first:pl-4 last:pr-4";
# A cell for prose, which wraps rather than widening the table.
glob TD_TEXT: str = "min-w-[180px] border-b border-line/60 px-3 py-2.5 text-[13px] first:pl-4 last:pr-4";
glob TD_NUM: str = "num whitespace-nowrap border-b border-line/60 px-3 py-2.5 text-right text-[13px] first:pl-4 last:pr-4";
glob ROW: str = "transition-colors duration-150 hover:bg-hover [&:last-child>td]:border-b-0";
