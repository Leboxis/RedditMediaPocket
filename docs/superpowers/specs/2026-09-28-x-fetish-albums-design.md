# X-Fetish profile albums

## Goal

The source selector accepts an X-Fetish model slug as a fourth source. Starting a download scans every public album listed for that model and saves only the album's full image links. Video pages, profile pictures, album previews, related albums, and private content are outside this feature.

## User flow

The existing source button cycles through `u/`, `r/`, `♥`, and `x/`. In `x/` mode, the text field asks for the X-Fetish profile name (the slug in `/models/<name>/`). The existing start/stop button, collection chips, gallery, export, deletion, and kDrive actions continue to work. Collections use the distinct ID `x/<name>` and folder `x.<name>`. Existing saved collections decode without migration loss.

## Data flow

`XFetishAlbums` validates the model slug, reads the public `/models/<name>/albums/` listing, follows its pagination, and extracts album links belonging to that listing. For each album, it reads the gallery's `rel="screenshots"` links and requests the public `get_block` fragments advertised by `data-total`. Only HTTPS image URLs under the site's `/get_image/.../sources/...` path are accepted. Image IDs provide stable filenames across rescans; the existing download queue handles cancellation, duplicate files, errors, metadata, and display.

The scanner rechecks album listings and all album pages on each run so newly added images in an existing album are found. Files already present are skipped. Network failures and malformed album pages surface as errors rather than silently declaring completion.

## Verification

Unit tests cover source parsing, URL construction, album listing pagination, gallery and fragment extraction, rejected off-site or thumbnail links, and duplicate image IDs. A full Swift package test run and iOS build are required when a Swift/Xcode environment is available. The sample profile and its public asynchronous image endpoint were inspected on 2026-09-28; the site's HTML may change.
