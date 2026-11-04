# Cushion: a fast, read-only WinDirStat for Mac

## Context

You want to see what fills your Mac's disk so you can clear space. The disk map (treemap) is the most important part. The app never changes your files; you delete in Finder.

This Mac has 4.6 million files and 373 GB used on the Data volume. It has 64 GB free, 8 CPU cores and 24 GB of memory. These numbers set the speed targets.

**Tier 3:** this is a new project, so it gets full checks and a fresh review, placed at the end as you asked.

**Size:** my planning rules call any public launch "Large". I keep that milestone count, but I drop the extra planning stops, as you asked.

## What the research found

Sources: web pages through Exa. **Skipped:** the Reddit, X and YouTube pulls, because plan mode blocks the scratch files they need. Forum threads from MacRumors and MPU Talk stand in for them.

- **Free apps already do much of this.** DiskAtlas has a cushion map, a tree and file kinds. QDirStat has a tree and a map. GrandPerspective has a map only. All three can delete, and none promises read-only. Disk Inventory X is dead on current Macs.
- **What Cushion adds:** read-only by design, a Frees column, and speed as a measured target.
- **Licenses:** MacDirStat (AGPL) and QDirStat and GrandPerspective (GPL) restrict reuse. I write the code from the two published papers (squarified layout, cushion shading) and copy nothing.
- **The fastest scan call** is `getattrlistbulk`. It returns names and sizes in batches. A rough published rate is 137,000 files a second on an M1 Pro.
- **Known scan traps:**
  - `/Users` is a firmlink (a macOS link between volumes). One app showed 11.8 GB instead of 479 GB because it dropped these.
  - Hard links and APFS clones double-count unless they are handled.
  - An unreadable folder that counts as zero looks like an empty folder.
- **The Frees number:** `ATTR_CMNEXT_PRIVATESIZE` gives the bytes freed by deleting a file. I confirmed it is in this Mac's SDK header. Its speed cost in a bulk scan is unknown, so Milestone 1 measures it.
- **Open conflict:** DiskAtlas says a whole-disk scanner cannot be sandboxed, but store versions of DaisyDisk and GrandPerspective exist. Milestone 1 tests this.

## Your decisions

1. **Read-only:** Reveal in Finder, Copy Path and Quick Look only.
2. **Layout:** classic WinDirStat. Tree top left, file types top right, full-width map below.
3. **Size:** box area is real disk use, with hard links and clones counted once. A Frees column shows what deleting would free.
4. **Shipping:** public GitHub release and a yili.dev page.
5. **Extras:** Top 100 largest files only.
6. **After deleting in Finder:** a Rescan button, with no auto-update.
7. **Map look:** classic cushions.
8. **UI and speed:** clean and minimal, and very fast.
9. **Stops:** one design stop right after you approve this plan, then none until the end.

## How it works

```
disk -> Scanner -> flat in-memory tree -> Treemap layout -> Cushion shading -> map image
        (parallel,   (no per-file objects)   (squarified,     (per pixel,
         metadata                             stops at         all cores)
         only)                                1 pixel)
                         |
                         +-> Tree list <-> File types <-> Map  (one shared selection)
```

- **Stack:** Swift 6 and AppKit. `NSOutlineView` handles huge trees and draws only visible rows.
- **Project setup:** a SwiftPM package named `DiskCore` holds the scanner and map code, so it builds and tests in seconds. XcodeGen builds the app, copying the setup in /Users/yili/work/Projects/QuickEdit/project.yml, and the DMG script comes from /Users/yili/work/Projects/QuickEdit/scripts/make-dmg.sh.
- **Repo:** `~/work/Projects/Cushion`, built in a worktree. Private until Milestone 7.

### Speed targets

These are first guesses. Milestone 1 replaces them with measured numbers, and the final report gives the real ones.

| Action | Target |
| --- | --- |
| Whole disk scan, files already cached | under 30 s |
| Whole disk scan, after a reboot | under 90 s |
| Peak memory for 4.6 million files | under 1.5 GB |
| Full map redraw (resize, zoom) | under 100 ms |
| Selection, hover, tree expand | under 16 ms |
| App launch to first window | under 300 ms |

The tree and the map fill in live during a scan, about 4 times a second.

### How read-only is enforced

- The app reads metadata only and never opens file contents. Quick Look is drawn by macOS.
- If Milestone 1 shows it works, the macOS sandbox runs in read-only mode, so the OS itself refuses writes. The app's own settings are the only exception.
- A check script fails the build if the code uses a call that deletes, moves or writes files.
- A test compares a test folder's names, sizes and dates before and after a scan.

### Clean and minimal UI

- The start screen lists your disks, plus Choose Folder.
- The scan window has no toolbar row of buttons. It holds the three panes and one status line. Actions sit in the menus and the right-click menu.
- The status line shows used, free and "not counted". "Not counted" is one number: the gap between scanned files and disk use, with the count of unreadable folders. It is not the full breakdown you left out.
- Light and dark mode follow the system.

## Milestones

Times are budgets. M2 and M3 run side by side once M1 fixes the tree's interface. M4 starts as soon as M3's window exists.

