# Changelog

What's changed in each release of HomeClerk. Add to **Unreleased** as you go; when releasing, rename
it to the version and date, and the release workflow publishes that section as the release's notes.

## Unreleased

## 1.0.0 — 2026-10-07

The first release. HomeClerk watches a folder for scanned PDFs, reads each one, and files it: named
consistently, in the right folder, searchable, and tagged in Finder.

**Reading documents**
- Claude for the best accuracy, or Apple Intelligence or a local Ollama model, so nothing leaves your Mac.
- A household profile (people, vehicles, pets, groups) so names come out the same every time.
- Multi-document scans are split, unreadable or uncertain ones wait in Review, and duplicates are set aside.

**Filing**
- Folder rules, document types, areas, tags, and keep periods you can edit in Settings ▸ Rules,
  including Devices and work expenses (Employment - Expenses).
- A searchable text layer, Finder tags, and reminders for due dates and expirations.
- Emailed bills through a Mail rule, password-protected PDFs, and scanning from an iPhone.

**Keeping track**
- Upcoming bills, paid bills (checked off automatically when the receipt arrives), bills higher
  than usual, Spending by vendor or category, and Year in Review.
- Tidy Up for documents that need details, duplicates, documents past their keep period (with
  Keep All Like This), and old copies of scans.
- Library Health to find and fix records whose PDF is gone, or PDFs the Library doesn't know.

**Your folder**
- Plain folders and well-named PDFs you can open in Finder, sync with iCloud Drive, and keep even
  if you stop using the app.
- Move… in Settings takes the folder anywhere; moved it in Finder? HomeClerk asks where it went.
- Spotlight, Shortcuts, and a menu bar item.

**Coming from DocuSort**
- HomeClerk was called DocuSort before 1.0. On first launch it carries over DocuSort's settings,
  Claude key, folder, Reminders list, and Mail rule. Move the old app to the Trash afterwards.

**Installing**
- `brew tap mockclan/homeclerk https://github.com/MockClan/HomeClerk` then `brew install --cask homeclerk`,
  or download the zip below. HomeClerk isn't signed with an Apple Developer ID, so open it from
  Applications, then choose **Open Anyway** in System Settings ▸ Privacy & Security.
