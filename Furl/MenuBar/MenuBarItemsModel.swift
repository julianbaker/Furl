//
//  MenuBarItemsModel.swift
//  Furl
//

import AppKit
import Combine

/// Maintains a background-refreshed cache of the menu bar's items, so the
/// dropdown and settings can display them instantly without enumerating the
/// Accessibility tree on the main thread at click time.
@MainActor
final class MenuBarItemsModel: ObservableObject {
    /// The most recently enumerated menu bar items.
    @Published private(set) var items = [MenuBarItemEntry]()

    /// Identities of items the user has excluded from Furl — those stay
    /// visible in the menu bar with their own icon (right of the Furl icon).
    /// Everything else is managed: hidden off-screen and reachable via the menu.
    ///
    /// The array is ORDERED: it records the items' left-to-right order beside
    /// the icon, captured from the bar itself (so manual ⌘-drags stick) and
    /// replayed when items are re-placed after a relaunch.
    @Published private(set) var excludedIdentities = [String]()

    /// Per-item auto-hide overrides (seconds), keyed by identity. Absent means
    /// the item uses the global default. Only meaningful for managed items.
    @Published private(set) var autoHideOverrides = [String: Double]()

    private var cancellables = Set<AnyCancellable>()
    private var isRefreshing = false

    /// The managed items, shown in the Furl dropdown, sorted by app name.
    var managedItems: [MenuBarItemEntry] {
        items
            .filter { !isExcluded($0) }
            .sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
    }

    /// All items, sorted by app name (for the settings list).
    var sortedItems: [MenuBarItemEntry] {
        items.sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
    }

    /// Begins periodic and event-driven refreshes.
    func performSetup() {
        excludedIdentities = Defaults.stringArray(forKey: .excludedMenuBarItems) ?? []
        if let raw = Defaults.dictionary(forKey: .autoHideOverrides) {
            autoHideOverrides = raw.compactMapValues { ($0 as? NSNumber)?.doubleValue }
        }

        refresh()

        // Periodic refresh keeps the cache warm.
        Timer.publish(every: 7, on: .main, in: .default)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        // Refresh when the set of running apps changes.
        let center = NSWorkspace.shared.notificationCenter
        Publishers.MergeMany(
            center.publisher(for: NSWorkspace.didLaunchApplicationNotification),
            center.publisher(for: NSWorkspace.didTerminateApplicationNotification)
        )
        .debounce(for: 0.5, scheduler: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.refresh()
        }
        .store(in: &cancellables)
    }

    /// Whether the item is excluded from Furl (stays visible with its own icon).
    func isExcluded(_ entry: MenuBarItemEntry) -> Bool {
        excludedIdentities.contains(entry.identity) || excludedIdentities.contains(entry.legacyIdentity)
    }

    /// Records whether the item is excluded. (Repositioning in the bar is
    /// handled by `ControlItem`.) New exclusions append to the order; the
    /// reconcile pass captures the real on-bar order shortly after.
    func setExcluded(_ entry: MenuBarItemEntry, _ excluded: Bool) {
        if excluded {
            if !isExcluded(entry) {
                excludedIdentities.append(entry.identity)
            }
        } else {
            excludedIdentities.removeAll { $0 == entry.identity || $0 == entry.legacyIdentity }
        }
        Defaults.set(excludedIdentities, forKey: .excludedMenuBarItems)
    }

    /// The persisted order index for the entry, if it is excluded.
    func excludedOrderIndex(_ entry: MenuBarItemEntry) -> Int? {
        excludedIdentities.firstIndex(of: entry.identity)
            ?? excludedIdentities.firstIndex(of: entry.legacyIdentity)
    }

    /// Records the observed left-to-right order of the given excluded
    /// identities (a subset of `excludedIdentities` — items whose apps aren't
    /// running stay where they are in the stored order).
    func recordExcludedOrder(_ observed: [String]) {
        let observedSet = Set(observed)
        var iterator = observed.makeIterator()
        var merged = excludedIdentities
        for index in merged.indices where observedSet.contains(merged[index]) {
            if let next = iterator.next() {
                merged[index] = next
            }
        }
        guard merged != excludedIdentities else {
            return
        }
        excludedIdentities = merged
        Defaults.set(merged, forKey: .excludedMenuBarItems)
    }

    /// The per-item auto-hide override in seconds, or `nil` if using the default.
    func autoHideOverride(_ entry: MenuBarItemEntry) -> Double? {
        autoHideOverrides[entry.identity] ?? autoHideOverrides[entry.legacyIdentity]
    }

    /// Sets (or clears, with `nil`) the per-item auto-hide override.
    func setAutoHideOverride(_ entry: MenuBarItemEntry, _ seconds: Double?) {
        autoHideOverrides.removeValue(forKey: entry.legacyIdentity)
        if let seconds {
            autoHideOverrides[entry.identity] = seconds
        } else {
            autoHideOverrides.removeValue(forKey: entry.identity)
        }
        Defaults.set(autoHideOverrides, forKey: .autoHideOverrides)
    }

    /// Re-enumerates the menu bar items off the main thread and republishes them.
    func refresh() {
        guard !isRefreshing else {
            return
        }
        isRefreshing = true
        let apps = MenuBarItemsReader.appSnapshot()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let entries = MenuBarItemsReader.readItems(from: apps)
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                // Migrate BEFORE publishing — subscribers (the reconcile
                // pass) match against identities the moment items lands.
                self.migrateLegacyIdentities(entries)
                self.items = entries
                self.isRefreshing = false
            }
        }
    }

    /// Upgrades persisted index-based identities to identifier-based ones as
    /// their items are observed. Old keys age out one match at a time; no
    /// big-bang migration.
    private func migrateLegacyIdentities(_ entries: [MenuBarItemEntry]) {
        for entry in entries where entry.identity != entry.legacyIdentity {
            if let index = excludedIdentities.firstIndex(of: entry.legacyIdentity) {
                excludedIdentities[index] = entry.identity
                Defaults.set(excludedIdentities, forKey: .excludedMenuBarItems)
            }
            if let value = autoHideOverrides[entry.legacyIdentity] {
                autoHideOverrides.removeValue(forKey: entry.legacyIdentity)
                autoHideOverrides[entry.identity] = value
                Defaults.set(autoHideOverrides, forKey: .autoHideOverrides)
            }
        }
    }
}
