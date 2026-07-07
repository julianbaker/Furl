//
//  AboutSettingsPane.swift
//  Furl
//

import SwiftUI

struct AboutSettingsPane: View {
    @EnvironmentObject var appState: AppState
    @State private var updateOutcome: UpdateChecker.Outcome?
    @State private var isCheckingForUpdates = false
    @State private var isPresentingAcknowledgements = false

    var body: some View {
        VStack(spacing: 0) {
            mainForm
            Spacer(minLength: 20)
            bottomBar
        }
        .padding(30)
    }

    @ViewBuilder
    private var mainForm: some View {
        IceForm(padding: EdgeInsets(), spacing: 0) {
            appIconAndCopyrightSection
                .layoutPriority(1)
        }
        .scrollDisabled(true)
    }

    @ViewBuilder
    private var appIconAndCopyrightSection: some View {
        IceSection {
            HStack(spacing: 24) {
                Image(.appIconPreview)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 225)

                VStack(alignment: .leading) {
                    Text("Furl")
                        .font(.system(size: 72, weight: .medium))
                        .foregroundStyle(.primary)

                    Text("Version \(Constants.versionString)")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)

                    Text(Constants.copyrightString)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.tertiary)

                    Link("GitHub", destination: repositoryURL)
                        .font(.system(size: 14))
                        .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var repositoryURL: URL {
        URL(string: "https://github.com/julianbaker/Furl")!
    }

    @ViewBuilder
    private var bottomBar: some View {
        HStack {
            Button("Quit Furl", role: .destructive) {
                NSApp.terminate(nil)
            }
            .tint(.red)
            Spacer()
            Button(isCheckingForUpdates ? "Checking…" : "Check for Updates…") {
                isCheckingForUpdates = true
                Task {
                    updateOutcome = await UpdateChecker.check()
                    isCheckingForUpdates = false
                }
            }
            .disabled(isCheckingForUpdates)
            Button("Acknowledgements") {
                isPresentingAcknowledgements = true
            }
            .sheet(isPresented: $isPresentingAcknowledgements) {
                AcknowledgementsView()
            }
        }
        .buttonStyle(.bordered)
        .frame(height: 40)
        .alert(
            updateAlertTitle,
            isPresented: Binding(
                get: { updateOutcome != nil },
                set: { if !$0 { updateOutcome = nil } }
            ),
            presenting: updateOutcome
        ) { outcome in
            if case .available(_, let url) = outcome {
                Button("View Release") { NSWorkspace.shared.open(url) }
                Button("Cancel", role: .cancel) { }
            } else {
                Button("OK") { }
            }
        } message: { outcome in
            switch outcome {
            case .upToDate:
                Text("Furl \(Constants.versionString) is the latest version.")
            case .available(let version, _):
                Text("Furl \(version) is available. You have \(Constants.versionString).")
            case .failed:
                Text("Check your connection and try again.")
            }
        }
    }

    private var updateAlertTitle: String {
        switch updateOutcome {
        case .available: "Update Available"
        case .upToDate: "You're up to date"
        case .failed: "Unable to Check for Updates"
        case nil: ""
        }
    }
}

private struct AcknowledgementsView: View {
    @Environment(\.dismiss) private var dismiss

    private let iceURL = URL(string: "https://github.com/jordanbaird/Ice")!
    private let launchAtLoginURL = URL(string: "https://github.com/sindresorhus/LaunchAtLogin-Modern")!

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Acknowledgements")
                .font(.title3.weight(.semibold))
                .padding(.bottom, 2)

            sectionHeader("Ice", url: iceURL)
            bodyText("Furl is based on Ice by Jordan Baird.")
            noteText("Ice is licensed under the GNU General Public License v3.0. Furl inherits the license; the full text ships with Furl's source.")

            Divider()

            sectionHeader("LaunchAtLogin-Modern", url: launchAtLoginURL)
            bodyText("Furl uses LaunchAtLogin-Modern by Sindre Sorhus.")

            ScrollView {
                Text(Self.mitLicenseText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(height: 140)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 8, style: .circular))

            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 440)
    }

    @ViewBuilder
    private func sectionHeader(_ name: String, url: URL) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name)
                .font(.headline)
            Spacer()
            Link("GitHub", destination: url)
                .font(.subheadline)
        }
    }

    @ViewBuilder
    private func bodyText(_ text: String) -> some View {
        Text(text)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func noteText(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static let mitLicenseText = """
    MIT License

    Copyright (c) Sindre Sorhus <sindresorhus@gmail.com> (https://sindresorhus.com)

    Permission is hereby granted, free of charge, to any person obtaining a copy of this \
    software and associated documentation files (the "Software"), to deal in the Software \
    without restriction, including without limitation the rights to use, copy, modify, \
    merge, publish, distribute, sublicense, and/or sell copies of the Software, and to \
    permit persons to whom the Software is furnished to do so, subject to the following \
    conditions:

    The above copyright notice and this permission notice shall be included in all copies \
    or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, \
    INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A \
    PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT \
    HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF \
    CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE \
    OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
    """
}
