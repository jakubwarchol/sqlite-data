# Explicit startup outcome (L5)

`try await engine.start()` now waits for account authorization and local
preparation and throws the original synchronous or asynchronous error. Previously,
`isRunning` became true when transports were allocated, and the asynchronous
preparation task reported errors without propagating them to the caller.

```swift
try await engine.start()
// The current generation completed account/schema/outgoing preparation.
// To establish applied downloads, separately await fetchChangesAndApply().
```

`startupState` is observable and has four cases: `stopped`, `preparing`, `ready`,
and `failed(any Error)`. `isPrepared` derives from it. `isRunning` retains its
transport-allocation meaning for compatibility. A caller should not substitute
that property for successful preparation. The failure preserves typed errors
and CloudKit retry-after values; diagnostics never export raw descriptions.

Manual starts, `startImmediately`, account adoption, and explicit reset all use
the same owned startup request. Concurrent callers join it. Failed attempts retire
their transports and leases automatically, including when nobody awaits an
automatic start. A subsequent `start()` waits for retirement before retrying.
An unavailable account throws instead of returning successful preparation.

Stopping during preparation invalidates its generation before cancellation;
late preparation cannot publish `ready`. Cancelling one waiting caller does not
stop the shared attempt for others. That caller receives cancellation after the
owned attempt completes; use `stop()`/`stopAndDrain()` to retire the attempt itself.
Startup and drain must be awaited outside engine delegate callbacks. A late
waiter never retires a newer startup attempt.

Preparation errors are not entered into the sticky incoming-application failure
slot. Repairing the preparation problem therefore permits a clean retry and
checked fetch. Retained incoming records still use L2's independent recovery
contract: attempted replay can fail or defer without preventing the transport
from starting. `ready` and the `startupFinished/prepared` diagnostic do not claim
that those downloads were applied, that uploads were acknowledged, or that other
devices have converged. Application diagnostics and checked fetch report that
separate work.

## Compatibility

No database format, record schema, merge policy, account binding, or dependency
version changes. The existing throwing `start()` signature remains source
compatible but now exposes errors which were previously swallowed. Applications
must handle those errors. For `startImmediately`, even synchronous preparation
errors are now exposed through the owned attempt/state rather than thrown from
the initializer; initializer schema/configuration validation still throws.
Observe `startupState` or await `start()` to join the automatic attempt.

The existing transport scheduling policy remains: work may begin while local
preparation is in progress. Retirement does not undo a transfer already accepted
by CloudKit. Readiness is an explicit preparation result, not a transaction around
all network effects.

Regression testing also corrected replay diagnostics: either database scope can
drive the durable replay queue, so application cannot borrow an operation ID from
a different scope. Cross-scope replay gets its own application operation ID.

## Verification

Regression tests cover asynchronous SQLite failure and a clean retry, account
unavailability, shared preparation/cancelled waiter, stop during suspended
preparation, original CloudKit retry information with diagnostics disabled,
automatic failure without a waiting caller, and joining a public automatic start.
Daily additionally verifies that transport allocation cannot establish startup
history, and that a real asynchronous library failure preserves rows and can be
retried without leaving checked fetch poisoned.

The complete debug/release CloudKit regression groups and the existing incoming /
outgoing subprocess scenarios are rerun for this patch. Signed live CloudKit and
distribution acceptance remain separate from mock-backed local regression proof.

Final verification: debug **261 tests / 43 suites** (27 existing/injected known
issues); release **259 tests / 42 suites** (28 known issues), with no unexpected
failures. Four incoming/account and ten outgoing crash/restart scenarios passed
with each build. All 159 recorded source/test/tool inputs remained unchanged
through both builds. Dependency revisions are unchanged.

Commands:

```sh
swift test --jobs 8 --filter 'BaseCloudKitTests|SyncDiagnostic|OutgoingIntent|SyncDrain|Incoming|SyncAccountIsolation|SyncStartup'
swift test -c release --jobs 8 --filter 'BaseCloudKitTests|SyncDiagnostic|OutgoingIntent|SyncDrain|Incoming|SyncAccountIsolation|SyncStartup'
python3 Tools/test-incoming-recovery.py .build/out/Products/Debug/IncomingRecoveryCrashProbe
python3 Tools/test-outgoing-durability.py .build/out/Products/Debug/OutgoingIntentCrashProbe
python3 Tools/test-incoming-recovery.py .build/out/Products/Release/IncomingRecoveryCrashProbe
python3 Tools/test-outgoing-durability.py .build/out/Products/Release/OutgoingIntentCrashProbe
```
