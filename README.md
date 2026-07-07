# Furl

Furl makes menu bar items that overflow off-screen — common on small or notched displays — reachable again. It is a minimal, single-purpose utility derived from [Ice](https://github.com/jordanbaird/Ice), built to do that one thing with the smallest possible permission footprint: Accessibility, and nothing else.

## How it works

Furl places two status items of its own: an icon and an invisible spacer that expands to push every other item off-screen to the left. Clicking the icon lists those hidden items; choosing one slides it on-screen next to the icon so you can click it like any menu bar item. When you're done, it slides back off-screen on its own — after a configurable delay if you never opened it, or shortly after you dismiss its menu if you did. You can bring out several at once; each hides itself independently. Items you exclude stay permanently visible to the right of the icon, and Furl re-establishes managed/excluded positions automatically as apps come and go.

Details: [`ARCHITECTURE.md`](ARCHITECTURE.md).

## Permissions and security

Furl requires **Accessibility** — to enumerate other apps' menu bar items and to post the synthetic mouse events that reposition their windows. That is the only permission it asks for. (Furl repositions items; it never opens or activates them — you do.)

It has:

- no Screen Recording, and no screen or window capture of any kind
- no background network activity, no telemetry, no crash reporting, no auto-updater — the only network code is the manual **Check for Updates** button (About pane), which fetches the latest version number from GitHub when you click it and opens the releases page; nothing is downloaded or executed
- no private window-server (CGS/SkyLight) APIs; window geometry comes from the public `CGWindowList`
- no code injection; hardened runtime enabled with no exception entitlements
- no data collection — it persists only its own settings (UserDefaults); nothing about other apps is written to disk beyond the items you explicitly exclude
- one dependency: [LaunchAtLogin-Modern](https://github.com/sindresorhus/LaunchAtLogin-Modern)

Releases are signed with a Developer ID certificate and notarized by Apple; Gatekeeper verifies both when you first open the app.

The app is not sandboxed — Accessibility plus cross-process event posting are incompatible with the App Sandbox; this is true of every tool in this category. The full reviewer-facing posture, including independent verification commands, is in [`Furl-Security-Review.md`](Furl-Security-Review.md).

## Installing and updating

Install with [Homebrew](https://brew.sh):

```sh
brew install julianbaker/tap/furl
```

or download the notarized zip from [Releases](https://github.com/julianbaker/Furl/releases). Furl deliberately has no auto-updater and never phones home on its own — update via `brew upgrade`, the **Check for Updates** button in Settings ▸ About, or by watching Releases.

## Troubleshooting

- **The dropdown is empty or shows an Accessibility hint.** Grant Furl Accessibility in System Settings ▸ Privacy & Security ▸ Accessibility, then quit and reopen Furl. The grant is tied to the app's code signature, so replacing the binary with a differently-signed build resets it.
- **Items are missing right after launch.** The item list warms up over the first few seconds; it refreshes continuously afterward.
- **An app crashes when you open it from the menu bar.** That's the app's own bug, not Furl's — Furl only moves the item on-screen; opening it is an ordinary click. Known case: MonitorControl 4.2.0 crashes when its slider is used on modern macOS — update it (its built-in updater is broken; see [MonitorControl#1663](https://github.com/MonitorControl/MonitorControl/issues/1663)).

## Building

Requires Xcode 26 on macOS 14+.

```sh
xcodebuild -project Furl.xcodeproj -scheme Furl -configuration Release \
    CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
```

The overrides produce an ad-hoc-signed build without needing the author's signing certificate.

Note that the Accessibility grant is bound to the code signature: re-signing with a new identity (including a fresh ad-hoc signature per build) makes macOS treat each build as a new app and re-prompt. Use a stable signing identity for local development.

## Credits and license

Furl is based on [Ice](https://github.com/jordanbaird/Ice) by Jordan Baird, including its menu bar item move engine. Licensed under the [GNU General Public License v3.0](LICENSE), inherited from Ice.
