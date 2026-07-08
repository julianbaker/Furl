//
//  ControlItem.swift
//  Furl
//

import Cocoa
import Combine

/// A status item that controls a section in the menu bar.
@MainActor
final class ControlItem {
    /// Possible identifiers for control items.
    enum Identifier: String, CaseIterable {
        case iceIcon = "SItem"
        case hidden = "HItem"
    }

    /// Possible hiding states for control items.
    enum HidingState {
        case hideItems, showItems
    }

    /// Possible lengths for control items.
    enum Lengths {
        static let standard: CGFloat = NSStatusItem.variableLength
        static let expanded: CGFloat = 10_000
    }

    /// The control item's hiding state (`@Published`).
    @Published var state = HidingState.hideItems

    /// A Boolean value that indicates whether the control item is visible (`@Published`).
    @Published var isVisible = true

    /// The frame of the control item's window (`@Published`).
    @Published private(set) var windowFrame: CGRect?

    /// The shared app state.
    private weak var appState: AppState?

    /// The control item's underlying status item.
    private let statusItem: NSStatusItem

    /// A horizontal constraint for the control item's content view.
    private let constraint: NSLayoutConstraint?

    /// The control item's identifier.
    private let identifier: Identifier

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// Entries shown in the menu bar items dropdown, indexed by menu item tag.
    private var dropdownEntries = [MenuBarItemEntry]()

    /// Window IDs of items currently peeked on-screen. Each peek tracks and
    /// hides itself independently; while any are active, the reconciliation
    /// pass leaves visible managed items alone.
    private var activePeeks = Set<CGWindowID>()

    /// Whether Furl's own dropdown / context menu is currently open. While it
    /// is, auto-hide and reconciliation must not move items — a synthetic drag
    /// would dismiss the menu out from under the user.
    private var isOwnMenuOpen = false

    /// The last time each item was auto-corrected by reconciliation, so an app
    /// that keeps re-asserting a stale position can't cause a move-fight.
    private var reconcileCooldown = [String: Date]()

    /// Whether a programmatic move (reconcile batch or exclude toggle) is in
    /// flight. Reconciliation won't start while one is — overlapping synthetic
    /// drags fight over the event taps and the cursor.
    private var isRepositioning = false

    /// Whether we're polling for the Accessibility grant after prompting the
    /// user, so the item list can fill in without a relaunch.
    private var isPollingForAccessibility = false

    /// When the app launched — used to tell a cold cache (normal for the first
    /// few seconds) from enumeration that is genuinely stuck.
    private static let launchTime = ContinuousClock.now

    /// The menu bar section associated with the control item.
    private weak var section: MenuBarSection? {
        appState?.menuBarManager.sections.first { $0.controlItem === self }
    }

    /// The control item's window.
    var window: NSWindow? {
        statusItem.button?.window
    }

    /// The identifier of the control item's window.
    var windowID: CGWindowID? {
        guard let window else {
            return nil
        }
        return CGWindowID(window.windowNumber)
    }

