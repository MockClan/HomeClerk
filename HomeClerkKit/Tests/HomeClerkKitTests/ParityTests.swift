import Foundation
import Testing
@testable import HomeClerkKit

/// Checks HomeClerkKit's prompt, schema, folders, file names, and parsing against reference outputs
/// for fictional inputs (Fixtures/parity-input.json). The expected outputs (parity-expected.json)
/// were produced by the original C# version, which HomeClerkKit replaced, so any difference is a
/// change in behavior: when one is intended — a new prompt line, say — update the expected file to
/// match. Set HOMECLERK_PARITY_DIR to a folder holding another input/expected pair to run the same
/// checks on other data — e.g. a local, never-committed set built from real documents.
@Suite struct ParityTests {
    let input: JSONValue
    let expected: JSONValue
    let profile: HouseholdProfile

    init() throws {
        if let dir = ProcessInfo.processInfo.environment["HOMECLERK_PARITY_DIR"] {
            func load(_ name: String) throws -> JSONValue {
                try JSONValue(parsing: String(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(name), encoding: .utf8))
            }
            input = try load("parity-input.json")
            expected = try load("parity-expected.json")
        } else {
            input = try TestData.fixture("parity-input.json")
            expected = try TestData.fixture("parity-expected.json")
        }
        profile = input["household"].map(HouseholdProfile.init(json:)) ?? .empty
    }

    @Test func systemPromptMatches() {
        #expect(FacetPrompt.buildSystem(TestData.taxonomy, profile) == expected["systemPrompt"]?.stringValue)
        #expect(FacetPrompt.buildSystem(TestData.taxonomy, .empty) == expected["systemPromptNoHousehold"]?.stringValue)
        #expect(profile.promptText() == expected["householdPrompt"]?.stringValue)
    }

    @Test func schemaMatchesIncludingKeyOrder() {
        #expect(FacetSchema.build(TestData.taxonomy) == expected["schema"])
        #expect(FacetSchema.build(TestData.taxonomy, constrainTags: true) == expected["schemaConstrained"])
    }

    @Test func foldersNamesKeysAndCanonicalNamesMatch() throws {
        let router = FilingRouter(TestData.taxonomy)
        let names = FilenameBuilder(TestData.taxonomy)
        let inputs = input["facets"]?.arrayValue ?? []
        let outputs = expected["facets"]?.arrayValue ?? []
        #expect(inputs.count == outputs.count)

        var mismatches: [String] = []
        for (i, (inp, out)) in zip(inputs, outputs).enumerated() {
            let facets = try TestData.facets(inp)
            let canonical = profile.canonicalize(facets)
            func check(_ field: String, _ actual: String, _ expected: String?) {
                if actual != expected { mismatches.append("facets[\(i)].\(field): \(actual) ≠ \(expected ?? "nil")") }
            }
            check("folder", router.folder(for: facets), out["folder"]?.stringValue)
            check("filename", names.build(facets), out["filename"]?.stringValue)
            check("facetKey", DuplicateDetector.facetKey(facets), out["facetKey"]?.stringValue)
            check("canonicalFilename", names.build(canonical), out["canonicalFilename"]?.stringValue)
            if let expectedCanonical = out["canonical"], try TestData.facets(expectedCanonical) != canonical {
                mismatches.append("facets[\(i)].canonical: \(canonical)")
            }
            if let tags = out["finderTags"]?.arrayValue?.compactMap(\.stringValue), FinishingPlan.finderTags(facets) != tags {
                mismatches.append("facets[\(i)].finderTags: \(FinishingPlan.finderTags(facets)) ≠ \(tags)")
            }
            if let reminders = out["reminders"]?.arrayValue {
                let actual = FinishingPlan.reminders(facets, filePath: "x.pdf", today: "2026-04-01", expirationLeadDays: 30)
                    .map { "\($0.due) \($0.title) | \($0.notes)" }
                let expected = reminders.map {
                    "\($0["due"]?.stringValue ?? "") \($0["title"]?.stringValue ?? "") | \($0["notes"]?.stringValue ?? "")"
                }
                if actual != expected { mismatches.append("facets[\(i)].reminders: \(actual) ≠ \(expected)") }
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) mismatches:\n\(mismatches.prefix(20).joined(separator: "\n"))")
    }

    @Test func simhashMatches() {
        let texts = input["texts"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let fingerprints = expected["texts"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(texts.map { String(Simhash.compute($0)) } == fingerprints)
    }

    @Test func vendorNormalizationMatches() {
        let vendors = input["vendors"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(vendors.map(VendorName.normalize) == expected["vendors"]?.arrayValue?.compactMap(\.stringValue))
    }

    @Test func userTextMatches() {
        let actual = (input["userTexts"]?.arrayValue ?? []).map {
            FacetPrompt.buildUserText(ocrText: $0["text"]?.stringValue ?? "", pageCount: Int($0["pageCount"]?.doubleValue ?? 0))
        }
        #expect(actual == expected["userTexts"]?.arrayValue?.compactMap(\.stringValue))
    }

    @Test func replyParsingMatches() throws {
        let replies = input["replies"]?.arrayValue ?? []
        let outputs = expected["replies"]?.arrayValue ?? []
        #expect(replies.count == outputs.count)
        for (i, (reply, out)) in zip(replies, outputs).enumerated() {
            let analysis = FacetSchema.parse(
                reply["json"]?.stringValue ?? "", pageCount: Int(reply["pageCount"]?.doubleValue ?? 1),
                modelName: "Test model", profile: reply["canonicalize"] == .bool(true) ? profile : nil)
            #expect((analysis.error != nil) == (out["failed"] == .bool(true)), "replies[\(i)] failed")
            #expect(analysis.summary == out["summary"]?.stringValue, "replies[\(i)] summary")
            let documents = out["documents"]?.arrayValue ?? []
            #expect(analysis.documents.count == documents.count, "replies[\(i)] document count")
            for (d, doc) in zip(analysis.documents, documents) {
                #expect(d.firstPage == Int(doc["firstPage"]?.doubleValue ?? -1), "replies[\(i)] firstPage")
                #expect(d.lastPage == Int(doc["lastPage"]?.doubleValue ?? -1), "replies[\(i)] lastPage")
                #expect(d.confidence == doc["confidence"]?.doubleValue, "replies[\(i)] confidence")
                #expect(try d.facets == TestData.facets(doc["facets"] ?? .null), "replies[\(i)] facets")
            }
        }
    }
}
