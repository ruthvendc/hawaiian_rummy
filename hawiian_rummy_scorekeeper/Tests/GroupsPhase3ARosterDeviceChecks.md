# Phase 3A roster verification

Use the Debug build from Xcode, the app’s CloudKit **Development** environment,
and a new disposable group. Phones A and B must use different Apple Accounts.
The command runs once per launch and logs to the Xcode console under
`[Roster verification]`. Remove the launch argument when finished.

## Recorded Increment 2 results

The owner reported all six checks passed on two physical iPhones signed in to
different Apple Accounts in CloudKit Development. The test group was
`Roster-Verification-1121`.

| Check | Result |
| --- | --- |
| Owner create | PASS — The owner saved and read back a player and reservation through the private database. |
| Member create | PASS — The approved member saved and read back a player and reservation through the shared database. |
| Cross-account read | PASS — Both phones saw both seeded player and reservation pairs. |
| Concurrent equivalent names | PASS — Both phones reached READY, the member committed, and the owner reported Duplicate rejected. Both phones then found exactly one valid race player and reservation. |
| Atomic rollback and name reuse | PASS — Rejected batches preserved the original records and reservations. A later rename released a name that a different player could claim. |
| Ambiguous save | PASS — The original draft UUID recovered a real committed write after a simulated lost response, yielding one player and reservation. |

Increment 2 is complete for Debug and CloudKit Development. The test group is
retained. The instructions below remain available for targeted regression checks.

## Development schema

The existing `GroupV1` root and hierarchical share hold both new record types.
Each record has its normal CloudKit `parent` set to the group root and lives in
the root’s zone. Use these definitions in the app container’s **Development**
schema. If you rely on development-time schema creation on save, the first
write of a field establishes its type. In particular, an active player omits
`retiredAt`, so define it before testing retirement or verify it after the
first retirement save.

| Record type | Record name | Custom fields |
| --- | --- | --- |
| `GroupPlayerV1` | `player-<UUID>` | `displayName` (String), `creatorKey` (String), `retiredAt` (optional Timestamp) |
| `GroupPlayerNameV1` | `player-name-<SHA256 of normalized name>` | `playerID` (String, player UUID or empty when released) |

The group zone and parent define group scope. The creator key is a group-scoped
digest of the authenticated account ID. The repository uses CloudKit change
tags and reads by record ID or paginated zone changes, so these operations
require no new query indexes. Compare the current Development schema before
adding fields. The personal SwiftData schema initializer covers the personal
store. The direct CloudKit roster types are configured separately.

The write path requires an atomic-capable zone and uses
`.ifServerRecordUnchanged` for new and fetched records. Owner-only actions and
creator rename are app policy. The CloudKit read/write share permission grants
broader record access.

## First check — owner create

1. On Phone A, run the Debug app from Xcode with the verification flag disabled.
   Create a disposable group named `Roster-Verification-1121` in **Groups**.
   Use an unused suffix if that name already exists.
2. In Xcode, open **Product → Scheme → Edit Scheme → Run → Arguments**. Under
   **Arguments Passed On Launch**, add `-VerifySharedRoster`,
   `Roster-Verification-1121`, and `owner-create` as three enabled entries
   in that order. Use the exact disposable group name.
3. Run again on Phone A. Capture the console line beginning
   `[Roster verification] PASS owner-create (owner private database)`, or
   capture the full `FAIL` line. The success line means CloudKit accepted an
   atomic write and the owner read back the player and its reservation.
4. Stop here and report the result before starting member verification.

## Subsequent checks after confirmation

| Step | Run on | Expected evidence |
| --- | --- | --- |
| `member-create` | Phone B, after normal owner approval and share acceptance | The member creates a second player and reads back its reservation through the shared database. |
| `read` | A and B | Each sees both seeded player/reservation pairs. |
| `race <epoch>` | A and B | Set both devices to automatic time. Use the same future Unix timestamp in seconds, for example the output of `date -v+2M +%s` on the Mac. Append that timestamp as a fourth launch argument. Both consoles must show `READY race` before the deadline. One console reports a commit and the other reports a duplicate rejection. |
| `race-read` | A and B | Each sees the same one valid race player. The roster audit rejects an orphaned player or reservation. |
| `rollback` | B | A conditional create of an existing player ID rejects the whole batch and leaves no new reservation. A rename that loses to a competing reservation preserves both players and their claims. The winning player can then release its name by renaming, and a different player can claim the released name. |
| `retry` | B | The check throws a simulated network error after a real successful CloudKit write. Recovery and a retry with the same draft UUID return the original player and reservation. |

Use a fresh disposable group if both race clients did not reach `READY`, or
if a later check needs to be repeated from its original state. Stop if the
member’s zone lacks atomic capability, a batch partially commits, or the
accounts see different results. Capture both console logs and keep the
disposable group for inspection.
