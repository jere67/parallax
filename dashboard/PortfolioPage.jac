"""The Portfolio page (TDD §10): the team portfolio at its last mark, its equity curve against
both baselines, the open positions with their stops and theses, and the recent orders and
closed trades. Every ticker links to the decision trail behind it."""
import from "@jac/runtime" { Link }
import from "lucide-react" { ChevronRight }
import from dashboard.api { get_performance, get_portfolio }
import from dashboard.ui.EquityChart { EquityChart }
import from dashboard.ui.format {
    MISSING,
    count,
    day_et,
    day_long,
    day_short,
    money,
    num,
    pct,
    qty,
    signed_money,
    signed_pct,
    stamp_et,
    title,
    tone
}
import from dashboard.ui.parts {
    FROZEN_CELL,
    FROZEN_HEAD,
    ROW,
    TD,
    TD_NUM,
    TH,
    TH_NUM,
    Empty,
    ErrorBox,
    Delta,
    Loading,
    Overline,
    Panel,
    SEGMENTS,
    Segment,
    Stat,
    StatusBadge
}
# Aliased: the endpoint bridge declares the wire classes under their own names.
import from models.views {
    OrderView as OrderData,
    PerformanceView as PerformanceData,
    PortfolioView as PortfolioData,
    PositionView as PositionData,
    Series as SeriesData
}

# A cell of the figures grid, on the panel fill over the grid's hairlines.
glob CELL: str = "min-w-0 bg-panel px-4 py-3.5";
glob SECTOR_CAP: float = 0.30;
glob STAT_ROWS: list[str] = ["Total return", "Sharpe", "Max drawdown", "Volatility"];
glob SHORT_LABELS: dict[str, str] = {"team": "Team", "equal_weight": "Equal wt", "spy": "SPY"};

def series_of(perf: PerformanceData | None, key: str) -> SeriesData | None {
    if perf is None {
        return None;
    }
    for s in perf.series {
        if s.key == key {
            return s;
        }
    }
    return None;
}

"""A decision trail's address, or "" when the decision's run is unknown."""
def trail_link(day: str, ticker: str) -> str {
    return "/runs/" + day + "/" + ticker if day else "";
}

def TickerCell(ticker: str, day: str, sub: str = "") -> JsxElement {
    to = trail_link(day, ticker);
    <div className="min-w-0">
        {if to {
            <Link to={to} className="font-semibold text-text hover:text-accent">{ticker}</Link>
        } else {
            <span className="font-semibold">{ticker}</span>
        }}
        {if sub {
            <div className="truncate text-[11px] text-faint">{sub}</div>
        }}
    </div>
}

"""The headline: the account's equity in the display face with its day's change beside it,
the way a quote reads, over the chart."""
def Hero(view: PortfolioData) -> JsxElement {
    <div className="px-4 pt-4">
        <Overline>Equity</Overline>
        <div className="mt-1 flex flex-wrap items-center gap-x-2.5 gap-y-1">
            <span className="display text-[40px] leading-[44px] text-text">{money(view.equity)}</span>
            <Delta text={signed_pct(view.day_return)} value={view.day_return}/>
            <span className={"num text-[13px] font-medium " + tone(view.day_pnl)}>{signed_money(view.day_pnl)}</span>
            <span className="text-[11px] text-muted">{"on " + day_short(view.last_day)}</span>
        </div>
    </div>
}

