# Furl — Architecture

Furl is a minimal, single-purpose menu bar utility derived from [Ice](https://github.com/jordanbaird/Ice). It does one thing: give access to menu bar items that overflow off-screen on small / notched displays. It hides items behind an expanding spacer and reveals a chosen one on demand, then tucks it back away — using Accessibility and nothing else.

For the permission/security posture see [`Furl-Security-Review.md`](Furl-Security-Review.md).

## The model in one paragraph

There are two owned status items: the **Furl icon** (`SItem`, preferred position `0`, rightmost) and a **spacer/divider** (`HItem`, position `1`, just left of the icon). The spacer expands to `10_000pt`, which — because status items lay out right-to-left — shoves everything to its left off-screen. So by default only the Furl icon is visible; every other menu bar item is parked off-screen to the left. Clicking the icon opens a dropdown of those hidden items; choosing one **slides it on-screen for the user to click, then slides it back once they're done** (after the auto-hide interval if they never open it, or shortly after they dismiss its menu). Several items can be out at once; each hides itself independently.

## Components

| File | Responsibility |
|---|---|
| `MenuBarManager.swift` | Owns the sections `[.visible (icon), .hidden (spacer)]`; `setItemExcluded` forwards exclude/manage to the icon control item. |
| `MenuBarSection.swift` / `ControlItem.swift` | The two `NSStatusItem`s and the length-trick hide. `ControlItem` also builds the dropdown and drives reveal / auto-hide / exclude. |
| `MenuBarItemsReader.swift` | Accessibility enumeration of menu bar items (`AXExtrasMenuBar` → children). Excludes Control Center's own items. Read-only — no activation. |
| `MenuBarItemsModel.swift` | Background-cached item list (`items`), the user's excluded set (`excludedIdentities` → `ExcludedMenuBarItems`, ordered), per-item auto-hide overrides, and `managedItems` (dropdown source, alphabetical). |
| `MenuBarItemWindowResolver.swift` | Resolves a menu bar item's **window** from the public `CGWindowList` (`resolve(axFrame:)`), plus helpers (`resolveSpacer(nearY:)`, `onScreenWindows()`, `isOnAnyDisplay`, `activeDisplayBounds`). |
| `MenuBarItemMover.swift` | The synthetic Command-drag engine (ported from Ice) that repositions another app's item window. |

## Key flows

**Declutter (default).** The spacer sits expanded; all non-pinned items are off-screen left. Nothing is touched in other apps.

**Peek (dropdown → click a hidden item)** — `ControlItem.activateMenuBarItem`:
1. `revealItemOnScreen` — resolve the item's window, then `MenuBarItemMover.move` it to just **left of the Furl icon** (the drop point is offset a full item-width left so the icon isn't shoved). If the item is already on-screen, it is not moved at all.
2. That's it — Furl does **not** open the item. The item sits in its correct position and the **user clicks it** themselves. Synthesizing the click was tried and abandoned: it is inconsistent across apps (some open, some ignore it) and `AXPress` opens menus off-screen and pops main windows. A real user click works uniformly because the item is in its true on-screen position.
3. `scheduleHide` keeps the item out until the user is done, then `hideItem` moves it back to the left of the spacer. Two cases: if the user never opens the menu, the item hides once the auto-hide interval elapses; if they open it, the item stays until the menu closes, then hides ~1s later. The menu is identified by the item app's **process id** (`looksLikeItemMenu`: a window owned by that app's pid, item-menu-sized, hanging from the menu bar) — attributing by pid rather than screen position is what lets several items be peeked at once without one seeing another's menu. Skipped if the item was excluded meanwhile, and never fired while Furl's own dropdown is open (a move would dismiss it). Bounded so a menu left open forever can't pin the item on-screen indefinitely. Each peeked item runs its own `scheduleHide`; `activePeeks` tracks them.

**Exclude / manage (Settings ▸ Menu Bar Items toggle)** — `ControlItem.setExcluded`: excluding moves the item right of the icon (always visible, own icon) and records it in `excludedIdentities`; managing moves it back to the hidden side. Excluded items leave the dropdown.

