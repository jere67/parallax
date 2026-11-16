"""The screener's Options view: every contract the reader's agent holds, has held, or has ordered,
with its stock, terms, days to expiry, and how it has done. The whole market's chains are on each
stock's page, under Options."""
import from "@jac/runtime" { Link }
import from react { useEffect }
import from dashboard.market.ScreenerPage { AssetSwitch }
import from dashboard.ui.format { MISSING, day_short, num, price, signed_money, signed_pct, title, tone }
import from dashboard.ui.parts { Empty, ErrorBox, FROZEN_CELL, FROZEN_HEAD, PILL_BASE, ROW, TD, TD_NUM, TH, TH_NUM, TONE_ACCENT, TONE_QUIET }
import from dashboard.ui.rpc { list_option_contracts }
import from models.market { OptionBookView as BookData, OptionHoldingView as HoldingData }

def days_text(days: int | None) -> str {
    if days is None {
        return MISSING;
    }
    if days < 0 {
        return "Expired";
    }
    return "Today" if days == 0 else (str(days) + (" day" if days == 1 else " days"));
}

def HoldingRow(h: HoldingData) -> JsxElement {
    <tr className={ROW}>
        <td className={TD + FROZEN_CELL + " min-w-[150px] max-w-[170px] whitespace-normal sm:max-w-none sm:whitespace-nowrap"}>
            <Link to={"/app/stocks/" + h.underlying + "/options"} className="group/link flex min-w-0 flex-col">
                <span className="font-semibold leading-5 text-text group-hover/link:text-accent">{h.label}</span>
                <span className="num truncate text-[11px] text-faint">{h.contract}</span>
            </Link>
        </td>
        <td className={TD}><span className={PILL_BASE + " " + (TONE_ACCENT if h.status == "Open" else TONE_QUIET)}>{h.status}</span></td>
        <td className={TD}>{title(h.kind)}</td>
        <td className={TD_NUM}>{price(h.strike)}</td>
        <td className={TD_NUM}>{day_short(h.expiry)}</td>
        <td className={TD_NUM}>{days_text(h.days_left) if h.status != "Closed" else MISSING}</td>
        <td className={TD_NUM}>{num(h.qty, 0)}</td>
        <td className={TD_NUM}>{price(h.entry_price)}</td>
        <td className={TD_NUM}>{price(h.last)}</td>
        <td className={TD_NUM + " " + tone(h.pnl)}>{signed_money(h.pnl) if h.pnl is not None else MISSING}</td>
        <td className={TD_NUM + " " + tone(h.pnl_pct)}>{signed_pct(h.pnl_pct) if h.pnl_pct is not None else MISSING}</td>
        <td className={TD}>
            {if h.decision_day {
                <Link to={"/app/runs/" + h.decision_day + "/" + h.underlying} className="text-accent hover:underline">{day_short(h.decision_day)}</Link>
            } else {
                <span className="text-faint">{MISSING}</span>
            }}
        </td>
    </tr>
}

def:pub OptionsBookPage -> JsxElement {
    has book: BookData | None = None,
        error: str = "";

    useEffect(
        lambda {
            active = True;
            async def load {
                try {
                    found = await list_option_contracts();
                    if active and found is not None {
                        book = found;
                    }
                } except Exception as e {
                    if active {
                        error = str(e);
                    }
                }
            }
            load();
            return lambda {
                active = False;
            };
        },
        []
    );

    rows: list[HoldingData] = book.rows if book is not None else [];
    <div className="flex flex-col gap-3">
        <header>
            <div className="flex flex-wrap items-center gap-x-4 gap-y-2">
                <h1 className="display text-[30px] leading-9 text-text">Screener</h1>
                <AssetSwitch current="Options"/>
            </div>
            <p className="mt-0.5 text-[13px] text-muted">The calls and puts your agent holds, has held, or has ordered. Every stock's full chain is on its page, under Options.</p>
        </header>
        {if error {
            <ErrorBox message={error}/>
        } elif book is None {
            <div className="h-64 animate-pulse rounded-md border border-line bg-panel-2" aria-busy="true" aria-label="Loading the contracts"></div>
        } elif len(rows) == 0 {
            <Empty title="Your agent has no options yet">
                It buys calls on its panel's confident buys and puts on confident sells, once options are on in Settings. <Link to="/app/screener" className="text-accent hover:underline">Find a stock's chain on its page</Link>
            </Empty>
        } else {
            <section className="overflow-hidden rounded-md border border-line bg-panel" aria-label="Your agent's contracts">
                <div className="max-h-[78dvh] overflow-auto overscroll-x-contain">
                    <table className="w-full border-separate border-spacing-0">
                        <thead>
                            <tr>
                                <th scope="col" className={TH + FROZEN_HEAD}>Contract</th>
                                <th scope="col" className={TH}>Status</th>
                                <th scope="col" className={TH}>Type</th>
                                <th scope="col" className={TH_NUM}>Strike</th>
                                <th scope="col" className={TH_NUM}>Expiry</th>
                                <th scope="col" className={TH_NUM}>Left</th>
                                <th scope="col" className={TH_NUM}>Contracts</th>
                                <th scope="col" className={TH_NUM}>Entry</th>
                                <th scope="col" className={TH_NUM}>Last</th>
                                <th scope="col" className={TH_NUM}>P&L</th>
                                <th scope="col" className={TH_NUM}>P&L %</th>
                                <th scope="col" className={TH}>Decision</th>
                            </tr>
                        </thead>
                        <tbody>
                            {for h in rows {
                                <HoldingRow key={h.contract + h.status} h={h}/>
                            }}
                        </tbody>
                    </table>
                </div>
            </section>
            <p className="text-[12px] text-muted">{"Prices are per share; one contract covers 100 shares. " + ("Demo data, invented here." if book.demo else "")}</p>
        }}
    </div>
}
