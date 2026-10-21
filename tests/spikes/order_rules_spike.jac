"""Spike #13: how Alpaca's paper account treats the executor's order sequences (TDD §8, stops
and adds; GAP-16).

It places real paper orders of one to three shares on the team paper account, so it runs
only when asked, while the market is open, and only on an account with no positions or
open orders; it closes everything it opened before it ends:

    set -a && source .env && set +a
    TRADING_AGENT_RUN_ORDER_SPIKE=1 SPIKE_OUT=/tmp/order-spike.json jac run --no-takeover tests/spikes/order_rules_spike.jac

With SPIKE_PART=closed it runs, while the market is closed, only the checks Alpaca makes when
an order is submitted: a reused client order ID, an opposite-side order while a buy is
working, a stop with no shares, and a one-triggers-other entry. Nothing can fill, and it
cancels every order it placed before it ends.

Every step records what was sent and what Alpaca answered. Findings:
docs/spikes/2026-10-20-alpaca-order-rules.md.
"""
import json;
import os;
import time;
import from datetime { datetime, timezone }
import from pathlib { Path }
import from action.broker { Broker, BrokerError, BrokerOrder, OrderRequest }
import from research.alpaca { latest_trades }
import from research.collector { run_budget }

glob RUN_ENV: str = "TRADING_AGENT_RUN_ORDER_SPIKE";
# A liquid stock near $10, so each step risks a few dollars at most.
glob SYMBOL: str = "F";
# Marketable limit offset (TDD §8, order type).
glob OFFSET: float = 0.003;
glob FILL_WAIT_S: float = 60.0;

obj Step {
    has name: str,
        question: str;
    has sent: dict[str, str] = {},
        status: int = 200,
        message: str = "",
        orders: list[dict[str, str | int | float | None]] = [],
        position: dict[str, str | int | float] = {},
        seconds: float = 0.0,
        note: str = "";
}

def snap(o: BrokerOrder) -> dict[str, str | int | float | None] {
    return {
        "client_order_id": o.client_order_id,
        "side": o.side,
        "type": o.order_type,
        "time_in_force": o.time_in_force,
        "order_class": o.order_class,
        "qty": o.qty,
        "filled_qty": o.filled_qty,
        "filled_avg_price": o.filled_avg_price,
        "limit_price": o.limit_price,
        "stop_price": o.stop_price,
        "status": o.status,
        "submitted_at": o.submitted_at,
        "filled_at": o.filled_at,
        "legs": json.dumps([{"type": l.order_type, "time_in_force": l.time_in_force, "status": l.status, "stop_price": l.stop_price} for l in o.legs])
    };
}

