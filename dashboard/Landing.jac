"""The public front page. It shows how the product works with one worked example, never a user's
data: nothing here calls the server. The example's company and votes are made up, and the page
says so where they appear.

The memorable part is the vote in the hero: five specialists' votes settle on a scale, and the
reader can drag the buy bar across the result, which is what a policy does."""
import from "@jac/runtime" { Link, jacIsLoggedIn }
import from "react" { useEffect }
import from dashboard.ui.format { signed }
import from dashboard.ui.brand { DISCLAIMER, DOCS_URL, PRODUCT, REPO_URL, ThemeSwitch, Wordmark }

glob SECTION: str = "mx-auto w-full max-w-[1200px] px-4 sm:px-6 lg:px-8";
glob LINK: str = "transition-colors duration-150 hover:text-text";
glob PRIMARY: str = "press inline-flex min-h-11 items-center justify-center rounded-md bg-accent px-5 text-[14px] font-medium text-bg hover:opacity-90";
glob SECONDARY: str = "press inline-flex min-h-11 items-center justify-center rounded-md border border-line-strong px-5 text-[14px] font-medium text-text hover:bg-hover";
glob HEADING: str = "display text-[34px] leading-[1.1] text-text sm:text-[44px]";
glob BODY: str = "mt-4 max-w-[52ch] text-[16px] leading-[1.6] text-muted";

# The worked example: made up, and labeled so on the page. Each specialist votes three times, so
# a view it is unsure of shows as spread. The score is their average, and the agreement is the
# share of specialists on its side of zero (TDD §7).
glob PANEL: list[tuple[str, list[float]]] = [
    ("Fundamentals", [0.55, 0.40, 0.62]),
    ("Technical", [0.25, 0.38, 0.12]),
    ("News", [0.48, 0.70, 0.35]),
    ("Macro", [-0.10, 0.05, -0.22]),
    ("Flow", [0.30, 0.18, 0.42])
];
glob SCORE: float = 0.30;
glob AGREEMENT: float = 0.80;
glob BAR_LOW: float = 0.0;
glob BAR_HIGH: float = 0.6;

"""Where a value from -1 to +1 sits across the scale, as a percentage."""
def spot(value: float) -> str {
    return str((value + 1.0) / 2.0 * 100.0) + "%";
}

"""The hero's example vote. The bar is the one control: moving it changes the decision, as moving
a policy's bar does."""
def VotePanel -> JsxElement {
    has bar: float = 0.2;

    buys: bool = SCORE >= bar;

    <figure className="overflow-hidden rounded-lg border border-line-strong bg-panel">
        <div className="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1 border-b border-line px-4 py-3 sm:px-6">
            <figcaption className="text-[14px] font-medium text-text">The panel votes on one stock</figcaption>
            <p className="text-[12px] text-faint">An example with made-up votes, not a live result</p>
        </div>
        <div className="grid lg:grid-cols-[minmax(0,1fr)_300px]">
            <div className="px-4 pb-5 pt-4 sm:px-6">
                <div className="grid grid-cols-[92px_minmax(0,1fr)] gap-x-3 sm:grid-cols-[110px_minmax(0,1fr)]">
                    <div></div>
                    <div className="flex justify-between pb-1.5 text-[12px] text-faint"><span>Sell</span><span>Buy</span></div>
                    {for (row, (name, votes)) in enumerate(PANEL) {
                        <div key={name} className="contents">
                            <div className="flex h-10 items-center text-[13px] text-muted">{name}</div>
                            <div className="relative h-10 border-t border-line">
                                <span className="absolute inset-y-0 left-1/2 w-px bg-line-strong" aria-hidden="true"></span>
                                {for (i, v) in enumerate(votes) {
                                    <span
                                        key={i}
                                        className="vote-dot absolute top-1/2 size-2.5 -translate-x-1/2 -translate-y-1/2 rounded-full bg-text/70"
                                        style={{"left": spot(v), "animationDelay": str(120 + row * 130 + i * 60) + "ms"}}
                                        aria-hidden="true"
                                    ></span>
                                }}
                            </div>
                        </div>
                    }}
                    <div className="flex h-12 items-center text-[13px] font-medium text-text">Score</div>
                    <div className="relative h-12 border-t border-line-strong">
                        <span className="vote-bar absolute inset-y-0 w-px border-l border-dashed border-text/60" style={{"left": spot(bar)}} aria-hidden="true"></span>
                        <span className="vote-needle absolute top-1/2 size-4 -translate-x-1/2 -translate-y-1/2 rounded-full bg-accent" style={{"left": spot(SCORE)}} aria-hidden="true"></span>
                    </div>
                </div>
            </div>
            <div className="flex flex-col justify-between gap-5 border-t border-line bg-panel-2 px-4 py-5 sm:px-6 lg:border-l lg:border-t-0">
                <div>
                    <p className="text-[13px] text-muted">The decision</p>
                    <p className={"display mt-1 text-[52px] leading-none " + ("text-up" if buys else "text-muted")} aria-live="polite">{"Buy" if buys else "No action"}</p>
                    <p className="num mt-3 text-[13px] leading-5 text-muted">{"Score " + signed(SCORE, 2) + ", with " + str(round(AGREEMENT * 100.0)) + "% agreement."}</p>
                </div>
                <label className="flex flex-col gap-1 text-[13px] text-text">
                    <span className="flex items-baseline justify-between gap-2">
                        <span className="font-medium">Your buy bar</span>
                        <span className="num text-muted">{signed(bar, 2)}</span>
                    </span>
                    <input
                        type="range"
                        min={str(BAR_LOW)}
                        max={str(BAR_HIGH)}
                        step="0.05"
                        value={bar}
                        onChange={lambda (e: ChangeEvent) { bar = float(e.target.value); }}
                        className="policy-slider w-full"
                        aria-label="Your buy bar"
                    />
                    <span className="text-[12px] leading-[18px] text-faint">Drag it past the score. Your policy sets this bar, and many more.</span>
                </label>
            </div>
        </div>
    </figure>
}

