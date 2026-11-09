---
title: Policy endpoints
description: Read your policy, try a draft against your latest run, save a version, and talk to the policy assistant.
related:
  - { text: Policies and the assistant, link: /guide/policies }
  - { text: Authentication, link: /api/authentication }
---

Every endpoint is a `POST` to `/function/<name>` with a JSON body, as described in the [overview](/api/overview).
A replay reads stored runs, so none of them but `send_policy_message` spends a model request, and none places an order.

Every endpoint here is private: it needs a bearer token and answers `401` to an anonymous caller.
Each account has one policy, and no endpoint takes a `scope`.
A saved policy drives the caller's own agent from its next morning run.

## The policy

A save names the `base_version` it was edited from, and is refused if a newer version exists.

| Function | Parameters | Returns |
| --- | --- | --- |
| `get_policy_catalog` | None | Every number and its limits, every metric, the rule effects and comparisons, and the defaults |
| `get_my_policy` | None | Your policy in force, in words, with its history |
| `preview_policy` | `policy`, `run_date` (optional; the newest when empty) | A replay of that run under the policy, compared with what your own latest run decided, or `problems` when it breaks a limit |
| `save_policy_version` | `policy`, `base_version`, `note` (optional) | Whether it saved, why not, and the policy in force |
| `restore_policy_version` | `version`, `base_version` | The same, after saving that version again as the newest (version 0 is the defaults) |

## The assistant

The assistant uses the caller's own OpenRouter key.
Without one, it asks the user to connect it in Settings.

A message is answered in the background: `send_policy_message` stores it, and `get_policy_chat` collects the answer, so call it until `pending` is false.

| Function | Parameters | Returns |
| --- | --- | --- |
| `get_policy_chat` | None | Your turns, whether one is `pending`, and how many messages are left today |
| `send_policy_message` | `text` (up to 500 characters) | The same, with your message added |
| `apply_policy_proposal` | `turn_id` | Whether it saved, the chat, and the policy in force |
| `discard_policy_proposal` | `turn_id` | The chat; the policy stays as it is |
