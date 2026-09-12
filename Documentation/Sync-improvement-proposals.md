# Optional sync improvements — awaiting individual decisions

Only [checked fetch completion](Fetch-completion-patch.md) is implemented in this
fork. These are proposals, not accepted implementation scope. Each should be a
separate patch with its own tests and migration review.

| Proposal | Problem / intended contract | Evidence required before adoption |
| --- | --- | --- |
| Durable outgoing intent | A committed local insert, update or deletion must remain uploadable after abrupt termination, including deletion tombstones and failed acknowledgements. Capture intent transactionally with the user write. | Subprocess crash windows around commit, enqueue, server acceptance and acknowledgement; retry identity and sidecar consistency. |
| Durable failed-download journal and replay | A caught apply failure must retain enough information to replay records and deletions even when CloudKit advances its change token. Recovery must prove application before clearing workflow holds. | Failed update/delete/asset, retry after relaunch, checkpoint ordering, partial transactions and repeated failures. |
| Awaitable stop and draining | Callers need to know that an old engine cannot write or recreate triggers before replacing it. | Suspend each callback, stop, release, and verify no old-generation writes; no delegate deadlock. |
| Account identity isolation | Data from account A must not upload to B during sign-out/switch, including changes already queued before the app sees the account event. | Two-account transitions during startup/fetch/send, offline writes, stale callbacks and retained stores. Requires the draining boundary. |
| Startup result | `isRunning` should not imply successful preparation when asynchronous startup work fails. | Fail schema preparation/account lookup/triggers and verify explicit failure, retry and ownership. |
| Upload acknowledgements | Report specific accepted record revisions separately from pending work and fetch state. | Server acceptance followed by dropped acknowledgement, conflicts and partial batch errors. |
| Supported shared test transport | Let independent public test engines share one controllable server without package internals. | Multi-client convergence, deterministic event scheduling, failure injection and stable test API. |

Cloud record compatibility, existing clocks and unknown-field preservation should
be retained unless a proposal explicitly includes a reviewed migration. No
proposal establishes visibility into edits that another device has not uploaded.
