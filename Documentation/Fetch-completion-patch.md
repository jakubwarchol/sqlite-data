# Focused fetch-completion patch

Current L2–L4 behavior and migration are described in
[Sync recovery and account isolation](Sync-recovery-and-account-isolation.md).
The original patch's verification record below is retained.

This fork starts from upstream **1.12.0**, commit
`164bb5f223738af3d5da7a1b8de14e67e4d9cd5d`. Previous fork-specific logging
changes are not included. The only addition is checked fetch completion and its
failure reporting, tests and documentation.

```swift
try await syncEngine.fetchChangesAndApply()
// The requested fetches and their local application have completed successfully.
```

The original `fetchChanges(_:)` API remains available. The new method requests
all zones in both private and shared databases, waits for startup, checks account
availability, and awaits both CloudKit operations and their delegate handlers.
It requires observed completion in both scopes and checks the local retry table
for unapplied foreign-key records. A stopped engine, silent no-op, cancellation,
engine replacement or observed account change cannot establish completion.
Concurrent checked requests are rejected explicitly; background sync continues.

SQLite apply and metadata failures were previously reported through
`withErrorReporting` and swallowed. They still reach IssueReporting, and now
also invalidate checked completion. This includes nested row upserts, deletes,
zone deletion, share caching, startup preparation and state persistence. A
missing asset must throw instead of being silently written as SQL NULL. Known
table records missing required sync fields cannot be silently ignored. Unknown
record types retain upstream forward-compatibility behavior.

Per-zone CloudKit errors and thrown fetch errors propagate. Both child operations
finish before error selection, so a transport error cannot conceal a local
application failure in the other database. Ordinary transport/zone failures can
be retried. Local application failures are conservatively retained for the
engine's lifetime; a later empty fetch does not establish that the failed records
were replayed. There is deliberately no API to clear that evidence blindly.

## Contract limits

- This is a request-completion check, not a permanent global "all synced" flag.
  Other devices may have unsent edits; new changes may arrive after return.
- It does not add atomicity between the main database and its metadata sidecar,
  durable pending writes, failed-download replay, or a durable completion receipt.
  Failure evidence in the library lasts for this object, not across process loss.
  A consumer must preserve any workflow hold it needs across normal relaunch.
- Existing partial-write/CloudKit checkpoint behavior is not repaired by reporting
  the error. Restarting an engine is not evidence that the failed changes returned.
- It does not drain old engines or isolate accounts. Identity/generation checks
  invalidate this request; they do not prevent all stale background writes.
- Do not call it from `CKSyncEngineDelegate.handleEvent`: CloudKit waits for
  delegate processing, so recursively fetching there can deadlock.
- There is no new database migration, record encoding, zone, table registration,
  conflict policy, logger injection, public mock-transport API or upload receipt.

Apple documents that [fetchChanges(_:)](https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/fetchchanges(_:))
returns after related delegate events finish. The
[delegate](https://developer.apple.com/documentation/cloudkit/cksyncenginedelegate-1q7g8)
processes events serially per engine. This patch exposes the additional SQLite
application failures needed to use that boundary safely.

## Validation

`swift test --jobs 8 --filter FetchCompletionTests` exercises current database
state after update/deletion, failed application followed by another fetch,
unavailable/stopped engines, empty/no-op fetches, network and zone errors,
concurrent requests, cancellation, stopping during fetch, unresolved dependencies,
and mixed failures across scopes. Injected IssueReporting failures are explicitly
expected in the tests. Broader CloudKit regression suites check compatibility.

Live, two-device iCloud acceptance and process/power-loss guarantees are separate
work. See [the improvement proposals](Sync-improvement-proposals.md).
