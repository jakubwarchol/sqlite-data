# L1: durable outgoing intent

This patch makes pending local changes durable independently of CKSyncEngine's
serialized scheduling state. It builds on the checked-fetch and L8 diagnostics
patches. No new public acknowledgement API or CloudKit record fields are added.

## Contract

After a configured `SyncEngine` installs its tracking triggers, a user transaction
records the latest desired save or deletion together with the application row in
`main.sqlitedata_icloud_outgoingIntents`. Both changes roll back together. The
journal belongs to the user database file, including in WAL mode; it is not an
asynchronously written sidecar queue. Ordinary `stop()` retains tracking and intent.

Each `(recordName, zoneName, ownerName)` has a random revision. Later edits coalesce
into the latest desired state; this is not an event history promising delivery of
every intermediate keystroke. The journal retains deletion identities and the
metadata needed to reconstruct pending saves with their existing modification
clocks, parent identity and unknown server fields.

Batch preparation reads the user row, metadata and revision in one database
transaction. Conversion/asset errors prevent that record from being offered to
CloudKit, even with diagnostics disabled. An internal receipt identifies the
prepared revision. Success clears only that revision, in the transaction that
updates cached server metadata. A newer save, deletion or recreated primary key
survives an older receipt. Failure recovery also checks the prepared revision inside
its database write, after any network suspension; an older conflict or permission
response cannot revive a newer deletion or overwrite a newer edit. Uncertain
overlapping attempts retain intent for retry.

CloudKit state remains a scheduling cache. Startup restores journaled metadata,
adopts the legacy pending queue and serialized pending state without overwriting
newer intent, and schedules retained work. Adoption and removal from the legacy
queue share one transaction. Encryption-reset recovery journals reuploads too, so
losing scheduling state before the next send does not lose that work. The journal
is never cleared merely because work
was added to CKSyncEngine state. A lost acknowledgement can cause another upload
of the same identity; there is no exactly-once network-delivery claim.

## Existing behavior retained

- Root/child ordering, private/shared routing and the existing field conflict
  policy remain in place. A zone move journals the old deletion and new save;
  recovery does not reuse the old zone's cached CKRecord for the new identity.
- Leaving a share retains the existing share-only server deletion behavior.
  Covered local tombstones are retired with the matching share-deletion receipt.
- Successfully applied remote deletion or conflict resolution may supersede
  local state, as before. Durability does not override those product semantics.
- Permission-rejected saves stop retrying automatically. The retained journal
  entry is blocked; a subsequent user write replaces it with a fresh intent.
  Existing permission recovery can restore server values. The journal does not
  provide an archive of rejected user content.
- Missing tables or rows are retained without repeatedly offering invalid saves.
  L8 reports preparation failures; it does not control correctness.
- Explicit `deleteLocalData()` clears local intent together with the user's data.
  Ordinary shutdown, retry, startup and state serialization do not clear it.

## Compatibility and limits

The main database gains two library-owned tables. The configuration table checks
its schema version and CloudKit container identifier; an incompatible binding
fails construction. This is a container guard, not iCloud account ownership (L4).
The existing sidecar schema and all cloud record names/fields are unchanged.
Backups and recovery copies must retain the whole user database and its WAL using
a supported SQLite backup/snapshot procedure, along with the existing sidecar.

Writes must use the configured writer after engine construction. Direct writes
from another process/connection without tracking, writes before tracking is
installed, and older binaries that do not maintain this journal are outside this
contract. Do not treat downgrading the library as a supported rollback migration.
The change cannot reconstruct intent already lost before this upgrade.

The user-row/journal transaction is in one SQLite file. SQLite explicitly does
not guarantee host-crash atomicity across attached WAL files ([SQLite ATTACH](https://www.sqlite.org/lang_attach.html)).
Pending metadata snapshots reduce dependence on the sidecar, but the tests here
establish abrupt process-loss recovery, not whole-machine power-loss acceptance,
filesystem-corruption recovery or durability beyond the caller's SQLite/VFS
configuration. Incoming checkpoints and account isolation remain L2/L3/L4 work.

Apple delivers a CKSyncEngine instance's delegate events serially ([delegate documentation](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5)).
Receipt bookkeeping is scoped to that engine. Unfinished attempts are forgotten
at send completion/stop while durable intent remains; it does not implement the
awaitable engine drain proposed in L3.

## Validation

The regression group includes existing CloudKit/checked-fetch/diagnostics tests,
plus outgoing-intent tests for rollback, failure to write the journal, lost and
failed acknowledgements, late success after newer edits/deletions/recreation,
ambiguous overlapping callbacks, metadata reconstruction, legacy queue adoption,
container mismatch, zone moves, encryption-reset reuploads across restart, delayed
conflict/permission failures, and asset encoding with diagnostics disabled.

```sh
swift test --jobs 8 --filter 'BaseCloudKitTests|SyncDiagnostic|OutgoingIntent'
swift test -c release --jobs 8 --filter 'BaseCloudKitTests|SyncDiagnostic|OutgoingIntent'
python3 Tools/test-outgoing-durability.py .build/out/Products/Debug/OutgoingIntentCrashProbe
```

The macOS-only executable uses the public test-context initializer and mock
CloudKit. Its runner creates a fresh temporary directory for each case. It exits
abruptly while still occupying the writer queue, then starts a separate process
to verify the journal and replay the operation. Running/stopped insert, update
and delete, three rollback cases, and acceptance without a received callback
make ten scenarios. No live accounts, production databases or resets are used.

Final local results: debug **233 tests / 38 suites**, release **231 tests / 37
suites**, both passed with nine existing/deliberately injected known issues.
Two existing DEBUG-only tests explain the count difference. All 16 new L1 test
declarations passed. The ten subprocess scenarios passed against both debug and
release executables. All 143 recorded source/test/tool inputs remained unchanged
through final verification. No dependency versions were changed. Signed-device
CloudKit delivery remains separate acceptance.
