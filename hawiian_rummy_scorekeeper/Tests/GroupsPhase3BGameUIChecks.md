# Phase 3B Increment 2 — Group game UI checks

Use the Debug app on two physical iPhones with separate Apple Accounts and
CloudKit Development. Leave the verification launch arguments disabled.
Use a new disposable group such as **Group Game UI Test**. Phone A owns
it, and Phone B joins by requesting access and receiving approval. Keep
the Increment 1 verification groups and games intact.

## Recorded Increment 2 results

The owner reported **8 of 8 checks passed** on two physical iPhones signed
in to separate Apple Accounts using CloudKit sharing.

| Check | Result |
| --- | --- |
| Personal game regression | PASS — Personal Game remained the default and the existing personal workflow worked. |
| Owner creates a group game | PASS — The owner created and opened a shared game. |
| Member creates a group game | PASS — An approved member created a shared game. |
| Cross-device history | PASS — Both phones saw both creators' games. |
| Group selection and scoring order | PASS — Selection order persisted and retired group players were excluded. |
| Copy and duplicate protection | PASS — The group copy synchronized, duplicate protection worked, and the personal profile was preserved. |
| Read-only history and stored scores | PASS — Existing rounds and scores were visible and historical names survived roster renames. |
| Offline and access loss | PASS — Previously loaded history remained visible offline. On reconnection the revoked member lost access and the owner retained history. |

## Device procedures

1. **Personal game regression.** On A open **Home → Start a New Game**.
   **Personal Game** should be selected by default. Choose two personal
   players in a known order, name the game, and start it. Verify the
   existing personal scoring screen opens and the game appears under the
   existing **Games** tab. It should be absent from the test group.
2. **Owner creates a group game.** Add at least two active players to the
   test group. On A open **New Game → Group Game**, choose the test group,
   select at least two players, and tap **Start Game**. The read-only
   detail should open with the group name, date, participants, scorekeeper,
   **In progress**, and an empty first round.
3. **Member creates a group game.** On B, before approval, verify the test
   group is absent from New Game. After approval and acceptance, choose it
   and create a game. B should see **You** as scorekeeper on the new game's
   detail. A remains the group owner.
4. **Cross-device history.** On both phones open **Groups → Group Game UI
   Test → Games** and pull to refresh. Both games should appear, regardless
   of creator. Compare dates, participant lists, and game status. A peer's
   name appears when CloudKit exposes a matching participant identity.
   Confirm these games are separate from the personal Games tab.
5. **Group selection and scoring order.** In New Game, choose the test
   group, select two players in reverse alphabetical order, and check the
   numbered badges. Deselect and reselect the first player, then confirm
   the order changes. Start a game and verify the saved order in the
   history detail. Retired group players should be absent from the picker.
6. **Copy and duplicate protection.** On B open **Groups → Group Game UI
   Test → Players → Copy a Personal Player**. Choose an existing personal
   name unused in the group and tap **Copy**. Refresh on A and verify the
   new group player appears. Attempt to copy it again, and try adding a
   case- or whitespace-variant name. Expect conflict feedback. Verify the
   personal profile and its history are intact. The group copy should
   appear in the group game picker.
7. **Read-only history and stored scores.** On A use **Groups →
   Roster or Game verification group → Games** for a previously recorded
   game. In `Game-Verification-3B1`, the owner game’s first hand should
   show 3 and 3, and the completed member game’s should show 21 and 21.
   Expand the hands and compare the stored participant order. On both
   phones verify group game detail offers no scoring or edit controls.
   In the new test group, rename a player and verify previously created
   games still display the original name.
8. **Offline and access loss.** On B open already loaded group history,
   then enable Airplane Mode and turn off Wi-Fi. Expect an offline message
   and read-only access to the data already open. Opening a fresh history
   screen offline requires a connection. Group Game creation should be
   unavailable, and Personal Game should still work. On A revoke B in
   the new test group. Reconnect B and refresh. The group and its history
   should become unavailable on B, while A still sees both games.
