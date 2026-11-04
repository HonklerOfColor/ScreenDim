import AppKit
import ScreenDimKit
import SwiftUI

/// Fenster „Diagnose …“: pro Display Zuordnung, Link, Kanalzustand und die letzten
/// I2C-Ergebnisse, dazu Test-Read und Test-Write.
struct DiagnosticsView: View {
    static let windowID = "diagnostics"

    let manager: DisplayManager
    @State private var testResults: [CGDirectDisplayID: String] = [:]
    @State private var running: Set<CGDirectDisplayID> = []
    @State private var copied = false
    /// Stand einmal pro Sekunde. Läse der Body `manager.diagnostics()` direkt, rendert das
    /// Fenster bei jedem Überblendungsschritt (20 Hz), weil `monitors` beobachtet wird.
    @State private var displays: [DisplayDiagnostics] = []

    var body: some View {
        // Die I2C-Ergebnisse liegen außerhalb von @Observable; einmal pro Sekunde neu lesen.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content
                .onChange(of: context.date, initial: true) { _, _ in
                    displays = manager.diagnostics()
                }
        }
        .frame(minWidth: 620, minHeight: 440)
    }

    private var content: some View {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("DDC-Timing: \(manager.timing.summary)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if displays.isEmpty {
                            Text("Kein Display gefunden").foregroundStyle(.secondary)
                        }
                        ForEach(displays) { display in
                            section(display)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                HStack {
                    Button("Monitore neu suchen") { manager.refresh(force: true) }
                    Spacer()
                    if copied {
                        Text("Kopiert").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Diagnose kopieren") { copy(displays) }
                        .keyboardShortcut("c", modifiers: [.command, .shift])
                }
                .padding(12)
            }
    }

    private func section(_ display: DisplayDiagnostics) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(display.name, systemImage: display.isBuiltIn ? "laptopcomputer" : "display")
                .font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                row("CGDirectDisplayID", "\(display.id)")
                row("EDID", display.edidText)
                row("AV-Service", display.avServiceText)
                if let link = display.linkText { row("Link", link) }
                if let branch = display.branchText { row("Branch", branch) }
                row("Zustand", display.stateText)
                if let ddc = display.ddc {
                    if let channel = display.channelText { row("Kanal", channel) }
                    row("Letzter Write", DisplayDiagnostics.describe(ddc.lastWriteOperation))
                    row("Letzter Read", DisplayDiagnostics.describe(ddc.lastReadOperation))
                    row("I2C-Write", DisplayDiagnostics.describe(ddc.lastWrite))
                    row("I2C-Read", DisplayDiagnostics.describe(ddc.lastRead))
                }
            }
            .font(.callout)
            HStack(spacing: 8) {
                Button("Test: Read 0x10") { runTest(display.id) { await manager.testRead(display.id) } }
                Button("Test: Write 0x10 = aktueller Wert") { runTest(display.id) { await manager.testWrite(display.id) } }
                    .help(Text("Schreibt einmal den Wert, den der Slider zeigt: \(Int(display.brightness).formatted()) von 100."))
                if running.contains(display.id) {
                    ProgressView().controlSize(.small)
                }
                if let result = testResults[display.id] {
                    Text(verbatim: result)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            .disabled(!display.hasChannel || running.contains(display.id))
        }
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(verbatim: value)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func runTest(_ id: CGDirectDisplayID, _ test: @escaping @MainActor () async -> String) {
        running.insert(id)
        testResults[id] = nil
        Task {
            testResults[id] = await test()
            running.remove(id)
        }
    }

    private func copy(_ displays: [DisplayDiagnostics]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(DisplayDiagnostics.report(displays, timing: manager.timing), forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