obj Spike {
    has broker: Broker,
        tag: str;
    has steps: list[Step] = [],
        out: Path = Path("order-spike.json"),
        started: str = "";

    def cid(name: str) -> str {
        return f"spike13-{self.tag}-{name}";
    }

    def price -> float {
        (trades, _gaps) = latest_trades([SYMBOL], run_budget());
        return trades[0].price;
    }

    def position -> dict[str, str | int | float] {
        held = self.broker.positions().get(SYMBOL);
        return {"qty": held.qty, "qty_available": held.qty_available, "avg_entry_price": held.avg_entry_price} if held is not None else {"qty": 0};
    }

    def save {
        self.out.write_text(json.dumps({"started": self.started, "symbol": SYMBOL, "steps": [_step_json(s) for s in self.steps]}, indent=1));
    }

    """Submit `request` as step `name`, recording Alpaca's answer, and wait for a fill when
    `wait_fill`. Returns the order, or None when Alpaca refused it."""
    def place(name: str, question: str, request: OrderRequest, wait_fill: bool = False) -> BrokerOrder | None {
        step = Step(name=name, question=question, sent={k: str(v) for (k, v) in request.body().items()});
        clock = time.monotonic();
        placed: BrokerOrder | None = None;
        try {
            placed = self.broker.submit(request);
            if wait_fill {
                placed = self.wait_fill(placed);
            }
            step.orders = [snap(placed)];
        } except BrokerError as e {
            (step.status, step.message) = (e.status, e.detail);
        }
        step.seconds = round(time.monotonic() - clock, 2);
        step.position = self.position();
        self.steps.append(step);
        self.save();
        return placed;
    }

    def wait_fill(o: BrokerOrder) -> BrokerOrder {
        deadline = time.monotonic() + FILL_WAIT_S;
        seen = o;
        while seen.working() and time.monotonic() < deadline {
            time.sleep(0.5);
            seen = self.broker.order(o.id);
        }
        return seen;
    }

    def cancel(name: str, question: str, o: BrokerOrder | None) -> BrokerOrder | None {
        if o is None {
            return None;
        }
        step = Step(name=name, question=question, sent={"cancel": o.client_order_id});
        clock = time.monotonic();
        accepted = self.broker.cancel(o.id);
        first = self.broker.order(o.id);
        closed = self.broker.cancel_and_wait(o.id) if accepted else first;
        step.seconds = round(time.monotonic() - clock, 2);
        step.orders = [snap(first), snap(closed)];
        step.note = f"cancel accepted: {accepted}; status right after the DELETE: {first.status}";
        step.position = self.position();
        self.steps.append(step);
        self.save();
        return closed;
    }

    def note(name: str, question: str, text: str) {
        self.steps.append(Step(name=name, question=question, note=text, position=self.position()));
        self.save();
    }

    def buy(qty: int, name: str) -> OrderRequest {
        return OrderRequest(symbol=SYMBOL, side="buy", qty=qty, order_type="limit", time_in_force="day", client_order_id=self.cid(name), limit_price=round(self.price() * (1 + OFFSET), 2));
    }

    def sell(qty: int, name: str) -> OrderRequest {
        return OrderRequest(symbol=SYMBOL, side="sell", qty=qty, order_type="limit", time_in_force="day", client_order_id=self.cid(name), limit_price=round(self.price() * (1 - OFFSET), 2));
    }

    def stop(qty: int, name: str, below: float = 0.1) -> OrderRequest {
        return OrderRequest(symbol=SYMBOL, side="sell", qty=qty, order_type="stop", time_in_force="gtc", client_order_id=self.cid(name), stop_price=round(self.price() * (1 - below), 2));
    }

    """Cancel every working order on the spike's symbol and sell what it holds."""
    def flatten(name: str) {
        for o in self.broker.orders("open", [SYMBOL]) {
            self.broker.cancel_and_wait(o.id);
        }
        held = self.broker.positions().get(SYMBOL);
        if held is not None and held.qty > 0 {
            sold = self.place(name, "Close the spike's position.", self.sell(held.qty, name), wait_fill=True);
            if sold is None or sold.status != "filled" {
                if sold is not None {
                    self.broker.cancel_and_wait(sold.id);
                }
                left = self.broker.positions().get(SYMBOL);
                if left is not None and left.qty > 0 {
                    self.place(f"{name}-market", "Close the rest at market.", OrderRequest(symbol=SYMBOL, side="sell", qty=left.qty, order_type="market", time_in_force="day", client_order_id=self.cid(f"{name}-market")), wait_fill=True);
                }
            }
        }
        self.note(f"{name}-check", "Is the account flat on the spike's symbol?", f"open orders: {len(self.broker.orders('open', [SYMBOL]))}; positions: {list(self.broker.positions())}");
    }

    """The checks Alpaca makes at submission, on a flat account while the market is closed, so
    nothing fills. Every order placed is canceled before it returns."""
    def run_closed {
        account = self.broker.account();
        if self.broker.clock().is_open {
            self.note("preflight", "Is the market closed?", "open; run the full spike instead");
            return;
        }
        if self.broker.positions() or self.broker.orders("open") {
            self.note("preflight", "Is the account untouched?", "the account has positions or open orders; the spike does not touch an account in use");
            return;
        }
        self.note("preflight", "Account and market", f"paper account {account.number[:4]}..., equity {account.equity:.2f}, market closed, last trade {self.price():.2f}");
        try {
            queued = self.place("closed-entry", "Q7: is a DAY limit buy accepted while the market is closed, and in what status?", self.buy(1, "closed-entry"));
            step = Step(name="closed-reuse-id", question="Q5: what does a reused client_order_id return while the first order is queued?");
            try {
                self.broker._object("POST", "/v2/orders", payload=self.buy(1, "closed-entry").body(), retry=False);
                step.note = "accepted: a reused ID was NOT refused";
            } except BrokerError as e {
                (step.status, step.message) = (e.status, e.detail);
            }
            found = self.broker.order_by_client_id(self.cid("closed-entry"));
            step.orders = [snap(found)] if found is not None else [];
            step.position = self.position();
            self.steps.append(step);
            self.save();
            self.place("closed-opposite-sell", "Q2: is a sell refused while a buy on the same stock is working (wash-trade protection)?", self.sell(1, "closed-opposite-sell"));
            self.place("closed-stop-no-shares", "Q3: is a GTC stop sell refused when the account holds no shares?", self.stop(1, "closed-stop-no-shares"));
            oto = OrderRequest(symbol=SYMBOL, side="buy", qty=1, order_type="limit", time_in_force="day", client_order_id=self.cid("closed-oto"), limit_price=round(self.price() * (1 + OFFSET), 2), stop_loss_price=round(self.price() * 0.9, 2));
            self.place("closed-oto", "Q4: is a one-triggers-other entry with a stop leg accepted, and with what time in force?", oto);
            canceled = self.cancel("closed-cancel", "Q8: how fast does a queued order cancel?", queued);
            if canceled is not None {
                self.note("cancel-twice", "What does canceling a closed order return?", f"cancel accepted: {self.broker.cancel(canceled.id)}");
            }
        } finally {
            self.flatten("closed-final");
        }
        self.note("account-after", "Account after the spike", f"equity {self.broker.account().equity:.2f}");
    }

    def run {
        account = self.broker.account();
        if not self.broker.clock().is_open {
            self.note("preflight", "Is the market open?", "closed; the spike needs live fills");
            return;
        }
        if self.broker.positions() or self.broker.orders("open") {
            self.note("preflight", "Is the account untouched?", "the account has positions or open orders; the spike does not touch an account in use");
            return;
        }
        self.note("preflight", "Account and market", f"paper account {account.number[:4]}..., equity {account.equity:.2f}, last trade {self.price():.2f}");

        # Q6 and the entry: a marketable limit buy fills, then a same-day exit is allowed (below).
        opened = self.place("entry", "Q1: does a marketable DAY limit buy at the last trade +0.3% fill, and how fast?", self.buy(2, "entry"), wait_fill=True);
        if opened is None or opened.filled_qty == 0 {
            self.flatten("abort");
            return;
        }
        # Q5: a reused client order ID.
        step = Step(name="reuse-id", question="Q5: what does a reused client_order_id return, and does the lookup find the first order?");
        try {
            self.broker._object("POST", "/v2/orders", payload=self.buy(1, "entry").body(), retry=False);
            step.note = "accepted: a reused ID was NOT refused";
        } except BrokerError as e {
            (step.status, step.message) = (e.status, e.detail);
        }
        found = self.broker.order_by_client_id(self.cid("entry"));
        step.orders = [snap(found)] if found is not None else [];
        self.steps.append(step);

        # Q1: the stop after the fill.
        stop1 = self.place("stop-after-fill", "Q1: is a GTC stop sell for the filled shares accepted after the entry fills?", self.stop(2, "stop1"));
        # Q2: an add while the stop is working.
        add_blocked = self.place("add-with-stop", "Q2: is a buy refused while a stop sell is working (wash-trade protection)?", self.buy(1, "add-with-stop"), wait_fill=True);
        if add_blocked is not None and add_blocked.working() {
            self.broker.cancel_and_wait(add_blocked.id);
        }
        # Q3: an exit while the stop reserves the shares.
        exit_blocked = self.place("exit-with-stop", "Q3: is a sell refused while a stop reserves the shares?", self.sell(1, "exit-with-stop"), wait_fill=True);
        if exit_blocked is not None and exit_blocked.working() {
            self.broker.cancel_and_wait(exit_blocked.id);
        }
        # Q2: the add sequence.
        self.cancel("add-cancel-stop", "Q2: canceling the stop before an add", stop1);
        added = self.place("add", "Q2: does the add buy fill once the stop is canceled?", self.buy(1, "add"), wait_fill=True);
        if added is not None and added.working() {
            self.broker.cancel_and_wait(added.id);
        }
        held = int(self.position()["qty"]);
        stop2 = self.place("add-restop", "Q2: is the stop re-placed for the whole position?", self.stop(held, "stop2"));
        # Q3: the trim sequence.
        self.cancel("trim-cancel-stop", "Q3: canceling the stop before a trim", stop2);
        trimmed = self.place("trim", "Q3 and Q6: does a same-day sell fill once the stop is canceled?", self.sell(1, "trim"), wait_fill=True);
        if trimmed is not None and trimmed.working() {
            self.broker.cancel_and_wait(trimmed.id);
        }
        left = int(self.position()["qty"]);
        stop3: BrokerOrder | None = None;
        if left > 0 {
            stop3 = self.place("trim-restop", "Q3: is the stop re-placed for the shares left?", self.stop(left, "stop3"));
        }
        # A canceled order cannot be canceled again.
        closed = self.cancel("exit-cancel-stop", "Q3: canceling the stop before the exit", stop3);
        if closed is not None {
            again = self.broker.cancel(closed.id);
            self.note("cancel-twice", "What does canceling a closed order return?", f"cancel accepted: {again}");
        }
        self.flatten("exit");

        # Q4: one-triggers-other, on a flat account.
        oto = OrderRequest(symbol=SYMBOL, side="buy", qty=1, order_type="limit", time_in_force="day", client_order_id=self.cid("oto"), limit_price=round(self.price() * (1 + OFFSET), 2), stop_loss_price=round(self.price() * 0.9, 2));
        placed = self.place("oto", "Q4: can a one-triggers-other entry attach the stop, and with what time in force?", oto, wait_fill=True);
        if placed is not None {
            time.sleep(2.0);
            seen = self.broker.order(placed.id);
            self.steps.append(Step(name="oto-after-fill", question="Q4: the stop leg after the entry fills", orders=[snap(seen)] + [snap(l) for l in seen.legs], position=self.position()));
            self.save();
        }
        self.flatten("final");
        self.note("account-after", "Account after the spike", f"equity {self.broker.account().equity:.2f}");
    }
}

def _step_json(s: Step) -> dict[str, object] {
    return {"name": s.name, "question": s.question, "sent": s.sent, "status": s.status, "message": s.message, "orders": s.orders, "position": s.position, "seconds": s.seconds, "note": s.note};
}

with entry {
    if os.environ.get(RUN_ENV) == "1" {
        now = datetime.now(timezone.utc);
        spike = Spike(broker=Broker(), tag=now.strftime("%Y%m%d%H%M%S"), out=Path(os.environ.get("SPIKE_OUT", "order-spike.json")), started=now.isoformat());
        try {
            if os.environ.get("SPIKE_PART") == "closed" {
                spike.run_closed();
            } else {
                spike.run();
            }
        } except Exception as e {
            spike.note("error", "The spike stopped", f"{type(e).__name__}: {e}");
            spike.flatten("cleanup");
            raise e;
        }
    }
}