"""The figures under the chart, in one hairline grid: six cells, so every row fills at two
and at three across."""
def Figures(view: PortfolioData, perf: PerformanceData | None) -> JsxElement {
    team = series_of(perf, "team");
    spy = series_of(perf, "spy");
    lead: float | None = None;
    if team is not None and spy is not None and team.total_return is not None and spy.total_return is not None {
        lead = team.total_return - spy.total_return;
    }
    drawdown = view.drawdown;
    open_pnl = 0.0;
    for p in view.positions {
        open_pnl = open_pnl + (p.pnl or 0.0);
    }
    cash_share: float | None = view.cash / view.equity if view.equity else None;
    <div className="grid grid-cols-2 gap-px border-t border-line bg-line sm:grid-cols-3">
        <div className={CELL}>
            <Stat
                label="Total return"
                value={signed_pct(view.total_return)}
                tone={tone(view.total_return)}
                sub={signed_money(view.total_pnl) + " since " + day_short(day_et(view.opened_at))}
            />
        </div>
        <div className={CELL}>
            <Stat
                label="Against SPY"
                value={signed_pct(lead)}
                tone={tone(lead)}
                sub={"SPY " + signed_pct(spy.total_return if spy is not None else None)}
                hint="Team total return minus SPY buy-and-hold over the same sessions"
            />
        </div>
        <div className={CELL}>
            <Stat
                label="Drawdown"
                value={signed_pct(0.0 - drawdown) if drawdown is not None else MISSING}
                tone={"text-down" if drawdown is not None and drawdown > 0.0001 else "text-text"}
                sub={"Peak " + money(view.peak_equity)}
                hint="From the highest close; new buys halt at 10%"
            />
        </div>
        <div className={CELL}>
            <Stat
                label="Gross exposure"
                value={pct(view.gross_exposure, 1)}
                sub={money(view.positions_value, 0) + " invested"}
            />
        </div>
        <div className={CELL}>
            <Stat
                label="Open P&L"
                value={signed_money(open_pnl)}
                tone={tone(open_pnl)}
                sub={count(len(view.positions), "position")}
            />
        </div>
        <div className={CELL}>
            <Stat label="Cash" value={money(view.cash)} sub={pct(cash_share, 1) + " of equity"}/>
        </div>
    </div>
}

def stat_value(s: SeriesData, row: str) -> str {
    if row == "Total return" {
        return signed_pct(s.total_return);
    }
    if row == "Sharpe" {
        return num(s.sharpe);
    }
    if row == "Max drawdown" {
        return signed_pct(0.0 - s.max_drawdown) if s.max_drawdown is not None else MISSING;
    }
    return pct(s.volatility, 1);
}

def stat_tone(s: SeriesData, row: str) -> str {
    return tone(s.total_return) if row == "Total return" else "text-text";
}

def StatsTable(perf: PerformanceData, view: PortfolioData) -> JsxElement {
    <Panel title="Performance" pad={False}>
        <div className="scroll-x">
            <table className="w-full">
                <thead>
                    <tr>
                        <th className={TH}></th>
                        {for s in perf.series {
                            <th key={s.key} className={TH_NUM}>{SHORT_LABELS.get(s.key, s.label)}</th>
                        }}
                    </tr>
                </thead>
                <tbody>
                    {for row in STAT_ROWS {
                        <tr key={row} className={ROW}>
                            <td className="whitespace-nowrap border-b border-line/60 py-2.5 pl-4 pr-2 text-[13px] text-muted">{row}</td>
                            {for s in perf.series {
                                <td key={s.key} className={TD_NUM + " " + stat_tone(s, row) + (" font-semibold" if s.key == "team" else "")}>
                                    {stat_value(s, row)}
                                </td>
                            }}
                        </tr>
                    }}
                </tbody>
            </table>
        </div>
        <p className="border-t border-line px-4 py-2.5 text-[12px] text-faint">
            {count(view.sessions, "session") + " since " + day_long(perf.start_day) + ". Sharpe and volatility are annualized from daily returns."}
        </p>
        <p className="flex items-start gap-2 border-t border-line px-4 py-2.5 text-[12px]">
            <span className={"mt-[5px] size-1.5 shrink-0 rounded-full " + ("bg-up" if view.bypasses == 0 and view.drift == 0 else "bg-down")}></span>
            <span className="text-muted">
                {"Ledger checks: " + count(view.bypasses, "order") + " outside the risk gate, " + count(view.drift, "position") + " drifted from the broker"}
            </span>
        </p>
    </Panel>
}

def by_weight(item: tuple[str, float]) -> float {
    return item[1];
}

