# Phase 3A Increment 3 — Group Players device checks

Run the Debug app from Xcode on two physical iPhones with different Apple
Accounts, using CloudKit Development and the roster verification launch
arguments disabled. Phone A owns the test group. Phone B joins as an approved
member. Use a new group named **Roster UI Test** or an unused variant. Keep
`Roster-Verification-1121` and existing groups and records intact.

## Recorded Increment 3 results

The owner reported all eight categories passed on two physical iPhones signed in
to different Apple Accounts in CloudKit Development. The device runs used
`Roster UI Test` and `Roster UI Test 2`. Both test groups are retained.

| Check | Result |
| --- | --- |
| Group roster visibility | PASS — The owner and approved member saw the same roster. |
| Player creation and synchronization | PASS — Both phones saw players added by the other account. |
| Duplicate-name protection | PASS — Case and surrounding whitespace were ignored within a group. Identical names worked across groups and personal rosters. |
| Rename permissions | PASS — The owner could rename any player. A member could rename only their own additions. |
| Retirement and restoration | PASS — Owner actions moved players between active and retired lists. Retired names stayed reserved and member retirement was unavailable. |
| Offline behavior | PASS — Saved players remained visible, editing controls disappeared, and editing returned after reconnection. |
| Revocation and reapproval | PASS — Revocation removed access. Reapproval of the same account restored access and original creator rename rights. |
| Personal data regression | PASS — Existing personal Players, Games, and Records remained intact. |

[Increment 2's six live CloudKit checks](GroupsPhase3ARosterDeviceChecks.md#recorded-increment-2-results)
also passed, including concurrent duplicate prevention, atomic rollback and
ambiguous-save recovery.

## Development status and remaining scope

The scoped Phase 3A roster implementation and device acceptance are complete
in Debug and CloudKit Development. Phase 3B is pending plan approval.

- The original Groups V1 plan also calls for an explicit copy from personal
  Players into a group. Direct group-player entry is available. Personal-player
  copy remains open in the broader plan.
- Roster viewing uses an account-scoped saved snapshot offline. A cold launch
  requires identifying the current iCloud account to display that snapshot.
  Edits require live access, and a disconnected device learns of revocation
  when it next verifies access.
- Owner and creator editing rules are app-level controls. CloudKit read/write
  share participants have broader record permissions.
- Group game selection and historical references are deferred to Phase 3B.
  Offline game creation and scoring, durable sync, group Records, and
  independent Games and Records filters remain Phase 4 work. Release and
  Production verification remain Phase 5 work.
- The shared Debug Run scheme has no roster verification launch arguments.
  Verification is opt-in. The `retry` check can issue a write to its named
  Development group when explicitly requested.

## Device procedures

Run one numbered check at a time for a targeted regression check.

1. **Owner and member visibility.** On A, create **Roster UI Test** and share
   the invitation. On B, request access. Verify B cannot open the group before
   A approves. After approval and acceptance, open **Groups → Roster UI Test →
   Players** on both phones. Expect the group name, **Add Player**, and **No
   active players**. Apple Account members are listed under **Members** on the
   group details screen.
2. **Add and sync.** On A add `Nani`. Pull down to refresh on B and verify
   `Nani` appears. On B add `Kai`. Pull down on A and verify both names.
   Reopen the screen and check the same roster appears. The personal
   **Players** tab should show its existing personal roster.
3. **Duplicate names.** With `Nani` loaded, enter `  nAnI  ` in **Add Player**.
   Expect an inline name conflict. On A, try renaming `Kai` to the same
   variant and verify Save is unavailable. For a group isolation check, add
   `Nani` to a second disposable group and verify each group has its own row.
   A name already used in personal Players may also be added to the test
   group if the name is available there.
4. **Rename permissions.** On B, verify `Nani` has no action menu. Rename
   `Kai` to `KAI` to check a case-only edit, then to `Kai Member`. Refresh
   A and verify the updated name. On A, rename it to `Kai Renamed`. Refresh
   B and confirm B can still rename the player it originally added. B should
   see no **Retire** or **Restore** actions.
5. **Retire and restore.** On A, retire `Kai Renamed` and confirm the alert.
   The player should move from **Active Players** to **Retired Players**.
   Refresh B, expand **Retired Players**, and check the same state. Try
   entering ` kai renamed ` as a new player and expect a retired-name
   conflict. On A choose **Restore**, then refresh B and verify the player
   returns to **Active Players** as a single row.
6. **Offline and reconnect.** On B, load the roster and open the Rename
   editor on `Kai Renamed`. Enter an unused name, then enable Airplane Mode
   and switch Wi-Fi off. Save should become unavailable and the typed name
   should remain in the editor. Cancel and verify the saved roster can be
   reopened read-only while offline. On A, rename `Nani` to `Nani Updated`.
   Reconnect B and verify the roster refreshes and editing returns. Pull
   down to retry if iCloud is still connecting.
7. **Revocation and reapproval.** While B is offline again with its saved
   roster available, remove B’s access on A. Reconnect B and refresh. The
   group and its saved roster should become unavailable on B. A should still
   see both player records. Have B request access again with the same Apple
   Account, approve B, and reopen Players. Confirm B can rename
   `Kai Renamed` and still cannot rename `Nani Updated`.
8. **Personal regression.** On both phones, check the existing personal
   Players, Games, and Records tabs. Verify known personal players, a
   saved game and its scores, and familiar Records totals are intact.
