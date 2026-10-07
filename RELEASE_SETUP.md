# Release Setup

How releases work, and the one-time setup before the first one.

This repository is its own Homebrew tap: `Casks/homeclerk.rb` installs HomeClerk.app into
Applications. There's no separate tap repository or token.

---

## 1. Enable GitHub Actions write permissions (one time)

The release workflow creates a GitHub Release and pushes the cask update to `main`.

1. Go to **github.com/MockClan/HomeClerk → Settings → Actions → General**
2. Under **Workflow permissions**, select **Read and write permissions**
3. Save

If you later protect `main` so that changes need a pull request, the cask update can't push and
that step fails; allow GitHub Actions to bypass the rule, or update the cask by hand.

---

## 2. Write the release notes, then tag

Add to the **Unreleased** section of `CHANGELOG.md` as you go. When releasing, rename it to the
version and date (`## 1.1.0 — 2026-11-02`), add a new empty **Unreleased** above it, and commit.
Preview what will be published with `scripts/release-notes.sh 1.1.0`. Then:

```bash
git tag v1.1.0
git push origin v1.1.0
```

This triggers `.github/workflows/release.yml`, which:

1. Selects the newest released Xcode 27 on the runner and runs `build.sh` with `VERSION=v1.0.0`: builds
   `HomeClerk.app`, ad-hoc signs it, and zips it as `HomeClerk-v1.0.0-osx-arm64.zip`
2. Publishes a GitHub Release with the zip attached, and that version's section of `CHANGELOG.md`
   as its notes (GitHub's generated notes if there's no section)
3. Updates `version` and `sha256` in `Casks/homeclerk.rb` and pushes that to `main`

---

## 3. Install and verify

```bash
brew tap mockclan/homeclerk https://github.com/MockClan/HomeClerk
brew install --cask homeclerk
```

HomeClerk isn't signed with an Apple Developer ID, so macOS blocks its first launch after each
install or upgrade: open HomeClerk from Applications, then choose **Open Anyway** in
System Settings → Privacy & Security. The Setup Assistant then asks for the API key (or sets up
Ollama or Apple Intelligence).

While the repository is private, `brew tap` needs a GitHub account with access to it.

---

## Releasing future versions

Move **Unreleased** in `CHANGELOG.md` under the new version (step 2), then:

```bash
git tag v1.1.0
git push origin v1.1.0
```

Forgot, or want to reword the notes after publishing? Fix `CHANGELOG.md`, commit, and:

```bash
scripts/release-notes.sh 1.1.0 | gh release edit v1.1.0 --notes-file -
```

Then `brew upgrade --cask homeclerk`, and approve the new version once in Privacy & Security.

---

## Notes

- **`build.sh --clean`** — full rebuild, removes `dist/` and `build/xcode` first
- **Settings** live in the app's preferences, which upgrades keep.
- **The runner needs an Xcode with the macOS 27 SDK** (Apple Foundation Models), so the workflow
  runs on GitHub's `xcode-27` image (in preview). The `macos-26` image stops at the macOS 26.5 SDK
  and won't compile HomeClerk. When a `macos-27` image is generally available, switch `runs-on` to it.
- **No more approval prompt** needs a Developer ID Application certificate (Apple Developer
  Program) and notarization, added to `build.sh` and the workflow.
