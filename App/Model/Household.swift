// The household in the model: loading and saving household.json, noticed names, and what a
// correction could teach HomeClerk.

import AppKit
import HomeClerkKit
import SwiftUI

/// What a correction could teach HomeClerk, offered under the form that made it.
struct Suggestion: Equatable {
    enum Action: Equatable {
        /// Treat `from` as the known name `to`.
        case remember
        /// Add `to` to the household (with `from` as an alias, when there was one).
        case add
    }

    var action: Action
    var kind: HouseholdKind
    /// What the document said; empty when it said nothing.
    var from: String
    /// The name you chose.
    var to: String
    /// Once remembered: other filed documents that still use `from`, offered for updating.
    var others: [String] = []
    var remembered = false
}

extension HomeClerkModel {
    private var settingsInUse: HomeClerkSettings { currentSettings ?? SettingsStore.app.load() }
    var householdURL: URL { settingsInUse.householdProfilePath }
    /// Bills marked paid or not paid by hand.
    var paidMarks: PaidMarks { PaidMarks(url: settingsInUse.basePath.appendingPathComponent(PaidMarks.fileName)) }
    private var noticedStore: NoticedStore {
        NoticedStore(url: settingsInUse.basePath.appendingPathComponent(NoticedStore.fileName))
    }

