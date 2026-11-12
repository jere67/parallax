---
title: Starting a run by hand
description: Start the team agent's morning run after 9:15 a.m., as the admin, when the server was down for the whole morning window.
related:
  - { text: start_morning_run, link: /api/start-morning-run }
  - { text: Authentication, link: /api/authentication }
  - { text: Run Guard, link: /system/run-guard }
---

The team agent's morning run starts by itself at 7:30 a.m. New York time, or at the first minute after that the server is up and awake, until 9:15.
A server that was down or asleep for that whole window has no team run that day.
The admin account can start it later with one request.

This page is about the admin's team agent.
Every other account runs its own agent by itself on a weekday between 7:30 and 9:15 a.m., or when its owner presses **Start today's run** in Settings.
See [Your agent](/guide/your-agent).
The admin can also press that button; it does the same as `start_morning_run`.

## Start the run

You need the admin password, which the server read from `ADMIN_PASSWORD` when it created the admin account.

<Steps>

1. **Sign in as the admin.**
   The login answers with a token.

   ```bash
   TOKEN=$(curl -s localhost:8000/user/login -H 'Content-Type: application/json' \
     -d "{\"identity\":{\"type\":\"username\",\"value\":\"admin\"},\"credential\":{\"type\":\"password\",\"password\":\"$ADMIN_PASSWORD\"}}" \
     | python3 -c 'import sys, json; print(json.load(sys.stdin)["data"]["token"])')
   ```

2. **Ask for the run.**

   ```bash
   curl -s localhost:8000/function/start_morning_run \
     -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{}'
   ```

3. **Wait.**
   The run starts within a minute and takes about 20 minutes.
   Follow it on the dashboard's [Runs page](/guide/dashboard#runs).

</Steps>

A request that is accepted answers like this:

```json
{
  "started": true,
  "run_day": "2026-11-02",
  "message": "The morning run for 2026-11-02 starts within a minute and takes about 20 minutes. The trading tick executes it once it finishes, if the team portfolio is in auto mode."
}
```

## When it trades

In auto mode, the next trading tick executes the run's orders, as long as that happens before the cancel time (3:50 p.m. on a normal day).
After that, the run only publishes its decisions.
In insight mode, it publishes its decisions as insight cards, as usual.

## When it is refused

The request answers with `started: false` and a reason when:

| Reason | Message |
| --- | --- |
| The caller is signed in, but not as the admin | `Only the admin can start a run.` Other accounts start their own run with `start_my_run`. |
| It is a weekend in New York | `2026-11-07 is a weekend; the market is closed.` |
| The team portfolio holds demo history | `The team portfolio holds the demo history, which never runs.` |
| The day's run is working now | `The run for 2026-11-02 is running now.` |
| The day's run has just ended and is not saved yet | `The run for 2026-11-02 has just finished and is being saved.` |
| The day already has a run, including a skipped one or a failed one that decided something | `The run for 2026-11-02 has already started (status: normal).` |

A request without a token never reaches the endpoint: `start_morning_run` is private, so the server rejects it first.
A market holiday is not refused here.
The run starts, finds no trading session, and is recorded as SKIPPED.

## Running a lost day again

A failed run that decided nothing can be run again the same day, with the same request.
That is a run the server could not save, which is recorded as failed with a summary that starts "Lost:" ([Run Guard](/system/run-guard#a-run-the-server-could-not-save)), or one whose data collection failed with no position open.
The new run takes over the same record, and the run's log keeps a line with what the earlier attempt said.
A failed run that decided something, such as a failed collection that held the open positions, is not run again.

While the run is working, the trading tick leaves the team portfolio alone, and the run's orders go out on the first tick after it is saved.

## How it works

The endpoint does not run anything itself.
It leaves a one-time request in the app's token store, valid until midnight in New York, and returns.
A scheduled job, `manual_run_job`, checks for a request every minute, takes it, and runs the morning run in the server's own context, where the team portfolio lives.
Taking the request deletes it, so two servers or two firings can never start two runs.

This design keeps three things true:

- A request from a user's session cannot attach a run to the team portfolio, since the team graph is reachable only from the server's own context.
- It does not depend on dynamic scheduler jobs, which stop after a hot reload in Jac 0.37.12.
- It does not expose the scheduler's job API, which any signed-in user could call.

The [Run Guard](/system/run-guard) still checks everything a scheduled run checks, including the request budget and whether the day already has a run.
