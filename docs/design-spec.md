# Scanner contract

`Scanner.scan(root:options:progress:)` returns an immutable `FileTree`. It scans metadata with `getattrlistbulk` and never opens a regular file. The call is async and cancellation stops queued work. Progress reports files, counted bytes, and running totals for folders in the first two levels about four times each second.

Node IDs are `Int32` indexes into parallel arrays. `parent`, `firstChild`, and `childCount` describe the tree. A folder's children occupy a span in `children`, sorted by counted size. `nameOffset` and `nameLength` point into `names`. `path(of:)` builds a path when needed. `topFiles(limit:)` returns the largest file IDs. `extensions` holds lowercased suffixes, sorted by counted bytes. The tree can be read across threads after `scan` returns.

Box size uses allocated bytes. A hard link's first name counts in full; later names count zero. A clone's first name counts in full; later names with the same clone ID count only their private bytes. `privateSize` is the sum of private bytes below a folder, so its Frees value is **at least** that amount. Deleting a whole clone group in one folder can free more. A hard-linked name with another link alive frees zero.

The scanner stops at mount points, tracks opened directory identities, and permits the System-to-Data firmlinks while scanning `/`. It lists unreadable folders. `volumeUsedBytes` comes from each volume's `ATTR_VOL_SPACEUSED`; a root scan adds the System and Data volumes, matching `df`. The gap from counted bytes includes unreadable content, file system data, and other space the scan cannot assign. When bulk attributes are unavailable, the scanner uses `readdir` and `lstat` and lists that limit. That path has no private or clone data. `--no-private` skips clone attributes too, so clone bytes can count twice in that speed test.

Commands: `scripts/check.sh` builds and runs 15 small checks and the source read-only check. `scripts/build.sh release` builds the bench and map tool. `build/macdiskstats-bench / --json` measures a scan. `scripts/measure.sh` compares private and no-private scans and prints `df`. `scripts/sandbox-probe.sh` tests a signed read-only sandbox app against the plain bench.

# Map interface

`Treemap.layout(tree:rootNode:widthPx:heightPx:params:)` returns a `TreemapLayout` with parallel node, rectangle, color and four surface-coefficient arrays. `rect(of:)` finds a box for a selection frame, and `hitTest(x:y:)` returns the deepest visible node through eight-pixel tiles and a pixel fallback at edges. Folders stay in the box arrays, while boxes under two pixels become solid leaves with their largest file's type. `Treemap.shade(_:into:params:highlightExtension:)` fills RGBA bytes on all cores; a highlight changes shading without layout. `TreemapParams` holds ridge, lighting and palette defaults. `build/macdiskstats-map <path> <out.png>` scans and saves a PNG.
