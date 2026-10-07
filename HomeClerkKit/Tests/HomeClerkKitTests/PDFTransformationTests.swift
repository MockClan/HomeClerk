import Foundation
import PDFKit
import Testing
@testable import HomeClerkKit

@Suite struct PDFTransformationTests {
    let temp = TempFolder()

    func copies(_ pdf: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: PDFTransformation.originalsFolder(for: pdf), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "pdf" }
    }

    /// Hand-authored objects exercise actual PDF catalog structure, not PDFKit's fixture writer.
    func structuredPDF(_ name: String, form: Bool = false) throws -> URL {
        let content = "BT /F1 14 Tf 72 700 Td (Invoice) Tj ET"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /Outlines 5 0 R \(form ? "/AcroForm << /Fields [] /SigFlags 3 >>" : "") >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 7 0 R >> >> >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /Outlines /First 6 0 R /Last 6 0 R /Count 1 >>",
            "<< /Title (Invoice) /Parent 5 0 R /Dest [3 0 R /XYZ 30 680 0] >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
        ]
        var bytes = Data("%PDF-1.7\n".utf8), offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(bytes.count)
            bytes.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = bytes.count
        bytes.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets { bytes.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        bytes.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        let pdf = temp.url.appendingPathComponent(name)
        try bytes.write(to: pdf)
        return pdf
    }

    @Test func catalogOutlineSurvivesRotationAndCatalogSignatureFlagsPreventIt() throws {
        let pdf = try structuredPDF("outlined.pdf")
        let baseline = try #require(PDFDocument(url: pdf))
        #expect(baseline.outlineRoot?.child(at: 0)?.label == "Invoice")
        try PDFTools.rotate(pdf, pages: nil, quarterTurns: 1)
        let output = try #require(PDFDocument(url: pdf))
        #expect(output.outlineRoot?.child(at: 0)?.label == "Invoice")
        #expect(output.outlineRoot?.child(at: 0)?.destination?.page == output.page(at: 0))
        let signed = try structuredPDF("signature-flags.pdf", form: true)
        let before = try Data(contentsOf: signed)
        #expect(throws: (any Error).self) { try PDFTools.rotate(signed, pages: nil, quarterTurns: 1) }
        #expect(try Data(contentsOf: signed) == before)
    }

    @Test func rotationPreservesLinksNotesCropAndExactOriginal() throws {
        let pdf = temp.url.appendingPathComponent("scan.pdf")
        try TestPDF.make(pdf, pages: ["Invoice text", "Untouched second page"])
        let document = try #require(PDFDocument(url: pdf))
        let first = try #require(document.page(at: 0))
        first.setBounds(CGRect(x: 20, y: 30, width: 560, height: 700), for: .cropBox)
        let link = PDFAnnotation(bounds: CGRect(x: 40, y: 80, width: 100, height: 30), forType: .link, withProperties: nil)
        link.url = URL(string: "https://example.test/invoice")
        first.addAnnotation(link)
        let note = PDFAnnotation(bounds: CGRect(x: 40, y: 40, width: 30, height: 30), forType: .text, withProperties: nil)
        note.contents = "Check this amount"
        first.addAnnotation(note)
        #expect(document.write(to: pdf))
        let before = try Data(contentsOf: pdf)
        let baseline = try #require(PDFDocument(data: before))
        try PDFTools.rotate(pdf, pages: [0], quarterTurns: 1)
        let output = try #require(PDFDocument(url: pdf))
        let page = try #require(output.page(at: 0))
        #expect(page.rotation == 90)
        #expect(output.page(at: 1)?.rotation == 0)
        #expect(output.string == baseline.string)
        #expect(page.bounds(for: .cropBox) == baseline.page(at: 0)?.bounds(for: .cropBox))
        #expect(page.annotations.first(where: { $0.type == "Link" })?.url == link.url)
        #expect(page.annotations.first(where: { $0.type == "Text" })?.contents == note.contents)
        #expect(page.annotations.map(\.bounds) == baseline.page(at: 0)?.annotations.map(\.bounds))
        let saved = try #require(copies(pdf).first)
        #expect(try Data(contentsOf: saved) == before)
        #expect(try FileManager.default.attributesOfItem(atPath: saved.path)[.posixPermissions] as? Int == 0o600)
        #expect(try FileManager.default.attributesOfItem(atPath: saved.deletingLastPathComponent().path)[.posixPermissions] as? Int == 0o700)
    }

    @Test func unlockPreservesEncryptedOriginalAndWrongPasswordDoesNotCreateBackup() throws {
        let pdf = temp.url.appendingPathComponent("locked.pdf")
        try LockedPDFTests.make(pdf, password: "secret")
        let before = try Data(contentsOf: pdf)
        #expect(throws: (any Error).self) { try PDFTools.unlock(pdf, password: "incorrect") }
        #expect(try Data(contentsOf: pdf) == before)
        #expect(!FileManager.default.fileExists(atPath: PDFTransformation.originalsFolder(for: pdf).path))
        try PDFTools.unlock(pdf, password: "secret")
        let saved = try #require(copies(pdf).first)
        #expect(try Data(contentsOf: saved) == before)
        #expect(PDFTools.isLocked(saved))
        #expect(!PDFTools.isLocked(pdf))
        #expect(try FileManager.default.attributesOfItem(atPath: pdf.path)[.posixPermissions] as? Int == 0o600)
        let record = try #require(PrivateFile.readJSON(PDFTransformation.Record.self,
            from: saved.deletingPathExtension().appendingPathExtension("json")))
        #expect(record.sourceName == "locked.pdf")
        #expect(record.operation == "unlocking")
    }

    /// A just-filed scan already has its exact bytes in _originals, so making it searchable
    /// doesn't store a third copy beside it; without that copy, the backup is still made.
    @Test(.requiresOCR) func searchableSkipsTheBackupWhenOriginalsAlreadyHasIt() throws {
        let originals = temp.url.appendingPathComponent("_originals")
        let kept = temp.url.appendingPathComponent("kept/scan.pdf")
        try FileManager.default.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
        try TestPDF.make(kept, pages: ["SCANNED INVOICE\nTOTAL AMOUNT 42.00"], asImage: true)
        try Originals.preserve(kept, in: originals)
        try Searchable.addTextLayer(to: kept, originals: originals)
        #expect(PDFDocument(url: kept)?.string?.contains("42.00") == true)
        #expect(!FileManager.default.fileExists(atPath: PDFTransformation.originalsFolder(for: kept).path))

        let unkept = temp.url.appendingPathComponent("unkept/scan.pdf")
        try FileManager.default.createDirectory(at: unkept.deletingLastPathComponent(), withIntermediateDirectories: true)
        try TestPDF.make(unkept, pages: ["SCANNED RECEIPT\nTOTAL AMOUNT 17.25"], asImage: true)
        try Searchable.addTextLayer(to: unkept, originals: originals)
        #expect(try !copies(unkept).isEmpty)
    }

    @Test(.requiresOCR) func searchableKeepsExactImageOnlyOriginal() throws {
        let pdf = temp.url.appendingPathComponent("scan.pdf")
        try TestPDF.make(pdf, pages: ["SCANNED INVOICE\nTOTAL AMOUNT 42.00"], asImage: true)
        let before = try Data(contentsOf: pdf)
        try Searchable.addTextLayer(to: pdf)
        #expect(PDFDocument(url: pdf)?.string?.contains("42.00") == true)
        #expect(try Data(contentsOf: #require(copies(pdf).first)) == before)
    }

    @Test func backupFailureAndLinkedBackupLeaveSourceUnchanged() throws {
        let pdf = temp.url.appendingPathComponent("scan.pdf")
        try TestPDF.make(pdf, pages: ["Original text"])
        let before = try Data(contentsOf: pdf)
        let folder = PDFTransformation.originalsFolder(for: pdf)
        try Data("occupied".utf8).write(to: folder)
        #expect(throws: (any Error).self) { try PDFTools.rotate(pdf, pages: nil, quarterTurns: 1) }
        #expect(try Data(contentsOf: pdf) == before)
        try FileManager.default.removeItem(at: folder)
        let outside = temp.url.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: outside)
        #expect(throws: (any Error).self) { try PDFTools.rotate(pdf, pages: nil, quarterTurns: 1) }
        #expect(try Data(contentsOf: pdf) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func changedSourceOrCorruptExistingBackupPreventsReplacement() throws {
        let pdf = temp.url.appendingPathComponent("scan.pdf")
        let staged = temp.url.appendingPathComponent("staged.pdf")
        try TestPDF.make(pdf, pages: ["Original"])
        let before = try Data(contentsOf: pdf)
        try TestPDF.make(staged, pages: ["Replacement"])
        try TestPDF.make(pdf, pages: ["Changed externally"])
        let changed = try Data(contentsOf: pdf)
        #expect(throws: (any Error).self) {
            try PDFTransformation.replace(pdf, with: staged, original: before, operation: "test")
        }
        #expect(try Data(contentsOf: pdf) == changed)
        try before.write(to: pdf)
        let folder = PDFTransformation.originalsFolder(for: pdf)
        try PrivateFolder.secure(folder)
        let copy = folder.appendingPathComponent("\(BackfillApplier.sha256(before)).pdf")
        try Data("damaged backup".utf8).write(to: copy)
        #expect(throws: (any Error).self) { try PDFTools.rotate(pdf, pages: nil, quarterTurns: 1) }
        #expect(try Data(contentsOf: pdf) == before)
        #expect(try Data(contentsOf: copy) == Data("damaged backup".utf8))
    }

    @Test func formAndSignatureWidgetsAreNeverRewritten() throws {
        for fieldType in ["Tx", "Sig"] {
            let pdf = temp.url.appendingPathComponent("\(fieldType).pdf")
            try TestPDF.make(pdf, pages: ["SCANNED FORM\nPLEASE KEEP THIS FORM"], asImage: true)
            let document = try #require(PDFDocument(url: pdf))
            let field = PDFAnnotation(bounds: CGRect(x: 70, y: 70, width: 200, height: 30), forType: .widget,
                withProperties: [PDFAnnotationKey.widgetFieldType: fieldType])
            field.fieldName = "Important field"
            document.page(at: 0)?.addAnnotation(field)
            #expect(document.write(to: pdf))
            let before = try Data(contentsOf: pdf)
            #expect(throws: (any Error).self) { try PDFTools.rotate(pdf, pages: nil, quarterTurns: 1) }
            #expect(try Data(contentsOf: pdf) == before)
            #expect(throws: (any Error).self) { try Searchable.addTextLayer(to: pdf) }
            #expect(try Data(contentsOf: pdf) == before)
            let locked = temp.url.appendingPathComponent("locked-\(fieldType).pdf")
            #expect(document.write(to: locked, withOptions: [.userPasswordOption: "secret", .ownerPasswordOption: "owner"]))
            #expect(PDFTools.isLocked(locked))
            let encrypted = try Data(contentsOf: locked)
            let lockedFixture = try #require(PDFDocument(data: encrypted))
            #expect(lockedFixture.unlock(withPassword: "secret"))
            #expect(lockedFixture.page(at: 0)?.annotations.contains(where: { $0.type == "Widget" }) == true)
            #expect(throws: (any Error).self) { try PDFTools.unlock(locked, password: "secret") }
            #expect(try Data(contentsOf: locked) == encrypted)
        }
    }

    @Test func noOpsAndInvalidPageSelectionDoNotRewriteOrSaveOriginals() throws {
        let pdf = temp.url.appendingPathComponent("text.pdf")
        try TestPDF.make(pdf, pages: ["Already selectable"])
        let before = try Data(contentsOf: pdf)
        try PDFTools.rotate(pdf, pages: nil, quarterTurns: 4)
        try PDFTools.rotate(pdf, pages: [], quarterTurns: 1)
        try PDFTools.unlock(pdf, password: "unused")
        try Searchable.addTextLayer(to: pdf)
        #expect(throws: (any Error).self) { try PDFTools.rotate(pdf, pages: [5], quarterTurns: 1) }
        #expect(try Data(contentsOf: pdf) == before)
        #expect(!FileManager.default.fileExists(atPath: PDFTransformation.originalsFolder(for: pdf).path))
    }
}
