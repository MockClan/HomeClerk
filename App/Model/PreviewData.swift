// Previews: Xcode draws the window's states in its canvas (Editor ▸ Canvas, ⌥⌘↩) from sample
// data, so they can be checked and restyled without running HomeClerk or scanning anything.

import AppKit
import CoreSpotlight
import HomeClerkKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

#if DEBUG   // Xcode Debug builds only; the command-line build skips previews

extension HomeClerkModel {
    /// A model that's watching a sample inbox, adjusted by `configure`.
    static func preview(_ configure: (HomeClerkModel) -> Void = { _ in }) -> HomeClerkModel {
        let model = HomeClerkModel()
        model.state = .watching
        model.inbox = URL(fileURLWithPath: "/Users/you/HomeClerk/Inbox")
        model.organized = URL(fileURLWithPath: "/Users/you/HomeClerk/Organized")
        model.review = URL(fileURLWithPath: "/Users/you/HomeClerk/_review")
        configure(model)
        return model
    }
}

#Preview("Processing") {
    ContentView(model: .preview { model in
        model.working = [
            WorkItem(id: "/Users/you/HomeClerk/Inbox/scan0043.pdf", stage: "analyzing",
                     engine: "Claude claude-sonnet-5-5"),
            WorkItem(id: "/Users/you/HomeClerk/Inbox/scan0044.pdf", stage: "analyzing",
                     engine: "Ollama qwen3-vl:8b-instruct", replacedEngine: "Claude claude-sonnet-5-5"),
            WorkItem(id: "/Users/you/HomeClerk/Inbox/scan0045.pdf", stage: "waiting")
        ]
        model.activity = [
            Activity(kind: .filed, title: "2026-04-24-Toll_Authority-2021_Toyota_RAV4-Toll_Bill-31.40.pdf",
                     detail: "Vehicle - Tolls", path: nil, engine: "Claude claude-sonnet-5-5"),
            Activity(kind: .review, title: "scan0041.pdf", detail: "Confidence 62% below threshold 85%",
                     path: nil, engine: "Ollama qwen3-vl:8b-instruct", fallback: true),
            Activity(kind: .duplicate, title: "scan0040.pdf", detail: "Already filed as Acme_Tire receipt",
                     path: nil)
        ]
        model.filed = 12
        model.needsReview = 1
        model.duplicates = 1
    })
    .frame(width: 660, height: 560)
}

#Preview("Ollama not running") {
    ContentView(model: .preview { model in
        model.ollama = OllamaInfo(status: "stopped", model: "qwen3-vl:8b-instruct", role: "fallback")
    })
    .frame(width: 660, height: 560)
}

#Preview("Ollama model missing") {
    ContentView(model: .preview { model in
        model.ollama = OllamaInfo(status: "missing-model", model: "qwen3-vl:8b-instruct", role: "primary")
    })
    .frame(width: 660, height: 560)
}

#Preview("Waiting for scans") {
    ContentView(model: .preview())
    .frame(width: 660, height: 560)
}

#Preview("Stopped unexpectedly") {
    ContentView(model: .preview { model in
        model.state = .failed("HomeClerk stopped unexpectedly (exit code 1)")
        model.errorDetails = "Unhandled exception: sample details shown under Details"
    })
    .frame(width: 660, height: 560)
}

#endif
