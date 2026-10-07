// The window: the sidebar's sections and the content beside them.

import AppKit
import HomeClerkKit
import PDFKit
import QuickLook
import SwiftUI

enum Section: String, CaseIterable, Identifiable {
    case activity = "Activity", review = "Review", filed = "Filed", upcoming = "Upcoming", spending = "Spending"
    case search = "Search", tidy = "Tidy Up", usage = "Usage"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .activity: "tray.and.arrow.down"
        case .review: "exclamationmark.bubble"
        case .filed: "archivebox"
        case .tidy: "sparkles"
        case .upcoming: "calendar"
        case .spending: "chart.bar"
        case .search: "magnifyingglass"
        case .usage: "dollarsign.circle"
        }
    }
}

struct MainView: View {
    @Bindable var model: HomeClerkModel

    var body: some View {
        // The standard Mac layout (Mail, Notes, Finder): a full-height sidebar holding the window
        // controls, and a toolbar over the content titled with the section's name
        NavigationSplitView {
            List(Section.allCases, selection: Binding(get: { model.section }, set: { if let s = $0 { model.section = s } })) { item in
                Label(item.rawValue, systemImage: item.symbol)
                    .badge(item == .review ? model.needsReview : item == .tidy ? model.tidyCount : 0)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 260)
        } detail: {
            Group {
                switch model.section {
                case .activity: ContentView(model: model)
                case .review: ReviewScreen(model: model)
                case .filed: FiledScreen(model: model)
                case .upcoming: UpcomingScreen(model: model)
                case .spending: SpendingScreen(model: model)
                case .search: SearchScreen(model: model)
                case .tidy: TidyScreen(model: model)
                case .usage: UsageScreen(model: model)
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        FolderButton(title: "Inbox", symbol: "tray.and.arrow.down", url: model.inbox)
                        FolderButton(title: "Organized", symbol: "folder", url: model.organized)
                        FolderButton(title: "Review", symbol: "exclamationmark.bubble", url: model.review)
                    } label: {
                        Label("Folders", systemImage: "folder")
                    }
                    .help("Open a HomeClerk folder in Finder")
                }
            }
        }
        // Renames, moves, and trashing change what Tidy Up lists; keep its badge current
        .onChange(of: model.documentsChanged) { model.refreshTidy() }
        .sheet(isPresented: Binding(get: { model.showWelcome }, set: { model.showWelcome = $0 })) { WelcomeSheet(model: model) }
        .sheet(isPresented: Binding(get: { model.showTaxExport }, set: { model.showTaxExport = $0 })) { TaxExportSheet(model: model) }
        .sheet(isPresented: Binding(get: { model.showWhatsNew }, set: { model.showWhatsNew = $0 })) { WhatsNewSheet() }
        .sheet(isPresented: Binding(get: { model.showYearInReview }, set: { model.showYearInReview = $0 })) { YearInReviewSheet(model: model) }
        .alert("Can't find your HomeClerk folder", isPresented: Binding(get: { model.missingFolder != nil }, set: { _ in })) {
            Button("Locate…") { model.locateMissingFolder() }
            Button("Try Again") { model.retryMissingFolder() }
            Button("Start a New Folder") { model.startNewFolder() }
        } message: {
            Text("It was at \(((model.missingFolder?.path ?? "") as NSString).abbreviatingWithTildeInPath). If you moved or renamed it, show HomeClerk where it is now. If it's on a drive that isn't connected, connect it and try again.")
        }
        // PDFs dropped anywhere in the window go to the inbox
        .overlay { if model.dropTargeted { DropOverlay() } }
        // Files from Finder, and attachments from Mail, Safari, and other apps
        .onDrop(of: [.fileURL, .pdf], isTargeted: Binding(get: { model.dropTargeted }, set: { model.dropTargeted = $0 })) { providers in
            model.receiveDrop(providers)
            return true
        }
        // File ▸ Import from iPhone: a document scanned (or photographed) with Continuity Camera
        .importsItemProviders([.pdf, .image]) { providers in
            model.importFromDevice(providers)
            return true
        }
    }
}

struct DropOverlay: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
                .padding(18)
            VStack(spacing: 10) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.accentColor)
                Text("Drop to add to the inbox").font(.title3.weight(.semibold))
            }
        }
        .transition(.opacity)
        .allowsHitTesting(false)
    }
}

struct FolderButton: View {
    let title: String
    let symbol: String
    let url: URL?

    var body: some View {
        Button {
            guard let url else { return }
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.open(url)
        } label: {
            Label(title, systemImage: symbol)
        }
        .disabled(url == nil)
        .help("Open the \(title) folder")
    }
}
