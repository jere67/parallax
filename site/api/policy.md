---
title: Policy endpoints
description: Read the team policy, try a draft against a stored run, keep your own policy, and talk to the policy assistant.
related:
  - { text: Policies and the assistant, link: /guide/policies }
  - { text: Authentication, link: /api/authentication }
---

Every endpoint is a `POST` to `/function/<name>` with a JSON body, as described in the [overview](/api/overview).
A replay reads stored runs, so none of them but `send_policy_message` spends a model request, and none places an order.

## Public

| Function | Parameters | Returns |
| --- | --- | --- |
| `get_policy_catalog` | None | Every number and its limits, every metric, the rule effects and comparisons, and the defaults |
| `get_team_policy` | None | The team policy in force, in words, with its history |
| `preview_policy` | `policy`, `run_date` (optional; the newest when empty) | A replay of that run under the policy, or `problems` when it breaks a limit |

## Signed in

A `scope` is `personal` or `team`, and saving to `team` needs the admin account.
Both saves name the `base_version` they were edited from, and are refused if a newer version exists.

| Function | Parameters | Returns |
| --- | --- | --- |
| `get_policy_workspace` | None | Your policy, the team's, and whether you may edit the team's |
| `save_policy_version` | `scope`, `policy`, `base_version`, `note` (optional) | Whether it saved, why not, and the policy in force |
| `restore_policy_version` | `scope`, `version`, `base_version` | The same, after saving that version again as the newest (version 0 is the defaults) |

## The assistant

A message is answered in the background: `send_policy_message` stores it, and `get_policy_chat` collects the answer, so call it until `pending` is false.

| Function | Parameters | Returns |
| --- | --- | --- |
| `get_policy_chat` | `scope` | Your turns, whether one is `pending`, and how many messages are left today |
| `send_policy_message` | `scope`, `text` (up to 500 characters) | The same, with your message added |
| `apply_policy_proposal` | `turn_id` | Whether it saved, the chat, and the policy in force |
| `discard_policy_proposal` | `turn_id` | The chat; the policy stays as it is |
