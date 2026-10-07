// The About window and the project's links: HomeClerk is open source, and its repository is where
// to read the docs, report a problem, or see what's changed.

import AppKit

enum Project {
    static let repository = URL(string: "https://github.com/MockClan/HomeClerk")!
    static let issues = URL(string: "https://github.com/MockClan/HomeClerk/issues")!
    static let publisher = URL(string: "https://github.com/MockClan")!

    /// The standard About window, with a line about the app, a link to its repository, and
    /// MockClan's crest.
    @MainActor
    static func showAbout() {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let credits = NSMutableAttributedString(
            string: "Names and files scanned household paperwork, with AI that stays on your Mac.\n\n",
            attributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: center])
        credits.append(NSAttributedString(string: "Open source on GitHub",
            attributes: [.font: small, .link: repository, .paragraphStyle: center]))
        if let crest = NSImage(named: "mockclan") {
            let attachment = NSTextAttachment()
            attachment.image = crest
            attachment.bounds = CGRect(origin: .zero, size: crest.size)   // 44 pt tall (Resources/mockclan.svg)
            credits.append(NSAttributedString(string: "\n\n", attributes: [.font: small, .paragraphStyle: center]))
            credits.append(NSAttributedString(attachment: attachment))
            credits.append(NSAttributedString(string: "\nby ",
                attributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: center]))
            credits.append(NSAttributedString(string: "MockClan",
                attributes: [.font: small, .link: publisher, .paragraphStyle: center]))
        }
        credits.addAttribute(.paragraphStyle, value: center, range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate()
    }
}