def Header(signed_in: bool) -> JsxElement {
    has scrolled: bool = False;

    useEffect(lambda {
        def seen { scrolled = window.scrollY > 8; }
        seen();
        window.addEventListener("scroll", seen, {"passive": True});
        return lambda { window.removeEventListener("scroll", seen); };
    }, []);

    surface: str = "border-line bg-bg/85 backdrop-blur-md" if scrolled else "border-transparent";

    <header className={"sticky top-0 z-20 border-b pt-[env(safe-area-inset-top)] transition-colors duration-150 " + surface}>
        <div className="mx-auto flex h-16 max-w-[1200px] items-center gap-6 px-4 sm:px-6 lg:px-8">
            <Wordmark/>
            <nav aria-label="On this page" className="hidden items-center gap-6 text-[14px] text-muted lg:flex">
                <a href="#morning" className={LINK}>How it works</a>
                <a href="#rules" className={LINK}>Your rules</a>
                <a href="#decisions" className={LINK}>Decisions</a>
                <a href="#keys" className={LINK}>Your keys</a>
                <a href={DOCS_URL} className={LINK}>Docs</a>
            </nav>
            <div className="ml-auto flex items-center gap-1.5 sm:gap-2.5">
                <span className="hidden sm:block"><ThemeSwitch/></span>
                {if signed_in {
                    <Link to="/app" className="press inline-flex min-h-11 items-center rounded-md bg-accent px-4 text-[13px] font-medium text-bg hover:opacity-90 md:min-h-9">Open your agent</Link>
                } else {
                    <>
                        <Link to="/login" className="press inline-flex min-h-11 items-center rounded-md px-3 text-[13px] font-medium text-text hover:bg-hover md:min-h-9">Log in</Link>
                        <Link to="/signup" className="press inline-flex min-h-11 items-center rounded-md bg-accent px-4 text-[13px] font-medium text-bg hover:opacity-90 md:min-h-9">Create account</Link>
                    </>
                }}
            </div>
        </div>
    </header>
}

"""One step of the morning. They run in this order, so the times and the line mean something."""
def Step(when: str, title: str, children: any = None) -> JsxElement {
    <li className="relative border-l border-line-strong pb-8 pl-5 last:pb-0 lg:border-l-0 lg:border-t lg:pb-0 lg:pl-0 lg:pr-6 lg:pt-5">
        <span className="absolute -left-[5px] top-1 size-[9px] rounded-full bg-accent lg:-top-[5px] lg:left-0" aria-hidden="true"></span>
        <p className="num text-[13px] text-accent">{when}</p>
        <h3 className="mt-1 text-[16px] font-medium leading-6 text-text">{title}</h3>
        <p className="mt-1 text-[14px] leading-[1.55] text-muted">{children}</p>
    </li>
}

