# Scanner contract

`Scanner.scan(root:options:progress:)` returns an immutable `FileTree`. It scans metadata with `getattrlistbulk` and never opens a regular file. The call is async and cancellation stops queued work. Progress reports files, counted bytes, and running totals for folders in the first two levels about four times each second.

Node IDs are `Int32` indexes into parallel arrays. `parent`, `firstChild`, and `childCount` describe the tree. A folder's children occupy a span in `children`, sorted by counted size. `nameOffset` and `nameLength` point into `names`. `path(of:)` builds a path when needed. `topFiles(limit:)` returns the largest file IDs. `extensions` holds lowercased suffixes, sorted by counted bytes. The tree can be read across threads after `scan` returns.

Box size uses allocated bytes. A hard link's first name counts in full; later names count zero. A clone's first name counts in full; later names with the same clone ID count only their private bytes. `privateSize` is the sum of private bytes below a folder, so its Frees value is **at least** that amount. Deleting a whole clone group in one folder can free more. A hard-linked name with another link alive frees zero.

The scanner stops at mount points, tracks opened directory identities, and permits the System-to-Data firmlinks while scanning `/`. It lists unreadable folders. `volumeUsedBytes` comes from each volume's `ATTR_VOL_SPACEUSED`; a root scan adds the System and Data volumes, matching `df`. The gap from counted bytes includes unreadable content, file system data, and other space the scan cannot assign. When bulk attributes are unavailable, the scanner uses `readdir` and `lstat` and lists that limit. That path has no private or clone data. `--no-private` skips clone attributes too, so clone bytes can count twice in that speed test.

Commands: `scripts/check.sh` builds and runs 15 small checks and the source read-only check. `scripts/build.sh release` builds the bench and map tool. `build/macdiskstats-bench / --json` measures a scan. `scripts/measure.sh` compares private and no-private scans and prints `df`. `scripts/sandbox-probe.sh` tests a signed read-only sandbox app against the plain bench.

# Map interface

`Treemap.layout(tree:rootNode:widthPx:heightPx:params:)` returns a `TreemapLayout` with parallel node, rectangle, color and four surface-coefficient arrays. `rect(of:)` finds a box for a selection frame, and `hitTest(x:y:)` returns the deepest visible node through eight-pixel tiles and a pixel fallback at edges. Folders stay in the box arrays, while boxes under two pixels become solid leaves with their largest file's type. `Treemap.shade(_:into:params:highlightExtension:)` fills RGBA bytes on all cores; a highlight changes shading without layout. `TreemapParams` holds ridge, lighting and palette defaults. `build/macdiskstats-map <path> <out.png>` scans and saves a PNG.

## Scan speed measurements (2026-11-04, warm cache, other builds running)

| Method | Scope | Time | Notes |
| --- | --- | --- | --- |
| `getattrlistbulk`, all fields, 16 workers | `/` | 38.2 s | 3.62 million files, 343.8 GB; the current scanner |
| Same, 32 workers, 1 MB buffer | `/` | 39.7 s | more kernel time, no gain |
| Same, 8 workers | `/` | 47.7 s | |
| `getattrlistbulk`, ordinary fields, 8 workers | `/` | 30.3 s | no private or clone fields |
| `getattrlistbulk`, count only, 32 workers | Data volume | 20.8 s | kernel time 95 s, user time 4 s |
| `searchfs` | `/` and Data | 2.7 s and 38.4 s | one thread; sums 414 GB on Data, so it sees clones as full size |

The limit is kernel time, not our code. Skipping clone and private rules changes the total by 4.9%. `Tools/scan-lab` reruns these. Reading the raw APFS device needs root and is out of scope.

## Extended-flag shortcut test (2026-11-04)

The SDK calls the bit `EF_MAY_SHARE_BLOCKS` (`sys/stat.h`) and the bulk field `ATTR_CMNEXT_EXT_FLAGS` (`sys/attr.h`). The field was cheap: `scan-lab bulk / ordinary 16 131072 1` took 23.803 s; `extflags` took 24.560 s. On `/Applications`, ordinary took 1.052 s and `extflags` took 0.748 s, with warm-cache order affecting that small sample. The root walk found 319,701 flagged files and zero flagged directories. The lab walk visits some paths the scanner stops at, so these counts are not scanner node counts.

The flag alone is not a valid private-size shortcut. On `/Applications`, 20,149 files with the flag clear had private bytes different from allocated bytes, with 2,762,952,704 bytes of absolute difference. All had `UF_COMPRESSED`. In the home-folder walk, 981 files differed by 6,017,024 bytes; two uncompressed `Icon\r` resource-fork files accounted for 212,992 bytes. On `/`, 323,047 clear-flag files differed by 18,992,893,952 bytes; 150,024 lacked `UF_COMPRESSED` and differed by 6,446,223,360 bytes. Examples include `/usr/standalone/bootcaches.plist` (24,576 allocated, zero private) and `/usr/standalone/i386/Firmware.scap` (15,732,736 allocated, zero private). The root walk had 934 directory errors. These are sampled, changing-volume observations, not a proof that compressed and system files are the only exceptions.

The `cp -c` original and clone both had the share bit set and zero private bytes. The clone with its sibling deleted kept the bit set but had private bytes equal to allocated bytes. Hard links and a sparse file had the bit clear and matching private and allocated bytes. A real `decmpfs` file in `/Applications/RedirectWeb.app` had the bit clear, 12,288 allocated bytes, and zero private bytes. A `ditto --hfsCompression` trial in the build fixtures did not produce a compressed file.

No scanner shortcut was built. Running the existing passes together might reduce the measured 64.271 s root scan toward a theoretical 39.917 s floor if their work overlapped completely. Both passes spend most of their time in the kernel, so contention could leave the time near 64 s; this range is an estimate, not a concurrent-pass benchmark. The current second pass also needs the first pass's tree and names, so per-directory handoff would be needed to overlap them.