    /// Reads household.json — on launch, when the HomeClerk folder changes, or when `force`d (Settings
    /// opening). Not on every restart: the copy here may hold edits still being typed, such as a new
    /// row without a name yet, which aren't written to the file.
    func loadHousehold(force: Bool = false) {
        let url = householdURL
        if force || householdLoadedFrom != url, let profile = try? HouseholdProfile.loadOrEmpty(from: url) {
            household = profile
            householdLoadedFrom = url
        }
        noticed = noticedStore.pending().filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Saves the household; the next scan uses it once watching restarts.
    func saveHousehold(_ profile: HouseholdProfile) {
        household = profile
        do {
            try profile.save(to: householdURL)
            scheduleRestart()
        } catch {
            errorDetails = "Couldn't save household.json: \(error.localizedDescription)"
        }
    }

    /// Asks about names on a newly filed document that the household doesn't know.
    func notice(_ path: URL) {
        Task {
            // The index entry is written just after the "filed" event; give it a moment
            for _ in 0..<5 {
                if let entry = library.documents.first(where: { $0.path == path.path }) {
                    noticedStore.add(Noticing.unknownNames(entry.facets, profile: household, path: entry.path))
                    noticed = noticedStore.pending()
                    return
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    // MARK: Learning from corrections

    /// After a correction, offers what it could teach — one thing at a time, so it stays a quick
    /// question rather than a form.
    func suggest(from original: DocumentFacets?, to edited: DocumentFacets) {
        laterSuggestions = []
        var found: [Suggestion] = []
        defer {
            suggestion = found.first
            laterSuggestions = Array(found.dropFirst())
        }
        let fields: [(HouseholdKind, String, String)] = [
            (.people, original?.person ?? "", edited.person), (.vehicles, original?.vehicle ?? "", edited.vehicle),
            (.pets, original?.pet ?? "", edited.pet), (.vendors, original?.vendor ?? "", edited.vendor)
        ]
        for (kind, before, after) in fields where !Self.key(after).isEmpty && Self.key(before) != Self.key(after) {
            if let (known, list) = knownName(after, kind) {
                // A known name: worth remembering what the document said instead
                guard !Self.key(before).isEmpty, knownName(before, kind)?.name != known else { continue }
                found.append(Suggestion(action: .remember, kind: list, from: before, to: known))
                continue
            }
            // A new name; vendors only when it replaces what the document said (most vendors are new)
            if kind == .vendors && Self.key(before).isEmpty { continue }
            found.append(Suggestion(action: .add, kind: kind, from: before, to: after))
        }
    }

    /// Moves on to the next thing a correction could teach, if any.
    func nextSuggestion() {
        suggestion = laterSuggestions.first
        laterSuggestions = Array(laterSuggestions.dropFirst())
    }

    /// Does what the suggestion offers. ⌘Z takes it back.
    func accept(_ suggestion: Suggestion, undoManager: UndoManager?) {
        let before = household
        var profile = household
        if suggestion.action == .add { profile.add(suggestion.to, kind: suggestion.kind) }
        if !suggestion.from.isEmpty {
            profile.remember(suggestion.from, as: suggestion.to, kind: suggestion.kind, today: DocumentProcessor.localToday())
        }
        saveHousehold(profile)
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.saveHousehold(before) }
        }
        undoManager?.setActionName(suggestion.action == .add ? "Add \(Self.readable(suggestion.to))" : "Remember Name")

        let others = suggestion.from.isEmpty ? [] : library.documents
            .filter { Self.key(Self.value(suggestion.kind, $0.facets)) == Self.key(suggestion.from) }.map(\.path)
        var done = suggestion
        done.remembered = true
        done.others = others
        if others.isEmpty { nextSuggestion() } else { self.suggestion = done }
    }

    /// Renames the other filed documents that still use the old name. ⌘Z puts them back.
    func updateOthers(_ suggestion: Suggestion, undoManager: UndoManager?) {
        guard let actions = reviewActions else { return }
        let entries = library.documents.filter { suggestion.others.contains($0.path) }
        nextSuggestion()
        Task {
            var refilings: [ReviewActions.Refiling] = [], failures: [any Error] = []
            for entry in entries {
                var facets = entry.facets
                Self.set(suggestion.kind, suggestion.to, in: &facets)
                // Keep a document in a folder you chose; otherwise the rules place it
                let current = ((entry.path as NSString).deletingLastPathComponent as NSString).lastPathComponent
                let keep = current == actions.destination(entry.facets).folder ? nil : current
                do { refilings.append(try await actions.refile(entry, facets: facets, folder: keep)) } catch { failures.append(error) }
            }
            reportSkipped(failures, of: entries.count, "renamed")
            undoManager?.registerUndo(withTarget: self) { model in
                MainActor.assumeIsolated {
                    model.undoRefilings(refilings, action: "Rename")
                }
            }
            undoManager?.setActionName("Update \(refilings.count) Documents")
            updateSpotlight()
            documentsChanged += 1
        }
    }

    // MARK: Noticed names

    /// "Same as" a known name: remembers it, then offers to update documents that use it.
    func answer(_ name: NoticedName, sameAs target: String, undoManager: UndoManager?) {
        let kind = knownName(target, name.kind)?.list ?? name.kind
        resolve(name, undoManager: undoManager)
        accept(Suggestion(action: .remember, kind: kind, from: name.value, to: target), undoManager: undoManager)
    }

    /// A new person (or group, pet, vehicle, vendor) for the household.
    func answer(_ name: NoticedName, addAs kind: HouseholdKind, undoManager: UndoManager?) {
        resolve(name, undoManager: undoManager)
        let before = household
        var profile = household
        profile.add(name.value, kind: kind)
        saveHousehold(profile)
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.saveHousehold(before) }
        }
    }

    func ignore(_ name: NoticedName, undoManager: UndoManager?) {
        noticedStore.ignore(name.id)
        noticed = noticedStore.pending()
        registerRestore(name, undoManager)
    }

    private func resolve(_ name: NoticedName, undoManager: UndoManager?) {
        noticedStore.resolve(name.id)
        noticed = noticedStore.pending()
        registerRestore(name, undoManager)
    }

    private func registerRestore(_ name: NoticedName, _ undoManager: UndoManager?) {
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.noticedStore.restore(name)
                model.noticed = model.noticedStore.pending()
            }
        }
    }

    // MARK: Helpers

    /// The household name `value` matches, and the list it's in (a person may be a group).
    func knownName(_ value: String, _ kind: HouseholdKind) -> (name: String, list: HouseholdKind)? {
        let lists: [HouseholdKind] = kind == .people || kind == .groups ? [.people, .groups] : [kind]
        for list in lists { if let name = household.known(value, list) { return (name, list) } }
        return nil
    }

    static func value(_ kind: HouseholdKind, _ facets: DocumentFacets) -> String {
        switch kind {
        case .people, .groups: facets.person
        case .vehicles: facets.vehicle
        case .pets: facets.pet
        case .vendors: facets.vendor
        }
    }

    static func set(_ kind: HouseholdKind, _ value: String, in facets: inout DocumentFacets) {
        switch kind {
        case .people, .groups: facets.person = value
        case .vehicles: facets.vehicle = value
        case .pets: facets.pet = value
        case .vendors: facets.vendor = value
        }
    }

    /// Letters and digits only, lowercased — how names are compared.
    static func key(_ value: String) -> String {
        String(value.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    static func readable(_ value: String) -> String { FinishingPlan.readable(value) }
}
