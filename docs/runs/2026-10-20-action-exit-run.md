# Action exit run (#91): three simulated trading days with zero bypasses and zero drift

Run on October 20, 2026, for the trading days of October 21 to 23, by `tests/runs/action_exit_run.jac`, against the fake broker in `tests/fakes/broker_server.jac`.
No key was used and nothing reached Alpaca or OpenRouter.
`tests/runs/action_exit_run_tests.jac` runs the same three days in every `jac test`, so a change that breaks them fails CI.

## Answer

**The simulated part of the Action exit criterion is met.**
Over three consecutive sessions the team portfolio entered, added, stopped out, exited on time stops, and re-entered.
Every evening's reconciliation found zero gate bypasses and zero drift, and the record's positions matched the account's.

The criterion itself is three consecutive days of trading on Alpaca paper with zero gate bypasses (TDD §15).
That live run waits for the team's go-ahead and for hosting (#14).
The order-rule spike (#13) checks the fake broker's rules against the paper account on the morning of October 21.
If the spike finds any rule different, the fake is corrected and this run is repeated.

| Session | Morning run | Decisions | Orders | Close equity | Drawdown | Drift | Bypasses | Record = account |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Wed Oct 21 | normal | BUY AAPL, MSFT, NVDA | 3 entries, 3 stops | 100,217.40 | 0.0% | 0 | 0 | AAPL 36, MSFT 10, NVDA 36 |
| Thu Oct 22 | normal | ADD AAPL, MSFT, NVDA | 1 add, 1 stop replaced, NVDA stop filled | 99,816.20 | 0.4% | 0 | 0 | AAPL 36, MSFT 36 |
| Fri Oct 23 | normal | SELL AAPL, MSFT (time stops), BUY NVDA | 2 exits, 1 entry, 1 stop | 99,816.80 | 0.4% | 0 | 0 | NVDA 38 |

## How the days were simulated

Each morning, the Run Guard ran the whole pipeline on the stubs in `run/stubs.jac`, with a scripted Orchestrator and every specialist voting STRONG_BUY at 0.9 confidence over two sessions.
The trading tick then fired every minute from 9:00 a.m. to 5:00 p.m. New York time on a fake clock, as the scheduled job does.
Prices followed a fixed tape (an open at 9:30, a low at noon, and a close at 4:00), and the script filled orders at set times.
At 4:00 the fake ended the session and canceled any working DAY order, as Alpaca does.

## What each session showed

**Wednesday.**
At 9:00 the forward test started from the flat account: a starting balance of 100,000.00, the team portfolio in auto mode, and both baselines created.
At 9:45 the executor sized each buy at 7.2% of equity (conviction 0.9 times the 8% scale), and the gate approved all three: 36 shares each, as marketable limits at 200.60.
AAPL and NVDA filled in full at 9:46 and got their stops at once, at the fill less two ATRs.
MSFT filled only 10 shares, so its stop waited while the buy was working.
At 3:50 the close window canceled the rest of the MSFT buy and placed a stop for the 10 shares.

**Thursday.**
The panel said ADD on all three, but AAPL and NVDA were already at their targets, so the sizing proposed only 26 more MSFT.
The executor canceled MSFT's stop first (Alpaca rejects a buy while a sell stop is working), bought, and placed one stop for all 36 shares.
At 11:00 NVDA traded at 191.00, below its 192.40 stop, so the stop filled, and the next poll closed the position on the record.

**Friday.**
AAPL's and MSFT's time stops (two sessions after Wednesday) reached the run date, so the panel's draft became SELL for both despite the strong votes.
The executor canceled both stops before selling, since a working stop reserves its shares.
MSFT sold in two fills (20 shares at 9:46, 16 at 10:00), and the record followed each one.
NVDA, no longer held, was bought again: 38 shares with a fresh stop.

## Orders

Every order the account received is traced to a risk check or to a position's stop.

| Client order ID | Side and size | Type | Final status | Filled |
| --- | --- | --- | --- | --- |
| 2026-10-21-AAPL-entry | buy 36 | limit | filled | 36 |
| 2026-10-21-MSFT-entry | buy 36 | limit | canceled at 3:50 | 10 |
| 2026-10-21-NVDA-entry | buy 36 | limit | filled | 36 |
| AAPL-20261021094600-stop1 | sell 36 | stop | canceled for Friday's exit | 0 |
| NVDA-20261021094600-stop1 | sell 36 | stop | filled at 191.00 | 36 |
| MSFT-20261021094600-stop1 | sell 10 | stop | canceled for Thursday's add | 0 |
| 2026-10-22-MSFT-add | buy 26 | limit | filled | 26 |
| MSFT-20261021094600-stop2 | sell 36 | stop | canceled for Friday's exit | 0 |
| 2026-10-23-AAPL-exit | sell 36 | limit | filled | 36 |
| 2026-10-23-MSFT-exit | sell 36 | limit | filled in two parts | 36 |
| 2026-10-23-NVDA-entry | buy 38 | limit | filled | 38 |
| NVDA-20261023094600-stop1 | sell 38 | stop | working | 0 |

## Evening steps

**Vote scoring.**
Wednesday's 45 votes have a two-session window, from Tuesday's close to Thursday's.
Thursday's bars are final only that evening, so Friday's 4:30 tick scored all 45 votes.
The 90 votes from Thursday and Friday are still open.

**Baselines.**
The baselines trade each session once its bars are final, so they ran a session behind the team portfolio.

| Session | Equal-weight shortlist | SPY buy-and-hold |
| --- | --- | --- |
| Wed Oct 21 | 100,240.00: bought 40 AAPL, MSFT, and NVDA at the 200.00 open | 100,400.00: bought 200 SPY at 500.00 |
| Thu Oct 22 | 99,840.00: NVDA stopped out at 192.00 | 99,600.00 |

The equal-weight shortlist bought 40 shares where the team bought 36, because it sizes every pick at conviction 1.

## Reproduce

```bash
TRADING_AGENT_RUN_ACTION_EXIT=1 EXIT_OUT=/tmp/action-exit.json jac run --no-takeover tests/runs/action_exit_run.jac
```

The run takes about 50 seconds from a cold compile and writes each session's tick log, the orders, and the baselines' trades to the JSON file.
