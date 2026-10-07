// Settings ▸ Ollama's model list: which models fit this Mac, how fast and accurate they've been,
// and downloading them.

import AppKit
import HomeClerkKit
import SwiftUI

/// How long each model has taken per document on this Mac — from the start of its analysis to the
/// document being filed — kept in HomeClerk's preferences.
enum ModelTimings {

    static func record(engine: String, seconds: Double) {
        guard seconds > 0, seconds < 3600 else { return }
        var all = UserDefaults.standard.dictionary(forKey: DefaultsKey.modelTimings) as? [String: [Double]] ?? [:]
        let old = all[engine] ?? [0, 0]
        all[engine] = [old[0] + 1, old[1] + seconds]
        UserDefaults.standard.set(all, forKey: DefaultsKey.modelTimings)
    }

    /// Average seconds per document for an Ollama model, and how many documents it's from.
    static func average(_ model: String) -> (seconds: Double, count: Int)? {
        let all = UserDefaults.standard.dictionary(forKey: DefaultsKey.modelTimings) as? [String: [Double]] ?? [:]
        let matching = all.filter { $0.key.lowercased().hasSuffix(model.lowercased()) }.values
        let count = matching.reduce(0) { $0 + $1[0] }, total = matching.reduce(0) { $0 + $1[1] }
        return count >= 1 ? (total / count, Int(count)) : nil
    }
}

extension HomeClerkModel {
    var ollamaClient: OllamaClient { OllamaClient(baseURL: (currentSettings ?? SettingsStore.app.load()).ollamaBaseURL) }

    func refreshOllamaModels() async {
        ollamaModels = try? await ollamaClient.models()
        ollamaLoaded = try? await ollamaClient.loaded()
    }

    /// Frees a model's memory now, rather than waiting for it to unload on its own.
    func unloadOllamaModel(_ name: String) async {
        do {
            try await ollamaClient.unload(name)
        } catch {
            record(.problem, "Ollama", "Couldn't unload \(name): \(error.localizedDescription)", nil)
        }
        ollamaLoaded = try? await ollamaClient.loaded()
    }

    /// Downloads a model through Ollama, showing progress in Settings.
    func download(_ name: String) {
        guard downloads[name] == nil else { return }
        downloads[name] = (nil, "Starting…")
        downloadProblem = nil
        let client = ollamaClient
        Task {
            do {
                try await client.pull(name) { progress, status in
                    // Only while it's still going: a late update mustn't bring back a finished download
                    Task { @MainActor in
                        if HomeClerkModel.shared.downloads[name] != nil { HomeClerkModel.shared.downloads[name] = (progress, status) }
                    }
                }
                downloads[name] = nil
                await refreshOllamaModels()
            } catch {
                downloads[name] = nil
                downloadProblem = "Couldn't download \(name): \(error)"
            }
        }
    }

    /// How a model has done on documents filed here.
    func trackRecord(_ model: String) -> ModelTrackRecord {
        let pending = self.pending.filter { $0.analysis?.model.lowercased().hasSuffix(model.lowercased()) == true }.count
        return ModelTrackRecord.of(model, in: library.documents, pendingInReview: pending)
    }
}

/// One model in Settings ▸ Ollama: what it is, and its memory, speed, and accuracy — measured on
/// this Mac where HomeClerk has used it, general guidance otherwise.
struct OllamaModelRow: View {
    let model: HomeClerkModel
    let name: String
    let installed: OllamaModelInfo?
    let recommended: RecommendedModel?
    let isSelected: Bool
    let isSuggested: Bool
    let choose: () -> Void

    private var size: Int64 { installed?.sizeBytes ?? recommended?.sizeBytes ?? 0 }
    private var memory: UInt64 { ProcessInfo.processInfo.physicalMemory }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .font(.title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(name).font(.body.weight(.medium))
                    if isSuggested { badge("Suggested for this Mac", .green) }
                    if installed?.readsImages == false { badge("Text only", .orange) }
                    else if installed?.readsImages == true || recommended != nil { badge("Reads page images", .blue) }
                }
                HStack(spacing: 14) {
                    metric("memorychip", memoryText, tint: fitTint)
                    metric("speedometer", speedText)
                    metric("checkmark.seal", accuracyText)
                }
                .font(.caption)
                if let note = recommended?.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                download
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { if installed != nil { choose() } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction { if installed != nil { choose() } }
    }

    @ViewBuilder
    private var download: some View {
        if installed == nil {
            if let state = model.downloads[name] {
                VStack(alignment: .leading, spacing: 2) {
                    if let progress = state.progress { ProgressView(value: progress) } else { ProgressView().controlSize(.small) }
                    Text(state.status.capitalized).font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Button("Download (\(Self.gigabytes(size)))") { model.download(name) }
                    .controlSize(.small)
                    .disabled(model.ollamaModels == nil)
                    .help(model.ollamaModels == nil ? "Start Ollama to download models" : "Downloads it through Ollama")
            }
        }
    }

    private var fit: OllamaCatalog.Fit { OllamaCatalog.fit(size, memory: memory) }
    private var fitTint: Color {
        switch fit { case .comfortable: .green; case .tight: .orange; case .tooBig: .red }
    }

    private var memoryText: String {
        let need = Self.gigabytes(OllamaCatalog.memoryNeeded(size))
        switch fit {
        case .comfortable: return "Needs \(need) — fits"
        case .tight: return "Needs \(need) — tight"
        case .tooBig: return "Needs \(need) — too big for this Mac"
        }
    }

    private var speedText: String {
        if let measured = ModelTimings.average(name) {
            return "About \(Int(measured.seconds.rounded())) s a document here"
        }
        return recommended.map { "\(OllamaCatalog.speedNames[$0.speed]) (typical)" } ?? "Speed not measured yet"
    }

    private var accuracyText: String {
        let record = model.trackRecord(name)
        if let share = record.share {
            return "\(record.filedOnItsOwn) of \(record.analyzed) filed without help (\(Int((share * 100).rounded()))%)"
        }
        return recommended.map { "\(OllamaCatalog.accuracyNames[$0.accuracy]) accuracy (typical)" } ?? "Accuracy not measured yet"
    }

    private func metric(_ symbol: String, _ text: String, tint: Color = .secondary) -> some View {
        Label { Text(text).foregroundStyle(.secondary) } icon: { Image(systemName: symbol).foregroundStyle(tint) }
    }

    private func badge(_ text: String, _ tint: Color) -> some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(tint.opacity(0.12), in: Capsule())
    }

    static func gigabytes(_ bytes: Int64) -> String {
        (Double(bytes) / 1_000_000_000).formatted(.number.precision(.fractionLength(1))) + " GB"
    }
}
