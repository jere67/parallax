---
title: Policies and the assistant
description: Say when to buy, sell, trim, and hold, try it against the latest run, and shape it in plain English.
related:
  - { text: The consensus, link: /system/consensus }
  - { text: Policy endpoints, link: /api/policy }
---

A policy says when to buy, sell, trim, and hold, and sets the limits a run sizes and gates with.
The Policy page shows one in plain English, with what it would have done in the latest morning run.

## Whose policy

| Policy | Who can read it | Who can change it | What it does |
| --- | --- | --- | --- |
| The team's | Anyone | The admin | Decides every morning run from the next one on |
| Your own | You | You | Shows what it would have done; places no orders |

A run keeps the version it was decided with, even if the policy changes before its orders are placed.
Every save is a new version, so any earlier one can be restored.

## Numbers and rules

The numbers are the decision rule's thresholds, sizing, and the risk gate's limits.
Each one has a hard limit no policy can loosen, so a save past one is refused whoever sends it.

A rule tests up to five figures, all of which must hold, and has one effect:

| Effect | What it does |
| --- | --- |
| Don't buy or add when | Blocks a buy or an add |
| Buy or add only when | Allows a buy or an add only then |
| Keep a held stock when | Holds a position the thresholds or its time stop would sell or trim |
| Trim a held stock when | Sells part of a held position |
| Sell a held stock when | Exits a held position |

Exit rules act last, so risk can always come off.
A rule on a figure a stock does not have is skipped, and the page says so.
The figures are the panel's scores, price indicators, the market's regime, and for a held stock its return and age.

## Trying a draft

The page replays the latest run under your draft as you edit it, from what that run stored, so it costs no model request and places no order.
A replay shows which decisions would differ from the team's and why.
A buy the team's rule did not propose never reached the Arbiter, so the replay marks it as unreviewed.

## The assistant

Sign in and ask it something, such as "why didn't this policy buy AAPL?" or "don't buy anything with RSI above 70".

When you ask for a change, it proposes one, and code checks it against the same limits as the form.
You see what would change and what it would have done in the latest run, and nothing is saved until you apply it.
A proposal goes out of date if the policy changes first, so it can never overwrite a newer version unseen.

It answers from the free model chain, so a reply can take up to a minute.
Each user has 20 messages a day, a message that fails does not count, and the assistant pauses while a morning run is using the models.
