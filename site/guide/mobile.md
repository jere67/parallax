---
title: Installing on a phone
description: Parallax works on a phone in the browser and can be installed to the home screen.
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
