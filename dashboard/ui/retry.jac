"""Calling a server function again when it lost a database conflict. Requests run in serializable
transactions, so a busy moment can cancel one with nothing saved: the runtime's own retry does
not cover a conflict raised by Postgres, and it reaches the client as a failed call. Other
failures are the caller's to report."""
import from "@jac/runtime" { __jacCallFunction }

glob RETRY_DELAYS_MS: list[int] = [200, 600];

def is_conflict(e: any) -> bool {
    text = str(e);
    return "40001" in text or "write_conflict" in text;
}

def wait_ms(ms: int) -> any {
    return new(Promise, lambda (resolve: any, reject: any) { window.setTimeout(resolve, ms); });
}

async def:pub call_function(name: str, args: dict[str, any], contract: dict[str, str]) -> any {
    for delay in RETRY_DELAYS_MS {
        try {
            return await __jacCallFunction(name, args, contract);
        } except Exception as e {
            if not is_conflict(e) {
                raise e;
            }
        }
        await wait_ms(delay);
    }
    return await __jacCallFunction(name, args, contract);
}
