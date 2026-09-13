# Incoming recovery, drained shutdown, and account isolation (L2–L4)

These patches build on durable outgoing intent, checked fetch completion, and
structured diagnostics. [L5 explicit startup outcomes](Sync-startup.md) were
implemented subsequently. L6 public revision-receipt and L7 public shared-server
APIs remain deferred.

## Incoming recovery (L2)

Incoming record updates, deletions, zone deletions/resets, and asset bytes are
staged in the **user SQLite file**. The CloudKit state serialization and promotion
of the corresponding staged entries commit in one transaction in that file.
Only promoted entries may change application rows. Applying a row and retiring
its exact inbox revision also share one transaction. This prevents a failed
receipt or old checkpoint from repeating a deletion over a later local recreation.

A failed capture never advances its scope's durable checkpoint. A failed apply
retains the complete payload even if CloudKit never delivers it again. Private
and shared checkpoints promote only their own entries. The journal retains the
latest staged server state per identity and uses separate slots for eligible and
not-yet-checkpointed entries. A confirmed zone deletion supersedes older queued
records from that zone. Parent-before-child replay preserves foreign-key deferral.

Assets are copied into the journal before checkpointing; the record archive's
temporary URLs alone are insufficient. Replay materializes content-addressed
scratch files from those bytes. Unsupported entity records remain available for
a future schema; registered entities, shares, and deletions must finish before
a checked fetch succeeds. The same typed table registry drives replay ordering.

```swift
try await syncEngine.recoverIncomingChanges()
```

This retries retained application and performs a checked fetch. If capture failed,
it first retires the generation and starts from the last committed checkpoint.
`fetchChangesAndApply()` also retries eligible entries. Neither operation treats
an empty fetch as proof that a failure outside the durable incoming path was fixed.
Legacy unresolved IDs remain pending until an actual replacement/deletion arrives.
Payloads already lost by an earlier library version cannot be reconstructed here.

Diagnostics distinguish `incomingStaged`/`retained` from `applicationFinished`/
`applied`. Application success is emitted only after the row and retirement commit.
Checkpoint persistence is reported independently of subsequent application failure.

## Engine retirement (L3)

```swift
try await syncEngine.stopAndDrain()
// The resource owner may now close this database or publish a replacement session.
```

`stop()` immediately closes generation admission and requests cancellation.
`stopAndDrain()` additionally waits for startup, account lookup, owned operations,
delegate processing, batch construction, writes, and CloudKit cancellation to
finish. SDK callbacks arriving later are fenced by their originating generation.
Activity state resets; old callbacks cannot repopulate it. Offline edit tracking
remains installed. Restart joins an outstanding retirement.

Every owned write validates its generation inside the SQLite transaction before
and after its changes. A late cancellation-ignoring operation cannot commit through
a retired session. Explicit local deletion is also tracked as a maintenance operation.

Do not await retirement/start/recovery or invoke `deleteLocalData()` from a delegate
callback or another owned operation. That would wait on itself and throws
`LifetimeError.reentrantDrain`. Request `stop()`, return, then let the resource owner
await retirement. A cancelled waiter never withdraws the retirement request.

## Account ownership (L4)

Enable the policy at construction and supply the **effective signed environment**:

```swift
let engine = try SyncEngine(
  for: database,
  tables: TaskRecord.self,
  containerIdentifier: "iCloud.example.app",
  startImmediately: false,
  accountIsolation: .init(environment: .production)
)
try await engine.start()
```

Before constructing live engines, the library resolves CloudKit's current user
record ID and checks an immutable container/environment/account binding in the
user file. The stored account value is a digest, not the raw user identifier or a
purchase-system identity. A genuinely empty store may bind automatically. Existing
unowned rows, outgoing/incoming work, or sync metadata require explicit adoption.

```swift
// Capture this value when presenting the connection prompt.
let request = engine.accountAdoptionRequest
// Only after the person confirms the displayed choice:
if let request { try await engine.adoptLocalDataForCurrentAccount(request) }
```

The opaque request is scoped to the engine and the offered account. Another lookup
or an account change cannot transfer an earlier confirmation to the new account.
An already bound store cannot be reassigned through adoption or local deletion.
A bound store also refuses construction with account protection omitted.

Transfer/batch and incoming/checkpoint/result boundaries revalidate ownership.
Sign-out or a switch from **either scope** immediately fences the session and
retains local rows and both journals, before notifying the application delegate.
The default delegate no longer erases data. Observe `accountIsolationFailure` for
ownership/adoption status even before the app's account notification arrives.
Sign back into the original account and start again to resume its pending work.
Use a separate database for a different account; merging or migrating ownership
requires a separate, explicit application workflow.

Without this optional policy, default account events still stop and retain data,
but callers are responsible for account-safe restart. Daily enables the policy.

## Compatibility and verification boundaries

The shared sync-store version advances from 1 to 2, preserving pending outgoing
revisions and importing the legacy checkpoint once. The previous L1 fork rejects
version 2 instead of using its stale sidecar checkpoint. Do not downgrade to older
clients that predate that version check; restore a matching pre-upgrade backup if
rollback is required. Keep the app's existing schema/compatibility protections.

Main-file row/inbox/checkpoint commits do not turn the legacy attached metadata
file into a cross-file WAL atomic transaction. The tests cover process termination,
not whole-machine power-loss guarantees or arbitrary file corruption. Corrupt or
unreadable checkpoints fail closed rather than silently triggering a full replay.

CloudKit does not accept an application-supplied expected-account credential for
an operation. These protections combine persistent ownership, boundary checks,
SDK account-change ordering, and generation fencing. They do not claim control over
an operation Apple already accepted before a switch. Real signed multi-device and
two-account acceptance still requires disposable accounts and the intended environment.

Verification commands:

```sh
swift test --jobs 8 --filter 'BaseCloudKitTests|SyncDiagnostic|OutgoingIntent|SyncDrain|Incoming|SyncAccountIsolation'
swift test -c release --jobs 8 --filter 'BaseCloudKitTests|SyncDiagnostic|OutgoingIntent|SyncDrain|Incoming|SyncAccountIsolation'
python3 Tools/test-incoming-recovery.py PATH_TO_IncomingRecoveryCrashProbe
python3 Tools/test-outgoing-durability.py PATH_TO_OutgoingIntentCrashProbe
```

The incoming probe abruptly exits and reopens independent processes for an update
with an asset, deletion, failed retirement followed by local recreation, and an
account A store reopened under B. It uses isolated WAL files and mock CloudKit only.

Final library verification (13 September 2026): debug **253 tests / 42 suites**
with 29 deliberately injected/existing known issues; release **251 tests / 41
suites** with 28. No unexpected failures. All four incoming/account and ten
outgoing subprocess scenarios passed with each build. All 157 recorded library
input hashes remained unchanged, and dependency revisions were preserved.
