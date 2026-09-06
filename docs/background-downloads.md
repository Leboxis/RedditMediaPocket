# Background transfers and individual deletion

Public media transfers use a persistent background URLSession with a bundle-scoped identifier. Cookie-bearing requests, Reddit pages and credential-bearing RSS URLs remain in the ephemeral session. URLSession owns the in-flight transfers while the app is suspended. Discovery and AVFoundation merging still require application execution time; a finite UIKit background assertion covers short transitions, not unlimited background execution.

The app delegate reconnects the session after a system relaunch and acknowledges delivery after delegate events are processed. Completed downloads without a live caller are staged outside Documents with their HTTP response. A subsequent run for the same media URL consumes this file and applies Network's normal response checks. Force-quitting cancels iOS background transfers; no automatic full-feed restart is promised. Embedded hosting environments such as LiveContainer require device testing and may impose additional lifecycle limitations.

Gallery thumbnails expose a destructive Delete context-menu action and a confirmation naming the file. Deletion is disabled during downloads and validates gallery membership, the parent collection folder and regular-file status. Errors are shown without removing the gallery entry; success reloads the count and size. A subsequent download run may download a deleted media again.

## Device acceptance checks

- Start several large image/video transfers, lock the device or switch apps, then return: completed media should appear without corruption.
- Repeat with Reddit video/audio assembly: if CPU execution is suspended, final assembly may wait until foreground.
- Let iOS relaunch the app for session events: verify the completion callback runs and orphan media is reused on the next download run.
- Force quit and reopen: no promise of continued transfers; explicitly restart the collection.
- Stop an active download: pending async callers finish with cancellation, without hanging.
- Long press a thumbnail and cancel Delete: the file, count and size stay unchanged.
- Confirm Delete: only that file disappears; adjacent media and other collections remain intact, including after relaunch.
- While downloading, Delete is disabled. A filesystem failure should leave the media visible and show an error.

The GitHub build checks compilation and the existing core tests; it cannot establish locked-device background execution or LiveContainer compatibility.
