"""Recent output and scored record for each analysis specialist."""
import from "@jac/runtime" { Link }
import from dashboard.ui.rpc { get_specialists }
import from dashboard.ui.format { count, day_short, pct, title }
import from dashboard.ui.parts { ActionBadge, Empty, ErrorBox, Loading, Panel }
import from models.views { SpecialistSummaryView as SummaryData, SpecialistVoteView as VoteData }

def VoteRow(v: VoteData) -> JsxElement {
    <li className="border-t border-line px-4 py-3 first:border-t-0">
        <div className="flex flex-wrap items-center gap-2 text-[12px]">
            <Link to={"/app/runs/" + v.run_date + "/" + v.ticker} className="font-semibold text-accent hover:underline">{v.ticker + " · " + day_short(v.run_date)}</Link>
            <ActionBadge action={v.stance}/>
            <span className="text-muted">{pct(v.confidence, 0) + " confidence · sample " + str(v.sample + 1)}</span>
            <span className="ml-auto text-muted">{("Hit" if v.hit else "Miss") if v.hit is not None else ("Awaiting score" if not v.scored_at else "No price to score")}</span>
        </div>
        <p className="mt-1 text-[13px] leading-relaxed text-muted">{v.rationale}</p>
    </li>
}

def RoleCard(s: SummaryData) -> JsxElement {
    <Panel title={title(s.specialist)} aside={count(s.votes, "vote") + " across up to 60 recent runs"} pad={False}>
        <div className="border-b border-line px-4 py-3 text-[13px]">
            <span className="font-medium">{pct(s.hit_rate, 0) if s.hit_rate is not None else "Not enough scored votes"}</span>
            <span className="text-muted">{(" hit rate · " + str(s.hits) + "/" + str(s.scored) + " scored directional votes") if s.scored else " · Awaiting scored directional votes"}</span>
        </div>
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