def SectorExposure(positions: list[PositionData]) -> JsxElement {
    totals: dict[str, float] = {};
    for p in positions {
        totals[p.sector or "Unknown"] = totals.get(p.sector or "Unknown", 0.0) + (p.weight or 0.0);
    }
    ranked = sorted([(name, w) for (name, w) in totals.items()], key=by_weight, reverse=True);
    <Panel title="Sector exposure" aside={<span className="text-[11px] text-faint">Cap 30%</span>}>
        {if len(ranked) == 0 {
            <p className="text-[13px] text-muted">No open positions.</p>
        } else {
            <ul className="flex flex-col gap-2.5">
                {for (name, w) in ranked {
                    <li key={name} className="text-[12px]">
                        <div className="mb-1 flex items-baseline justify-between gap-3">
                            <span className="truncate text-muted">{name}</span>
                            <span className="num">{pct(w, 1)}</span>
                        </div>
                        <div className="relative h-1.5 rounded-full bg-panel-2">
                            <div
                                className={"absolute inset-y-0 left-0 rounded-full " + ("bg-warn" if w > SECTOR_CAP - 0.02 else "bg-accent")}
                                style={{"width": str(min(w / 0.4, 1.0) * 100) + "%"}}
                            ></div>
                            <div className="absolute inset-y-[-3px] w-px bg-line-strong" style={{"left": str(SECTOR_CAP / 0.4 * 100) + "%"}}></div>
                        </div>
                    </li>
                }}
            </ul>
        }}
    </Panel>
}

def PositionsTable(positions: list[PositionData]) -> JsxElement {
    has opened: str = "";

    def toggle(ticker: str) {
        opened = "" if opened == ticker else ticker;
    }

    <Panel title="Open positions" aside={<span className="num">{count(len(positions), "position")}</span>} pad={False}>
        {if len(positions) == 0 {
            <p className="px-4 py-6 text-[13px] text-muted">No open positions.</p>
        } else {
            <div className="scroll-x">
                <table className="w-full min-w-[960px]">
                    <thead>
                        <tr>
                            <th className={TH + FROZEN_HEAD}>Ticker</th>
                            <th className={TH_NUM}>Qty</th>
                            <th className={TH_NUM}>Avg cost</th>
                            <th className={TH_NUM}>Last</th>
                            <th className={TH_NUM}>Value</th>
                            <th className={TH_NUM}>Weight</th>
                            <th className={TH_NUM}>Unrealized</th>
                            <th className={TH_NUM}>Return</th>
                            <th className={TH_NUM}>Stop</th>
                            <th className={TH_NUM}>To stop</th>
                            <th className={TH_NUM}>Time stop</th>
                            <th className={TH_NUM}>Opened</th>
                        </tr>
                    </thead>
                    <tbody>
                        {for p in positions {
                            <tr key={p.ticker} className={ROW + " group cursor-pointer"} onClick={lambda { toggle(p.ticker); }}>
                                <td className={TD + FROZEN_CELL}>
                                    <div className="flex items-center gap-2">
                                        <button
                                            type="button"
                                            className="press -ml-1 grid size-6 shrink-0 place-items-center rounded-[4px] text-faint hover:bg-panel-2 hover:text-text"
                                            aria-expanded={opened == p.ticker}
                                            aria-label={"Thesis for " + p.ticker}
                                        >
                                            <ChevronRight
                                                size={14}
                                                className={"transition-[rotate] duration-150 ease-out " + ("rotate-90" if opened == p.ticker else "")}
                                            />
                                        </button>
                                        <TickerCell ticker={p.ticker} day={p.decision_day} sub={p.sector}/>
                                    </div>
                                </td>
                                <td className={TD_NUM}>{qty(p.qty)}</td>
                                <td className={TD_NUM}>{money(p.avg_entry_price)}</td>
                                <td className={TD_NUM}>{money(p.last_price)}</td>
                                <td className={TD_NUM}>{money(p.market_value, 0)}</td>
                                <td className={TD_NUM}>{pct(p.weight, 1)}</td>
                                <td className={TD_NUM + " " + tone(p.pnl)}>{signed_money(p.pnl)}</td>
                                <td className={TD_NUM + " " + tone(p.pnl_pct)}>{signed_pct(p.pnl_pct)}</td>
                                <td className={TD_NUM}>{money(p.stop_price)}</td>
                                <td className={TD_NUM + " text-muted"}>{pct(p.stop_distance, 1)}</td>
                                <td className={TD_NUM + " text-muted"}>{day_short(p.time_stop)}</td>
                                <td className={TD_NUM + " text-muted"}>{day_short(day_et(p.opened_at))}</td>
                            </tr>
                            if opened == p.ticker {
                                <tr key={p.ticker + "-thesis"} className="bg-panel-2/50">
                                    <td colSpan={12} className="border-b border-line/60 py-3.5 pl-12 pr-4">
                                        <div className="sticky left-12 max-w-[min(640px,calc(100vw-5rem))]">
                                            <Overline>Thesis</Overline>
                                            <p className="mt-1 text-[13px] leading-relaxed text-text">
                                                {p.thesis or "No thesis was recorded for this position."}
                                            </p>
                                        </div>
                                        {if p.decision_day {
                                            <Link
                                                to={trail_link(p.decision_day, p.ticker)}
                                                className="sticky left-12 mt-2 inline-block text-[12px] font-medium text-accent hover:underline"
                                            >
                                                {"Open the " + day_short(p.decision_day) + " decision trail"}
                                            </Link>
                                        }}
                                    </td>
                                </tr>
                            }
                        }}
                    </tbody>
                </table>
            </div>
        }}
    </Panel>
}

