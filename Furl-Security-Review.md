# Furl — Security Review & Posture

**What Furl is.** Furl is a minimal, single-purpose menu bar utility derived from [Ice](https://github.com/jordanbaird/Ice), built with a deliberately small permission and API footprint. Its single purpose is to give access to menu bar items that overflow off-screen on small / notched displays: it keeps most items hidden behind an expanding spacer, slides a chosen item on-screen on demand for the user to click, then tucks it back away. It requires exactly one permission — Accessibility — and has no network access, no screen capture, and no auto-updater.

**Scope.** This document describes the **actual, shipping behavior of Furl** (repo checkout, branch `main`, bundle id `design.julianbaker.Furl`) — verified against source.

---

## 0. Executive summary

| Question | Answer |
|---|---|
| TCC permissions required | **Accessibility only.** No Screen Recording, no Input Monitoring, no Camera/Mic/Contacts/etc. |
| Network / telemetry | **No background networking, no telemetry.** The sole network code is a user-initiated update check (About ▸ Check for Updates): one HTTPS GET to `api.github.com` for the latest release's version string, then the releases page opens in the browser. Nothing downloaded or executed, nothing automatic. No analytics, no crash SDK, **no auto-updater** (Sparkle removed). |
| Screen capture | **None.** No window/screen image capture of any kind. |
| Private window-server (CGS / SkyLight) APIs | **None.** The private bridging island was removed; window geometry uses the **public** `CGWindowList` only. |
| Reads other apps' menu bar items | **Yes** — via the documented **Accessibility** API. |
| Moves items | **Yes** — synthesized **Command-drag mouse events** to reposition item windows (reveal, hide, reconcile); targeted by window ID. Furl never opens or activates items — the user does. (A failed move is retried after an inert Cmd-click "wake" nudge; see §1.) |
| Data stored about other apps | **Minimal** — the identities (bundle id + item index or AX identifier) of items the user explicitly excludes, plus any per-item auto-hide override. Nothing else. |
| Code injection into other processes | **No.** No dylib injection, no library-validation exception. |
| Sandboxed | **No** (required — Accessibility + cross-process event posting are incompatible with the App Sandbox). |

**Bottom line for review:** Furl needs exactly one meaningful grant — **Accessibility** — which it uses to (a) read the list of menu bar items and (b) post synthetic mouse events that reposition them. It performs no screen capture, makes no network connections beyond the manual update check described above, uses no private window-server APIs, stores no third-party data beyond the items you exclude, and injects no code into other processes.

---

## 1. What Furl does, and the exact APIs it uses

| Step | Mechanism | Permission | Files |
|---|---|---|---|
| **Enumerate menu bar items** | Accessibility: `AXUIElementCreateApplication` → `AXExtrasMenuBar` → children; reads `AXIdentifier`/`AXPosition`/`AXSize`. Per-app messaging bounded to 0.5s. | Accessibility | `MenuBarItemsReader.swift`, `MenuBarItemWindowResolver.swift` |
| **Hide items ("declutter")** | The `NSStatusItem.length` trick — an owned divider item expands to `10_000pt`, pushing everything to its left off-screen. No other app is touched. | none | `ControlItem.swift`, `MenuBarSection.swift` |
| **Resolve an item's window** | Public `CGWindowListCopyWindowInfo` — matches the status-layer window by frame (menu bar extras are composited by Control Center, so matched by geometry, not app pid). | none (public API) | `MenuBarItemWindowResolver.swift` |
| **Reveal an item on-screen** | Synthesized **Command-drag** mouse events (`CGEvent` mouse down/up) that reposition the item's window beside Furl's icon. Ported from Ice's item-move engine. If a drag attempt fails, the engine "wakes" the item with a synthetic Cmd-down/up pair at its center before retrying (Ice's technique) — Cmd-click is the menu bar's rearrange gesture and does not open or activate the item. | Accessibility (to post events into other apps) | `MenuBarItemMover.swift` |
| **Open the item** | Furl does not open it — the revealed item sits in place and the user clicks it. No synthetic click, no `AXUIElementPerformAction`. | — | — |
| **Know when its menu is open** | Public `CGWindowListCopyWindowInfo`: the menu/popover is a window owned by the item app's own pid, item-menu-sized, hanging from the menu bar; Furl waits for it to close before tucking the item back (so it never dismisses your menu). | none (public API) | `ControlItem.swift`, `MenuBarItemWindowResolver.swift` |
| **Auto-hide after use** | Once revealed, the item hides when the auto-hide interval elapses with no menu open, or (if the user opened its menu) once that menu is dismissed. Then a Command-drag slides it back off-screen. | Accessibility (for the move) | `ControlItem.swift` |
| **Position reconciliation** | After each periodic enumeration refresh (~7 s), items that drifted from the user's configured intent (apps restore their own saved positions at launch) are moved back: visible managed items are tucked off-screen; excluded items are returned beside the icon. Uses the same Command-drag mechanism; rate-limited per item and paused during peeks or while Furl's own menu is open. This is the one place synthetic events are posted *without* a same-moment user action — they enforce positions the user configured in settings. | Accessibility (for the moves) | `ControlItem.swift` |
| **Check for updates (manual)** | One HTTPS GET to `api.github.com/repos/julianbaker/Furl/releases/latest`, fired only when the user clicks About ▸ Check for Updates. Compares the returned version string to the running version; "View Release" opens the releases page in the browser. Nothing is downloaded or executed by Furl. | none (outbound HTTPS) | `UpdateChecker.swift` |

