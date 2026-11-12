"""Recent output and scored record for each analysis specialist. The hit rate and the calibration
bands are the stored evaluation's, as on the Results page; a figure with too few scored votes behind
it says so (dashboard/ui/evidence.jac)."""
import from "@jac/runtime" { Link }
import from dashboard.ui.rpc { get_specialists }
import from dashboard.ui.format { count, day_short, pct, title }
import from dashboard.ui.parts { ActionBadge, Empty, ErrorBox, Loading, Panel }
import from dashboard.ui.evidence { Thin, enough, votes_needed }
import from models.views { CalibrationBinView as BinData, SpecialistSummaryView as SummaryData, SpecialistVoteView as VoteData }

def CalibrationRow(b: BinData) -> JsxElement {
    if not enough(b.count, votes_needed()) {
        return <li className="grid gap-2 border-t border-line/60 px-4 py-2.5 first:border-t-0 sm:grid-cols-[90px_1fr] sm:items-center">
            <span className="num text-[12px] text-muted">{pct(b.low, 0) + " to " + pct(b.high, 0)}</span>
            <Thin have={b.count} need={votes_needed()} unit="votes" className="num text-[12px]"/>
        </li>;
    }
    <li className="grid gap-2 border-t border-line/60 px-4 py-2.5 first:border-t-0 sm:grid-cols-[90px_1fr_1fr_52px] sm:items-center">
        <span className="num text-[12px] text-muted">{pct(b.low, 0) + " to " + pct(b.high, 0)}</span>
        <div className="flex items-center gap-2">
            <span className="w-16 text-[11px] text-muted">Confidence</span>
            <span className="h-1.5 flex-1 rounded-full bg-line"><span className="block h-full rounded-full bg-accent" style={{"width": pct(b.mean_confidence, 0)}}></span></span>
            <span className="num w-9 text-right text-[11px]">{pct(b.mean_confidence, 0)}</span>
        </div>
        <div className="flex items-center gap-2">
            <span className="w-12 text-[11px] text-muted">Hit rate</span>
            <span className="h-1.5 flex-1 rounded-full bg-line"><span className="block h-full rounded-full bg-up" style={{"width": pct(b.hit_rate, 0)}}></span></span>
            <span className="num w-9 text-right text-[11px]">{pct(b.hit_rate, 0)}</span>
        </div>
        <span className="num text-[11px] text-faint sm:text-right">{count(b.count, "vote")}</span>
    </li>
}

def VoteRow(v: VoteData) -> JsxElement {
    <li className="border-t border-line px-4 py-3 first:border-t-0">
        <div className="flex flex-wrap items-center gap-2 text-[12px]">
            <Link to={"/app/runs/" + v.run_date + "/" + v.ticker} className="font-semibold text-accent hover:underline">{v.ticker + " · " + day_short(v.run_date)}</Link>
            <ActionBadge action={v.stance}/>
            <span className="text-muted">{pct(v.confidence, 0) + " confidence · sample " + str(v.sample + 1)}</span>
            <span className="ml-auto text-muted">{("Hit" if v.hit else "Miss") if v.hit is not None else ("Awaiting score" if not v.scored_at else "No price to score")}</span>
        </div>
        <p className="mt-1 line-clamp-3 text-[13px] leading-relaxed text-muted">{v.rationale}</p>
    </li>
}

def RoleCard(s: SummaryData) -> JsxElement {
    <Panel title={title(s.specialist)} aside={count(s.votes, "vote") + " in the last " + count(s.runs, "run")} pad={False}>
        <div className="flex flex-col gap-1 border-b border-line px-4 py-3 text-[13px]">
            {if enough(s.evaluated, votes_needed()) {
                <p className="num">
                    <span className="font-medium">{pct(s.evaluated_hit_rate, 0) + " hit rate"}</span>
                    <span className="text-muted">{" (" + pct(s.evaluated_lo, 0) + " to " + pct(s.evaluated_hi, 0) + ") over " + count(s.evaluated, "scored directional vote") + " since the start"}</span>
                </p>
            } elif s.evaluated > 0 {
                <p className="num"><Thin have={s.evaluated} need={votes_needed()} unit="scored votes for a hit rate" className="text-text"/></p>
            } else {
                <p className="text-muted">No hit rate yet. Votes are scored when their window closes, usually ten sessions after the run.</p>
            }}
            {if s.scored {
                <p className="num text-[12px] text-muted">{"In the last " + count(s.runs, "run") + ": " + str(s.hits) + " of " + count(s.scored, "scored vote") + " right."}</p>
            }}
        </div>
        <details className="border-b border-line">
            <summary className="cursor-pointer px-4 py-3 text-[13px] font-medium">Calibration · confidence versus hit rate</summary>
            <p className="px-4 pb-2 text-[12px] text-muted">{"Scored directional votes only. Each row compares average stated confidence with the share that beat SPY in the predicted direction, once the band has " + str(votes_needed()) + " votes." + ((" From evaluation snapshot " + s.snapshot + ".") if s.snapshot else "")}</p>
            {if len(s.calibration) == 0 {
                <p className="px-4 pb-4 text-[12px] text-muted">No scored votes for calibration yet.</p>
            } else {
                <ol className="border-t border-line">{for b in s.calibration { <CalibrationRow key={str(b.low)} b={b}/> }}</ol>
            }}
        </details>
        {if len(s.recent) == 0 {
            <p className="px-4 py-4 text-[13px] text-muted">No votes recorded yet.</p>
        } else {
            <ol>{for v in s.recent { <VoteRow key={v.run_date + v.ticker + str(v.sample)} v={v}/> }}</ol>
        }}
    </Panel>
}

def:pub SpecialistsPage -> JsxElement {
    has roles: list[SummaryData] = [], loaded: bool = False, error: str = "";

    async can with entry {
        try { roles = await get_specialists(); }
        except Exception as e { error = str(e); }
        loaded = True;
    }

    if error { return <ErrorBox message={error}/>; }
    if not loaded { return <Loading label="Loading specialists"/>; }
    if len(roles) == 0 { return <Empty title="No specialists">No specialist roles are available.</Empty>; }

    <div className="rise space-y-6">
        <header>
            <p className="text-[11px] font-medium uppercase tracking-[0.05em] text-faint">Analysis panel</p>
            <h1 className="display mt-1 text-3xl">Specialists</h1>
            <p className="mt-2 max-w-2xl text-[13px] text-muted">Recent votes from the five roles. Hit rate compares scored directional votes with SPY over each vote's horizon; open, hold, and unscorable votes are excluded.</p>
        </header>
        <div className="space-y-4">
            {for s in roles { <RoleCard key={s.specialist} s={s}/> }}
        </div>
    </div>
}
