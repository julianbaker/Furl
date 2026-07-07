//
//  AppState.swift
//  Furl
//

import Combine
import SwiftUI

/// The model for app-wide state.
@MainActor
final class AppState: ObservableObject {
    /// Manager for the state of the menu bar.
    private(set) lazy var menuBarManager = MenuBarManager(appState: self)

    /// Manager for the app's settings.
    private(set) lazy var settingsManager = SettingsManager(appState: self)

    /// Background-cached model of the menu bar's items.
    private(set) lazy var menuBarItemsModel = MenuBarItemsModel()

    /// Model for app-wide navigation.
    let navigationState = AppNavigationState()

    /// The app's delegate.
    private(set) weak var appDelegate: AppDelegate?

    /// The window that contains the settings interface.
    private(set) weak var settingsWindow: NSWindow?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// A Boolean value that indicates whether the app is running as a SwiftUI preview.
    let isPreview: Bool = {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        let key = "XCODE_RUNNING_FOR_PREVIEWS"
        return environment[key] != nil
        #else
        return false
        #endif
    }()

    /// Configures the internal observers for the app state.
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        NSWorkspace.shared.publisher(for: \.frontmostApplication)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] frontmostApplication in
                guard let self else {
                    return
                }
                navigationState.isAppFrontmost = frontmostApplication == .current
            }
            .store(in: &c)

        if let settingsWindow {
            settingsWindow.publisher(for: \.isVisible)
                .debounce(for: 0.05, scheduler: DispatchQueue.main)
                .sink { [weak self] isVisible in
                    guard let self else {
                        return
                    }
                    navigationState.isSettingsPresented = isVisible
                }
                .store(in: &c)
        } else {
            Logger.appState.warning("No settings window!")
        }

        menuBarManager.objectWillChange
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &c)
        settingsManager.objectWillChange
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &c)
        menuBarItemsModel.objectWillChange
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &c)

        cancellables = c
    }

    /// Sets up the app state.
    func performSetup() {
        configureCancellables()
        menuBarManager.performSetup()
        settingsManager.performSetup()
        menuBarItemsModel.performSetup()
        if !MenuBarItemsReader.hasAccessibility {
            MenuBarItemsReader.requestAccessibility()
        }
    }

    /// Assigns the app delegate to the app state.
    func assignAppDelegate(_ appDelegate: AppDelegate) {
        guard self.appDelegate == nil else {
            Logger.appState.warning("Multiple attempts made to assign app delegate")
            return
        }
        self.appDelegate = appDelegate
    }

    /// Assigns the settings window to the app state.
    func assignSettingsWindow(_ window: NSWindow) {
        guard window.identifier?.rawValue == Constants.settingsWindowID else {
            Logger.appState.warning("Window \(window.identifier?.rawValue ?? "<NIL>") is not the settings window!")
            return
        }
        settingsWindow = window
        configureCancellables()
    }

    /// Opens the settings window.
    func openSettingsWindow() {
        with(EnvironmentValues()) { environment in
            environment.openWindow(id: Constants.settingsWindowID)
        }
    }

    /// Dismisses the settings window.
    func dismissSettingsWindow() {
        with(EnvironmentValues()) { environment in
            environment.dismissWindow(id: Constants.settingsWindowID)
        }
    }

    /// Activates the app and sets its activation policy to the given value.
    func activate(withPolicy policy: NSApplication.ActivationPolicy) {
        // Store whether the app has previously activated inside an internal
        // context to keep it isolated.
        enum Context {
            static let hasActivated = ObjectStorage<Bool>()
        }

        func activate() {
            if let frontApp = NSWorkspace.shared.frontmostApplication {
                NSRunningApplication.current.activate(from: frontApp)
            } else {
                NSApp.activate()
            }
            NSApp.setActivationPolicy(policy)
        }

        if Context.hasActivated.value(for: self) == true {
            activate()
        } else {
            Context.hasActivated.set(true, for: self)
            Logger.appState.debug("First time activating app, so going through Dock")
            // Hack to make sure the app properly activates for the first time.
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                activate()
            }
        }
    }

    /// Deactivates the app and sets its activation policy to the given value.
    func deactivate(withPolicy policy: NSApplication.ActivationPolicy) {
        if let nextApp = NSWorkspace.shared.runningApplications.first(where: { $0 != .current }) {
            NSApp.yieldActivation(to: nextApp)
        } else {
            NSApp.deactivate()
        }
        NSApp.setActivationPolicy(policy)
    }
}

// MARK: AppState: BindingExposable
extension AppState: BindingExposable { }

// MARK: - Logger
private extension Logger {
    /// The logger to use for the app state.
    static let appState = Logger(category: "AppState")
}