**M0. Design stop (30 min).** I render 4 or 5 looks of the same real screen. Astra and a fresh reviewer critique them. I publish them side by side with my pick, and you choose.
*Done-test:* you picked one, and its values are in the token file (one file of named colors and sizes).

**M1. Scanner (1 h).** The parallel scan, flat tree, hard links, clones, firmlinks, mount edges, unreadable folders, and a command-line bench.
*Done-test:* a whole-disk scan prints its total, file count, time and memory, and the total is within 5% of `df` once the unreadable count is included. Records the Frees speed cost and the sandbox result. If Frees slows the scan by more than 20%, it is computed only for what you select.

**M2. Map engine (1 h).** Squarified layout, cushion shading on all cores, click lookup, and offscreen PNG output.
*Done-test:* a PNG of the real disk scan, which I look at, and a measured redraw time.

**M3. The window (1.5 h).** The three panes with shared selection in all directions, file type colors, and the Frees and % columns.
*Done-test:* clicking a box selects its row in the tree, and clicking a file type highlights its boxes. Screenshots checked.

**M4. Finding and acting (1 h).** Zoom in and out, Reveal in Finder, Copy Path, Quick Look, Top 100, Rescan, the live scan view, the Full Disk Access prompt, and the start screen.
*Done-test:* a whole-disk flow runs from start screen to Reveal in Finder, and Rescan picks up a deleted test file in a test folder.

**M5. Speed and polish (1 h).** Measure every target above, fix the slowest parts, and do the dark mode and small visual passes.
*Done-test:* each target is met, or its real number and reason are reported.

**M6. Full testing and review (2 h).** Most testing happens here: unit, integration and end-to-end. Astra and a fresh Opus reviewer run in parallel with a 900 s deadline, and I fix what they find. A diagram of the design goes in `docs/`.
*Done-test:* the full suite passes with no retries or skips, and every review finding is fixed or rejected with a reason.

**M7. Release (1 h).** Icon, README, a notarized DMG, public repo, GitHub release, and the yili.dev page.
*Done-test:* the public DMG's SHA-256 matches, it opens on this Mac, and the page's live checks pass.

**Not in this version:** delete or Trash, hidden space breakdown, space hog labels, saved scans and compare, sunburst, duplicate finder, auto-refresh, scan as administrator, flat map mode, auto-update, App Store, translations.

## Testing, from your milestone-tuneup skill

- **Per change:** `swift test` on the changed module plus a whole build. Target 2 minutes. Only a few early tests, for size counting, because a wrong number there breaks everything later.
- **M1 to M5 end:** a whole build, the bench and my screenshot check. No full suite.
- **M6:** the full suite, under 10 minutes. It logs as `milestone`.
- **Release:** before M7, on macOS 27. That is the only OS I can test here, so the build target of macOS 15 stays untested on older versions and the README says so.
- **Logs:** `docs/test-times.csv`, `docs/review-log.md`, and the review rules written before the review. I read the tune-up signals at each milestone end.
- **Reduced from my usual rules, at your request:** no per-milestone full suite or review, a short `docs/design-spec.md` as the only design doc, and no per-milestone hands-on script.

## Who builds

Native Opus `builder` subagents do the builds, because the runner's sandbox cannot run Swift tools (recorded on 2026-10-14). One builder per milestone. Side-by-side builds use clones from `prep-clone.sh`. I commit, push and release. One progress page gets updated at each milestone, so the link stays the same.

## Verification at the end

1. I run the full suite and read the counts myself.
2. I run a real whole-disk scan and compare the total to `df`.
3. I look at screenshots of each screen, light and dark.
4. End-to-end tests drive the real window from inside the test process, because XCUITest needs Automation Mode, which is off and needs your password. **Not covered as a result:** real mouse and keyboard events. Your hands-on script covers those.
5. You follow a short hands-on script, which includes granting Full Disk Access.

## Approvals this plan asks for

Approving this plan approves these outward steps at M7:

1. Create `wizdes/Cushion` as a private repo, then make it public.
2. Publish a GitHub release with the DMG.
3. Add `yili.dev/projects/cushion` through the existing homepage deploy.

**Only you can do:**

1. Pick a design at M0.
2. Possibly click Always Allow on a Keychain dialog the first time the app is signed.
3. Grant Full Disk Access at the end.

## Choices to check

- **Name:** Cushion, after the map's shading. "Acreage" is already a Mac disk app. My search found no Mac app named Cushion, but it was a quick check. Tell me if you want another name; changing it is cheap before M7.
- **License:** MIT.
- **Minimum macOS:** 15.

## Changes after approval (2026-11-04, user instructions)

- **Name:** The app is now MacDiskStats.

- **Main thread only coordinates.** Sol builds everything through the runner. Astra does all reviews and design critique. No native Opus builders or reviewers, to save Claude tokens.
- **No SwiftPM or Xcode.** Neither runs in the runner's sandbox; plain `swiftc` does (tested). `scripts/build.sh` calls `swiftc`, assembles the `.app`, and signs it. Tests are a small `checks` executable, not XCTest. Root runs only what the sandbox cannot: whole-disk measures, signing, release.
