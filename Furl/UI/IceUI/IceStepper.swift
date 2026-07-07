//
//  IceStepper.swift
//  Furl
//

import SwiftUI

/// A compact segmented `−` / value / `+` stepper with hover, press, and
/// hold-to-repeat, dimming each button at the range limits. Clamps its
/// binding to `range`.
struct IceStepper: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 1
    var format: (Double) -> String = { "\(Int($0))s" }

    var body: some View {
        HStack(spacing: 0) {
            StepperButton(systemName: "minus", disabled: value <= range.lowerBound) {
                value = max(value - step, range.lowerBound)
            }
            Divider()
            Text(format(value))
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(.primary)
                .frame(minWidth: 48, maxHeight: .infinity)
            Divider()
            StepperButton(systemName: "plus", disabled: value >= range.upperBound) {
                value = min(value + step, range.upperBound)
            }
        }
        .fixedSize()
        .frame(height: 28)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct StepperButton: View {
    let systemName: String
    let disabled: Bool
    let action: () -> Void

    @State private var hovering = false
    @State private var pressing = false
    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(disabled ? .tertiary : (hovering || pressing ? .primary : .secondary))
            .frame(width: 32, height: 28)
            .background(background)
            .contentShape(Rectangle())
            .onHover { hovering = disabled ? false : $0 }
            .gesture(press)
    }

    private var background: Color {
        if disabled { return .clear }
        if pressing { return Color.primary.opacity(0.12) }
        if hovering { return Color.primary.opacity(0.06) }
        return .clear
    }

    private var press: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !disabled, !pressing else {
                    return
                }
                pressing = true
                action()
                repeatTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(450))
                    while !Task.isCancelled {
                        action()
                        try? await Task.sleep(for: .milliseconds(60))
                    }
                }
            }
            .onEnded { _ in
                pressing = false
                repeatTask?.cancel()
                repeatTask = nil
            }
    }
}
