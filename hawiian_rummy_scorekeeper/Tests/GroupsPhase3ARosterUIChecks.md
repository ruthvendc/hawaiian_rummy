# Phase 3A Increment 3 — Group Players device checks

Run the Debug app from Xcode on two physical iPhones with different Apple
Accounts, using CloudKit Development and the roster verification launch
arguments disabled. Phone A owns the test group. Phone B joins as an approved
member. Use a new group named **Roster UI Test** or an unused variant. Keep
`Roster-Verification-1121` and existing groups and records intact.

Run one numbered check at a time and report the result before moving on.
These checks are pending until observed on the devices.

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
