"""A decision's trail: how one stock went from research to an order in one run, step by step,
in the order the run took them."""

import from "@jac/mobui" { View, Text, ScrollView, ActivityIndicator, Pressable }
import from ..theme { C, S, R, F, styles }
import from ..fonts { SERIF }
import from ..api { call }
import from ..views { OrderView, ResearchView, SpecialistView, TrailView }
import from ..format { action_word, clock, day_label, order_word, percent, price, score }
import from ..components.Icon { Icon }
import from ..components.parts { ActionPill, Notice }

"""One step of the trail, numbered, with a line down to the next."""
def Step(n: int, title: str, last: bool = False, children: any = None) -> JsxElement {
    <View style={{"flexDirection": "row", "gap": S.md}}>
        <View style={{"alignItems": "center", "width": 26}}>
            <View style={{"width": 26, "height": 26, "borderRadius": 13, "borderWidth": 1, "borderColor": C.accent, "alignItems": "center", "justifyContent": "center"}}>
                <Text style={{"color": C.accent, "fontSize": F.xs, "fontWeight": "700"}}>{str(n)}</Text>
            </View>
            {(<View style={{"flex": 1, "width": 1, "backgroundColor": C.line, "marginVertical": S.xs}}/>) if not last else None}
        </View>
        <View style={{"flex": 1, "gap": S.sm, "paddingBottom": S.xl if not last else 0}}>
            <Text style={[styles.sectionTitle, {"lineHeight": 26}]}>{title}</Text>
            {children}
        </View>
    </View>
}

def view_word(view: str) -> str {
    return view.replace("_", " ").lower();
}

def ResearchLine(r: ResearchView) -> JsxElement {
    <View style={{"gap": 4}}>
        <View style={styles.between}>
            <Text style={{"color": C.text, "fontSize": F.sm, "fontWeight": "600"}}>{r.domain[0].upper() + r.domain[1:]}</Text>
            <Text style={[styles.num, {"fontSize": F.xs, "color": C.muted}]}>{f"{view_word(r.view)}, {percent(r.confidence, 0)} sure"}</Text>
        </View>
        <Text style={styles.note}>{r.summary}</Text>
        {(<Text style={styles.faint}>{f"{len(r.evidence)} cited {'source' if len(r.evidence) == 1 else 'sources'}"}</Text>) if len(r.evidence) > 0 else None}
    </View>
}

"""A specialist's vote as a bar from the center: right for buy, left for sell."""
def VoteBar(s: SpecialistView) -> JsxElement {
    voted = s.status == "voted";
    width = min(abs(s.score), 1.0) * 50;
    color = C.up if s.score > 0 else C.down;
    <View style={{"flexDirection": "row", "alignItems": "center", "gap": S.sm}}>
        <Text style={{"color": C.text if voted else C.faint, "fontSize": F.sm, "width": 92}}>{s.specialist[0].upper() + s.specialist[1:]}</Text>
        <View style={{"flex": 1, "height": 8, "borderRadius": 4, "backgroundColor": C.hover, "flexDirection": "row"}}>
            <View style={{"width": "50%", "alignItems": "flex-end"}}>
                {(<View style={{"width": f"{width * 2}%", "height": 8, "borderTopLeftRadius": 4, "borderBottomLeftRadius": 4, "backgroundColor": color}}/>) if voted and s.score < 0 else None}
            </View>
            <View style={{"width": 1, "height": 8, "backgroundColor": C.lineStrong}}/>
            <View style={{"flex": 1}}>
                {(<View style={{"width": f"{width * 2}%", "height": 8, "borderTopRightRadius": 4, "borderBottomRightRadius": 4, "backgroundColor": color}}/>) if voted and s.score > 0 else None}
            </View>
        </View>
        <Text style={[styles.num, {"fontSize": F.xs, "width": 64, "textAlign": "right", "color": C.text if voted else C.faint}]}>{score(s.score) if voted else s.status.replace("_", " ")}</Text>
    </View>
}

