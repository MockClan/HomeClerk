// Help ▸ Copy Diagnostics: a plain-text report for troubleshooting — versions, settings, what can
// read documents, counts, and error timestamps. Free-form messages and settings stay local.

import AppKit
import HomeClerkKit
import OSLog
import SwiftUI

extension HomeClerkModel {
    func diagnostics() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let settings = currentSettings ?? SettingsStore.app.load()

        var lines: [String] = []
        func line(_ label: String, _ value: String) { lines.append("\(label): \(value)") }
        func section(_ title: String) { lines.append(""); lines.append("## \(title)") }

        lines.append("# HomeClerk diagnostics — \(Date.now.formatted(date: .abbreviated, time: .shortened))")
        line("Version", "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))")
        line("macOS", ProcessInfo.processInfo.operatingSystemVersionString)
        line("Memory", ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory))
        line("Chip", Self.chip())
        switch state {
        case .starting: line("State", "starting")
        case .watching: line("State", "watching")
        case .paused: line("State", "paused")
        case .stopping: line("State", "stopping")
        case .failed: line("State", "failed (details omitted)")
        }

        section("Settings")
        for (key, value) in settings.diagnosticValues { line(key, value) }
        line("Rules", usingCustomTaxonomy ? "your taxonomy.json" : "built in")
        if taxonomyProblem != nil { line("Rules problem", DiagnosticPrivacy.omittedError) }

        section("Readers")
        let readers = Readers.detect()
        line("Claude API key stored", readers.hasClaudeKey ? "yes" : "no")
        line("Apple Intelligence available", readers.appleIntelligence ? "yes" : "no")
        line("Ollama installed", readers.ollamaInstalled ? "yes" : "no")
        if let ollama {
            let status = ["ready", "stopped", "missing-model"].contains(ollama.status) ? ollama.status : "other"
            line("Ollama status", status)
        }
        if readinessProblem != nil { line("Can't read documents", "yes (details omitted)") }
        let budget = claudeBudget
        line("Claude this month", "\(FinishingPlan.currency(budget.spent))" + (budget.limit > 0 ? " of \(FinishingPlan.currency(budget.limit))" : ""))

        section("Counts")
        line("Filed documents", "\(library.documents.count)")
        line("Waiting in Review", "\(pending.count)")
        line("Names to confirm", "\(noticed.count)")
        line("Tidy Up", "\(needsDetails.count) need details, \(duplicateItems.count) duplicates, \(expiredDocuments.count) past keep period")
        line("Scans in progress", "\(working.count)")
        line("Finishing repairs", "\(finishingRepairs.count)")
        line("Backed up by", backupCoverage.map { $0.isEmpty ? "nothing HomeClerk recognizes" : $0.map(\.rawValue).joined(separator: ", ") }
             ?? "not checked yet")

        section("Recent problems")
        let problems = activity.filter { $0.kind == .problem }.prefix(10)
        if problems.isEmpty { lines.append("None") }
        for item in problems { lines.append("- \(item.time.formatted(date: .numeric, time: .shortened)): \(DiagnosticPrivacy.omittedError)") }
        if !errorDetails.isEmpty { lines.append("- Last start-up error: \(DiagnosticPrivacy.omittedError)") }

        section("Recent log errors")
        let logged = Self.recentLogErrors()
        lines += logged.isEmpty ? ["None"] : logged.map { "- \($0)" }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Preview the exact report before replacing the clipboard. Cancel leaves it untouched.
    func copyDiagnostics() {
        let report = diagnostics()
        let alert = NSAlert()
        alert.messageText = "Preview Diagnostics"
        alert.informativeText = "Includes versions, safe settings summaries, counts, and error timestamps. Document content, paths, custom names, URLs, and raw error messages are omitted. Review before copying or sharing."
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Cancel")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 340))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.bounds)
        text.string = report
        text.isEditable = false
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        scroll.documentView = text
        alert.accessoryView = scroll
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }

    private static func chip() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "?" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Export structured log metadata only, regardless of the message's OSLog privacy flags.
    private static func recentLogErrors() -> [String] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
              let entries = try? store.getEntries(at: store.position(date: Date.now.addingTimeInterval(-24 * 3600)),
                                                  matching: NSPredicate(format: "subsystem == %@", "com.mockclan.homeclerk"))
        else { return [] }
        var lines: [String] = []
        for case let entry as OSLogEntryLog in entries where entry.level == .error || entry.level == .fault {
            let time = entry.date.formatted(date: .omitted, time: .standard)
            let level = entry.level == .fault ? "fault" : "error"
            lines.append("\(time) [\(DiagnosticPrivacy.logCategory(entry.category))] \(level); details omitted")
        }
        return Array(lines.suffix(20))
    }
}
