//
//  GeneralSettingsPane.swift
//  Furl
//

import LaunchAtLogin
import SwiftUI

struct GeneralSettingsPane: View {
    @EnvironmentObject var appState: AppState
    @State private var isImportingCustomIceIcon = false
    @State private var isPresentingError = false
    @State private var presentedError: LocalizedErrorWrapper?

    private var manager: GeneralSettingsManager {
        appState.settingsManager.generalSettingsManager
    }

    var body: some View {
        IceForm {
            IceSection {
                launchAtLogin
            }
            IceSection {
                iceIconOptions
            }
            IceSection {
                autoHideOption
            }
        }
        .alert(isPresented: $isPresentingError, error: presentedError) {
            Button("OK") {
                presentedError = nil
                isPresentingError = false
            }
        }
    }

    @ViewBuilder
    private var launchAtLogin: some View {
        LaunchAtLogin.Toggle()
    }

    @ViewBuilder
    private func menuItem(for imageSet: ControlItemImageSet) -> some View {
        Label {
            Text(imageSet.name.rawValue)
        } icon: {
            if let nsImage = imageSet.hidden.nsImage(for: appState) {
                switch imageSet.name {
                case .custom:
                    Image(size: CGSize(width: 18, height: 18)) { context in
                        context.draw(
                            Image(nsImage: nsImage),
                            in: context.clipBoundingRect
                        )
                    }
                default:
                    Image(nsImage: nsImage)
                }
            }
        }
    }

    @ViewBuilder
    private var iceIconOptions: some View {
        IceMenu("Menu bar icon") {
            Picker("Menu bar icon", selection: manager.bindings.iceIcon) {
                ForEach(ControlItemImageSet.userSelectableIceIcons) { imageSet in
                    Button {
                        manager.iceIcon = imageSet
                    } label: {
                        menuItem(for: imageSet)
                    }
                    .tag(imageSet)
                }
                if let lastCustomIceIcon = manager.lastCustomIceIcon {
                    Button {
                        manager.iceIcon = lastCustomIceIcon
                    } label: {
                        menuItem(for: lastCustomIceIcon)
                    }
                    .tag(lastCustomIceIcon)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()

            Divider()

            Button("Choose image…") {
                isImportingCustomIceIcon = true
            }
        } title: {
            menuItem(for: manager.iceIcon)
        }
        .annotation("Choose a custom icon to show in the menu bar")
        .fileImporter(
            isPresented: $isImportingCustomIceIcon,
            allowedContentTypes: [.image]
        ) { result in
            do {
                let url = try result.get()
                guard url.startAccessingSecurityScopedResource() else {
                    throw CocoaError(.fileReadNoPermission)
                }
                defer { url.stopAccessingSecurityScopedResource() }
                let data = try Data(contentsOf: url)
                manager.iceIcon = ControlItemImageSet(name: .custom, image: .data(data))
            } catch {
                presentedError = LocalizedErrorWrapper(error)
                isPresentingError = true
            }
        }

        if case .custom = manager.iceIcon.name {
            Toggle("Apply system theme to icon", isOn: manager.bindings.customIceIconIsTemplate)
                .annotation("Display the icon as a monochrome image matching the system appearance")
        }
    }

    @ViewBuilder
    private var autoHideOption: some View {
        IceLabeledContent("Auto-hide revealed items after") {
            IceStepper(value: manager.bindings.autoHideInterval, range: 2...60)
        }
    }
}