**Reconciliation** — apps restore their own saved item positions when they (re)launch, so positions drift from the user's intent. After every enumeration refresh (~7 s), `ControlItem.reconcileItems` tucks stray visible *managed* items back off-screen and returns *excluded* items to the right of the icon (in their persisted left-to-right order, which it also captures so ⌘-drag rearrangements survive). Rate-limited per item (60 s), serialized, and paused while a peek or programmatic move is in flight or Furl's own menu is open. This is also what restores positions at Furl launch.

## Non-obvious facts (the ones that cost time)

- **Menu bar extras are composited by Control Center**, so an item's *window* is owned by Control Center's pid, not the item's app. The resolver therefore matches windows **by frame geometry at the status layer** (see the both-axes note below), not by app pid, and the move events target the **window owner's** pid. Matching by app pid silently finds nothing. (Note this is the opposite of menu-open detection, which keys on the *app's* pid — the item's composited window is Control Center's, but the menu the app opens is the app's own.)
- **Off-screen status windows *are* returned** by `CGWindowListCopyWindowInfo` — but only if you do **not** pass `.optionOnScreenOnly`. Hidden items live far off-screen (e.g. `x ≈ -4000`); that flag would hide exactly what we need.
- **Moving an item dismisses whatever menu it has open.** There's no way to move it without that side effect, and no reliable, permission-free way to know an arbitrary app's menu is open *except* watching the public window list for the window the app opened. Hence the peek waits for that window to disappear before hiding.
- **Control Center's own items** (Clock, Wi-Fi, Battery, …) sit right of the icon, can't be hidden, and are excluded from enumeration (`MenuBarItemsReader.systemBundleIDs`).
- **Furl does not synthesize activation.** Two mechanisms were tried and both rejected: a synthesized click is inconsistent across apps (works for some, ignored by others — and it must warp the cursor onto the item since status-item buttons hit-test the real cursor position), and `AXPress` opens menus anchored to the item's off-screen logical position (observed at x≈-3800) and pops apps' main windows, besides crashing some apps (PixelSnap 2). Revealing the item and letting the user click it is uniform and needs no per-app handling.
- **A menu is attributed to its item by owning process id, not screen position.** Two items peeked at once sit close together, so a positional match would let each see the other's menu. Every app whose menu bar item opens a menu/popover owns that window under its own pid, so `looksLikeItemMenu` keys on `ownerPID == itemPID`. Limitation: a menu the window server owns rather than the app (a plain `NSMenu` on some apps) can't be attributed this way and won't hold its item open past the auto-hide interval — those were never reliably detected anyway. Two further limitations of the heuristic (both benign): two peeked items of the *same* app share a pid, so each sees the other's menu and they hide together rather than independently; and a popover wider than 600 pt isn't recognized as a menu at all, so the auto-hide timer can tuck its item mid-use.
- **Windows are matched to AX frames in both axes.** Each display has its own copy of every status item's window; matching x-only at global y≈0 breaks with multiple displays, so `resolve(axFrame:)` matches on x and y and on-screen checks use every active display's bounds. (Testing on physical multi-monitor setups has been limited.)
- **Apps restore their own saved item positions at (re)launch** — possibly on-screen, even for items Furl manages. Reconciliation (above) is what keeps the bar consistent.
- **Peeking an item whose cached AX element has died re-enumerates that app synchronously on the main thread** (`MenuBarItemsReader.refreshedEntry`). Each AX message is bounded to 0.5 s, but a hung app can stack a few of them into a short stall.

## Building & the Accessibility grant

The Accessibility grant is tied to the code signature + bundle id, so an ad-hoc rebuild would reset it every time. Local development builds are therefore **re-signed with a stable signing identity**, which keeps the grant across rebuilds; changing the bundle id resets it (a one-time re-approval). `scripts/bi.sh` is the build → re-sign → install dev loop.
