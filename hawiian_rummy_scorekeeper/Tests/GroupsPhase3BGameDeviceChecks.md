# Phase 3B Increment 1 — Shared game storage

## Recorded Increment 1 results

The owner reported all seven checks passed in CloudKit Development on two
physical iPhones signed in to separate Apple Accounts. The original
`Game-Verification-3B1` group and both games were retained.

| Check | Result |
| --- | --- |
| Owner creation | PASS — The owner created the game, first round and receipt through the private database. |
| Member creation | PASS — The approved member created the same record types through the shared database. |
| Cross-account visibility | PASS — Both phones read both games. |
| Scores and permissions | PASS — Each scorekeeper wrote their own scores. App-level checks rejected changes by the other account. |
| Atomic rollback | PASS — The stale batch left neither hand 2 nor a receipt. The member game reached completed revision 3. |
| Ambiguous save and retry | PASS — The original Xcode console result confirmed recovery of revision 4's receipt and preservation of revision 5 and its scores. |
| Membership revocation | PASS — Phone B lost access. Phone A retained both games and their scores. |

Xcode's launch reports showed two `retry` launches on Phone B. The later
revision-3 preflight failure was consistent with an already-advanced game.
The read-only `retry-status` found completed revision 5 with one hand scored
21 and 21. Receipts 05/06/07/08 were
`verified/missing/verified/verified`. The owner recovered the original
`PASS retry` from Xcode's Report Navigator, which established the recovery
result in addition to the persisted readback.

Final owner readback showed the owner game at revision 2, in progress,
with one round and first-hand scores of 3 and 3. The member game was
complete at revision 5, with one round and first-hand scores of 21 and 21.
The shared Run scheme no longer supplies verification arguments.

## Approved design

- Copying a personal player into a group is a prerequisite for the game
  picker. The copy has a separate group UUID and uses the roster’s atomic
  name reservation. The personal record stays independent. The copy UI
  comes in a later increment.
- The game creator starts as the assigned scorekeeper. Only the current
  scorekeeper can enter or correct scores and complete the game. The group
  owner can explicitly reassign an unfinished game after the scorekeeper
  leaves or loses access. The successor must be an approved member. A future
  reassignment transaction must condition on the game version and retain
  audit details for the owner, previous scorekeeper, and successor. Rejoining
  does not automatically undo an assignment. Increment 1 stores creator
  and scorekeeper keys separately to support that transaction.
- The game captures ordered group-player UUIDs and display names at
  creation. A roster rename or retirement leaves that history intact.
  A retired player can finish an existing game. Group members and game
  participants are independent, so a player needs neither an Apple Account
  nor the app to participate. Personal games use their existing private store.
- Membership and scorekeeper checks run in the app. CloudKit read/write
  share participants have broader record access. Shared game writes in this
  increment require live membership. Offline creation and scoring remain
  later work.

## Development schema

Use the app’s **Development** container. These types live under the existing
private group root and its hierarchical share. Owners use the private
database and members use the shared database.

| Record type | Record name and parent | Custom fields |
| --- | --- | --- |
| `GroupGameV1` | `game-<game UUID>`, parent is the group root | `participants` (Bytes, ordered UUID and display-name snapshots), `creatorKey` and `scorekeeperKey` (String), `revision` and `roundCount` (Int64), `completedAt` (optional Timestamp) |
| `GroupGameRoundV1` | `game-round-<game UUID>-<round number>`, parent is the game header | `hands` (Bytes, hand numbers and scores by player UUID) |
| `GroupGameOperationV1` | `game-op-<game UUID>-<operation UUID>`, parent is the game header | `actorKey` and `fingerprint` (String), `revision` (Int64) |

The verified zone and parent supply the group identity. Record IDs supply
the game and round identities. CloudKit supplies creation and modification
dates and change tags. Use the Development schema in CloudKit Console if
the types or fields need to be predeclared. Development can also discover
fields on first write. In that case, `completedAt` first appears when the
rollback check completes the member’s game. Record-ID reads require no new
query indexes. The personal SwiftData schema initializer does not create
these direct CloudKit types.

