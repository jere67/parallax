"""The run's deadline holds inside its model work (#240).

On 2026-11-12 OpenRouter refused almost every request with a 429 from 8:06, and the team's run
kept calling for two and a half hours: the deadline was read only between the Orchestrator's
steps, and the Run Guard's fixed-order finish read it not at all. Here every request to a local
fake OpenRouter gets a 429, through the real LimitedModel and its limiter, so the run meets the
same refusals."""
import time;
import uuid;
import from agents.models { LimitedModel, ModelChain, PRIMARY_MODEL, RequestLimiter }
import from models.graph { Covers, Decided, Decision, Portfolio, PortfolioMode, Run, RunStatus }
import from run.guard { RunLimits, RunOutcome, daily_run }
import from run.stubs { MACRO_JSON, REPORT_JSON, RUN_DAY, Stubs }
import from tests.fakes.openrouter { FakeOpenRouter }

glob fake: FakeOpenRouter = FakeOpenRouter();
glob BASE: str = fake.start();

def team -> Portfolio {
    found = Portfolio(name=f"test-{uuid.uuid4()}", mode=PortfolioMode.INSIGHT, starting_cash=0.0, opened_at="2026-10-01T00:00:00+00:00");
    root ++> found;
    return found;
}

"""A model whose every request reaches the fake, with the run's retries but no backoff wait."""
def refused_model -> LimitedModel {
    return LimitedModel(
        model_name=PRIMARY_MODEL,
        api_key="test-key",
        config={"base_url": BASE},
        limiter=RequestLimiter(per_minute=60000),
        chain=ModelChain(models=[PRIMARY_MODEL]),
        role="specialist",
        backoff_s=0.0,
        request_timeout_s=5.0
    );
}

"""Run the day with the macro brief and the research answered and every later request refused,
as on 2026-11-12, each answer taking `delay` seconds."""
def refused_run(deadline_s: float, delay: float = 0.05) -> tuple[RunOutcome, float] {
    fake.script = [(200, MACRO_JSON)] + [(200, REPORT_JSON)] * 6 + [(429, "")] * 5000;
    fake.delays = [delay] * 5000;
    fake.requests = [];
    stubs = Stubs(llm=refused_model());
    stubs.install();
    started = time.monotonic();
    try {
        outcome = daily_run(team(), RUN_DAY, None, RunLimits(deadline_s=deadline_s));
    } finally {
        stubs.restore();
    }
    return (outcome, time.monotonic() - started);
}

def decisions_of(run: Run | None) -> list[Decision] {
    assert run is not None;
    return [d for cov in [run ->:Covers:->] for d in [cov ->:Decided:->[?:Decision]]];
}

test "a run whose every request is refused stops at its deadline and says why" {
    (outcome, took) = refused_run(1.0);
    # The panel's refused votes would go on for the whole panel; at the deadline they stop.
    assert took < 2.5, f"the run took {took:.1f}s past a 1s deadline, {len(fake.requests)} requests";
    assert outcome.status == RunStatus.FALLBACK;
    run = outcome.run;
    assert run is not None;
    assert run.summary.startswith("Ran out of time: "), run.summary;
    assert "refusing" in run.summary and "rate limit" in run.summary.lower(), run.summary;
    # Every covered ticker still ends with a decision, a hold with the deadline as its reason.
    decisions = decisions_of(run);
    assert len(decisions) == 2;
    assert all(d.forced_hold_reason for d in decisions);
    assert all("deadline" in d.forced_hold_reason for d in decisions), [d.forced_hold_reason for d in decisions];
}
