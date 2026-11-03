import time;
import from agents.models { REQUEST_BUDGET, RequestBudget, RequestLimiter }
import from run.workers { ContextPool }

test "report request ceiling follows network tasks and counts each provider attempt" {
    budget = RequestBudget(remaining=2, deadline=time.monotonic() + 10);
    limiter = RequestLimiter(per_minute=1000000);
    pool = ContextPool(max_workers=2);
    token = REQUEST_BUDGET.set(budget);
    try {
        pool.submit(limiter.acquire, "research", "first_attempt").result();
        pool.submit(limiter.acquire, "research", "parse_retry").result();
        failed = False;
        try { pool.submit(limiter.acquire, "research", "fallback").result(); }
        except RuntimeError { failed = True; }
        assert failed and budget.used == 2 and limiter.sent == 2;
    } finally { REQUEST_BUDGET.reset(token); pool.shutdown(); }
    # A subsequent ordinary run is not constrained by the completed report.
    limiter.acquire();
    assert limiter.sent == 3;
}
