# x-fetish.tube Profile Albums Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Download all publicly accessible images in paginated albums of an x-fetish.tube model by entering only its profile name in the existing iPhone app.

**Architecture:** Add a distinct source identity and a small, testable HTML discovery module in MediaCore. Keep Reddit RSS traversal intact; route the new source through its own page traversal while reusing Downloader's transfer, gallery, and collection handling.

**Tech Stack:** Swift 5 mode, SwiftUI, Foundation, URLSession, Swift Package tests, iOS 26 app and GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-09-28-xfetish-albums-design.md`

## Global Constraints

- Selector cycle: `u/ → r/ → ♥ → x/ → u/`; preserve its existing flip interaction and bilingual accessibility.
- The x source accepts one lower-case ASCII profile segment and builds `https://x-fetish.tube/models/<name>/`.
- Collection ID and directory: `x/<name>` and `x.<name>`; existing Reddit collection storage remains readable.
- Public album images only, across profile and album pagination; no video, avatar, banner, thumbnail-only results, account, cookie sharing, or access-control bypass.
- Never present a blocked, malformed, cyclic, or safety-limited crawl as complete. Stop on HTTP 429; keep a resumable checkpoint.
- No verified live HTML is available in this environment. Obtain representative public profile, album, and pagination HTML before locking parser selectors; do not invent a successful live smoke test.

## Review Focus

- A missing/HTTP 404 profile must show a source error, not an empty successful collection (Task 3 test).
- A cyclic or off-site pagination link must terminate as incomplete or be rejected, not spin or leave the site (Task 2 tests).
- Protocol-relative or relative image URLs must normalize to HTTPS and select content images over thumbnails (Task 2 tests).
- An album linked from an unrelated profile or an ad must be excluded (Task 2 test).
- HTTP 429 during an image must abort without committing the page checkpoint (Task 3 test).

---

## File map

- Create `Sources/MediaCore/SourceSelection.swift`: source kind cycle and x-profile identity/validation; do not widen Reddit `FeedSource`.
- Create `Sources/MediaCore/XFetishPages.swift`: HTML link/image extraction and page URL validation, with no network side effects.
- Create `Sources/MediaCore/XFetishTraversal.swift`: fetch/process/persist traversal over profile and album pages, cycle and safety handling.
- Modify `App/Downloader.swift`: backward-compatible collection encoding, x source routing, checkpoint persistence, image conversion to the existing `Download` pipeline.
- Modify `App/RedditMediaPocketApp.swift`: fourth face of the current selector, input copy and collection icon.
- Modify `App/Network.swift` only if the verified site requires a narrow request header or its CDN needs a valid image-response check; keep Reddit cookies scoped as today.
- Create `Tests/MediaCoreTests/SourceSelectionTests.swift`, `XFetishPagesTests.swift`, `XFetishTraversalTests.swift`; update README and downloads documentation with scope and known access limits.

### Task 1: Source identity and compatible collection storage

**Files:** Create `Sources/MediaCore/SourceSelection.swift`, `Tests/MediaCoreTests/SourceSelectionTests.swift`; modify `App/Downloader.swift`.

**Interfaces:** Produce `public enum SourceSelection: String, CaseIterable, Sendable { case u, r, saved, x; var next: SourceSelection { get } }` and `public struct XFetishProfile: Hashable, Sendable { init(_ rawName: String) throws; let name: String; var id: String { get }; var folderName: String { get }; var url: URL { get } }`. Keep the existing `UserCollection` JSON keys readable; encode a new explicit `source` field for new records and map absent source from legacy `isSubreddit` / `isSaved` fields.

- [ ] **Step 1: Write failing source tests.** Assert `u.next == .r`, `r.next == .saved`, `saved.next == .x`, `x.next == .u`; `XFetishProfile("itwasalwaysmysolesvip")` yields the exact ID, folder, and URL above. Assert a slash, query, dot segment, URL, uppercase, and empty name throw.
- [ ] **Step 2: Run `swift test --filter SourceSelectionTests`.** Expect compilation/test failure before implementation.
- [ ] **Step 3: Implement the interfaces and compatible collection decoding.** Keep old IDs and folder names unchanged, add `x.` discovery in `migrateFolders`, and restore x selection from `lastUsername` or a selected collection. Add a package-level migration test helper if app-only `UserCollection` cannot be exercised by SwiftPM; test actual old/new JSON shapes rather than mirroring code.
- [ ] **Step 4: Run `swift test --filter SourceSelectionTests`.** Expect pass; review a legacy `u/`, `r/`, and `saved/` fixture plus a new `x/` fixture.
- [ ] **Step 5: Commit** `feat: model x profile sources and migrate collections`.

### Task 2: Public page parsing and traversal

**Files:** Create `Sources/MediaCore/XFetishPages.swift`, `Sources/MediaCore/XFetishTraversal.swift`, `Tests/MediaCoreTests/XFetishPagesTests.swift`, `Tests/MediaCoreTests/XFetishTraversalTests.swift`.

