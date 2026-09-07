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
