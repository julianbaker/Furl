//
//  SettingsManager.swift
//  Furl
//

import Combine

@MainActor
final class SettingsManager: ObservableObject {
    /// The manager for general settings.
    let generalSettingsManager: GeneralSettingsManager

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// The shared app state.
    private(set) weak var appState: AppState?

    init(appState: AppState) {
        self.generalSettingsManager = GeneralSettingsManager(appState: appState)
        self.appState = appState
    }

    func performSetup() {
        configureCancellables()
        generalSettingsManager.performSetup()
    }

    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        generalSettingsManager.objectWillChange
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &c)

        cancellables = c
    }
}

// MARK: SettingsManager: BindingExposable
extension SettingsManager: BindingExposable { }