**Interfaces:** Produce `public struct XFetishImage: Hashable, Sendable { let url: URL; let albumURL: URL; let ordinal: Int }`, `public struct XFetishPage: Sendable { let albumURLs: [URL]; let images: [XFetishImage]; let nextURL: URL? }`, `public enum XFetishPages { static func profile(html: String, url: URL, model: XFetishProfile) throws -> XFetishPage; static func album(html: String, url: URL) throws -> XFetishPage }`, and `public enum XFetishTraversal { static func run(model: XFetishProfile, checkpoint: XFetishCheckpoint, fetch: (URL) async throws -> String, process: ([XFetishImage]) async throws -> Void, persist: (XFetishCheckpoint) -> Void) async throws -> Bool }`. Define `XFetishCheckpoint` in the traversal file with completed page URL strings and a pending URL; `Bool` means exhausted pagination versus explicitly incomplete.

- [ ] **Step 1: Capture representative public profile/album/pagination HTML and write failing fixture tests.** If the site refuses access in the implementation environment, obtain a user-supplied saved page or stop and report the block; do not substitute guessed selectors. Tests assert image originals rather than list thumbnails, relative/protocol-relative URL resolution, profile ownership of albums, profile and album next pages, malformed HTML errors, and off-site link rejection.
- [ ] **Step 2: Run `swift test --filter XFetishPagesTests`.** Expect failure before parser code.
- [ ] **Step 3: Implement `XFetishPages`.** Extract only verified content links/attributes from the fixture, normalize URLs, validate page paths and permitted image CDN hosts observed in the fixture, and deduplicate stable URLs. Keep parsing independent of URLSession and UIKit.
- [ ] **Step 4: Run parser tests.** Expect pass.
- [ ] **Step 5: Write traversal tests with an injected in-memory `fetch`.** Assert all pages and albums visited once, cyclic/off-site pagination, an explicit incomplete result at a safety limit, 404 page propagation, and `persist` called only after `process` completes.
- [ ] **Step 6: Run `swift test --filter XFetishTraversalTests`.** Expect failure before traversal code.
- [ ] **Step 7: Implement `XFetishTraversal.run`.** Traverse until pagination exhaustion; bound visited URLs to 10,000 and return incomplete with a pending URL at the bound. Preserve cancellation and thrown fetch/process errors without advancing the checkpoint.
- [ ] **Step 8: Run both x-fetish test groups; commit** `feat: discover public profile album images`.

### Task 3: Downloader route and resumable transfers

**Files:** Modify `App/Downloader.swift`, optionally `App/Network.swift`; add tests to `Tests/MediaCoreTests/XFetishTraversalTests.swift` and a focused app test if the CI setup supports it.

**Interfaces:** `Downloader.run()` branches on `.x` before creating `FeedSource`; fetch HTML via `network.data`, call `XFetishTraversal.run`, and turn `XFetishImage` batches into the existing `Download(media: .direct(url), destination:, postDate: nil, author:, postLink:)` values for `executeDownloads`. Use stable album/image positions and URL-derived identity for filenames via `FilenamePolicy`; checkpoint keys remain scoped to `x/<name>`.

- [ ] **Step 1: Write failing integration-oriented tests.** A missing profile response must propagate as an error; a simulated 429 in `process` must leave the pending page checkpoint unchanged; repeat traversal must skip completed image identities. Test via injected fetch/process in MediaCore where app tests are unavailable.
- [ ] **Step 2: Run `swift test --filter XFetishTraversalTests`.** Expect failure.
- [ ] **Step 3: Implement x source route and storage.** Use the current cancellation, concurrency, retry, inaccessible-media count, status, reload, and file-existence behavior; do not pass Reddit cookies to the new host. Record a source-specific incomplete status when the traversal bound is reached.
- [ ] **Step 4: Run `swift test` and the app build workflow.** Expect tests and iOS compilation pass; inspect 429, cancellation, and resume diagnostics.
- [ ] **Step 5: Commit** `feat: download and resume x profile albums`.

### Task 4: Existing selector and user-facing behavior

**Files:** Modify `App/RedditMediaPocketApp.swift`, `README.md`, `docs/downloads.md`; modify `Tests/MediaCoreTests/SourceSelectionTests.swift` for any pure selector rule.

**Interfaces:** `SourceKindToggle.next` delegates to `SourceSelection.next`; `face(.x)` renders `x/`; voice label says “profil x-fetish.tube” / “x-fetish.tube profile”. The name field and gallery chip use `x/`; subreddit sort and Reddit login hints stay source-specific.

- [ ] **Step 1: Write/extend failing cycle test** for `u → r → saved → x → u` and source-to-collection restoration; run `swift test --filter SourceSelectionTests` and expect failure for the new assertion.
- [ ] **Step 2: Implement selector face, label, placeholder, chip/icon, and source restoration.** Retain flip timing and disabled-while-running behavior.
- [ ] **Step 3: Update README/download docs** with example `itwasalwaysmysolesvip`, public album scope, and honest incomplete/error wording.
- [ ] **Step 4: Run `swift test`, build the iOS target in CI, and manually check LiveContainer** selection cycle, collection reopening, cancel/resume, export/delete, and a public sample profile. State explicitly if live access or iPhone testing is unavailable.
- [ ] **Step 5: Commit** `feat: expose x profile albums in source selector`.

## Final review

- Compare the diff with the spec: no hidden thumbnail, video, cookie, or unrelated source behavior.
- Run the full Swift package tests and inspect the GitHub Actions iOS build for the branch. A CI pass is evidence of compilation, not proof of live site compatibility.
- Open a draft PR with the observed test results and the unresolved live-site/iPhone checks. Request review before merging.
