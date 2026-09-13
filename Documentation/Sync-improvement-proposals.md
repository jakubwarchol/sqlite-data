# Optional sync improvements — awaiting individual decisions

[Checked fetch completion](Fetch-completion-patch.md),
[structured diagnostics](Sync-diagnostics.md), and
[durable outgoing intent](Durable-outgoing-intent.md), and
[incoming recovery, drain and account isolation](Sync-recovery-and-account-isolation.md)
are implemented in this fork. L5–L7 remain proposals with separate decisions and acceptance.

| Proposal | Problem / intended contract | Evidence required before adoption |
| --- | --- | --- |
| Durable outgoing intent (L1) — implemented | A committed local insert, update or deletion must remain uploadable after abrupt termination, including deletion tombstones and failed acknowledgements. Capture intent transactionally with the user write. | Debug/release regressions and ten subprocess crash/reopen scenarios passed; see [contract and limits](Durable-outgoing-intent.md). |
| Durable failed-download journal and replay (L2) — implemented | A caught apply failure must retain enough information to replay records and deletions even when CloudKit advances its change token. Recovery must prove application before clearing workflow holds. | Failed update/delete/asset, retry after relaunch, checkpoint ordering, partial transactions and repeated failures. |
| Awaitable stop and draining (L3) — implemented | Callers need to know that an old engine cannot write or recreate triggers before replacing it. | Suspend each callback, stop, release, and verify no old-generation writes; no delegate deadlock. |
| Account identity isolation (L4) — implemented | Data from account A must not upload to B during sign-out/switch, including changes already queued before the app sees the account event. | Two-account transitions during startup/fetch/send, offline writes, stale callbacks and retained stores. Requires the draining boundary. |
| Startup result | `isRunning` should not imply successful preparation when asynchronous startup work fails. | Fail schema preparation/account lookup/triggers and verify explicit failure, retry and ownership. |
| Upload acknowledgements | Report specific accepted record revisions separately from pending work and fetch state. | Server acceptance followed by dropped acknowledgement, conflicts and partial batch errors. |
| Supported shared test transport | Let independent public test engines share one controllable server without package internals. | Multi-client convergence, deterministic event scheduling, failure injection and stable test API. |
| App-supplied structured sync diagnostics (L8) — implemented | Production-capable lifecycle, fetch/apply/send outcomes, partial failures and retry information through an injectable, entity-independent sink. Apps choose OSLog, Sentry or another destination. | See [implementation and validation](Sync-diagnostics.md); the [original investigation](Sync-diagnostics-proposal.md) is retained. |

Cloud record compatibility, existing clocks and unknown-field preservation should
be retained unless a proposal explicitly includes a reviewed migration. No
proposal establishes visibility into edits that another device has not uploaded.

## Practical value assessment

Daily authorized and implemented L2–L4. L5 remains a recommended follow-up. The practical priorities are: failed-download recovery, awaited
shutdown, account isolation and a small explicit startup-result contract. L6
(public revision acknowledgements) and L7 (a public shared test transport) are
deferred until a concrete app feature needs them. The private receipt tracking
and crash probe used by L1 do not add either public API.
