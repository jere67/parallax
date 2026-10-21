# Spike #13: Alpaca's order rules on the team paper account

The spike ran in two parts with `tests/spikes/order_rules_spike.jac` on the team paper account.
Part 1 ran on October 20, 2026, at 10:17 p.m. New York time, with the market closed and `SPIKE_PART=closed`.
It placed three 1-share orders on F and canceled all of them.
Part 2 ran on October 21, 2026, from 11:22:36 to 11:22:59 a.m. New York time, with the market open.
It bought and sold 1 to 3 shares of F at about $11.91, through the executor's entry, stop, add, trim, and exit sequences, and a one-triggers-other entry.
After each part the account had no positions and no open orders; part 2 cost $0.02 in spread, leaving equity at $99,999.98.

## Answer

**Every order sequence the executor uses works on Alpaca's paper account as designed, and the executor needs no change.**
Three answers differed from the fake broker, which now matches Alpaca: a one-triggers-other entry is accepted, canceling an order twice succeeds, and a new stop reads `pending_new`.
A one-triggers-other entry cannot replace the separate stop, because its stop leg stays a DAY order after the entry fills and would expire at the close.

### Part 1: rules Alpaca checks at submission (market closed)

| Question | Alpaca paper | The fake before | Change |
| --- | --- | --- | --- |
| Q7. Is a DAY limit buy accepted while the market is closed? | Yes, as `accepted`, waiting for the open | `new` | The fake answers `accepted` while closed |
| Q5. What does a reused `client_order_id` return? | 422 "client_order_id must be unique"; the lookup by client order ID finds the first order | Same | None |
| Q2. Is a sell refused while a buy on the same stock is working? | Yes, 403 "potential wash trade detected. use complex orders" | Same | None |
| Q3. Is a stop sell refused with no shares, while a buy is working? | Yes, 403 wash trade: Alpaca checks the opposite side before the share count | Same | None |
| Q4. Can a one-triggers-other entry attach the stop? | Accepted, `order_class` oto; the stop leg is `time_in_force` day and `held` until the entry fills | Refused with 422 | The fake still refuses order classes, on purpose (below) |
| Q8. What does canceling an already-canceled order return? | Success, the same as the first cancel | 422 | The fake accepts it; `Broker.cancel` returns True |

### Part 2: rules that need fills (market open)

| Question | Alpaca paper | The fake | Change |
| --- | --- | --- | --- |
| Q1. Does a marketable DAY limit buy at the last trade +0.3% fill, and how fast? | Yes: 2 shares, limit $11.94 against a last trade of $11.90, filled at $11.91 in 0.4 seconds; the run's six marketable orders filled 0.41 to 0.70 seconds after submission | Fills at once with `auto_fill` | None |
| Q1. Is a GTC stop sell accepted once the entry fills? | Yes, as `pending_new`; the position's `qty_available` drops to 0 while it works | `accepted` | The fake answers `pending_new` for a stop while open |
| Q2. Is a buy refused while a stop sell is working? | Yes, 403 "potential wash trade detected. use complex orders" | Same | None |
| Q2. Does the add sequence work? | Yes: the stop read `canceled` straight after the cancel, the 1-share add filled, and a stop for all 3 shares was accepted | Same | None |
| Q3. Does a working stop reserve its shares? | Yes, 403 "insufficient qty available for order (requested: 1, available: 0)" | Same | None |
| Q3. Does the trim sequence work? | Yes: cancel the stop, sell 1 (filled at $11.90), and re-place a stop for the 2 shares left | Same | None |
| Q4. After a one-triggers-other entry fills, what time in force has its stop leg? | Still `day`; the leg moves from `held` to `new`, so it would expire at the close | Refused with 422 | None; the fake refuses order classes on purpose |
| Q6. Is a same-day sell after a buy allowed? | Yes: the trim, the exit, and the final sale each sold shares bought minutes earlier, three round trips in one session; the account reports no `pattern_day_trader`, `daytrade_count`, or `daytrading_buying_power` fields, which fits FINRA's replacement of the pattern-day-trader rule, though at $100,000 the account was above the old $25,000 minimum anyway | Same | None |
| Q8. What does canceling a canceled stop return? | Success again, as in part 1 | Same | None |

## What it means for the executor

- **The separate GTC stop stays.**
  A one-triggers-other stop leg is a DAY order before and after the entry fills, so it would expire at the close and leave the position unprotected overnight.
  The executor places its own GTC stop once the entry fills, and the stop keeper re-checks it at every poll.
  The fake refuses order classes, so a change that sends one fails the tests.
- **The add, trim, and exit sequences stand.**
  Alpaca refuses a buy beside a working stop as a wash trade, and refuses a sell of shares a stop reserves, so the executor cancels the stop first, trades, and re-places a stop for the shares then held.
  It reads `qty_available` to size a sell, which Alpaca sets to 0 while a stop works and restores once it is canceled.
- **A position is unprotected for a few seconds during an add or a trim.**
  That window runs from the stop's cancel, through the trade's fill, to the new stop; in the spike it was 3.2 seconds for the add and 3.8 for the trim, including the spike's own extra reads.
  It is the cost of not using order classes.
- **A repeated cancel is harmless.**
  `cancel_and_wait` ignores the cancel's answer and waits for a closed status, so a second cancel cannot stall it.
  During market hours a cancel took effect at once: the order read `canceled` on the first read after the DELETE.
- **Listings lag cancels for a moment.**
  In part 1 the open-orders list taken right after the cancels still showed one order; a minute later the account had none.
  The executor reads each order by ID after a cancel, never from the open list, so it is not affected.
- **Partial fills were not observed.**
  Every order of 1 to 3 shares on F filled in full, so the spike says nothing about how Alpaca reports a partial fill.
  The executor's partial-fill path, a stop for the shares filled once the entry's remainder is canceled at 3:50, is tested only against the fake broker (`tests/runs/action_exit_run_tests.jac`, MSFT filling 10 of 36).
  The live three-day run is the first check of it on Alpaca.
- **Statuses are read as sets, not single values.**
  A new order can read `accepted`, `pending_new`, or `new`, and `WORKING_STATUSES` in `action/broker.jac` includes all three.

## Reproduce

```bash
set -a && source .env && set +a
TRADING_AGENT_RUN_ORDER_SPIKE=1 SPIKE_PART=closed SPIKE_OUT=/tmp/order-spike-closed.json jac run --no-takeover tests/spikes/order_rules_spike.jac   # market closed
TRADING_AGENT_RUN_ORDER_SPIKE=1 SPIKE_OUT=/tmp/order-spike.json jac run --no-takeover tests/spikes/order_rules_spike.jac                            # market open
```

The script refuses to run on an account with positions or open orders, and cancels and sells everything it opened before it ends.
`tests/spikes/order_rules_spike_tests.jac` runs both parts against the fake broker.
