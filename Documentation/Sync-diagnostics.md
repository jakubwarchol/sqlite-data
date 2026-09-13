# Structured sync diagnostics

The optional `diagnostics:` argument on `SyncEngine` exposes sanitized events in
debug **and release** builds. It is independent of the existing `OSLog.Logger`
argument and does not add a logging backend dependency.

```swift
let diagnostics = SyncDiagnostics(minimumLevel: .info, bufferCapacity: 256) { event in
  // Hand this value to your app's logger. Return promptly; do not wait for sync.
  appLogger.record(event)
}
let engine = try SyncEngine(
  for: database,
  tables: Item.self,
  logger: Logger(.disabled), // Avoid duplicate legacy DEBUG output if desired.
  diagnostics: diagnostics
)

// Thread-safe; no engine replacement is necessary.
diagnostics.minimumLevel = .debug
```

Omitting `diagnostics` preserves the previous API and does not construct
diagnostic payloads. Existing IssueReporting behavior and the OSLog initializer
remain available. Constructor failures still throw to the caller; diagnostics
cover an initialized engine's work rather than replacing app startup error handling.

## Events and interpretation

Each event includes a kind, level, opaque engine-instance/session ID, emission
sequence and timestamp. Observed operations additionally include an opaque
operation ID, scope, stage, counts and completion duration where available.
Registered entity names are bounded to 16 names of 96 characters; unknown
remote type names and raw record IDs are not exported.

| Event | Meaning |
| --- | --- |
| `startupStarted` / `startupFinished` | Preparation began and was observed prepared, unavailable or failed. This does not change the existing startup API's error behavior. |
| `stopRequested` / `stopReturned` | The current synchronous stop returned. This is **not** a drained shutdown. Queued diagnostics and old engine callbacks may still arrive. |
| `accountChanged` | Sign-in, sign-out or account-switch category, without user identifiers. |
| `fetchStarted` / `fetchFinished` | Per-scope fetch callback lifecycle, with received counts and observed errors. Completion is not proof of global freshness. |
| `changesReceived` / `applicationFinished` | A received batch and its local processing result. Apply errors, deferred parents and ignored records prevent an `applied` outcome for the batch. Counts called `errors` count error observations, not rejected rows. |
| `statePersisted` | State serialization was written, or its write failed. |
| `sendStarted` / `sendFinished` | Send callback lifecycle. Finishing a callback does not prove all local revisions were uploaded. |
| `batchPrepared` | Outgoing preparation, requested change count, skipped records and observed conversion failures. This is not submission or acceptance. |
| `uploadResults` / `zoneUploadResults` | Server-reported saved/deleted results and failed save/delete counts. Partial batches are explicitly `partial`. A saved response is not a durable revision-specific receipt. |
| `retryEnqueued` | The library added retry work; this does not expose Apple's internal retry schedule. |
| `operationFailed` / `invariantViolation` | Sanitized failures, correlated to the current stage when available. |
| `fetchRequested`, `sendRequested`, `checkedFetchRequested` / `requestFinished` | Explicit API requests and returns/throws, including cancellation. A request returning normally is labeled `callbackCompleted`. |
| `eventsDropped` | The diagnostic receiver fell behind; the stream is incomplete. |

Transfer starts/finishes and important outcomes use info or higher. Zone detail,
received-batch detail, successful metadata writes and ordinary batch preparation
use debug. CloudKit errors include numeric codes, fixed code names and validated
retry-after values. Batch failure samples contain at most eight distinct errors.
Arbitrary error descriptions, NSError domains/userInfo, assets, SQL bindings,
paths, account/zone/record IDs and change tokens are excluded from these payloads.
The existing IssueReporting/default OSLog paths retain their previous behavior;
this is not a redaction retrofit of unrelated app or library logging.

Correlation is local to an engine instance. Private/shared operations can
interleave. A bounded map retains at most eight active transfer contexts,
including old engine generations; callbacks without a retained start get a new
context. No raw CloudKit identifiers are used to stitch records across devices.

## Delivery and ownership

One serial queue per configured engine delivers immutable value snapshots.
No receiver is invoked inline under a database or sync-engine lock. A bounded
ring buffer holds 1–4096 events (default 256), plus the currently delivered event.
When full it drops new entries at any severity and reports the total loss after
queued work drains. The loss warning bypasses the configured minimum level.
Sequence gaps indicate overflow; filtered events consume no sequence numbers.

The receiver must return promptly and must not synchronously wait for more
diagnostics. A blocked receiver cannot block the sync producer, but it delays
delivery and causes drops. Arbitrary consumer code can still crash or block
itself. Do not enqueue an unbounded task or network request for every event in
the app adapter. The library performs no telemetry upload or log persistence.
Queued values can outlive engine stop; stopping is not a log flush operation.

Diagnostics never control scheduling, repair holds, account ownership or
durability. They are not a recovery journal. Existing test issue reporting is
preserved, so adding a separate global IssueReporter forwarding the same errors
requires app-level duplicate handling. This patch does not install such a reporter.

## Validation

The focused tests exercise public initializer injection, release emission,
runtime filtering, private/shared correlation, committed updates/deletions,
failed writes and assets, deferred/unknown records, partial delivery, retry
information, cancellation, metadata read failure, bounded overflow and a
receiver reading the database after emission inside its writer.

Validation on Xcode 27 RC / Swift 6.4:

- `swift test --jobs 8 --filter 'BaseCloudKitTests|SyncDiagnostic'`: 217 tests in
  35 suites passed, including seven known issues (existing and deliberately
  injected failures).
- `swift test -c release --jobs 8 --filter 'BaseCloudKitTests|SyncDiagnostic'`:
  215 tests in 34 suites passed, with the same seven known issues. Two existing
  DEBUG-only tests are excluded; the diagnostics tests execute in release.
- Final debug diagnostics check after the entity-summary assertions:
  `swift test --jobs 8 --filter SyncDiagnostic`: 17 tests in three suites passed,
  including four deliberately injected known issues.

The 17 added tests do not use DEBUG-gated event implementations. Source/test
hashes are recorded with the app integration evidence to identify the tested patch.
Signed CloudKit sessions and actual telemetry delivery remain separate app
integration acceptance; mock transport tests cannot establish those outcomes.
