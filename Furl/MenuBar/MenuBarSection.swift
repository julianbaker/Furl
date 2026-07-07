//
//  MenuBarSection.swift
//  Furl
//

import Cocoa

/// A representation of a section in a menu bar.
@MainActor
final class MenuBarSection {
    /// The name of a menu bar section.
    enum Name: CaseIterable {
        case visible
        case hidden

        /// A string to show in the interface.
        var displayString: String {
            switch self {
            case .visible: "Visible"
            case .hidden: "Hidden"
            }
        }
    }

    /// The name of the section.
    let name: Name

    /// The control item that manages the section.
    let controlItem: ControlItem

    /// The shared app state.
    private weak var appState: AppState?

    /// A Boolean value that indicates whether the section is hidden.
    var isHidden: Bool {
        controlItem.state == .hideItems
    }

    /// Creates a section with the given name, control item, and app state.
    init(name: Name, controlItem: ControlItem, appState: AppState) {
        self.name = name
        self.controlItem = controlItem
        self.appState = appState
    }

    /// Creates a section with the given name and app state.
    convenience init(name: Name, appState: AppState) {
        let controlItem = switch name {
        case .visible:
            ControlItem(identifier: .iceIcon, appState: appState)
        case .hidden:
            ControlItem(identifier: .hidden, appState: appState)
        }
        self.init(name: name, controlItem: controlItem, appState: appState)
    }

    /// Shows the section: both control items leave the expanded state, so the
    /// spacer collapses and the hidden items become visible.
    func show() {
        guard
            let appState,
            isHidden,
            controlItem.isAddedToMenuBar,
            let otherSection = appState.menuBarManager.sections.first(where: { $0.name != name })
        else {
            return
        }
        controlItem.state = .showItems
        otherSection.controlItem.state = .showItems
    }

    /// Hides the section: the spacer expands again, pushing the hidden items
    /// back off-screen.
    func hide() {
        guard
            let appState,
            !isHidden,
            let otherSection = appState.menuBarManager.sections.first(where: { $0.name != name })
        else {
            return
        }
        controlItem.state = .hideItems
        otherSection.controlItem.state = .hideItems
    }

    /// Toggles the visibility of the section.
    func toggle() {
        if isHidden {
            show()
        } else {
            hide()
        }
    }
}

// MARK: MenuBarSection: BindingExposable
extension MenuBarSection: BindingExposable { }
