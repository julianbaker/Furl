//
//  MenuBarItemsSettingsPane.swift
//  Furl
//

import SwiftUI

struct MenuBarItemsSettingsPane: View {
    @EnvironmentObject var appState: AppState

    private var model: MenuBarItemsModel {
        appState.menuBarItemsModel
    }

    var body: some View {
        IceForm {
            IceSection {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Control which items appear in the Furl menu and which appear directly on your menu bar. To hide an item entirely, disable it in macOS System Settings.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack {
                        Spacer()
                        Button("Open Menu Bar settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.link)
                        .fixedSize()
                    }
                }
            }
            IceSection {
                if model.sortedItems.isEmpty {
                    Text("No menu bar items found. Make sure Furl has Accessibility access in System Settings ▸ Privacy & Security ▸ Accessibility.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(model.sortedItems, id: \.identity) { entry in
                        MenuBarItemRow(entry: entry)
                    }
                }
            }
        }
    }
}

/// A single row: app icon + name, a per-item auto-hide value (managed items
/// only) that opens a stepper popover, and the "Managed" toggle.
private struct MenuBarItemRow: View {
    @EnvironmentObject var appState: AppState
    let entry: MenuBarItemEntry

    @State private var showingAutoHide = false

    private var model: MenuBarItemsModel {
        appState.menuBarItemsModel
    }

    private var globalDefault: Double {
        appState.settingsManager.generalSettingsManager.autoHideInterval
    }

    var body: some View {
        IceLabeledContent {
            HStack(spacing: 10) {
                if !model.isExcluded(entry) {
                    autoHideButton
                }
                Toggle(
                    "",
                    isOn: Binding(
                        get: { !model.isExcluded(entry) },
                        set: { appState.menuBarManager.setItemExcluded(entry, !$0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
        } label: {
            HStack(spacing: 8) {
                if let icon = entry.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 18, height: 18)
                }
                Text(entry.displayTitle)
            }
        }
    }

    private var autoHideButton: some View {
        let override = model.autoHideOverride(entry)
        return Button {
            showingAutoHide = true
        } label: {
            Text("\(Int(override ?? globalDefault))s")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(override == nil ? .secondary : .primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.separator, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .help("Auto-hide time for this item")
        .popover(isPresented: $showingAutoHide, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Auto-hide after")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                IceStepper(
                    value: Binding(
                        get: { model.autoHideOverride(entry) ?? globalDefault },
                        set: { model.setAutoHideOverride(entry, $0) }
                    ),
                    range: 2...60
                )
                if model.autoHideOverride(entry) != nil {
                    Button("Reset to default") {
                        model.setAutoHideOverride(entry, nil)
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }
            }
            .padding(14)
        }
    }
}
