# Album Management

Open Google Photos -> profile -> GoToHP Settings, then use the **Upload photos
and videos** row in the body. Account connection/refresh is the compact refresh icon on the right of the account
status row; it becomes a spinner while a request is running.
The album picker header shows only Back, Choose album and Done, without an email
prompt. Account scoping still uses the connected account internally.
The root page has Done on the right and no Back button; pushed pages have native
Back and Done. Back returns one page; Done closes the whole GoToHP panel.

The **Album** group in Uploads only contains **Album destination**. There is no
album-status row or separate status card. Album status/counters are included in
the combined upload diagnostics export instead.

1. In **Uploads**, tap **Album destination** and choose **Do not add to an album**
   (the default), **Existing Album**, or **Create New Album**.
2. Existing Album opens the current account's cloud album picker. Select by name;
   search filters names and pulling down reloads the catalog. A failed load shows
   Retry beside its error. Manual album ID entry is the first row below search;
   its text field uses the standard iOS editing menu for Paste, with no custom
   clipboard button. Pasting only fills the field; choosing the album
   still requires confirmation and validation. Manual entry remains a fallback. Choosing an album saves immediately;
   canceling leaves the destination unchanged. Create New Album asks for a name
   and saves only when Save is tapped.
3. Use **Choose photos and videos** or **Choose album on this device** to choose
   upload sources. Device albums are sources, distinct from Google Photos destinations.
4. For troubleshooting, enable **Upload diagnostics** and use **Export diagnostics**
   in Settings. The JSON includes the current album diagnostic report. Keep Google
   Photos in the foreground for a Jailed/TrollStore installation.

New imports snapshot the saved target. Successful uploads retain confirmed media
keys; once the account's import/upload work has settled, the album worker sends
batches of at most 500 keys. Failed uploads do not block successful items. Creating
a new album is a separate durable step: its returned ID is saved and reused by
later uploads. Re-saving the same name does not request another album.

Settings changes apply to new imports. Already queued work keeps its target.
Disabling the feature pauses album work without pausing uploads. Existing pending
album work resumes when enabled again. Counts include all targets for this account;
the saved destination name belongs to the current configuration. Selecting a
new destination does not retarget already queued jobs.

The picker requests collection metadata only, using the current account's existing
authentication. Discovery is transient, asynchronous and bounded; it never uploads
media or creates an album. Removing or reconnecting an account clears its cached
catalog. A failed or incomplete enumeration is shown as a failure, not an empty
library. Shared albums can be visible without granting permission to add items.

## Status and retries

- **Disabled:** album work paused by its account configuration.
- **Waiting:** awaiting successful uploads, import completion, connectivity,
  Wi-Fi/charging policy, authorization, or a bounded retry delay.
- **Uploading:** the existing upload queue is running.
- **Adding to album:** an album create/add RPC is in progress.
- **Completed:** all eligible assignments have been acknowledged by the API.
- **Failed:** an album operation failed, its result is uncertain, or a media ID
  cannot be resolved. Upload completion remains intact.

The **Accepted** count means the private API returned an HTTP success and a
well-formed protobuf body (an empty acknowledgement is also allowed by upstream).
There is no verified per-item acknowledgement schema or independent membership
read-back in this version. Check the destination album before deleting local media.

Album status is no longer displayed as a separate control. **Export diagnostics**
in Settings exports one JSON report for uploads and albums. The `album` section
explicitly marks availability; when available its report contains fixed status/error
codes and counters, excluding account names, tokens, album names/IDs and media IDs.
Missing album status does not prevent the upload report from being exported.

The export requests fresh album data. The upload screen caches only its destination
metadata between polls and refreshes it on page entry, account change, destination
change or a previously failed read. It does not continuously poll album counters.

Failed album work retains the existing backend retry policy. Album failure does not
reupload media. Permission/ID errors still require fixing the target/account; an
unresolved outcome must not be assumed to be a confirmed album membership.

## Persistence and media types

Album configuration, target IDs and tasks are added to the existing private
`state.json` alongside upload jobs. Atomic state replacement persists upload
completion and its album work together. Completed upload history and primary
`mediaKey` remain compatible with native backup reconciliation. New RAW+JPEG jobs
record both component keys; a linked Live Photo remains one media item.

Explicit picker/album/share imports maintain a renewed import lease while exporting
so the worker does not flush between items. A dead client lease expires after one
minute; engine restarts release all leases. Native automatic backup uses account
queue quiescence; future system backup events form subsequent batches.

Do not edit `state.json` while the app/service runs. Album-only tasks are independent
of the staged local media, so clearing completed upload history does not erase
their pending assignments. Account removal is blocked while album work is pending
or unresolved, to prevent silently orphaning it.

## Build and install

Use the existing **Build and test** GitHub Actions workflow on the feature branch,
with `release_tag` empty. It runs Go tests, native macOS fixtures, and Theos builds.
Download the `gotohp-tweak-jailed` artifact. It contains `GunshotJailed.dylib`,
`gotohp-tweak-jailed.deb`, notices and this guide.

For a local macOS build:

```sh
git submodule update --init --recursive
python3 scripts/prepare-core.py
bash scripts/test-core.sh
bash scripts/test-native.sh jailed
export THEOS="$PWD/.theos-sdk"
bash scripts/setup-theos.sh
bash scripts/package.sh jailed
python3 scripts/verify-package.py jailed
python3 scripts/verify-ios-minimum.py packages/jailed/GunshotJailed.dylib 16.1
```

Follow [the existing Jailed guide](jailed.md) for injection. With Sideloadly, inject
the `.deb`, leave its separate Cydia Substrate option OFF, and export/install using
the existing process. For manual injection, replace the old Gunshot library rather
than loading two versions. Preserve the Google Photos Bundle ID and existing
framework dependencies/signing process; install through TrollStore as before.
No Google Photos IPA, token or certificate belongs in the repository or release.

## Rollback

Keep the previous working IPA and a private copy of the app's existing GoToHP
state before updating. Disable album work, close Google Photos, then reinstall the
previous IPA with the same Bundle ID using the original TrollStore process. Do
not uninstall the app or clear its data. Preserve a copy of the new `state.json`
before launching an older build: older code can discard unknown album fields on
its next save. Do not restore an older state over newer successful upload history
without reconciling those uploads first.

## Device acceptance still required

Validate on the actual iOS 16.1/Google Photos 7.20.2 installation: launch and SSO,
five photos into an existing album, create/reuse a new album, mixed video/RAW/Live
Photos, airplane mode and force-close recovery, album-only retry, account change,
and feature OFF. A passing build or mocked backend does not replace these checks.

For the consolidated UI, also check root Done without Back, native Back on pushed
pages, Done from the cloud picker, reconnect using the account-row icon, cancellation
without changing the destination, shared-media upload without an Add header button,
and a combined export whose album section contains no account/album/media IDs.
