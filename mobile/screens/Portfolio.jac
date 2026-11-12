"""Portfolio: what the agent's paper account is worth, against SPY, and what it holds."""

import from "@jac/mobui" { View, Text, ScrollView, RefreshControl, ActivityIndicator }
import from ..theme { C, S, F, styles }
import from ..api { call }
import from ..views { PerformanceView, PortfolioView, PositionView }
import from ..format { clock, day_label, money, percent, price, signed_money, signed_percent }
import from ..components.EquityChart { EquityChart }
import from ..components.parts { Figure, Notice, SectionHead, Tappable }

def lean_of(value: float | None) -> str {
    if value is None or value == 0 {
        return "";
    }
    return "up" if value > 0 else "down";
}

def PositionRow(p: PositionView, onOpen: Callable[[], None]) -> JsxElement {
    pnl_color = C.up if (p.pnl or 0) > 0 else (C.down if (p.pnl or 0) < 0 else C.muted);
    <Tappable onPress={onOpen}>
        <View style={styles.between}>
            <Text style={{"color": C.text, "fontSize": F.md, "fontWeight": "600"}}>{p.ticker}</Text>
            <Text style={styles.num}>{money(p.market_value)}</Text>
        </View>
        <View style={styles.between}>
            <Text style={[styles.faint, {"flex": 1}]} numberOfLines={1}>{f"{p.qty} sh at {price(p.avg_entry_price)} · {p.sector}"}</Text>
            <Text style={[styles.num, {"color": pnl_color, "fontSize": F.sm}]}>{f"{signed_money(p.pnl)}  {signed_percent(p.pnl_pct)}"}</Text>
        </View>
    </Tappable>
}

def:pub Portfolio(server: str, token: str, onSignedOut: Callable[[], None], onOpenTrail: Callable[[str, str], None]) -> JsxElement {
    has view: PortfolioView | None = None,
        perf: PerformanceView | None = None,
        loading: bool = True,
        refreshing: bool = False,
        problem: str = "";

    async def load {
        problem = "";
        got = await call(server, token, "get_portfolio");
        if got.signed_out {
            onSignedOut();
            return;
        }
        if not got.ok {
            problem = got.problem;
            loading = False;
            return;
        }
        view = got.data as PortfolioView;
        curve = await call(server, token, "get_performance");
        perf = curve.data as PerformanceView if curve.ok else None;
        loading = False;
    }

    async def refresh {
        refreshing = True;
        await load();
        refreshing = False;
    }

    async can with entry {
        await load();
    }

    if loading {
        return <View style={[styles.screen, {"justifyContent": "center"}]}><ActivityIndicator color={C.accent}/></View>;
    }

    v = view;
    <ScrollView style={styles.scroll} contentContainerStyle={styles.content} refreshControl={<RefreshControl refreshing={refreshing} onRefresh={refresh} tintColor={C.accent}/>}>
        {(<Notice text={problem}/>) if problem else None}
        {(<Notice text="Demo data: invented prices and votes, made by the project's own code. Nothing here is a real trade."/>) if v and v.demo else None}
        {(
            <View style={{"gap": S.xs}}>
                <Text style={styles.eyebrow}>{f"Account value · {day_label(v.last_day)} close" if v.last_day else "Account value"}</Text>
                <Text style={styles.hero}>{money(v.equity)}</Text>
                <View style={styles.row}>
                    <Text style={[styles.num, {"color": C.up if (v.day_pnl or 0) >= 0 else C.down, "fontSize": F.sm}]}>{f"{signed_money(v.day_pnl)} ({signed_percent(v.day_return)}) today"}</Text>
                </View>
            </View>
        ) if v and v.started else None}
        {(
            <View style={styles.card}>
                <Text style={styles.sectionTitle}>No trading yet</Text>
                <Text style={styles.note}>This account has not been marked at a close. Its value and positions appear after its first trading day.</Text>
            </View>
        ) if v and not v.started else None}
        {(<View style={styles.card}><EquityChart series={perf.series}/></View>) if perf and perf.started and len(perf.series) > 0 else None}
        {(
            <View style={{"flexDirection": "row", "flexWrap": "wrap", "rowGap": S.lg, "columnGap": S.md}}>
                <Figure label="Since the start" value={signed_percent(v.total_return)} lean={lean_of(v.total_return)}/>
                <Figure label="Cash" value={money(v.cash, 0)}/>
                <Figure label="Invested" value={percent(v.gross_exposure, 0)}/>
                <Figure label="Below the peak" value={percent(v.drawdown, 1)} lean={"down" if (v.drawdown or 0) > 0 else ""}/>
            </View>
        ) if v and v.started else None}
        {(
            <View style={styles.section}>
                <SectionHead title="Positions" note={f"{len(v.positions)} open"}/>
                <View>
                    {[
                        <View key={p.ticker}>
                            {(<View style={styles.rule}/>) if i > 0 else None}
                            <PositionRow p={p} onOpen={lambda { onOpenTrail(p.decision_day, p.ticker); }}/>
                        </View> for (i, p) in enumerate(v.positions)
                    ]}
                </View>
            </View>
        ) if v and len(v.positions) > 0 else None}
        {(<Text style={styles.faint}>{f"Marked {clock(v.as_of)} on {day_label(v.last_day)}. Pull down to refresh."}</Text>) if v and v.as_of else None}
    </ScrollView>
}
