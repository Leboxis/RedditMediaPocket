# X-Fetish album images implementation plan

Base: `main` at `c07053d`. Work branch: `codex/xfetish-album-images`.

## 1. Source identity and parsing

- Add focused tests in `Tests/MediaCoreTests/XFetishAlbumsTests.swift` for valid `x/<slug>`, invalid slugs, distinct collection IDs and folders, and the model album listing URL.
- Add the `xFetish` source case and validation in `Sources/MediaCore/Feed.swift`, and the four-face cycle in `Sources/MediaCore/SourceKind.swift`.
- Run the package tests.

## 2. Public album HTML adapter

- Add fixture based tests for album links, next listing page, full image links, extra-image page count, and rejected unrelated links.
- Implement the small pure parser and URL builders in `Sources/MediaCore/XFetishAlbums.swift`.
- Run the package tests.

## 3. Download integration

- Extend collection persistence and source selection in `App/Downloader.swift`.
- Scan each listing page and each album's extra image fragments, then pass one stable image post at a time into the existing preparation and transfer pipeline.
- Add an X-Fetish service group in `Sources/MediaCore/RatePolicy.swift` and a test for it.

## 4. Interface and documentation

- Add `x/` to the existing rotating source button, profile placeholder, collection icon, and empty-state guidance in `App/RedditMediaPocketApp.swift`.
- Explain how to enter an X-Fetish model name and the image-only scope in `README.md`.

## 5. Review and verification

- Review the diff for all `FeedSource` switches, collection decoding, duplicate detection, pagination, cancellation, and URL filtering.
- Run the full Swift package suite and iOS build where tooling is available; report unavailable checks explicitly.
