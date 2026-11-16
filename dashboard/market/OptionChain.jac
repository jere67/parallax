"""A stock's option chain, one expiry at a time: calls on the left and puts on the right of each
strike, the strikes in the money shaded, the stock's price marked between them, and the contracts
the reader's agent holds badged."""
import from react { useEffect }
import from dashboard.ui.format { MISSING, compact, day_short, num, pct, price }
import from dashboard.ui.parts { Empty, PILL_BASE, Panel, TD_NUM, TH_NUM, TONE_ACCENT }
import from dashboard.ui.rpc { get_option_chain }
import from models.market { OptionChainView as ChainData, OptionSideView as SideData, OptionStrikeView as StrikeData }

glob CHAIN_RETRY_MS: int = 8000;
glob SIDE_COLUMNS: list[str] = ["Bid", "Ask", "Last", "Vol", "OI", "IV", "Delta"];
# The calls read outward from the strike, so their columns run the other way.
glob CALL_COLUMNS: list[str] = ["Delta", "IV", "OI", "Vol", "Last", "Ask", "Bid"];
# A phone shows the prices alone: these columns wait for a wider screen.
glob WIDE_ONLY: list[str] = ["Vol", "OI", "IV", "Delta"];
glob WIDE: str = " hidden sm:table-cell";

def wide(name: str) -> str {
    return WIDE if name in WIDE_ONLY else "";
}

def cell_values(side: SideData | None) -> list[str] {
    if side is None {
        return [MISSING, MISSING, MISSING, MISSING, MISSING, MISSING, MISSING];
    }
    return [
        price(side.bid),
        price(side.ask),
        price(side.last),
        compact(side.volume) if side.volume is not None else MISSING,
        compact(side.open_interest) if side.open_interest is not None else MISSING,
        pct(side.iv, 1) if side.iv is not None else MISSING,
        num(side.delta, 2) if side.delta is not None else MISSING
    ];
}

def SideCells(side: SideData | None, in_money: bool, mirror: bool) -> JsxElement {
    values = cell_values(side);
    names = CALL_COLUMNS if mirror else SIDE_COLUMNS;
    shown = [values[len(values) - 1 - i] for i in range(len(values))] if mirror else values;
    <>
        {for (i, text) in enumerate(shown) {
            <td key={i} className={TD_NUM + wide(names[i]) + (" bg-accent/10" if in_money else "")}>{text}</td>
        }}
    </>
}

def HeldMark(side: SideData | None, kind: str) -> JsxElement {
    if side is None or side.held == 0 {
        return <></>;
    }
    <span className={PILL_BASE + " " + TONE_ACCENT + " ml-1.5"} title={"Your agent holds " + num(side.held, 0) + " of " + side.symbol}>{"Held " + num(side.held, 0) + " " + kind}</span>
}

def StrikeRow(row: StrikeData, spot: float) -> JsxElement {
    <tr className="border-t border-line">
        <SideCells side={row.call} in_money={row.strike < spot} mirror={True}/>
        <th scope="row" className="whitespace-nowrap border-b border-line/60 bg-panel-2 px-3 py-1.5 text-center text-[13px] font-semibold text-text">
            <span className="num">{price(row.strike)}</span>
            <HeldMark side={row.call} kind="call"/>
            <HeldMark side={row.put} kind="put"/>
        </th>
        <SideCells side={row.put} in_money={row.strike > spot} mirror={False}/>
    </tr>
}

"""The stock's price as a line between the strikes it falls between."""
def SpotRow(spot: float) -> JsxElement {
    <tr aria-label={"The stock at " + price(spot)}>
        <td colSpan={2 * len(SIDE_COLUMNS) + 1} className="border-y border-accent/50 bg-accent/10 py-1 text-center text-[11px] font-medium text-accent">{"Stock " + price(spot)}</td>
    </tr>
}

def:pub OptionChain(symbol: str) -> JsxElement {
    has chain: ChainData | None = None,
        expiry: str = "",
        error: str = "";

    useEffect(
        lambda {
            active = True;
            timers: list[any] = [];
            async def load {
                try {
                    found = await get_option_chain(symbol, expiry);
                    if not active or found is None {
                        return;
                    }
                    chain = found;
                    if found.busy {
                        timers.append(setTimeout(load, CHAIN_RETRY_MS));
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
                for timer in timers {
                    clearTimeout(timer);
                }
            };
        },
        [symbol, expiry]
    );

    if error {
        return <Empty title="The option chain could not load">{error}</Empty>;
    }
    if chain is None or (chain.busy and len(chain.strikes) == 0) {
        return <div className="h-96 animate-pulse rounded-md border border-line bg-panel-2" aria-busy="true" aria-label="Loading the option chain"></div>;
    }
    if chain.message or len(chain.strikes) == 0 {
        return <Empty title="No option chain">{chain.message or "No listed options were found for this stock."}</Empty>;
    }

    spot = float(chain.price or 0);
    rows: list[StrikeData] = chain.strikes;
    split = len([r for r in rows if r.strike < spot]);
    # The stock's price sits between the strikes below it and those above, as a row of its own.
    lines: list[StrikeData | None] = rows[0:split] + [None] + rows[split:];

    <Panel
        title="Option chain"
        aside={
            <label className="flex items-center gap-2 text-[12px] text-muted">
                Expiry
                <select
                    aria-label="Expiry"
                    value={chain.expiry}
                    onChange={lambda (e: ChangeEvent) { expiry = e.target.value; }}
                    className="h-8 rounded-md border border-line bg-bg px-2 text-[13px] text-text"
                >
                    {for day in chain.expiries {
                        <option key={day} value={day}>{day_short(day)}</option>
                    }}
                </select>
            </label>
        }
        pad={False}
    >
        <div className="flex items-center justify-between border-b border-line px-4 py-2 text-[12px] font-medium text-muted" aria-hidden="true">
            <span>Calls</span>
            <span>Puts</span>
        </div>
        <div className="max-h-[70dvh] overflow-auto overscroll-x-contain">
            <table className="w-full border-separate border-spacing-0 text-[12px]" aria-label={"Option chain for " + symbol + ", " + day_short(chain.expiry)}>
                <thead>
                    <tr>
                        {for name in CALL_COLUMNS {
                            <th key={"c" + name} scope="col" className={TH_NUM + wide(name)}>{name}</th>
                        }}
                        <th scope="col" className={TH_NUM + " text-center"}>Strike</th>
                        {for name in SIDE_COLUMNS {
                            <th key={"p" + name} scope="col" className={TH_NUM + wide(name)}>{name}</th>
                        }}
                    </tr>
                </thead>
                <tbody>
                    {for line in lines {
                        if line is None {
                            <SpotRow key="spot" spot={spot}/>
                        } else {
                            <StrikeRow key={str(line.strike)} row={line} spot={spot}/>
                        }
                    }}
                </tbody>
            </table>
        </div>
        <p className="border-t border-line px-4 py-2.5 text-[12px] text-muted">
            {("Invented prices for the demo. " if chain.demo else "Quotes from Alpaca's free indicative feed, which can lag the market. ") + "One contract covers 100 shares. Shaded strikes are in the money. None of this is advice."}
        </p>
    </Panel>
}
