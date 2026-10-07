// Learning from Review: the "remember this?" prompt under a correction, and names HomeClerk noticed.

import AppKit
import HomeClerkKit
import SwiftUI

/// The question a correction raises, under the page's toolbar: answer it or let it go.
struct SuggestionBanner: View {
    let model: HomeClerkModel
    let suggestion: Suggestion
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: suggestion.remembered ? "checkmark.circle.fill" : "lightbulb")
                .foregroundStyle(suggestion.remembered ? Color.green : Color.yellow)
                .font(.title3)
            Text(message).fixedSize(horizontal: false, vertical: true).lineLimit(3)
            Spacer(minLength: 8)
            if suggestion.remembered {
                Button("Update \(suggestion.others.count == 1 ? "It" : "Them")") {
                    model.updateOthers(suggestion, undoManager: undoManager)
                }
                Button("Not Now") { model.nextSuggestion() }
            } else {
                Button(suggestion.action == .add ? "Add" : "Remember") { model.accept(suggestion, undoManager: undoManager) }
                Button("Not Now") { model.nextSuggestion() }
            }
        }
        .padding(.horizontal, Layout.margin)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.6))
        .accessibilityElement(children: .contain)
    }

    private var message: AttributedString {
        let from = FinishingPlan.readable(suggestion.from), to = FinishingPlan.readable(suggestion.to)
        let count = suggestion.others.count
        let text: String
        if suggestion.remembered {
            text = "Remembered. \(count == 1 ? "1 filed document still uses" : "\(count) filed documents still use") “\(from)”. Rename \(count == 1 ? "it" : "them") to use **\(to)**?"
        } else if suggestion.action == .remember {
            text = "The document said “\(from)”. Remember it as **\(to)** from now on?"
        } else if from.isEmpty {
            text = "Add **\(to)** to your household as a \(suggestion.kind.singular)?"
        } else {
            text = "Add **\(to)** to your household as a \(suggestion.kind.singular), and treat “\(from)” as the same?"
        }
        return (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}

/// "Who is this?" for a name seen on a filed document: the same as someone known, someone new,
/// or not worth asking about again.
struct NoticedInspector: View {
    let model: HomeClerkModel
    let name: NoticedName
    @Environment(\.undoManager) private var undoManager
    @State private var newKind: HouseholdKind = .people

    var body: some View {
        let value = FinishingPlan.readable(name.value)
        let entry = model.library.documents.first { $0.path == name.path }
        Form {
            SwiftUI.Section {
                Text(question).font(.headline)
                if let entry {
                    Text("Seen on \(FiledScreen.title(entry)), filed in \(FiledScreen.folder(entry)).")
                        .foregroundStyle(.secondary)
                }
            }
            if let similar = name.resembles {
                SwiftUI.Section {
                    Button("Same as \(FinishingPlan.readable(similar))") {
                        model.answer(name, sameAs: similar, undoManager: undoManager)
                    }
                    .keyboardShortcut(.defaultAction)
                    Button("A Different Vendor") { model.ignore(name, undoManager: undoManager) }
                }
            } else {
                let known = names
                if !known.isEmpty {
                    SwiftUI.Section("Someone you know") {
                        Menu("Same as…") {
                            ForEach(known, id: \.self) { target in
                                Button(FinishingPlan.readable(target)) { model.answer(name, sameAs: target, undoManager: undoManager) }
                            }
                        }
                    }
                }
                SwiftUI.Section("Someone new") {
                    if name.kind == .people || name.kind == .groups {
                        Picker("Add as", selection: $newKind) {
                            Text("A person").tag(HouseholdKind.people)
                            Text("A group").tag(HouseholdKind.groups)
                        }
                        .pickerStyle(.segmented)
                    }
                    Button("Add \(value) to Household") { model.answer(name, addAs: kind, undoManager: undoManager) }
                }
                SwiftUI.Section {
                    Button("Don't Ask Again") { model.ignore(name, undoManager: undoManager) }
                } footer: {
                    Text("Nothing is moved or renamed; this only teaches HomeClerk for next time.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { newKind = name.kind == .groups ? .groups : .people }
    }

    private var kind: HouseholdKind { name.kind == .people || name.kind == .groups ? newKind : name.kind }

    private var names: [String] {
        name.kind == .people || name.kind == .groups
            ? model.household.names(.people) + model.household.names(.groups) : model.household.names(name.kind)
    }

    private var question: String {
        let value = FinishingPlan.readable(name.value)
        if let similar = name.resembles { return "Is “\(value)” the same vendor as \(FinishingPlan.readable(similar))?" }
        switch name.kind {
        case .people, .groups: return "Who is “\(value)”?"
        case .pets: return "Is “\(value)” one of your pets?"
        case .vehicles: return "Is “\(value)” one of your vehicles?"
        case .vendors: return "Who is “\(value)”?"
        }
    }
}