def side_tone(side: str) -> str {
    return "text-up" if side == "buy" else "text-down";
}

def OrdersTable(orders: list[OrderData]) -> JsxElement {
    if len(orders) == 0 {
        return <p className="px-4 py-6 text-[13px] text-muted">No orders yet.</p>;
    }
    <div className="max-h-[480px] overflow-auto overscroll-contain">
        <table className="w-full min-w-[900px]">
            <thead>
                <tr>
                    <th className={TH + FROZEN_HEAD}>Ticker</th>
                    <th className={TH}>Submitted</th>
                    <th className={TH}>Side</th>
                    <th className={TH}>Purpose</th>
                    <th className={TH}>Type</th>
                    <th className={TH_NUM}>Price</th>
                    <th className={TH_NUM}>Filled</th>
                    <th className={TH_NUM}>Avg fill</th>
                    <th className={TH}>Status</th>
                </tr>
            </thead>
            <tbody>
                {for o in orders {
                    <tr key={o.client_order_id} className={ROW + " group"}>
                        <td className={TD + FROZEN_CELL}><TickerCell ticker={o.ticker} day={o.run_day}/></td>
                        <td className={TD + " num text-muted"}>{stamp_et(o.submitted_at)}</td>
                        <td className={TD + " font-semibold uppercase " + side_tone(o.side)}>{o.side}</td>
                        <td className={TD + " text-muted"}>{title(o.purpose)}</td>
                        <td className={TD + " text-muted"}>{title(o.order_type) + " · " + o.time_in_force.upper()}</td>
                        <td className={TD_NUM}>{money(o.limit_price if o.limit_price is not None else o.stop_price)}</td>
                        <td className={TD_NUM}>{qty(o.filled_qty) + " / " + qty(o.qty)}</td>
                        <td className={TD_NUM}>{money(o.filled_avg_price)}</td>
                        <td className={TD} title={o.reject_reason}><StatusBadge status={o.status}/></td>
                    </tr>
                }}
            </tbody>
        </table>
    </div>
}

