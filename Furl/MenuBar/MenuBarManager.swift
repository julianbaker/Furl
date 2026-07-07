//
//  MenuBarManager.swift
//  Furl
//

import Cocoa
import Combine

/// Manager for the state of the menu bar.
@MainActor
final class MenuBarManager: ObservableObject {
    /// The shared app state.
    private weak var appState: AppState?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// The managed sections in the menu bar.
    private(set) var sections = [MenuBarSection]()

    /// Initializes a new menu bar manager instance.
    init(appState: AppState) {
        self.appState = appState
    }

    /// Performs the initial setup of the menu bar manager.
    func performSetup() {
        initializeSections()
        configureCancellables()
    }

    /// Performs the initial setup of the menu bar manager's sections.
    private func initializeSections() {
        // Make sure initialization can only happen once.
        guard sections.isEmpty else {
            Logger.menuBarManager.warning("Sections already initialized")
            return
        }

        guard let appState else {
            Logger.menuBarManager.error("Error initializing menu bar sections: Missing app state")
            return
        }

        // Visible icon + a hidden-section divider. The divider expands (the
        // spacer hack — pure NSStatusItem length, no synthetic events) to push
        // the items to its left off-screen; the icon stays to its right and
        // remains visible. The dropdown reaches the hidden items.
        sections = [
            MenuBarSection(name: .visible, appState: appState),
            MenuBarSection(name: .hidden, appState: appState),
        ]
    }

    /// Configures the internal observers for the manager.
    private func configureCancellables() {
        // No observers currently needed; peek reveal/auto-hide is driven by the
        // control item, not by section rehide strategies.
        cancellables = []
    }

    /// Returns the menu bar section with the given name.
    func section(withName name: MenuBarSection.Name) -> MenuBarSection? {
        sections.first { $0.name == name }
    }

    /// Excludes the given item from Furl (visible with its own icon) or
    /// returns it to the managed/hidden side, repositioning it in the bar.
    func setItemExcluded(_ entry: MenuBarItemEntry, _ excluded: Bool) {
        section(withName: .visible)?.controlItem.setExcluded(entry, excluded)
    }
}

// MARK: MenuBarManager: BindingExposable
extension MenuBarManager: BindingExposable { }

// MARK: - Logger
private extension Logger {
    /// Logger to use for the menu bar manager.
    static let menuBarManager = Logger(category: "MenuBarManager")
}
