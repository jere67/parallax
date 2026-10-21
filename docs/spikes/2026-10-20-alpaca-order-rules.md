# Spike #13: Alpaca's order rules on the team paper account

Part 1 ran on October 20, 2026, at 10:17 p.m. New York time, with the market closed, by `tests/spikes/order_rules_spike.jac` with `SPIKE_PART=closed`.
It placed three 1-share orders on F on the team paper account and canceled all of them; the account stayed at $100,000.00 with no positions and no open orders.
Part 2 needs fills, so it runs during market hours and is added below when it has run.

## Answer so far

**Every rule the executor relies on that Alpaca checks at submission holds, and the executor needs no change.**
Two answers differed from the fake broker, which now matches Alpaca: a one-triggers-other entry is accepted, and canceling an order twice succeeds.
The one-triggers-other entry cannot replace the separate stop, because its stop leg is a DAY order that would expire at the close.

| Question | Alpaca paper | The fake before | Change |
| --- | --- | --- | --- |
| Q7. Is a DAY limit buy accepted while the market is closed? | Yes, as `accepted`, waiting for the open | `new` | The fake answers `accepted` while closed |
| Q5. What does a reused `client_order_id` return? | 422 "client_order_id must be unique"; the lookup by client order ID finds the first order | Same | None |
| Q2. Is a sell refused while a buy on the same stock is working? | Yes, 403 "potential wash trade detected. use complex orders" | Same | None |
| Q3. Is a stop sell refused with no shares, while a buy is working? | Yes, 403 wash trade: Alpaca checks the opposite side before the share count | Same | None |
| Q4. Can a one-triggers-other entry attach the stop? | Accepted, `order_class` oto; the stop leg is `time_in_force` day and `held` until the entry fills | Refused with 422 | The fake still refuses order classes, on purpose (below) |
| Q8. What does canceling an already-canceled order return? | Success, the same as the first cancel | 422 | The fake accepts it; `Broker.cancel` returns True |

## What it means for the executor

- **The separate GTC stop stays.**
  A one-triggers-other stop leg inherits the entry's DAY time in force, so it would expire at the close and leave the position unprotected overnight.
  The executor places its own GTC stop once the entry fills, and the stop keeper re-checks it at every poll.
  The fake refuses order classes, so a change that sends one fails the tests.
- **The add and exit sequences stand.**
  Alpaca refuses an order on one side while an order on the other side is working, even with the market closed, so the executor still cancels a stop before an add, an exit, or a trim.
- **A repeated cancel is harmless.**
  `cancel_and_wait` ignores the cancel's answer and waits for a closed status, so a second cancel cannot stall it.
- **Listings lag cancels for a moment.**
  The open-orders list taken right after the cancels still showed one order; a minute later the account had none, and both the entry and the one-triggers-other order with its leg read `canceled`.
  The executor reads each order by ID after a cancel, never from the open list, so it is not affected.

## Part 2: rules that need fills

These run during market hours with `SPIKE_PART` unset, on 1 to 3 shares, and the account is flattened at the end:

- Q1. Does a marketable DAY limit buy at the last trade +0.3% fill, and how fast? Is a GTC stop sell accepted once it fills?
- Q2. Does the add sequence work: cancel the stop, buy, and re-place the stop for the whole position?
- Q3. Does a working stop reserve its shares, so a sell is refused until the stop is canceled? Does the trim sequence work?
- Q4. After a one-triggers-other entry fills, what time in force does its stop leg have?
- Q6. Is a same-day sell after a buy allowed on the paper account?

## Reproduce

```bash
set -a && source .env && set +a
TRADING_AGENT_RUN_ORDER_SPIKE=1 SPIKE_PART=closed SPIKE_OUT=/tmp/order-spike-closed.json jac run --no-takeover tests/spikes/order_rules_spike.jac   # market closed
TRADING_AGENT_RUN_ORDER_SPIKE=1 SPIKE_OUT=/tmp/order-spike.json jac run --no-takeover tests/spikes/order_rules_spike.jac                            # market open
```

The script refuses to run on an account with positions or open orders, and cancels and sells everything it opened before it ends.