def ClosedTable(closed: list[PositionData]) -> JsxElement {
    if len(closed) == 0 {
        return <p className="px-4 py-6 text-[13px] text-muted">No closed trades yet.</p>;
    }
    <div className="max-h-[480px] overflow-auto overscroll-contain">
        <table className="w-full min-w-[820px]">
            <thead>
                <tr>
                    <th className={TH + FROZEN_HEAD}>Ticker</th>
                    <th className={TH_NUM}>Opened</th>
                    <th className={TH_NUM}>Closed</th>
                    <th className={TH_NUM}>Shares sold</th>
                    <th className={TH_NUM}>Avg cost</th>
                    <th className={TH_NUM}>Exit</th>
                    <th className={TH_NUM}>Realized</th>
                    <th className={TH_NUM}>Return</th>
                </tr>
            </thead>
            <tbody>
                {for p in closed {
                    <tr key={p.ticker + p.opened_at} className={ROW + " group"}>
                        <td className={TD + FROZEN_CELL}><TickerCell ticker={p.ticker} day={p.decision_day} sub={p.sector}/></td>
                        <td className={TD_NUM + " text-muted"}>{day_short(day_et(p.opened_at))}</td>
                        <td className={TD_NUM + " text-muted"}>{day_short(day_et(p.closed_at))}</td>
                        <td className={TD_NUM}>{qty(p.entry_qty)}</td>
                        <td className={TD_NUM}>{money(p.avg_entry_price)}</td>
                        <td className={TD_NUM}>{money(p.exit_price)}</td>
                        <td className={TD_NUM + " " + tone(p.pnl)}>{signed_money(p.pnl)}</td>
                        <td className={TD_NUM + " " + tone(p.pnl_pct)}>{signed_pct(p.pnl_pct)}</td>
                    </tr>
                }}
            </tbody>
        </table>
    </div>
}

def Activity(view: PortfolioData) -> JsxElement {
    has tab: str = "orders";

    tabs = <div className={SEGMENTS}>
        <Segment label="Orders" count={len(view.orders)} active={tab == "orders"} pick={lambda { tab = "orders"; }}/>
        <Segment label="Closed trades" count={len(view.closed)} active={tab == "closed"} pick={lambda { tab = "closed"; }}/>
    </div>;
    <Panel title="Activity" aside={tabs} pad={False}>
        {<OrdersTable orders={view.orders}/> if tab == "orders" else <ClosedTable closed={view.closed}/>}
    </Panel>
}

def:pub PortfolioPage -> JsxElement {
    has view: PortfolioData | None = None,
        perf: PerformanceData | None = None,
        error: str = "";

    async can with entry {
        try {
            view = await get_portfolio();
            perf = await get_performance();
        } except Exception as e {
            error = str(e);
        }
    }

    if error {
        return <ErrorBox message={error}/>;
    }
    if view is None {
        return <Loading label="Loading the portfolio"/>;
    }
    if not view.started {
        return <Empty title="The forward test has not started">
            The team portfolio has no closing mark yet. Once the first trading day closes, its equity, positions, and orders appear here.
        </Empty>;
    }

    <div className="rise flex flex-col gap-6">
        <header className="flex flex-col gap-2">
            <Overline className="num">{"Paper account · " + day_long(view.last_day) + " close"}</Overline>
            <h1 className="display text-[36px] leading-10 text-text">Team portfolio</h1>
            <p className="max-w-[600px] text-[13px] leading-5 text-muted">
                Five specialists research each stock, the Arbiter decides, and the risk gate sizes every order.
                The account is marked at each close against SPY and an equal-weight basket of the same shortlist.
            </p>
        </header>
        <div className="grid grid-cols-1 gap-6 lg:grid-cols-[minmax(0,1fr)_340px]">
            <Panel
                title="Return since start"
                aside={<span className="num">{"Since " + day_short(perf.start_day) if perf is not None and perf.started else ""}</span>}
                pad={False}
                fill={True}
            >
                <Hero view={view}/>
                {if perf is not None and perf.started {
                    <div className="flex flex-1 flex-col px-4 pb-4 pt-5">
                        <EquityChart series={perf.series} starting_cash={perf.starting_cash}/>
                    </div>
                }}
                <Figures view={view} perf={perf}/>
            </Panel>
            <div className="flex flex-col gap-6">
                {if perf is not None and perf.started {
                    <StatsTable perf={perf} view={view}/>
                }}
                <SectorExposure positions={view.positions}/>
            </div>
        </div>
        <PositionsTable positions={view.positions}/>
        <Activity view={view}/>
    </div>
}
