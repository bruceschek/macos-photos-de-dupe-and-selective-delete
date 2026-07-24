# Photos App Launch Hang — Investigation Notes

**Machine:** MacBook Air, M5, latest macOS (build 25F84 / macOS 26.5.2 at time of investigation)
**Date of investigation:** 2026-07-23
**Reported by:** Bruce Schechter

## Symptom

Launching Photos.app produces no UI at all — no window, no dialog, nothing. Force Quit shows
"Photos (Not Responding)". This happens on every launch attempt, including:

- Normal double-click launch
- Holding `Option` (should show the "Choose Library" picker)
- Holding `Cmd+Option` (should trigger Photos' built-in "Repair Library" mode)

A related symptom noticed at the same time: Spotlight (`Cmd+Space`) fails to find installed
applications by name.

## Investigation timeline and findings

1. **Activity Monitor check.** Photos process sits at 0% CPU while hung — it is *blocked*, not
   doing work. Same for its helper processes (`cloudphotod`, `photolibraryd`, `photoanalysisd`) —
   none show meaningful CPU/disk activity. This ruled out "it's just slow / indexing a huge
   library" as an explanation.

2. **Library inspection.** `~/Pictures/Photos Library.photoslibrary` is ~395–398 GB, stored
   locally on the internal disk (not network/external — ruled out an unreachable-volume cause).
   Inside `database/`, found a stale `Photos.sqlite.lock` file dated from a prior unclean
   shutdown, alongside a `Photos.sqlite-wal` file that had been touched that morning — consistent
   with a previous launch attempt getting partway into opening the database before hanging.

3. **Attempted to delete the stale lock file via Finder.** The "Move to Trash" operation itself
   hung and never completed — twice, with progress dialogs stuck mid-bar indefinitely. This
   pointed past an app-level lock to something wedged at the filesystem/kernel level, since even
   Finder couldn't complete a trivial 465-byte file delete.

4. **Attempted a normal restart via the Apple menu.** Blocked — Finder reported it "can't quit
   because some operations are still in progress" (the wedged trash operations from step 3,
   which persisted even after their dialogs were dismissed).

5. **Force Quit Finder**, then performed a **hard power-cycle restart** (holding the power button).
   This is necessary to clear a wedged kernel-level file lock; a normal restart or app relaunch
   cannot. **Result: Photos still hung identically after the full reboot.** This ruled out a
   transient wedged lock/process state as the root cause, since a power cycle resets all of that.

6. **Checked macOS's own hang diagnostics** at `~/Library/Logs/DiagnosticReports/` and
   `/Library/Logs/DiagnosticReports/`. Found several `Photos_*.hang` reports, including one
   generated after the reboot. Opening one in Console.app and reading the main thread's stack
   trace found the actual blocking call:

   ```
   xpc_connection_send_message_with_reply_sync
   __NSXPCCONNECTION_IS_WAITING_FOR_A_SYNCHRONOUS_REPLY__
   -[NSXPCConnection _sendInvocation:orArguments:onSimpleMessageSignature:selector:withProxy:]
   +[PLAssetsdSystemLibraryURLReadOnlyClient systemPhotoLibraryURLWithError:]
   +[PLPhotoLibraryPathManagerCore systemLibraryURLIfResolvable]
   +[PLPhotoLibraryPathManagerCore systemLibraryURL]
   ```

   In plain terms: on launch, Photos makes a **synchronous XPC call** to `photolibraryd` (the
   system Photo Library service) asking "what is the System Photo Library path?" and blocks
   forever waiting for a reply that never comes. This happens very early in the launch sequence —
   before Photos ever checks which modifier keys are held, which is why even Option and
   Cmd+Option launches hung identically with no UI or dialog of any kind.

7. **Also found, in the same diagnostics folder**, a resource-usage report showing `apfsd` (the
   Apple File System daemon) pinned at ~76% CPU sustained over 180 seconds — genuinely overloaded,
   not idle. Also noted: Finder/Disk Utility reported ~830 GB "available," but the hang report's
   own accounting and Disk Utility both showed actual free space closer to ~121–130 GB out of a
   ~1.86 TB used / 2 TB total container — a large gap between "available" (includes reclaimable/
   purgeable space) and true free space. This was a plausible contributing factor but turned out
   not to be the root cause (see step 9).

8. **Ran Disk Utility First Aid** on the full "Macintosh HD" APFS volume group (done from
   macOS Recovery to avoid freezing the live system for an unknown duration). **Result: Photos
   still hung identically afterward.** This ruled out filesystem corruption as the root cause.

9. **Tested with a brand-new macOS user account** (no existing Photos library/designation at
   all). **Result: Photos launched and worked perfectly in the new account.** This was the
   key finding — it proved the problem is not the disk, not the hardware, not the Photos app
   binary itself, and not (necessarily) the library file's data integrity. It's specific to
   persistent state tied to the original user account.

10. **Final isolation test:** temporarily renamed `~/Pictures/Photos Library.photoslibrary` to a
    different name (so nothing exists at the path Photos would normally expect), then launched
    Photos again in the original account. **Result: hung identically anyway**, in the exact same
    XPC call, with no "library not found" error and no create-new-library prompt. This is the
    conclusive result: the block happens in `photolibraryd`'s attempt to resolve the System Photo
    Library designation *before it ever checks whether a library file exists at that location*.
    The library was renamed back afterward and is untouched.

## Conclusion

The root cause is **corrupted or wedged per-user state inside `photolibraryd`** (macOS's system
Photo Library service) — most likely a stuck/invalid security-scoped bookmark or internal
database record it uses to answer "what is the System Photo Library for this user," rather than
anything wrong with:

- The Photos library file itself (395 GB, intact, confirmed by the rename test)
- The disk/filesystem (confirmed healthy by First Aid)
- The Mac's hardware or a wedged kernel lock (confirmed by full reboot + Recovery-mode repair)
- The Photos.app binary (confirmed working under a fresh user account)

This is why nothing short of a full account-level reset of that daemon's state fixes it — and
why it's not something safely fixable via Finder/GUI actions alone (recommended taking it to
Apple Support with these findings, or resolving via Terminal-level reset of `photolibraryd`'s
per-user state if the exact file/mechanism can be identified).

## Why this may be relevant to a recent Claude Code project

Bruce suspects a recent Claude Code project that used the **Photos app / PhotoKit API** may be
connected to this. Worth investigating in that context:

- Did the project use AppleScript/JXA automation (`osascript`) or the Photos "scripting bridge"
  to interact with Photos — e.g., scripting Photos to switch libraries, create a new library,
  or set the "System Photo Library" designation?
- Did it use PhotoKit (`PHPhotoLibrary`) directly from a compiled app/script, particularly any
  call touching `PHPhotoLibrary.shared()`, library authorization, or multi-library APIs?
- Did the project write directly into
  `~/Pictures/Photos Library.photoslibrary/database/` (e.g., touching `Photos.sqlite`,
  `Photos.sqlite.lock`, or files under `database/search/`) rather than going through Apple's
  supported APIs? The stale `Photos.sqlite.lock` found in step 2 is consistent with *something*
  having opened the library and not shut down cleanly.
- Did it interact with `~/Library/Containers/com.apple.photolibraryd/` or any
  `com.apple.photolibraryd.plist` / bookmark data directly?
- Timing: when did the project last run relative to when Photos first started hanging? A
  correlation there would strengthen the suspicion.

If any of the above match, that script/tool is a strong candidate for having corrupted the
System Photo Library bookmark or left `photolibraryd` in a bad state — worth checking its code
for direct file writes into the library package or any library-switching/authorization calls,
rather than assuming it's unrelated.
