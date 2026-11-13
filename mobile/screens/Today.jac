"""Today: the latest morning run, or an earlier one. What the committee decided for each stock
it covered, and what the risk gate and the broker did with it."""

import from "@jac/mobui" { View, Text, ScrollView, RefreshControl, ActivityIndicator, Pressable }
import from ..theme { C, S, R, F, styles }
import from ..api { call }
import from ..views { CoverageRow, RunView }
import from ..format { clock_span, day_label, order_word, percent, score, status_word }
import from ..components.Icon { Icon }
import from ..components.parts { ActionPill, Notice, SectionHead, StatusPill, Tappable }

def tone_of(status: str) -> str {
    return "up" if status == "normal" else ("warn" if status == "fallback" else "down");
}

"""What became of the decision: the order and its fill, or why there was none."""
def outcome_of(r: CoverageRow) -> str {
    if r.forced_hold {
        return "Held: the run could not finish its research";
    }
    if r.order_status == "filled" {
        return f"{'Bought' if r.order_side == 'buy' else 'Sold'} {r.filled_qty} at ${r.filled_avg_price or 0:.2f}";
    }
    if r.order_status {
        return f"Order {order_word(r.order_status)}";
    }
    if r.gate_outcome == "rejected" {
        return "Stopped by the risk gate";
    }
    if r.gate_outcome == "resized" {
        return f"Resized by the risk gate to {r.approved_qty}";
    }
    return "No order" if r.action in ["NO_ACTION", "HOLD", ""] else "Approved, not yet sent";
}

def DecisionRow(r: CoverageRow, onOpen: Callable[[], None]) -> JsxElement {
    <Tappable onPress={onOpen}>
        <View style={styles.between}>
            <View style={styles.row}>
                <Text style={{"color": C.text, "fontSize": F.md, "fontWeight": "600", "minWidth": 54}}>{r.ticker}</Text>
                <ActionPill action={r.action}/>
            </View>
            <Text style={[styles.num, {"fontSize": F.sm, "color": C.muted}]}>{score(r.score)}</Text>
        </View>
        <Text style={styles.faint} numberOfLines={1}>{outcome_of(r)}</Text>
    </Tappable>
}

def DayButton(icon: str, label: str, day: str, onPress: Callable[[], None]) -> JsxElement {
    <Pressable onPress={onPress} disabled={not day} style={{"flexDirection": "row", "alignItems": "center", "gap": 4, "paddingVertical": S.xs, "opacity": 1.0 if day else 0.3}}>
        {(<Icon name="back" size={16} color={C.muted}/>) if icon == "back" else None}
        <Text style={styles.note}>{label}</Text>
        {(<View style={{"transform": [{"rotate": "180deg"}]}}><Icon name="back" size={16} color={C.muted}/></View>) if icon == "next" else None}
    </Pressable>
}

def:pub Today(server: str, token: str, version: int, onSignedOut: Callable[[], None], onOpenTrail: Callable[[str, str], None]) -> JsxElement {
    has run: RunView | None = None,
        day: str = "",
        loading: bool = True,
        refreshing: bool = False,
        problem: str = "";

    async def load {
        problem = "";
        got = await call(server, token, "get_run", {"run_date": day});
        if got.signed_out {
            onSignedOut();
            return;
        }
        if not got.ok {
            problem = got.problem;
        } else {
            run = got.data as RunView if got.data else None;
        }
        loading = False;
    }

    async def refresh {
        refreshing = True;
        await load();
        refreshing = False;
    }

    def go(to: str) {
        day = to;
        loading = True;
    }

    # Reload when the day changes, and when the app sees a new run come in (`version`).
    async can with (day, version) entry {
        await load();
    }

    if loading {
        return <View style={[styles.screen, {"justifyContent": "center"}]}><ActivityIndicator color={C.accent}/></View>;
    }

    r = run;
    shown_day = r.run_date if r else "";
    earlier = r.previous_day if r else "";
    later = r.next_day if r else "";
    acted = [x for x in (r.rows if r else []) if x.action not in ["NO_ACTION", "HOLD", ""]];
    held = [x for x in (r.rows if r else []) if x.action in ["NO_ACTION", "HOLD", ""]];
    <ScrollView style={styles.scroll} contentContainerStyle={styles.content} refreshControl={<RefreshControl refreshing={refreshing} onRefresh={refresh} tintColor={C.accent}/>}>
        {(<Notice text={problem}/>) if problem else None}
        {(
            <View style={styles.card}>
                <Text style={styles.sectionTitle}>No runs yet</Text>
                <Text style={styles.note}>The committee meets at 7:30 a.m. New York time on trading days. Its run shows here once it is saved.</Text>
            </View>
        ) if not r and not problem else None}
        {(
            <View style={{"gap": S.md}}>
                <View style={styles.between}>
                    <DayButton icon="back" label="Earlier" day={earlier} onPress={lambda { go(earlier); }}/>
                    <DayButton icon="next" label="Later" day={later} onPress={lambda { go(later); }}/>
                </View>
                <View style={{"gap": S.sm}}>
                    <Text style={styles.eyebrow}>Morning run</Text>
                    <Text style={styles.title}>{day_label(r.run_date)}</Text>
                    <View style={styles.row}>
                        <StatusPill label={status_word(r.status)} tone={tone_of(r.status)}/>
                        {(<Text style={styles.faint}>{clock_span(r.started_at, r.finished_at)}</Text>) if r.finished_at else None}
                    </View>
                </View>
                {(<Notice text="Demo data: an invented run, made by the project's own code."/>) if r.demo else None}
                <Text style={styles.body}>{r.summary or "The run left no summary."}</Text>
                {(<Text style={styles.note}>{f"The risk gate: {r.execution_summary}. The broker: {r.execution_detail}."}</Text>) if r.execution_summary and r.execution_detail else None}
            </View>
        ) if r else None}
        {(
            <View style={[styles.card, {"gap": S.xs}]}>
                <View style={styles.between}>
                    <Text style={styles.note}>Market regime</Text>
                    <Text style={[styles.num, {"fontSize": F.sm, "color": C.accent}]}>{f"{r.macro.regime.replace('_', ' ').lower()}, {percent(r.macro.confidence, 0)} sure"}</Text>
                </View>
                <Text style={styles.note} numberOfLines={4}>{r.macro.summary}</Text>
            </View>
        ) if r and r.macro else None}
        {(
            <View style={styles.section}>
                <SectionHead title="Buys and sells" note={f"{len(acted)} of {len(r.rows)} stocks"}/>
                <View>{[<View key={x.ticker}>{(<View style={styles.rule}/>) if i > 0 else None}<DecisionRow r={x} onOpen={lambda { onOpenTrail(shown_day, x.ticker); }}/></View> for (i, x) in enumerate(acted)]}</View>
            </View>
        ) if r and len(acted) > 0 else None}
        {(
            <View style={styles.section}>
                <SectionHead title="Held" note={f"{len(held)} stocks"}/>
                <View>{[<View key={x.ticker}>{(<View style={styles.rule}/>) if i > 0 else None}<DecisionRow r={x} onOpen={lambda { onOpenTrail(shown_day, x.ticker); }}/></View> for (i, x) in enumerate(held)]}</View>
            </View>
        ) if r and len(held) > 0 else None}
        {(<Text style={styles.faint}>The score is the panel's signed consensus, from -1 (sell) to +1 (buy). Tap a stock for its full trail.</Text>) if r and len(r.rows) > 0 else None}
    </ScrollView>
}
