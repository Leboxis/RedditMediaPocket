# Foreground downloads

Downloads use Network's ephemeral URLSession and SafeRedirects for every request. Entering the background cancels the current download run; the user can restart it after returning. There is no background execution assertion, automatic resume, or system-owned transfer scheduling.

On upgrading from the background-transfer version, LegacyBackgroundCleanup reconnects the previous bundle-scoped session only to call invalidateAndCancel. It never creates or resumes a download task. Invalidation discards late temporary results, removes only Application Support/BackgroundMedia, and records completion. Gallery files in Documents are preserved. Cleanup failures are retried next launch; late system callbacks are acknowledged.

Individual thumbnail deletion remains available through long press → Delete → confirmation. It validates collection membership and the regular file before deleting, reloads counts and size on success, and reports errors. It remains disabled while downloading.

## Device checks

- Upgrade with old background transfers queued: opening the new version cancels them and clears their staging cache without changing the gallery.
- Start a download, background Pocket, and return: the run stops; another download requires a user action.
- Cancel an individual Delete: no file is removed. Confirm: only that media is removed and gallery totals update.
- Repeat an upgrade cleanup or deliver a late session event: callbacks complete without starting new transfers.

CI checks compilation and existing tests. Lifecycle and upgrade behavior require an iPhone test, including the actual hosting environment if using LiveContainer.

## Rate-limit and error regression checks

- Refuse a media request with HTTP 429 after some files have completed. The batch stops; the alert contains the service, HTTP code and total files kept in the collection. Dismiss it: no error text remains above the gallery.
- Restart while an old cooldown exists. Verify a new HTTP request reaches the server; a genuine repeated 429 still stops the run. A late response from a previous request generation must not restore its cooldown.
- Allow the next attempt. The interrupted page is retried and its remaining files are saved; already complete files are not downloaded again.
- Repeat with a 429 during gallery resolution, RSS pagination and a saved-feed request. Verify the last fully processed page remains the checkpoint.
- Start with an older installation’s visited history. Its first run rebuilds the history while preserving existing media files.
- Open Following, Saved, Reddit sign-in and kDrive screens; trigger a network failure. Errors appear as native alerts. Dismiss and retry: the same error can be presented again and Retry stays available.

`FeedTraversalTests` covers the separate cursors, interrupted pages, cancellation, known-page overlap, page budgets, repeated pages and saved-comment cursors. `DownloadFailureTests` covers propagation of HTTP 429 and cancellation while allowing an unavailable file to be skipped. Run `swift test` and the Xcode build on macOS. Network reset, file deduplication and native alert presentation still require app-level checks.