    /// The control item's window frame in CoreGraphics (top-left origin)
    /// global coordinates — the space AX frames and CGWindowList use.
    /// (`window.frame` is AppKit bottom-left origin.)
    private var iconCGFrame: CGRect? {
        guard
            let window,
            let primaryScreen = NSScreen.screens.first
        else {
            return nil
        }
        let frame = window.frame
        return CGRect(
            x: frame.minX,
            y: primaryScreen.frame.maxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    /// A Boolean value that indicates whether the control item serves as
    /// a divider between sections.
    var isSectionDivider: Bool {
        identifier != .iceIcon
    }

    /// A Boolean value that indicates whether the control item is currently
    /// displayed in the menu bar.
    var isAddedToMenuBar: Bool {
        statusItem.isVisible
    }

    /// Creates a control item with the given identifier and app state.
    init(identifier: Identifier, appState: AppState) {
        let autosaveName = identifier.rawValue

        // If the status item doesn't have a preferred position, set it
        // according to the identifier.
        if StatusItemDefaults[.preferredPosition, autosaveName] == nil {
            switch identifier {
            case .iceIcon:
                StatusItemDefaults[.preferredPosition, autosaveName] = 0
            case .hidden:
                StatusItemDefaults[.preferredPosition, autosaveName] = 1
            }
        }

        self.statusItem = NSStatusBar.system.statusItem(withLength: 0)
        self.statusItem.autosaveName = autosaveName
        self.identifier = identifier
        self.appState = appState

        // This could break in a new macOS release, but we need this constraint in order to be
        // able to hide the control item when the `ShowSectionDividers` setting is disabled. A
        // previous implementation used the status item's `isVisible` property, which was more
        // robust, but would completely remove the control item. With the current set of
        // features, we need to be able to accurately retrieve the items for each section, so
        // we need the control item to always be present to act as a delimiter. The new solution
        // is to remove the constraint that prevents status items from having a length of zero,
        // then resize the content view.
        if
            let button = statusItem.button,
            let constraints = button.window?.contentView?.constraintsAffectingLayout(for: .horizontal),
            let constraint = constraints.first(where: Predicates.controlItemConstraint(button: button))
        {
            assert(constraints.filter(Predicates.controlItemConstraint(button: button)).count == 1)
            self.constraint = constraint
        } else {
            self.constraint = nil
        }

        configureStatusItem()
    }

    /// Removes the status item without clearing its stored position.
    deinit {
        // Removing the status item has the unwanted side effect of deleting
        // the preferredPosition. Cache and restore it.
        let autosaveName = statusItem.autosaveName as String
        let cached = StatusItemDefaults[.preferredPosition, autosaveName]
        NSStatusBar.system.removeStatusItem(statusItem)
        StatusItemDefaults[.preferredPosition, autosaveName] = cached
    }

    /// Configures the internal observers for the control item.
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        $state
            .sink { [weak self] state in
                self?.updateStatusItem(with: state)
            }
            .store(in: &c)

        Publishers.CombineLatest($isVisible, $state)
            .sink { [weak self] (isVisible, state) in
                guard
                    let self,
                    let section
                else {
                    return
                }
                if isVisible {
                    statusItem.length = switch section.name {
                    case .visible: Lengths.standard
                    case .hidden:
                        switch state {
                        case .hideItems: Lengths.expanded
                        case .showItems: Lengths.standard
                        }
                    }
                    constraint?.isActive = true
                } else {
                    statusItem.length = 0
                    constraint?.isActive = false
                    if let window {
                        var size = window.frame.size
                        size.width = 1
                        window.setContentSize(size)
                    }
                }
            }
            .store(in: &c)

        constraint?.publisher(for: \.isActive)
            .removeDuplicates()
            .sink { [weak self] isActive in
                self?.isVisible = isActive
            }
            .store(in: &c)

        window?.publisher(for: \.frame)
            .sink { [weak self] frame in
                guard
                    let self,
                    let screen = window?.screen,
                    screen.frame.intersects(frame)
                else {
                    return
                }
                windowFrame = frame
            }
            .store(in: &c)

        if let appState {
            appState.settingsManager.generalSettingsManager.$iceIcon
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else {
                        return
                    }
                    updateStatusItem(with: state)
                }
                .store(in: &c)

            appState.settingsManager.generalSettingsManager.$customIceIconIsTemplate
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else {
                        return
                    }
                    updateStatusItem(with: state)
                }
                .store(in: &c)

            // Keep the bar consistent with the user's managed/excluded intent
            // after every enumeration refresh (apps restore their own saved
            // item positions at launch, so both directions drift).
            if identifier == .iceIcon {
                appState.menuBarItemsModel.$items
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] items in
                        self?.reconcileItems(items)
                    }
                    .store(in: &c)
            }
        }

        cancellables = c
    }

    /// Sets the initial configuration for the status item.
    private func configureStatusItem() {
        defer {
            configureCancellables()
            updateStatusItem(with: state)
        }
        guard let button = statusItem.button else {
            return
        }
        button.target = self
        button.action = #selector(performAction)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// Updates the appearance of the status item using the given hiding state.
    private func updateStatusItem(with state: HidingState) {
        guard
            let appState,
            let section,
            let button = statusItem.button
        else {
            return
        }

        switch section.name {
        case .visible:
            isVisible = true
            // Enable the cell, as it may have been previously disabled.
            button.cell?.isEnabled = true
            let icon = appState.settingsManager.generalSettingsManager.iceIcon
            // We can usually just set the image directly from the icon.
            button.image = switch state {
            case .hideItems: icon.hidden.nsImage(for: appState)
            case .showItems: icon.visible.nsImage(for: appState)
            }
            if
                case .custom = icon.name,
                let originalImage = button.image
            {
                // Custom icons need to be resized to fit inside the button.
                let originalWidth = originalImage.size.width
                let originalHeight = originalImage.size.height
                let ratio = max(originalWidth / 25, originalHeight / 17)
                let newSize = CGSize(width: originalWidth / ratio, height: originalHeight / ratio)
                button.image = originalImage.resized(to: newSize)
            }
        case .hidden:
            switch state {
            case .hideItems:
                isVisible = true
                // Prevent the cell from highlighting while expanded.
                button.cell?.isEnabled = false
                // Cell still sometimes briefly flashes on expansion unless manually unhighlighted.
                button.isHighlighted = false
                button.image = nil
            case .showItems:
                // Furl never shows the divider as a chevron item.
                isVisible = false
                // Enable the cell, as it may have been previously disabled.
                button.cell?.isEnabled = true
                button.image = ControlItemImage.builtin(.chevronLarge).nsImage(for: appState)
            }
        }
    }

    /// Briefly shows a warning symbol in place of the icon after a failed
    /// reveal, so the pick isn't silently inert.
    private func flashRevealFailure() {
        guard let button = statusItem.button else {
            return
        }
        button.image = NSImage(
            systemSymbolName: "exclamationmark.triangle",
            accessibilityDescription: "Furl could not reveal the item"
        )
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self else {
                return
            }
            updateStatusItem(with: state)
        }
    }

    /// Performs the control item's action.
    @objc private func performAction() {
        guard
            let appState,
            let event = NSApp.currentEvent
        else {
            return
        }
        switch event.type {
        case .leftMouseDown, .leftMouseUp:
            if NSEvent.modifierFlags == .control {
                presentMenu(createMenu())
            } else if isSectionDivider {
                section?.toggle()
            } else {
                showItemsDropdown(with: appState)
            }
        case .rightMouseUp:
            presentMenu(createMenu())
        default:
            break
        }
    }

    /// Shows one of Furl's own menus under the icon, tracking that it's open.
    /// `showMenu` runs a nested tracking loop and returns once dismissed; while
    /// it runs, `isOwnMenuOpen` keeps auto-hide/reconcile from moving items and
    /// dismissing the menu.
    private func presentMenu(_ menu: NSMenu) {
        isOwnMenuOpen = true
        defer { isOwnMenuOpen = false }
        statusItem.showMenu(menu)
    }

    /// Shows a dropdown listing every menu bar item, so items that are hidden
    /// or overflowed off-screen can still be reached.
    private func showItemsDropdown(with appState: AppState) {
        let menu = NSMenu(title: "Furl")

        // Use the background-cached list for an instant menu — never
        // enumerate the AX tree on the main thread at click time (a cold
        // sweep takes over a second on a busy system).
        let model = appState.menuBarItemsModel
        // Kick off a background re-enumeration so the list self-heals across
        // opens — e.g. items that were slow to register right after launch.
        model.refresh()
        dropdownEntries = model.managedItems

        // If the list is empty, watch for that refresh landing while the menu
        // is open and swap the real rows in live, instead of making the user
        // close and reopen. (Menu tracking drains the main queue, so the
        // publisher delivers while the menu is up.)
        var liveUpdate: AnyCancellable?

        if dropdownEntries.isEmpty {
            liveUpdate = model.$items
                .receive(on: DispatchQueue.main)
                .sink { [weak self, weak menu] _ in
                    guard
                        let self,
                        let menu,
                        dropdownEntries.isEmpty
                    else {
                        return
                    }
                    let entries = model.managedItems
                    guard !entries.isEmpty else {
                        return
                    }
                    dropdownEntries = entries
                    // Replace the placeholder rows above the utility section.
                    while let first = menu.items.first, !first.isSeparatorItem {
                        menu.removeItem(at: 0)
                    }
                    for (index, item) in entryMenuItems(for: entries).enumerated() {
                        menu.insertItem(item, at: index)
                    }
                }

            if !MenuBarItemsReader.hasAccessibility {
                let grantItem = NSMenuItem(
                    title: "Enable Accessibility for Furl…",
                    action: #selector(requestAccessibility),
                    keyEquivalent: ""
                )
                grantItem.target = self
                menu.addItem(grantItem)

                let hintItem = NSMenuItem(
                    title: "Furl needs Accessibility to list menu bar items.",
                    action: nil,
                    keyEquivalent: ""
                )
                hintItem.isEnabled = false
                menu.addItem(hintItem)
                menu.addItem(relaunchMenuItem())
            } else if model.items.isEmpty {
                // Cold cache right after launch; the refresh above fills it
                // within a second or two (and the live update swaps it in).
                // Still empty long after launch means enumeration is stuck —
                // offer the remedy.
                let loadingItem = NSMenuItem(
                    title: "Loading items…",
                    action: nil,
                    keyEquivalent: ""
                )
                loadingItem.isEnabled = false
                menu.addItem(loadingItem)
                if ContinuousClock.now - Self.launchTime > .seconds(20) {
                    menu.addItem(relaunchMenuItem())
                }
            } else {
                let allExcludedItem = NSMenuItem(
                    title: "All items are visible in the menu bar — see Furl Settings",
                    action: nil,
                    keyEquivalent: ""
                )
                allExcludedItem.isEnabled = false
                menu.addItem(allExcludedItem)
            }
        } else {
            for item in entryMenuItems(for: dropdownEntries) {
                menu.addItem(item)
            }
        }

        appendUtilityItems(to: menu)
        presentMenu(menu)
        liveUpdate?.cancel()
    }

    /// Menu rows for the given entries; tags index into `dropdownEntries`.
    private func entryMenuItems(for entries: [MenuBarItemEntry]) -> [NSMenuItem] {
        entries.enumerated().map { index, entry in
            let item = NSMenuItem(
                title: entry.displayTitle,
                action: #selector(pickDropdownItem(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = index
            if let icon = entry.appIcon, let resized = icon.copy() as? NSImage {
                resized.size = NSSize(width: 16, height: 16)
                item.image = resized
            }
            return item
        }
    }

    /// A row that relaunches Furl — the remedy when the Accessibility state
    /// looks stuck (e.g. the grant landed against a stale process record).
    private func relaunchMenuItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "Relaunch Furl",
            action: #selector(relaunchApp),
            keyEquivalent: ""
        )
        item.target = self
        return item
    }

    /// Appends the settings and quit items to the given menu.
    private func appendUtilityItems(to menu: NSMenu) {
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(
            title: "Settings",
            action: #selector(AppDelegate.openSettingsWindow),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = .command
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settingsItem)
        let quitItem = NSMenuItem(
            title: "Quit",
            action: #selector(NSApp.terminate),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = .command
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quitItem)
    }

    /// Activates the menu bar item for the selected dropdown entry.
    @objc private func pickDropdownItem(_ sender: NSMenuItem) {
        let index = sender.tag
        guard dropdownEntries.indices.contains(index) else {
            return
        }
        let entry = dropdownEntries[index]
        // Defer until our dropdown has fully dismissed, then bring the item
        // on-screen (if hidden) and open it.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            await self?.activateMenuBarItem(entry)
        }
    }

    /// Brings a (possibly hidden / off-screen) menu bar item on-screen via the
    /// move engine and leaves it there for the user to click.
    ///
    /// Furl does not synthesize the click. It was tried and is inconsistent:
    /// some apps open their menu from a synthetic click, some ignore it, and
    /// AXPress opens menus off-screen and pops main windows. Revealing the item
    /// in its correct position and letting the user click it is uniform across
    /// every app and needs no per-app handling. The item auto-hides once the
    /// user is done with it (see `scheduleHide`). Multiple items can be peeked
    /// at once; each tracks and hides itself independently.
    @MainActor
    private func activateMenuBarItem(_ entry: MenuBarItemEntry) async {
        // The cached AX element can be stale — the app may have recreated its
        // item since the last refresh. Re-resolve against a fresh single-app
        // enumeration before acting.
        var entry = entry
        if MenuBarItemWindowResolver.axFrame(of: entry.element) == nil {
            guard let fresh = MenuBarItemsReader.refreshedEntry(for: entry) else {
                return
            }
            entry = fresh
        }

        // Reveal, retrying once — a synthetic drag can fail transiently if the
        // bar is still settling from another move.
        var revealedTarget = await revealItemOnScreen(entry)
        if revealedTarget == nil {
            try? await Task.sleep(for: .milliseconds(200))
            revealedTarget = await revealItemOnScreen(entry)
        }
        guard let revealed = revealedTarget else {
            // Every drag attempt failed — the item won't appear. Say so
            // rather than leaving the pick silently inert.
            NSSound.beep()
            flashRevealFailure()
            return
        }
        // Already peeked (e.g. picked again while still on-screen) — its
        // existing auto-hide loop owns it; don't start a second one.
        guard !activePeeks.contains(revealed.windowID) else {
            return
        }
        activePeeks.insert(revealed.windowID)

        // Baseline: windows already open (owned by this item's app) at reveal
        // time, so a pre-existing one isn't mistaken for a menu the user opens.
        let windowsBeforeOpen = Set(
            MenuBarItemWindowResolver.onScreenWindows()
                .filter { Self.looksLikeItemMenu($0, itemPID: entry.pid, itemFrame: revealed.frame) }
                .map(\.windowID)
        )

        scheduleHide(of: revealed, entry: entry, windowsBeforeOpen: windowsBeforeOpen)
    }

    /// Excludes the given item (moves it to the visible side, just right of our
    /// icon), or returns it to the managed/hidden side. Driven by the settings.
    func setExcluded(_ entry: MenuBarItemEntry, _ excluded: Bool) {
        appState?.menuBarItemsModel.setExcluded(entry, excluded)
        isRepositioning = true
        Task { @MainActor in
            defer {
                isRepositioning = false
            }
            if excluded {
                _ = await moveItemToExcludedPosition(entry)
            } else if
                let axFrame = MenuBarItemWindowResolver.axFrame(of: entry.element),
                let match = MenuBarItemWindowResolver.resolve(axFrame: axFrame)
            {
                await hideItem(
                    MenuBarItemMover.Target(windowID: match.windowID, pid: match.ownerPID, frame: match.frame)
                )
            }
        }
    }

    /// Moves an excluded item to the visible side, just right of our icon (so
    /// it's clearly separate from temporarily-peeked items on the left).
    @discardableResult
    private func moveItemToExcludedPosition(_ entry: MenuBarItemEntry) async -> MenuBarItemMover.Target? {
        guard
            let axFrame = MenuBarItemWindowResolver.axFrame(of: entry.element),
            let itemMatch = MenuBarItemWindowResolver.resolve(axFrame: axFrame),
            let iconFrame = iconCGFrame,
            let anchorMatch = MenuBarItemWindowResolver.resolve(axFrame: iconFrame)
        else {
            return nil
        }
        var item = MenuBarItemMover.Target(
            windowID: itemMatch.windowID,
            pid: itemMatch.ownerPID,
            frame: itemMatch.frame
        )
        let anchor = MenuBarItemMover.Target(
            windowID: anchorMatch.windowID,
            pid: anchorMatch.ownerPID,
            frame: anchorMatch.frame
        )
        do {
            try await MenuBarItemMover.move(item: item, toEdge: .right, of: anchor)
            if let after = MenuBarItemMover.liveFrame(for: item.windowID) {
                item.frame = after
            }
            return item
        } catch {
            Logger.controlItem.warning("Failed to move item to visible side: \(error)")
            return nil
        }
    }

    /// Slides a hidden item on-screen, just left of our icon, and returns its
    /// moved target. The item's window is composited by Control Center, so it's
    /// matched by frame and the move events target Control Center's pid.
    @discardableResult
    private func revealItemOnScreen(_ entry: MenuBarItemEntry) async -> MenuBarItemMover.Target? {
        guard
            let axFrame = MenuBarItemWindowResolver.axFrame(of: entry.element),
            let itemMatch = MenuBarItemWindowResolver.resolve(axFrame: axFrame),
            let iconFrame = iconCGFrame,
            let anchorMatch = MenuBarItemWindowResolver.resolve(axFrame: iconFrame)
        else {
            return nil
        }
        // If the item is already visible (e.g. its app restored an on-screen
        // position at launch), don't move it — a drag to a spot it already
        // occupies can never satisfy the mover's frame-changed check and just
        // jitters through retries. Peeking a visible item = clicking it.
        if MenuBarItemWindowResolver.isOnAnyDisplay(itemMatch.frame) {
            return MenuBarItemMover.Target(
                windowID: itemMatch.windowID,
                pid: itemMatch.ownerPID,
                frame: itemMatch.frame
            )
        }
        var item = MenuBarItemMover.Target(
            windowID: itemMatch.windowID,
            pid: itemMatch.ownerPID,
            frame: itemMatch.frame
        )
        // Drop the item a full item-width to the left of our icon, so it lands
        // beside the icon on the left rather than shoving the icon over.
        var anchorFrame = anchorMatch.frame
        anchorFrame.origin.x -= itemMatch.frame.width
        let anchor = MenuBarItemMover.Target(
            windowID: anchorMatch.windowID,
            pid: anchorMatch.ownerPID,
            frame: anchorFrame
        )
        do {
            try await MenuBarItemMover.move(item: item, toEdge: .left, of: anchor)
            if let after = MenuBarItemMover.liveFrame(for: item.windowID) {
                item.frame = after
            }
            return item
        } catch {
            Logger.controlItem.warning("Failed to reveal menu bar item: \(error)")
            return nil
        }
    }

    /// Slides an item back to the hidden side of the spacer (off-screen).
    private func hideItem(_ target: MenuBarItemMover.Target) async {
        var item = target
        if let live = MenuBarItemMover.liveFrame(for: item.windowID) {
            item.frame = live
        }
        // Prefer the spacer copy in the same menu-bar band as the item (each
        // display has its own copy of every status item).
        guard let spacer = MenuBarItemWindowResolver.resolveSpacer(nearY: item.frame.minY) else {
            return
        }
        let spacerTarget = MenuBarItemMover.Target(
            windowID: spacer.windowID,
            pid: spacer.ownerPID,
            frame: spacer.frame
        )
        do {
            try await MenuBarItemMover.move(item: item, toEdge: .left, of: spacerTarget)
        } catch {
            Logger.controlItem.warning("Failed to hide menu bar item: \(error)")
        }
    }

    /// Corrects item positions after every enumeration refresh: managed items
    /// found visible on the bar are tucked back off-screen, and excluded items
    /// found anywhere but right of the icon are moved back there. This is what
    /// restores positions at launch (both Furl's and the items' apps — apps
    /// restore their own saved, possibly stale, positions when they start).
    /// Skipped while a peek is active or our menu is open (a move would dismiss
    /// it), and rate-limited per item.
    private func reconcileItems(_ items: [MenuBarItemEntry]) {
        guard
            activePeeks.isEmpty,
            !isOwnMenuOpen,
            !isRepositioning,
            // Never start corrective moves while the user is mid-click or
            // mid-drag — the mover freezes the cursor. The next refresh retries.
            NSEvent.pressedMouseButtons == 0,
            let model = appState?.menuBarItemsModel,
            let iconFrame = iconCGFrame
        else {
            return
        }
        // Entries older than the cooldown no longer constrain anything.
        reconcileCooldown = reconcileCooldown.filter {
            Date().timeIntervalSince($0.value) < 60
        }

        // A correction either tucks a stray managed item (with its resolved
        // window) or re-places an excluded item right of the icon.
        var tucks = [(entry: MenuBarItemEntry, match: MenuBarItemWindowResolver.Match)]()
        var placements = [MenuBarItemEntry]()
        // Excluded items that are already where they belong, with their
        // current x — their left-to-right order is the user's arrangement.
        var inPlaceExcluded = [(entry: MenuBarItemEntry, minX: CGFloat)]()

        for entry in items {
            guard let axFrame = MenuBarItemWindowResolver.axFrame(of: entry.element) else {
                continue
            }
            if model.isExcluded(entry) {
                // Excluded items belong on-screen, right of the icon.
                let isInPlace = MenuBarItemWindowResolver.isOnAnyDisplay(axFrame)
                    && axFrame.minX >= iconFrame.maxX - 5
                if isInPlace {
                    inPlaceExcluded.append((entry, axFrame.minX))
                } else if reconcileCooldown[entry.identity] == nil {
                    reconcileCooldown[entry.identity] = Date()
                    placements.append(entry)
                }
            } else {
                guard
                    MenuBarItemWindowResolver.isOnAnyDisplay(axFrame),
                    reconcileCooldown[entry.identity] == nil,
                    let match = MenuBarItemWindowResolver.resolve(axFrame: axFrame)
                else {
                    continue
                }
                reconcileCooldown[entry.identity] = Date()
                tucks.append((entry, match))
            }
        }

        // Capture the user's on-bar arrangement (⌘-drags) so it survives
        // relaunches. Only when nothing is mid-move, so a half-finished batch
        // can't be recorded as intent.
        if placements.isEmpty && !inPlaceExcluded.isEmpty {
            let observedOrder = inPlaceExcluded.sorted { $0.minX < $1.minX }.map(\.entry.identity)
            model.recordExcludedOrder(observedOrder)
        }

        guard !(tucks.isEmpty && placements.isEmpty) else {
            return
        }
        // Restore the persisted left-to-right order: place in REVERSE order,
        // because each placement lands at the icon's right edge and pushes
        // earlier placements further right.
        placements.sort { lhs, rhs in
            (model.excludedOrderIndex(lhs) ?? .max) > (model.excludedOrderIndex(rhs) ?? .max)
        }
        // Move sequentially — concurrent synthetic drags would fight over the
        // event taps and the cursor.
        isRepositioning = true
        Task { @MainActor in
            defer {
                isRepositioning = false
            }
            for (entry, match) in tucks {
                await Self.waitForNoMouseButtons()
                Logger.controlItem.info("Tucking stray managed item \(entry.identity) off-screen")
                await hideItem(
                    MenuBarItemMover.Target(windowID: match.windowID, pid: match.ownerPID, frame: match.frame)
                )
            }
            for entry in placements {
                await Self.waitForNoMouseButtons()
                Logger.controlItem.info("Restoring excluded item \(entry.identity) right of the icon")
                await moveItemToExcludedPosition(entry)
            }
        }
    }

    /// Whether an on-screen window is the menu the peeked item has open.
    /// Attributed by the item app's process id (see below) rather than by
    /// screen position, so two items peeked at once don't see each other's
    /// menus.
    private static func looksLikeItemMenu(
        _ window: MenuBarItemWindowResolver.WindowInfo,
        itemPID: pid_t,
        itemFrame: CGRect
    ) -> Bool {
        // Attribute the menu to a specific item by its OWNING PROCESS, not by
        // screen position — two items peeked at once sit close together, and a
        // position match would let each see the other's menu. Every app whose
        // menu bar item opens a menu/popover owns that window under its own pid.
        // (The rare menu owned by the window server rather than the app — a
        // plain NSMenu on some apps — can't be attributed this way and won't
        // hold the item open; those were never reliably detected regardless.)
        guard window.ownerPID == itemPID else {
            return false
        }
        // Menu/popover shape: not full-window-sized (excludes an app's main
        // window, which some apps raise alongside their menu bar action), and
        // hanging from the menu bar rather than floating mid-screen.
        return window.frame.width <= 600
            && window.frame.minY >= itemFrame.minY - 10
            && window.frame.minY <= itemFrame.maxY + 700
            && MenuBarItemWindowResolver.isOnAnyDisplay(window.frame)
    }

    /// Keeps a revealed item on-screen until the user is done with it, then
    /// slides it back off-screen. Two cases:
    ///
    /// - The user never opens it: hide once the auto-hide interval elapses with
    ///   no menu open.
    /// - The user opens its menu: keep it out while the menu is open, then hide
    ///   shortly after the menu is dismissed.
    private func scheduleHide(
        of target: MenuBarItemMover.Target,
        entry: MenuBarItemEntry,
        windowsBeforeOpen: Set<CGWindowID>
    ) {
        let duration = hideDuration(for: entry)
        Task { @MainActor in
            defer {
                activePeeks.remove(target.windowID)
            }
            var idleDeadline = ContinuousClock.now.advanced(by: .seconds(duration))
            // Bound the whole peek so a menu left open forever can't pin the
            // item on-screen indefinitely.
            let hardDeadline = ContinuousClock.now.advanced(by: .seconds(600))
            // After the user dismisses the menu, let the item settle for a beat
            // before sliding it away — an instant tuck feels abrupt, and this
            // also lets a quick re-open keep the item on-screen.
            let settleAfterDismiss = Duration.seconds(1)
            var everOpened = false
            var dismissedAt: ContinuousClock.Instant?

            while ContinuousClock.now < hardDeadline {
                // Excluded mid-peek → it belongs on the visible side now; leave
                // it there (setExcluded handles the position).
                if appState?.menuBarItemsModel.isExcluded(entry) == true {
                    return
                }
                // Never move an item while our own menu is open — the drag
                // would dismiss it. Hold and re-check.
                if isOwnMenuOpen {
                    try? await Task.sleep(for: .milliseconds(300))
                    continue
                }
                let menuOpen = MenuBarItemWindowResolver.onScreenWindows().contains { window in
                    !windowsBeforeOpen.contains(window.windowID)
                        && Self.looksLikeItemMenu(window, itemPID: entry.pid, itemFrame: target.frame)
                }
                if menuOpen {
                    everOpened = true
                    dismissedAt = nil
                } else if Self.isPointerNearItem(windowID: target.windowID, fallbackFrame: target.frame) {
                    // The pointer is on the item — resting there or reaching
                    // for it. Hold the hide, with a short grace period after
                    // it leaves.
                    dismissedAt = nil
                    idleDeadline = max(idleDeadline, ContinuousClock.now.advanced(by: .seconds(2)))
                } else if everOpened {
                    // Menu was open and is now closed. Hold for a beat; a
                    // re-open clears this and keeps the item out.
                    let since = dismissedAt ?? ContinuousClock.now
                    dismissedAt = since
                    if ContinuousClock.now - since >= settleAfterDismiss {
                        break
                    }
                } else if ContinuousClock.now >= idleDeadline {
                    // Never opened within the interval → done.
                    break
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
            // Don't grab the item mid-click/drag — the mover freezes the
            // cursor, which would interrupt whatever the user is doing.
            await Self.waitForNoMouseButtons()
            await hideItem(target)
        }
    }

    /// Whether the pointer is on (or within a few points of) the peeked item —
    /// the user is using it or reaching for it, so it must not hide.
    private static func isPointerNearItem(windowID: CGWindowID, fallbackFrame: CGRect) -> Bool {
        guard let primaryScreen = NSScreen.screens.first else {
            return false
        }
        let frame = MenuBarItemMover.liveFrame(for: windowID) ?? fallbackFrame
        // NSEvent.mouseLocation is AppKit bottom-left origin; the frame is
        // CoreGraphics top-left origin.
        let mouse = NSEvent.mouseLocation
        let point = CGPoint(x: mouse.x, y: primaryScreen.frame.maxY - mouse.y)
        return frame.insetBy(dx: -6, dy: -4).contains(point)
    }

    /// Waits (bounded) until no mouse button is pressed, so a synthetic move
    /// never freezes the cursor in the middle of a real click or drag.
    private static func waitForNoMouseButtons(upTo limit: Duration = .seconds(30)) async {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while NSEvent.pressedMouseButtons != 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// The number of seconds a peeked item stays on-screen before auto-hiding —
    /// the item's per-app override if set, otherwise the global default.
    private func hideDuration(for entry: MenuBarItemEntry) -> Double {
        let global = appState?.settingsManager.generalSettingsManager.autoHideInterval ?? 10
        return appState?.menuBarItemsModel.autoHideOverride(entry) ?? global
    }

    /// Prompts the user to grant Accessibility access, then polls for the
    /// grant so the item list fills in as soon as it's given — no relaunch.
    @objc private func requestAccessibility() {
        MenuBarItemsReader.requestAccessibility()
        guard !isPollingForAccessibility else {
            return
        }
        isPollingForAccessibility = true
        Task { @MainActor [weak self] in
            defer {
                self?.isPollingForAccessibility = false
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(300))
            while ContinuousClock.now < deadline {
                if MenuBarItemsReader.hasAccessibility {
                    self?.appState?.menuBarItemsModel.refresh()
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Relaunches the app: spawns a detached `open` for our bundle (after a
    /// beat, so this instance has fully exited) and terminates.
    @objc private func relaunchApp() {
        let path = Bundle.main.bundlePath.replacingOccurrences(of: "'", with: "'\\''")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.5; /usr/bin/open '\(path)'"]
        do {
            try process.run()
        } catch {
            Logger.controlItem.error("Failed to spawn relauncher: \(error)")
            return
        }
        NSApp.terminate(nil)
    }

    /// Creates a menu to show under the control item.
    private func createMenu() -> NSMenu {
        let menu = NSMenu(title: "Furl")

        let settingsItem = NSMenuItem(
            title: "Settings",
            action: #selector(AppDelegate.openSettingsWindow),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = .command
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit",
            action: #selector(NSApp.terminate),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = .command
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quitItem)

        return menu
    }

    /// Adds the control item to the menu bar.
    func addToMenuBar() {
        guard !isAddedToMenuBar else {
            return
        }
        statusItem.isVisible = true
    }

    /// Removes the control item from the menu bar.
    func removeFromMenuBar() {
        guard isAddedToMenuBar else {
            return
        }
        // Setting `statusItem.isVisible` to `false` has the unwanted side
        // effect of deleting the preferredPosition. Cache and restore it.
        let autosaveName = statusItem.autosaveName as String
        let cached = StatusItemDefaults[.preferredPosition, autosaveName]
        statusItem.isVisible = false
        StatusItemDefaults[.preferredPosition, autosaveName] = cached
    }
}

// MARK: - Logger
private extension Logger {
    /// The logger to use for control items.
    static let controlItem = Logger(category: "ControlItem")
}
