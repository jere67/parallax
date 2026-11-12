# Parallax for phones

A native app for following Parallax from a phone, written in Jac (`kind = "mobile"`, React Native through Expo) and run in Expo Go.
It reads a Parallax server over the same HTTP endpoints the web dashboard calls.
It only reads: it cannot place an order, start a run, or change a setting.

It has four parts:

- **Sign-in:** pick the live or demo server with one tap, or type any address.
- **Portfolio:** the account's value, its curve against SPY, and the open positions.
- **Today:** the latest run (or an earlier one), its market read, and what it bought, sold, and held.
- **Decision trail:** for one stock, research, the panel's votes, consensus, the Arbiter, the risk gate, and the order.

While the app is open it checks for a finished run every minute and when it comes back to the screen, then shows a banner and a notification.
Push notifications to a closed app would need an Expo account and a build of our own, so the app does not use them.

## Run it on your phone

1. Install **Expo Go** from the App Store or Google Play.
   The app is built for Expo SDK 58, the version the App Store's Expo Go ran in November 2026; Expo Go says so if the two differ.
2. Once, from this folder: `scripts/setup.sh`.
3. Start the dev server: `scripts/dev.sh` on the same network as the phone, or `scripts/tunnel.sh` from anywhere.
4. Scan the QR code it prints: with the Camera app on an iPhone, or from Expo Go on Android.
5. Sign in with an account on the server you picked.

## Reaching the servers

The phone needs to reach Metro (port 8081, which serves the app) and a Parallax server.
The **Live** and **Demo** buttons point at ports 8100 and 8200 on the computer running the dev server.

- **A phone hotspot or a home network (recommended):** join the computer to the phone's hotspot and run `scripts/dev.sh`.
  On a private address the script forwards ports 8100 and 8200 to the phone, so servers that listen only on the computer need no restart.
- **A campus or other public network:** the script forwards nothing there, since anyone on the internet could then reach the servers.
  A campus network may also keep two devices from reaching each other, so use a hotspot.
- **Anywhere, through Cloudflare:** `scripts/tunnel.sh` (or `scripts/tunnel.sh demo` for the demo server only) opens temporary `https://<random>.trycloudflare.com` addresses for Metro and the servers, and the Live and Demo buttons use them.
  Anyone with an address can reach that server's sign-in page while it runs.
  It needs `cloudflared` (`brew install cloudflared`), and some networks' DNS blocks quick tunnels, including the University of Michigan's at times.
- **A deployed server:** type its address, such as `parallax.jaseci.app`.

To run a demo server: from the repository root, `TRADING_AGENT_DEMO=1 TRADING_AGENT_DISABLE_ORDERS=1 jac run --no-dev -p 8200 main.jac`.

## Preview in a browser

`jac run --dev` serves the same app as a web page at <http://localhost:8000>, for checking a screen without a phone.

## How it is built

| File | What it holds |
| --- | --- |
| `main.jac` | The app shell: session, tabs, the trail overlay, the run check |
| `screens/` | Sign-in, Portfolio, Today, and the decision trail |
| `components/` | Shared parts, icons, and the equity chart (drawn from rotated views, no SVG) |
| `api.jac` | Sign-in and endpoint calls; every call returns a `Reply`, never raises |
| `views.jac` | The server's response shapes, mirrored from `models/views.jac` |
| `theme.jac`, `fonts*.jac` | The web dashboard's dark palette and Instrument Serif |
| `*.native.jac` | Phone versions of a web module, with the same names: session storage, notifications, icons, fonts, the server address |
| `expo/` | Copied into Jac's Expo project by `scripts/setup.sh` |

Jac 0.37.12 needs a few settings, each explained where it is set:

- `jac.toml` raises Jac's Expo SDK 57 scaffold to SDK 58, which is the Expo Go in the stores.
- `jac.toml` pins every module to the client, because the app has no server code.
- `jac.toml` sets the app's platform to web, so the dev server's backend does not start an Xcode build; `scripts/dev.sh` passes `--platform ios`.
