---
title: Installing on a phone
description: Parallax works on a phone in the browser, can be installed to the home screen, and has a native app for Expo Go.
related:
  - { text: Reading the dashboard, link: /guide/dashboard }
---

The dashboard works in a phone's browser, with a tab bar along the bottom, and can be installed like an app.
The installed app is named Parallax and opens at `/app`, so a signed-in user lands on the Portfolio and anyone else on the login page.
The service worker registers on every page.
Tables become cards: a shortlist card opens that stock's decision trail, and a position's card opens its thesis and the rest of its figures.

## Installing

- **Android:** open Parallax in Chrome and tap **Install the app** at the bottom of the page, or use Chrome's menu.
- **iPhone:** open Parallax in Safari, tap **Share**, then **Add to Home Screen**.

A browser offers this only over HTTPS, or on `localhost`.

## Offline

The installed app still opens with no signal, and a banner says it is offline.
Its figures are never served from a cache, so what is on screen is never older than the page says, and nothing can be saved until you reconnect.

## The native app

`mobile/` holds a native app for following Parallax from a phone, written in Jac and run in Expo Go.
It has sign-in, the Portfolio, the latest run, and each decision's trail, and it only reads.
While it is open, it checks for a finished run every minute and shows a notification when one is in.

To run it, install Expo Go on the phone, then from `mobile/` run `scripts/setup.sh` once and `scripts/dev.sh`, and scan the QR code it prints.
The phone must reach the computer running it: a phone hotspot works best, and `scripts/tunnel.sh` works from any network that allows Cloudflare quick tunnels.
`mobile/README.md` covers each way to connect, the demo server, and how the app is built.