def Morning -> JsxElement {
    <section id="morning" className={SECTION + " scroll-mt-20 py-16 sm:py-24"}>
        <h2 className={HEADING}>What your agent does each morning</h2>
        <ol className="mt-10 grid lg:grid-cols-5">
            <Step when="7:30 a.m." title="Research">It narrows the S&P 500 to a shortlist, then gathers prices, filings, and news, each with its source.</Step>
            <Step when="Next" title="The panel votes">Five specialists read that research and vote three times each, so an unsure view shows as spread.</Step>
            <Step when="Then" title="The Arbiter checks">It tests each proposed buy against the evidence, and can overrule the panel, but never argue it higher.</Step>
            <Step when="9:45 a.m." title="Orders go out">A risk gate sizes each order within your limits and sends it to your paper account, if you turned trading on.</Step>
            <Step when="4:30 p.m." title="The score is kept">Your account is marked against SPY and an equal-weight basket of the same shortlist.</Step>
        </ol>
    </section>
}

def Bubble(mine: bool, children: any = None) -> JsxElement {
    <div className={"max-w-[88%] rounded-lg px-3.5 py-2.5 text-[14px] leading-[1.5] " + ("self-end bg-accent/15 text-text" if mine else "self-start border border-line bg-panel text-text")}>{children}</div>
}

def Rules -> JsxElement {
    <section id="rules" className="scroll-mt-20 border-y border-line bg-panel-2">
        <div className={SECTION + " grid items-center gap-10 py-16 sm:py-24 lg:grid-cols-2 lg:gap-16"}>
            <div>
                <h2 className={HEADING}>Tell it your rules in plain English</h2>
                <p className={BODY}>Set when to buy, sell, trim, and hold, in a form or by asking the assistant. It drafts the change, you see what that change would have done to your latest run, and nothing is saved until you apply it.</p>
                <p className={BODY}>Code checks every proposal against fixed limits, so no message can take on more risk than the form allows.</p>
            </div>
            <figure className="flex flex-col gap-2.5">
                <Bubble mine={True}>Don't buy anything that's already run hot.</Bubble>
                <Bubble mine={False}>
                    <p>This rule blocks a buy while a stock's 14-day RSI is above 70.</p>
                    <p className="mt-2.5 rounded-md border border-line-strong bg-panel-2 px-3 py-2 text-[13px] text-muted">Would have changed 1 decision in your latest run.</p>
                    <div className="mt-2.5 flex gap-2" aria-hidden="true">
                        <span className="rounded-md bg-accent px-3 py-1.5 text-[13px] font-medium text-bg">Apply</span>
                        <span className="rounded-md border border-line-strong px-3 py-1.5 text-[13px] text-text">Discard</span>
                    </div>
                </Bubble>
                <figcaption className="mt-1 text-[12px] text-faint">An example conversation</figcaption>
            </figure>
        </div>
    </section>
}

def TrailRow(label: str, detail: str, tone: str = "text-text") -> JsxElement {
    <div className="grid grid-cols-[104px_minmax(0,1fr)] gap-3 border-t border-line px-4 py-3 first:border-t-0 sm:grid-cols-[130px_minmax(0,1fr)] sm:px-5">
        <dt className="text-[13px] text-muted">{label}</dt>
        <dd className={"text-[14px] leading-[1.5] " + tone}>{detail}</dd>
    </div>
}

def Decisions -> JsxElement {
    <section id="decisions" className={SECTION + " grid scroll-mt-20 items-center gap-10 py-16 sm:py-24 lg:grid-cols-2 lg:gap-16"}>
        <figure className="order-2 lg:order-1">
            <dl className="rounded-lg border border-line-strong bg-panel">
                <TrailRow label="Research" detail="12 cited claims from filings, price history, and news"/>
                <TrailRow label="Panel" detail="Score +0.30, with 80% agreement"/>
                <TrailRow label="Your policy" detail="Passes your buy bar and your rules"/>
                <TrailRow label="Arbiter" detail="Upheld: the evidence supports the vote"/>
                <TrailRow label="Risk gate" detail="Sized to 6.4% of the account, under your 10% limit"/>
                <TrailRow label="Order" detail="Filled on your paper account" tone="text-up"/>
            </dl>
            <figcaption className="mt-2.5 text-[12px] text-faint">An example decision, with made-up figures</figcaption>
        </figure>
        <div className="order-1 lg:order-2">
            <h2 className={HEADING}>Follow any decision back to its sources</h2>
            <p className={BODY}>Every call your agent makes keeps its full trail: the research and its links, each specialist's votes, what your policy said, the Arbiter's ruling, and the risk checks.</p>
            <p className={BODY}>Your account is judged in the open too, against two simple benchmarks, from the day it starts trading.</p>
        </div>
    </section>
}

