"""Small pieces every page shares: panels, figures, badges, and the loading, empty, and error
states. Colors come from the theme tokens in dashboard/theme.css."""

glob BADGE_BASE: str = "inline-flex items-center rounded px-1.5 py-px text-[11px] font-semibold leading-4 tracking-wide whitespace-nowrap";
glob ACTION_TONES: dict[str, str] = {
    "BUY": "bg-up-soft text-up",
    "ADD": "bg-up-soft text-up",
    "SELL": "bg-down-soft text-down",
    "TRIM": "bg-down-soft text-down",
    "HOLD": "bg-panel-2 text-muted",
    "NO_ACTION": "text-faint ring-1 ring-inset ring-line"
};
glob STATUS_TONES: dict[str, str] = {
    "normal": "bg-up-soft text-up",
    "fallback": "bg-warn-soft text-warn",
    "failed": "bg-down-soft text-down",
    "skipped": "bg-panel-2 text-muted",
    "running": "bg-accent-soft text-accent",
    "approved": "bg-up-soft text-up",
    "resized": "bg-warn-soft text-warn",
    "rejected": "bg-down-soft text-down",
    "filled": "bg-up-soft text-up",
    "partially_filled": "bg-accent-soft text-accent",
    "canceled": "bg-panel-2 text-muted",
    "expired": "bg-panel-2 text-muted",
    "replaced": "bg-panel-2 text-muted",
    "auto": "bg-accent-soft text-accent",
    "insight": "bg-panel-2 text-muted"
};

"""A bordered section with a small header and an optional control on its right. `fill` lets
the body grow to the panel's height, for a chart beside a taller column; `anchor` is an id to
link to, which lands below the sticky top bar."""
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
        className={"scroll-mt-16 rounded-lg border border-line bg-panel " + ("flex flex-col " if fill else "") + className}
    >
        {if title or aside {
            <header className="flex min-h-10 shrink-0 items-center justify-between gap-3 border-b border-line px-4 py-2">
                <h2 className="text-[12px] font-semibold uppercase tracking-[0.06em] text-muted">{title}</h2>
                {aside}
            </header>
        }}
        <div className={("p-4" if pad else "") + (" flex flex-1 flex-col" if fill else "")}>{children}</div>
    </section>
}

"""One headline figure: a label, the value, and a smaller line under it."""
def:pub Stat(label: str, value: str, sub: any = None, tone: str = "text-text", hint: str = "") -> JsxElement {
    <div className="min-w-0" title={hint}>
        <div className="truncate text-[11px] font-medium uppercase tracking-[0.06em] text-faint">{label}</div>
        <div className={"num mt-1 truncate text-[20px] font-semibold leading-6 tracking-tight " + tone}>{value}</div>
        {if sub {
            <div className="num mt-0.5 truncate text-[12px] text-muted">{sub}</div>
        }}
    </div>
}

def:pub ActionBadge(action: str) -> JsxElement {
    tone = ACTION_TONES.get(action, "bg-panel-2 text-muted");
    <span className={BADGE_BASE + " " + tone}>{"No action" if action == "NO_ACTION" else action}</span>
}

"""Alpaca's names for an order still working at the broker."""
glob WORKING: list[str] = ["new", "accepted", "pending_new", "accepted_for_bidding", "held", "pending_replace", "pending_cancel"];

def:pub StatusBadge(status: str, label: str = "") -> JsxElement {
    working = status in WORKING;
    tone = STATUS_TONES.get(status, "bg-accent-soft text-accent");
    text = label or ("working" if working else status.replace("_", " "));
    <span className={BADGE_BASE + " capitalize " + tone} title={status}>{text}</span>
}

"""A muted label and its value, on one line."""
def:pub Field(label: str, children: any = None) -> JsxElement {
    <div className="flex items-baseline justify-between gap-4 py-1.5 text-[13px]">
        <span className="shrink-0 text-muted">{label}</span>
        <span className="num min-w-0 text-right">{children}</span>
    </div>
}

def:pub Loading(label: str = "Loading") -> JsxElement {
    <div className="flex flex-col gap-3" aria-busy="true" aria-label={label}>
        <div className="h-24 animate-pulse rounded-lg border border-line bg-panel"></div>
        <div className="h-72 animate-pulse rounded-lg border border-line bg-panel"></div>
        <div className="h-48 animate-pulse rounded-lg border border-line bg-panel"></div>
    </div>
}

def:pub Empty(title: str, children: any = None) -> JsxElement {
    <div className="rounded-lg border border-dashed border-line-strong bg-panel px-6 py-12 text-center">
        <div className="text-[15px] font-semibold">{title}</div>
        <div className="mx-auto mt-2 max-w-md text-[13px] text-muted">{children}</div>
    </div>
}

def:pub ErrorBox(message: str) -> JsxElement {
    <div className="rounded-lg border border-down/40 bg-down-soft px-4 py-3 text-[13px] text-down" role="alert">
        <span className="font-semibold">Could not load this page.</span>
        {" "}{message}
    </div>
}

"""Table cell classes, so every table lines up the same way. Header cells stick to the top of a
scrolling table."""
glob TH: str = "sticky top-0 z-[1] bg-panel whitespace-nowrap border-b border-line px-3 py-2 text-left text-[11px] font-medium uppercase tracking-[0.06em] text-faint first:pl-4 last:pr-4";
glob TH_NUM: str = "sticky top-0 z-[1] bg-panel whitespace-nowrap border-b border-line px-3 py-2 text-right text-[11px] font-medium uppercase tracking-[0.06em] text-faint first:pl-4 last:pr-4";
glob TD: str = "whitespace-nowrap border-b border-line px-3 py-2 text-[13px] first:pl-4 last:pr-4";
# A cell for prose, which wraps rather than widening the table.
glob TD_TEXT: str = "min-w-[180px] border-b border-line px-3 py-2 text-[13px] first:pl-4 last:pr-4";
glob TD_NUM: str = "num whitespace-nowrap border-b border-line px-3 py-2 text-right text-[13px] first:pl-4 last:pr-4";
glob ROW: str = "transition-colors hover:bg-hover [&:last-child>td]:border-b-0";