Each operation atomically saves its records and a receipt, using
`.ifServerRecordUnchanged` in an atomic-capable zone. Each mutation changes
the game header revision. The receipt binds the authenticated actor, command
payload and resulting revision to the operation UUID. A retry returns only
the original receipt. A fresh read supplies the current game state. A
rejected stale write must leave neither partial changes nor a receipt.

## Capture the device output

Use two physical iPhones with separate Apple Accounts and a Debug install
from Xcode. Use a new disposable group such as `Game-Verification-3B1`. Keep
the Phase 3A test groups and their records intact. The shared Xcode scheme
does not launch either verifier by default.

Use Xcode’s device names or IDs from `xcrun devicectl list devices`. In one
Terminal tab per phone, run the following with the appropriate device, step,
and log filename. Keep the log for each step. The verifier runs once per
process and prints a `[Game verification] PASS` or full `FAIL` line.

```sh
xcrun devicectl device process launch --device "PHONE_A_NAME_OR_ID" \
  --console --terminate-existing com.davidruthven.hawiian-rummy-scorekeeper \
  -- -VerifySharedGame Game-Verification-3B1 owner-create \
  2>&1 | tee /tmp/rummy-game-owner-create-A.log
```

The rollback check uses a deterministic interleaving of two writes in one
session. It does not need synchronized clocks or a run-destination switch.

## Numbered checklist

1. **Owner creation.** On Phone A, create the new disposable group with the
   ordinary Debug app. In Group Players, add `Storage Player One` and
   `Storage Player Two` as active players. Run `owner-create` on A. Expect
   `PASS owner-create (owner private database)` for the header, first
   round and receipt.
2. **Member creation.** Invite Phone B, approve it, and ensure it has
   accepted the share. Run `member-create` on B. Expect `PASS member-create
   (member shared database)` for the same three record types.
3. **Cross-account visibility.** Run `read` on both phones. Both should
   report two distinct games at revision 1, each with the same ordered
   participants, one round, and no scores.
4. **Score write and permissions.** Run `write` once on each phone. Each
   should save its own first hand at revision 2 and reject a completion
   attempt on the other scorekeeper’s game. Run `read` on both and verify
   the two revision 2 games each have one hand with scores of 3 and 3.
5. **Stale batch and atomic rollback.** Run `rollback` on B. It prepares
   a batch that would add hand 2, commits completion separately, then
   submits the stale batch. Expect the completed game at revision 3,
   with hand 1 intact, hand 2 absent, and no receipt for the stale batch.
   On A, run `read` and verify the completed member game.
6. **Ambiguous save and delayed retry.** Run `retry-status` on B first. This
   command only reads the member game and receipts. Continue with `retry`
   on B only if the console reports `READY for retry`, with revision 3
   complete, one hand scored 3 and 3, and receipts 05/06/07/08 listed as
   `verified/missing/missing/missing`. If the status is `BLOCKED`, capture
   the full line and leave the game and its receipts in place. The `retry` check commits a
   correction at revision 4, commits a newer correction at revision 5,
   then simulates loss of the first save response. Expect recovery of
   revision 4’s receipt and preservation of revision 5. Run `read` on
   both phones and verify the completed member game still has revision 5
   and scores of 21 and 21.
7. **Revoked access.** In this test group only, remove B’s access on A.
   Once the change is confirmed, run `revoked` on B. Expect the group
   to be absent from B’s discovery. Run `read` on A and verify both games
   and the last recorded scores are still available.

The live checks remain pending until reported from the phones. Stop on a
missing atomic capability, unexpected write, or partial record set. Save the
logs and leave the test data in place. Use a fresh uniquely named disposable
group for a repeat that needs the original revisions.