def KeyRow(name: str, need: str, about: str) -> JsxElement {
    <div className="flex flex-col gap-1 border-t border-line py-4 first:border-t-0 sm:flex-row sm:gap-6">
        <div className="sm:w-[190px] sm:shrink-0">
            <h3 className="text-[15px] font-medium leading-6 text-text">{name}</h3>
            <p className="text-[13px] text-faint">{need}</p>
        </div>
        <p className="text-[14px] leading-[1.55] text-muted">{about}</p>
    </div>
}

def Keys -> JsxElement {
    <section id="keys" className="scroll-mt-20 border-t border-line">
        <div className={SECTION + " grid gap-10 py-16 sm:py-24 lg:grid-cols-2 lg:gap-16"}>
            <div>
                <h2 className={HEADING}>It runs on your accounts, and only on paper</h2>
                <p className={BODY}>You connect your own API keys, so your agent, its research, and its trades are yours alone. Each key is checked when you enter it, stored encrypted, and never shown again.</p>
                <p className={BODY}>Live trading accounts are refused. Your agent only researches until you turn on paper trading yourself.</p>
            </div>
            <div>
                <KeyRow name="Alpaca" need="Required, free" about="Market data, and the paper account your agent trades."/>
                <KeyRow name="OpenRouter" need="Required" about="The free AI models your agent thinks with. A full run needs OpenRouter's one-time $10 credit, which raises the free limit from 50 requests a day to 1,000."/>
                <KeyRow name="Finnhub" need="Optional, free" about="Fundamentals, earnings dates, and analyst views. Without it, those show as gaps your specialists do not vote on."/>
            </div>
        </div>
    </section>
}

def:pub Landing -> JsxElement {
    signed_in: bool = jacIsLoggedIn();

    <div className="flex min-h-dvh flex-col">
        <Header signed_in={signed_in}/>
        <main className="flex-1">
            <section className={SECTION + " pb-16 pt-10 sm:pb-24 sm:pt-16"}>
                <h1 className="display max-w-[15ch] text-[52px] leading-[1.02] tracking-[-0.015em] text-text sm:text-[72px] lg:max-w-[22ch] lg:text-[84px]">An investment committee of your own, on paper</h1>
                <p className="mt-6 max-w-[56ch] text-[17px] leading-[1.6] text-muted">
                    {"Every trading morning, five AI specialists research S&P 500 stocks and vote. Your rules decide what " + PRODUCT + " does with the result, on a simulated account you own, and every reason stays on the record."}
                </p>
                <div className="mt-8 flex flex-wrap gap-3">
                    <Link to={"/app" if signed_in else "/signup"} className={PRIMARY}>{"Open your agent" if signed_in else "Create your agent"}</Link>
                    <a href="#morning" className={SECONDARY}>See how it works</a>
                </div>
                <div className="mt-12 sm:mt-16"><VotePanel/></div>
            </section>
            <Morning/>
            <Rules/>
            <Decisions/>
            <Keys/>
            {if not signed_in {
                <section className="border-t border-line bg-panel-2">
                    <div className={SECTION + " flex flex-col items-start gap-6 py-16 sm:flex-row sm:items-center sm:justify-between"}>
                        <h2 className={HEADING}>Start with research, and decide later</h2>
                        <Link to="/signup" className={PRIMARY + " shrink-0"}>Create your agent</Link>
                    </div>
                </section>
            }}
        </main>
        <footer className="border-t border-line">
            <div className="mx-auto flex max-w-[1200px] flex-col gap-3 px-4 py-6 pb-[calc(1.5rem+env(safe-area-inset-bottom))] text-[12px] leading-[18px] text-faint sm:flex-row sm:items-start sm:justify-between sm:gap-8 sm:px-6 lg:px-8">
                <p className="max-w-2xl">{DISCLAIMER}</p>
                <p className="flex shrink-0 gap-4">
                    <a href={DOCS_URL} className={LINK}>Docs</a>
                    <a href={REPO_URL} className={LINK}>Source</a>
                </p>
            </div>
        </footer>
    </div>
}