---

## 2. Permission inventory

| Permission | Required? | Why / notes |
|---|---|---|
| **Accessibility** (TCC) | **Yes** | Enumerate menu bar items (read-only AX) **and** post synthetic Command-drag mouse events into other apps to reposition them. This is the only TCC prompt Furl triggers. |
| **Screen Recording** (TCC) | **No** | Not used. All screen-capture code (`ScreenCapture.swift`, image caches) was removed. Window *geometry* (position/size) via `CGWindowList` does **not** require Screen Recording. |
| **Input Monitoring** (TCC) | **No** | No `IOHIDRequestAccess`/`CGRequestListenEventAccess`. No global keyboard monitoring anywhere. |
| Files (user-selected, read-only) | entitlement only | Benign; inherited. |

---

## 3. Capability / API surface (what a reviewer will find in the binary)

**Present (and why):**
- **Accessibility** — `AXIsProcessTrusted(WithOptions)`, `AXUIElementCreateApplication`, `AXUIElementCopyAttributeValue`, `AXUIElementSetMessagingTimeout`. Read-only enumeration only; no `AXUIElementPerformAction`.
- **Synthetic mouse input** — `CGEvent(mouseEventSource:…)`, `event.post(tap:)` / `postToPid`, `CGEventSource`. (The Command-drag that repositions an item.) Confined to `MenuBarItemMover.swift`.
- **CGEvent taps** — `CGEvent.tapCreate` / `tapCreateForPid`, **created and torn down per move** to sequence the drag; not a persistent system-wide tap.
- **One private/undocumented event field** — `CGEventField(rawValue: 0x33)`, used to target a specific window by ID during the synthetic drag (matches Ice's proven technique). This is the only undocumented symbol in the reveal path.
- **Cursor control during a move** — `CGDisplayHideCursor` / `CGDisplayShowCursor` / `CGWarpMouseCursorPosition` / `CGAssociateMouseAndMouseCursorPosition`, so the synthetic drag isn't visible; the cursor's real position and mouse association are restored immediately afterward.
- **Public window list** — `CGWindowListCopyWindowInfo`, `CGWindowListCreateDescriptionFromArray`, `CGWindowLevelForKey`. Geometry + menu-open detection. No image/pixel APIs.
- **HTTPS fetch, one endpoint** — `URLSession` GET to `api.github.com/…/releases/latest`, reached only from the About pane's Check for Updates button. Confined to `UpdateChecker.swift`; no other networking exists in the app.
- **NSEvent monitors** — **none.** The inherited auto-rehide logic and its monitor classes were removed entirely; there are no global or local NSEvent monitors of any kind.
- **Objective-C method swizzling (own process only)** — `NSSplitViewItem.canCollapse` is swizzled to keep the settings window's sidebar from collapsing (`NSSplitViewItem+swizzledCanCollapse.swift`). Cosmetic, scoped to Furl's own windows; it touches no other process.

**Absent (removed or never present):**
- ❌ Screen/window image capture (`CGWindowListCreateImage`, `SCShareableContent`).
- ❌ Private CGS / SkyLight window-server calls (`CGSMainConnectionID`, `CGSGetProcessMenuBarWindowList`, `@_silgen_name` bridging) — the whole island was deleted.
- ❌ Background networking of any kind (the manual update check above is the sole network call); ❌ auto-updater (Sparkle); ❌ analytics/telemetry/crash SDK.
- ❌ Input Monitoring / global keyboard monitoring; ❌ clipboard access.
- ❌ Code injection (no dylib injection; no library-validation / `get-task-allow` exception).
- ❌ Carbon hotkeys.

---

## 4. Data at rest

All persistence is UserDefaults; the complete key inventory:

- **`ExcludedMenuBarItems`**: identities — `"<bundleID>#<index>"`, or `"<bundleID>#id:<AXIdentifier>"` when the app exposes a stable one — of the items you exclude (keep visible with their own icon), in left-to-right order. Third-party identifiers, only for items you explicitly choose.
- **`AutoHideOverrides`**: per-item auto-hide durations, keyed by the same identities.
- **`IceIcon`**, **`CustomIceIconIsTemplate`**, **`AutoHideInterval`**: Furl's own appearance/behavior settings (a custom icon image, if chosen, is stored as image data here).
- **Own status-item positions** (`StatusItemDefaults` "Preferred Position") — Furl's own icon/divider only.
- Everything else enumerated (app names, item positions) is held **in memory** for the dropdown and never written to disk. No history, no caches on disk.

---

## 5. Entitlements & runtime

| Item | Value | Note |
|---|---|---|
| `com.apple.security.app-sandbox` | **false** | Required: Accessibility + posting synthetic events into other processes are not sandbox-compatible. This is the headline IT item for any tool in this category. |
| `ENABLE_HARDENED_RUNTIME` | YES | On. |
| Hardened-runtime exceptions | **none** | No library-validation disable, no JIT/`get-task-allow`/injection — confirms Furl does not inject code into other apps; it works in-process + via synthetic events. |
| `com.apple.security.files.user-selected.read-only` | true | Benign. |
| `LSUIElement` | YES | Agent app, no Dock icon. |
| Deployment target | macOS 14+ | — |

Dependencies (SPM): **LaunchAtLogin-Modern** only. Removed from upstream: **Sparkle** (network/updates), **AXSwift** (replaced with direct AX calls), **Ifrit** (search), **CompactSlider** (replaced with a native stepper).

---

## 6. Risk assessment (for IT)

**Intrinsic to the category (cannot be avoided by any tool that manages foreign menu bar items):**
- **Not sandboxed**, and **Accessibility required**. Apple provides no public, sandbox-safe API to reposition another app's menu bar item; every tool here (Bartender, Hidden Bar, Ice, …) needs Accessibility and/or private calls.

**Furl-specific posture (better than typical):**
- **No screen recording** — unlike many menu bar managers, Furl never captures the screen. Verifiable in the binary (no capture symbols).
- **No private window-server APIs** — geometry is public `CGWindowList` only. The private CGS/SkyLight surface that upstream Ice links was removed.
- **No background network / no auto-update** — nothing leaves the machine on its own, and there is no remote code delivery. The sole network call is the user-clicked version check (one GET, version string in, browser link out).

**Worth calling out explicitly:**
- **Synthetic input into other processes.** The reveal/move engine posts synthetic Command-drag mouse events targeting item windows (including one undocumented event field, `0x33`, to address a window by ID). It reads no input, captures no content, opens/activates nothing, and is transient/local — but it is the most powerful capability and reviewers should know it exists. It is confined to `MenuBarItemMover.swift`. One detail a source reviewer will encounter: the move retry path posts a Cmd-down/up "wake" pair at a stuck item's center (`wakeUp`) — click-shaped events, but Cmd-click on a menu bar item is the rearrange gesture and opens nothing. Note that the reconciliation pass posts the same drag events on a timer (not only in response to a user action) to enforce the item positions the user configured; the events always target menu-bar-item windows resolved at the status-window layer.

---

## 7. How to verify (independent checks)

```sh
# No screen capture, no private CGS/SkyLight — expect zero hits:
grep -rn "CGWindowListCreateImage\|SCShareableContent\|CGSMainConnection\|CGSGet\|@_silgen_name" Furl/

# The ONLY networking is the manual update check — expect exactly UpdateChecker.swift:
grep -rln "URLSession\|URLRequest" Furl/

# Synthetic events / taps / private field are confined to the mover:
grep -rln "tapCreate\|CGEventField\|CGWarpMouse\|CGDisplayHideCursor" Furl/

# Binary: no screen-capture / private CGS-SkyLight / Sparkle symbols, no embedded frameworks.
# (Match specific symbols — a bare "CGS" also hits Swift's CGSize and gives false positives.)
otool -L /Applications/Furl.app/Contents/MacOS/Furl
nm -u /Applications/Furl.app/Contents/MacOS/Furl | grep -iE "CGSConnection|CGSMainConnection|CGSGetProcess|CGSCopy|SkyLight|SCStream|SCShareableContent|Sparkle|CGWindowListCreateImage" || echo "none"
```
