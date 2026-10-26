# Changelog

What's changed in each release of HomeClerk. Add to **Unreleased** as you go; when releasing, rename
it to the version and date, and the release workflow publishes that section as the release's notes.

## Unreleased

**Scanning a pile**
- A pile of documents scanned as one PDF is split far more reliably. Pages are numbered for the
  reader, and pages about one transaction or matter stay together — including an invoice and the
  receipt for paying it.
- Apple Intelligence finds where each document starts first, then reads each one on its own. When
  it can't tell, the scan waits in Review to be split instead of being filed as one document.
- In a pile, the documents the reader is sure of are filed and only an uncertain one waits in
  Review, as its own scan ("… pages 3–4.pdf") — instead of the whole pile waiting.
- Paperwork with no amount of its own — a shop's inspection checklist after its invoice, even one
  dated the same day — stays with the document it came with. A page after a document's printed
  last page ("Page 4 of 4") is read as a document of its own unless it's plainly that document's
  back page.
- Separator pages: put a blank page (or, for double-sided scanning, a blank sheet) between
  documents and turn on Settings ▸ General ▸ Between documents in a pile. Each section is read on
  its own, and double-sided scans lose the blank backs of single-sided pages. The pile goes to the
  Trash unless a verified copy of it is kept in _originals.

**Duplicates**
- A document in a pile that's already filed — scanned before on its own or in another pile — is
  set aside in Duplicates ("… page 3.pdf") and the rest of the pile is filed. Several copies of one
  form in the same pile are all kept. Documents filed from piles before this version are checked
  too.
- A rescan is recognized even when one reading found the person (or vehicle or pet) and the other
  didn't, and forms filled in by different people aren't taken for each other when the reader
  describes them differently.
- Tidy Up ▸ Duplicates also lists documents filed twice — the same paper from two scans, even when
  the two readings describe it differently, or a scan of some of its pages beside one of all of
  them. Copies within one pile aren't listed.
- Choose which copy to keep: the two are side by side, each with its page count and file size,
  and Keep This One under each. The other copy goes to the Trash — nothing is overwritten — and ⌘Z
  brings it back. A kept copy named with a "_2" takes the plain name. Keeping the copy with fewer
  pages asks first. Or Keep Both.
- A new scan set aside as a duplicate can be the one you keep, when it's the better scan: it takes
  the filed copy's place — same name, folder, details, and tags — and the filed copy goes to the
  Trash.

**Documents filed in parts**
- Tidy Up ▸ Filed in Parts finds a document filed in two parts — its first pages from one scan and
  the rest from another — by the page numbers printed on it ("Page 3 of 4"), and puts it back
  together: Combine. Or select documents in Search and choose Combine into One Document. The
  combined document keeps the name, folder, details, and tags of the part whose pages come first;
  the other goes to the Trash, and ⌘Z separates them again.

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
- `brew tap mockclan/homeclerk https://github.com/MockClan/HomeClerk`, `brew trust mockclan/homeclerk`,
  then `brew install --cask homeclerk`, or download the zip below. HomeClerk isn't signed with an Apple Developer ID, so open it from
  Applications, then choose **Open Anyway** in System Settings ▸ Privacy & Security.
