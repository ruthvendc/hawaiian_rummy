# Groups Phase 2 closeout checks

Use the current **Debug** build on both iPhones with their existing Apple Accounts. Run from Xcode over the installed app so each phone keeps its personal data. Use CloudKit Development. Phone A owns the group and Phone B is the recipient.

Use disposable groups for each approval test. Paste the owner’s iCloud link into **Groups → Join Group** on Phone B when testing automatic joining. The iCloud link also retains its native Messages behavior.

| Action | Expected result |
| --- | --- |
| **Approve while B is open** | On B, paste the link, tap **Request to Join**, and leave the screen open. On A, open the group, pull to refresh, and tap the requester → **Approve**. B shows **Waiting for approval** first, then shows the group in Groups automatically after the next check. A should see B as **Member** after refreshing. |
| **Approve while B is closed** | Repeat with a second disposable group. After B sees the pending confirmation, quit B’s app before A approves. Open B online, then visit Groups. The new group should appear without reopening the link or tapping Join. |
| **Interruption and deduplication** | Repeat with a third group. After B submits the request, paste the same link again and verify there is only one pending invitation. Disconnect B, approve on A, and reconnect B. The request should stay visible while offline, then the group should appear only once. |
| **Native Messages fallback** | For a separate invite, request access through Apple’s **Ask for Access** screen without pasting the link in the app. After A approves, reopen the original Messages link on B. Complete any Apple verification prompt. The app should finish joining without an in-app Join button. |
| **Layout** | Open **Groups** on both phones. The **Your Groups** card should start at the same top inset as the Players intro card. At a larger Dynamic Type size, check that the card and both actions stay reachable by scrolling. |
| **Discovery and member sharing** | Relaunch both apps. A should rediscover the owned group and B the joined group without reopening the link. On B, **Share Invitation Link** should yield a link to the same private share. If duplicate names have not been checked, make a second disposable group with the same name on A and confirm the two entries open independently. |
| **Temporary connectivity loss** | With Groups loaded on one phone, temporarily disconnect and pull to refresh. Existing groups should remain visible as saved data. Reconnect and refresh before testing membership changes. |
| **Leave and revoke** | On B, leave a disposable joined group and refresh both phones. A retains the group and B loses access. Rejoin with owner approval, then use **Remove Access** on A. Refresh B and verify the group disappears while A can still open it. B should not see owner-only controls. |
| **Request controls** | On disposable groups, verify **Decline** removes the request, **Block** prevents that account from requesting again, and turning off **Allow Access Requests** prevents new requests. None grants membership. Confirm the outcome on A as well as B. |
| **Delete and personal regression** | While B is still a member of a disposable group, delete it from A and confirm both phones lose the group after refresh. Open existing **Players**, **Games**, and **Records** on both phones and verify their personal data is intact and separate. Check that **Home → How to Play** opens Rules and Back returns to Home. |

If a check fails, record the phone, step, and displayed error. For a crash, capture the new device crash report in Xcode’s **Devices and Simulators** window.

## Member display names

1. Update the Debug app in place on both phones and open the same existing group. On A, open **Members → Edit My Display Name**, keep the saved draft if it is prefilled, and save **David**. On B, open or pull down to refresh Group Details. Expect **David** on the left and **Owner** on the right.
2. On B, use **Members → Edit My Display Name** to save **Wendy** if it is not already saved. Open or pull down to refresh Group Details on A and verify **Wendy** on the left and **Member** on the right. Each phone should show **(You)** next to its own name and a single **Edit My Display Name** action beneath the member list.
3. Fully close and relaunch both apps, reopen the group, and verify both saved names. Check the rows in light and dark mode. Clear Wendy’s custom name and refresh A to verify the visible CloudKit name returns, or **Member** appears if no name is available. If checking a second group, its display names should stay as they were.
4. Open the editor on B while online, disconnect, enter a new name, and tap **Save**. Expect an error and a locally saved draft. Close and reopen the editor after reconnecting, verify the draft is present, and tap **Save**. A should see the updated name after refresh. Verify the unsent draft never appeared on A.
5. Try a long name and a larger Dynamic Type size. Verify the name wraps, the role stays visible, and VoiceOver reads the name and role together. An unnamed join request should show **Join request** in place of a contact handle.

When creating a new group, **Your display name** is optional. A provided name should appear immediately as the owner’s chosen name. For a new member, the same **Edit My Display Name** action becomes available as soon as they can open the group.

Display names are optional records within the existing private group share. New name records are keyed by the signed-in account within that group. The app accepts existing records linked to the same member and accounts for the current-user alias CloudKit provides in the owner’s private database. CloudKit still grants broad record writes to participants with read/write access, so the self-edit restriction describes the normal app. The fix uses the existing GroupMemberDisplayNameV1 record type. If a name remains missing after refresh, capture the **GroupDisplayNames** messages in Console from both phones. These report record counts and error codes without names or account IDs.

## Release verification

On another iPhone with a **fresh app installation and no restored app cache**, sign into an Apple Account that already owns one group and has accepted membership in another. Open Groups online. Verify both groups appear with the correct roles without reopening either invitation, and verify that the owner can manage the owned group and that the member can share the joined group's invitation. Repeat against the release environment with the release build during Phase 5. Use a spare device or test account; signing a family member out of a daily-use iPhone is unnecessary.