def OrderLine(o: OrderView) -> JsxElement {
    done = o.status == "filled";
    what = f"{'Buy' if o.side == 'buy' else 'Sell'} {o.qty} {o.ticker}" + (", protective stop" if o.purpose == "stop" else "");
    <View style={{"gap": 2}}>
        <View style={styles.between}>
            <Text style={{"color": C.text, "fontSize": F.sm, "fontWeight": "600"}}>{what}</Text>
            <Text style={{"color": C.up if done else (C.down if o.reject_reason else C.muted), "fontSize": F.xs, "fontWeight": "600"}}>{order_word(o.status)}</Text>
        </View>
        <Text style={styles.faint}>{(f"Filled {o.filled_qty} at {price(o.filled_avg_price)}, " if done else "") + f"sent {clock(o.submitted_at)}"}</Text>
        {(<Text style={[styles.faint, {"color": C.down}]}>{o.reject_reason}</Text>) if o.reject_reason else None}
    </View>
}

def:pub Trail(server: str, token: str, day: str, ticker: str, onBack: Callable[[], None], onSignedOut: Callable[[], None], onOpen: Callable[[str, str], None]) -> JsxElement {
    has trail: TrailView | None = None,
        loading: bool = True,
        problem: str = "";

    async can with (day, ticker) entry {
        loading = True;
        problem = "";
        if not day {
            trail = None;
            problem = "This position has no decision on record.";
            loading = False;
            return;
        }
        got = await call(server, token, "get_decision_trail", {"run_date": day, "ticker": ticker});
        if got.signed_out {
            onSignedOut();
            return;
        }
        if not got.ok {
            problem = got.problem;
        } elif not got.data {
            problem = f"No decision for {ticker} on {day_label(day)}.";
        }
        trail = got.data as TrailView if got.ok and got.data else None;
        loading = False;
    }

    t = trail;
    run_day = t.run_date if t else day;
    d = t.decision if t else None;
    c = t.consensus if t else None;
    g = t.gate if t else None;
    <View style={styles.screen}>
        <View style={{"flexDirection": "row", "alignItems": "center", "justifyContent": "space-between", "paddingHorizontal": S.lg, "paddingVertical": S.sm, "borderBottomWidth": 1, "borderBottomColor": C.line}}>
            <Pressable onPress={onBack} hitSlop={12} style={{"flexDirection": "row", "alignItems": "center", "gap": 6, "paddingVertical": S.xs}}>
                <Icon name="back" size={20} color={C.accent}/>
                <Text style={{"color": C.accent, "fontSize": F.md}}>Back</Text>
            </Pressable>
            <Text style={styles.faint}>{day_label(day)}</Text>
        </View>
        {(<View style={{"flex": 1, "justifyContent": "center"}}><ActivityIndicator color={C.accent}/></View>) if loading else (
            <ScrollView style={styles.scroll} contentContainerStyle={styles.content}>
                {(<Notice text={problem}/>) if problem else None}
                {(
                    <View style={{"gap": S.sm}}>
                        <View style={styles.between}>
                            <Text style={{"color": C.text, "fontFamily": SERIF, "fontSize": 44, "lineHeight": 50}}>{t.ticker}</Text>
                            {(<ActionPill action={d.action}/>) if d else None}
                        </View>
                        <Text style={styles.note}>{f"{t.sector}. " + ("From the screen" if t.reason == "screen" else ("Held, reviewed" if t.reason == "held" else "Flagged")) + (f", last close {price(t.last_close)}." if t.last_close else ".")}</Text>
                        {(<Text style={styles.body}>{d.thesis}</Text>) if d and d.thesis else None}
                        {(<Notice text="Demo data: an invented decision, made by the project's own code."/>) if t.demo else None}
                    </View>
                ) if t else None}
                {(
                    <View>
                        <Step n={1} title="Research">
                            {[<ResearchLine key={r.domain} r={r}/> for r in t.research]}
                            {(<Text style={styles.note}>No research was saved for this stock.</Text>) if len(t.research) == 0 else None}
                        </Step>
                        <Step n={2} title="The panel votes">
                            <View style={{"gap": S.sm}}>{[<VoteBar key={s.specialist} s={s}/> for s in t.specialists]}</View>
                        </Step>
                        <Step n={3} title="Consensus">
                            {(<Text style={styles.note}>{f"Score {score(c.score)}, with {percent(c.agreement, 0)} of the votes agreeing (likely range {score(c.ci_low)} to {score(c.ci_high)}). The rule drafts: {action_word(c.draft_action)}."}</Text>) if c else <Text style={styles.note}>No consensus: the panel did not vote.</Text>}
                        </Step>
                        <Step n={4} title="The Arbiter decides">
                            {(
                                <View style={{"gap": S.xs}}>
                                    <Text style={styles.note}>{f"{action_word(d.action)} at {percent(d.conviction, 0)} conviction. Verdict: {d.arbiter_verdict.lower() or 'none'}."}</Text>
                                    {(<Text style={[styles.note, {"color": C.warn}]}>{d.downgrade_reason}</Text>) if d.downgrade_reason else None}
                                    {(<Text style={[styles.note, {"color": C.warn}]}>{d.forced_hold_reason}</Text>) if d.forced_hold_reason else None}
                                    {(<Text style={styles.faint}>{f"Exit: {d.exit_condition}"}</Text>) if d.exit_condition else None}
                                </View>
                            ) if d else <Text style={styles.note}>No decision was saved.</Text>}
                        </Step>
                        <Step n={5} title="The risk gate">
                            {(
                                <View style={{"gap": S.xs}}>
                                    <Text style={styles.note}>{f"{g.outcome[0].upper() + g.outcome[1:]}: {g.approved_qty} of {g.requested_qty} shares."}</Text>
                                    {[
                                        <View key={x.rule} style={{"flexDirection": "row", "gap": S.sm, "alignItems": "flex-start"}}>
                                            <Icon name={"check" if x.passed else "x"} size={15} color={C.up if x.passed else C.down}/>
                                            <Text style={[styles.faint, {"flex": 1, "color": C.muted}]}>{x.rule + (f": {x.detail}" if x.detail else "")}</Text>
                                        </View> for x in g.rules
                                    ]}
                                </View>
                            ) if g else <Text style={styles.note}>Nothing went to the gate: the decision was to hold.</Text>}
                        </Step>
                        <Step n={6} title="The order" last={True}>
                            <View style={{"gap": S.md}}>{[<OrderLine key={o.client_order_id} o={o}/> for o in t.orders]}</View>
                            {(<Text style={styles.note}>No order was sent.</Text>) if len(t.orders) == 0 else None}
                        </Step>
                    </View>
                ) if t else None}
                {(
                    <View style={{"gap": S.sm}}>
                        <Text style={styles.note}>{f"Other stocks on {day_label(t.run_date)}"}</Text>
                        <View style={{"flexDirection": "row", "flexWrap": "wrap", "gap": S.sm}}>
                            {[
                                <Pressable key={x} onPress={lambda { onOpen(run_day, x); }} style={{"paddingHorizontal": S.md, "paddingVertical": 6, "borderRadius": R.pill, "borderWidth": 1, "borderColor": C.accent if x == t.ticker else C.line, "backgroundColor": C.accentSoft if x == t.ticker else "transparent"}}>
                                    <Text style={{"color": C.accent if x == t.ticker else C.muted, "fontSize": F.xs, "fontWeight": "600"}}>{x}</Text>
                                </Pressable> for x in t.tickers
                            ]}
                        </View>
                    </View>
                ) if t and len(t.tickers) > 1 else None}
                {(<Text style={styles.faint}>{t.disclaimer}</Text>) if t and t.disclaimer else None}
            </ScrollView>
        )}
    </View>
}
