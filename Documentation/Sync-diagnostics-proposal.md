# App-supplied structured sync diagnostics (L8)

Investigated 13 September 2026. The user subsequently authorized implementation;
see [the implemented API and its limits](Sync-diagnostics.md). The text below
preserves the investigation and proposed contract.
This accompanies the [optional improvement list](Sync-improvement-proposals.md).

## Current capabilities and gaps

Upstream's live release and main endpoints both resolve to version
[1.12.0](https://github.com/pointfreeco/sqlite-data/releases/tag/1.12.0), commit
`164bb5f223738af3d5da7a1b8de14e67e4d9cd5d`. This fork's checked-fetch patch does
not change the logging interface.

- The public initializer already accepts a concrete `OSLog.Logger`. It does not
  accept a custom logging protocol, event closure or backend adapter. Despite
  the initializer's prose saying disabled, its actual default is disabled in
  tests and otherwise uses subsystem `SQLiteData`, category `CloudKit`.
- Detailed CloudKit lifecycle, record/zone results, account events and outgoing
  batch tables require the **library** to be compiled with `DEBUG`. Changing an
  app's runtime log level cannot restore those calls in a release library.
  Most errors inside these tables are logged at debug severity. A metadatabase
  connection debug message is not DEBUG-gated, so not all logging disappears.
- The public `SyncEngineDelegate` only exposes account-change behavior.
- Selected internal errors use `IssueReporting` in non-DEBUG code. Its public
  `IssueReporter` supports application-default and task-scoped customization;
  an app can forward those existing reports without patching SQLiteData. Keep
  the default/test reporters and sanitize errors. Callback context must be
  verified rather than assuming a scoped reporter reaches all CloudKit work.
  This is a subset of failures, not a structured per-engine transfer timeline.

Upstream added tabular logs in September 2025 and adopted IssueReporting 2.x in
August 2026. Neither adds the sink described here. Source references:
[initializer and dispatch](https://github.com/pointfreeco/sqlite-data/blob/164bb5f223738af3d5da7a1b8de14e67e4d9cd5d/Sources/SQLiteData/CloudKit/SyncEngine.swift),
[formatter](https://github.com/pointfreeco/sqlite-data/blob/164bb5f223738af3d5da7a1b8de14e67e4d9cd5d/Sources/SQLiteData/CloudKit/Internal/Logging.swift),
[delegate](https://github.com/pointfreeco/sqlite-data/blob/164bb5f223738af3d5da7a1b8de14e67e4d9cd5d/Sources/SQLiteData/CloudKit/SyncEngineDelegate.swift),
[reporter API](https://github.com/pointfreeco/swift-issue-reporting/blob/71c7c9a761d1ca6ed4ccb6ced040fe1c1a39e8e7/Sources/IssueReporting/IssueReporter.swift).

## Proposed contract

Add an optional, per-engine, `Sendable` sink receiving typed diagnostic values.
A closure-backed client can avoid a dependency on any logging framework or
backend. Preserve source-compatible initializers, existing OSLog support and
IssueReporting behavior. Final API naming remains open.

Each event should have a kind, severity, timestamp, opaque session/operation
identifiers, private/shared scope and sanitized attributes. Define ordering per
operation; independent scopes can interleave. Use registered record types so
new entities need no diagnostic-specific implementation.

Cover startup/preparation failures, account availability/change, observed stop
boundaries, fetch/zone progress, local application and state-persistence results,
deferred parents, asset/decoding errors, submitted batches, server-reported
save/delete outcomes, partial failures and conflict handling. Include counts,
durations, sanitized error domains/codes and retry-after values when present.
Report library retry decisions; mark Apple's unknown scheduling state unknown.

“Received,” “committed locally,” “submitted,” and “accepted by the server” are
different events. Receiving a batch does not prove successful application;
finishing a send does not prove every pending revision was accepted. Do not
claim a stop is drained without an awaited boundary or call activity flags
“everything synced.” Other devices can still hold unsent changes.

Emit in release builds with runtime filtering and lazy verbose payloads. Define
callback concurrency and require nonblocking consumers. Keep network/disk I/O
outside database/engine locks and delegate completion. Use bounded handoff,
overflow counts and summaries; do not create unbounded tasks or log queues.
Slow-consumer behavior must be explicit. Arbitrary callback code can still
block or crash itself; the contract must not promise otherwise.

Logging is observational and may drop entries. It must not control retries,
readiness or durability. Preserve test failure reporting and support deduping
errors also surfaced through IssueReporting or throwing APIs.

Default payloads contain counts, timings, record types and error codes. Opaque
IDs correlate operations without raw account/owner/zone/record identifiers.
Exclude record contents, assets, paths, tokens, SQL bindings and arbitrary
NSError userInfo. OSLog interpolation privacy does not sanitize a second sink.

Apps own Console/Sentry adapters, severity policy, sampling, retention, export
and upload. Expected offline retries should not create an issue per attempt;
actionable failures may create a grouped issue with recent context. Verify the
app's production filtering actually retains the intended summaries. No Sentry
dependency or telemetry upload belongs in this library patch.

Diagnostics can expose observed outcomes now. Durable intent, replay, drained
shutdown, account isolation, awaitable startup and revision-specific delivery
accounting remain separate proposals. Add their events when those contracts
exist. Logs themselves are not a recovery journal or upload receipt.

## Acceptance

Use a collecting sink to verify scoped ordering, successes, partial failures,
cancellation, conflicts, missing assets and metadata failures. Prove that
received-but-uncommitted records never emit local success. Execute emission
tests without `DEBUG`, check disabled/filtering cost and initializer compatibility.
Exercise slow consumers and repeated errors for bounded memory, overflow,
duplicate suppression and lock reentrancy. Inspect nested failure payloads for
content/identity leakage and verify that diagnostics do not change sync results.
App adapter and signed live-device checks are separate integration acceptance.
