// ContentView.swift — SP1.5 tracer-bullet status panel (brand spine tokens, dark-only).
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            Brand.ink900.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 22) {
                header
                Divider().overlay(Brand.muted.opacity(0.3))
                row("BUNDLE", model.bundleId)
                row("SIDECAR", model.sidecarStatus, value2: model.sidecarHeartbeat)
                row("APP INTENT", model.intentStatus)
                row("EVENTKIT / TCC", model.calendarStatus)
                Spacer()
                Button(action: { model.probeCalendar() }) {
                    Text("PROBE CALENDAR (EVENTKIT)")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .kerning(1.5)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .foregroundStyle(Brand.ink900)
                        .background(Brand.ember500)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                Text("SP1.5 · packaging / TCC tracer-bullet")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(Brand.muted)
            }
            .padding(28)
        }
        .frame(minWidth: 560, minHeight: 420)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("GINEXUS")
                .font(.system(size: 34, weight: .heavy, design: .default))
                .kerning(2)
                .foregroundStyle(Brand.bone50)
            Text("nexus")
                .font(.system(size: 30, weight: .semibold, design: .serif))
                .italic()
                .foregroundStyle(Brand.ember500)
        }
    }

    private func row(_ label: String, _ value: String, value2: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .kerning(1.5)
                .foregroundStyle(Brand.muted)
            Text(value)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(Brand.bone50)
            if let value2 {
                Text(value2)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(Brand.ok)
            }
        }
    }
}
