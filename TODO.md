# Tech-debt plan

From the 2026-10-25 repo review. Work top to bottom; each item is one small change, built and `zig fmt`-checked before the next.

## 1. Bugs

- [x] `fz_var` on every local mutated inside `fz_try` and read in `fz_always`/`fz_catch` (`src/mupdf-z/fitz-z.c`: `fz_pixmap_png_z`, `fz_page_content_bbox_z`, `fz_page_text_bbox_z`, `fz_line_text_at_z`, `fz_selection_z`, `fz_extract_pages_z`, `extract_flush_pending`)
- [x] Deferred mode switch: `changeMode` sets `next_mode`, applied after dispatch, so CommandMode/TocMode/MarksMode stop touching `self` after their payload was deinit'd (`src/Context.zig:630`, `src/modes/CommandMode.zig:42-47`, `TocMode.zig:153`, `MarksMode.zig:66,92`)
- [x] Command history index reset when leaving command mode; bounds-check against the filtered list (`src/modes/CommandMode.zig:88-108`, `src/services/History.zig`)
- [x] Sync reports each backend failure once, with the git/HTTP reason; no slices of a shared buffer cross the thread (`src/services/Sync.zig:218-297`, `GitStore.zig:140`)
- [x] `time.zig` uses `std.c.clock_gettime(.MONOTONIC/.REALTIME)`; drop the macOS clock ids and `mcp.nowSeconds` (`src/utilities/time.zig:13`, `src/mcp.zig:603`)
- [x] One `utilities/fs.zig: writeFileAtomic` (pid-suffixed temp, rename) replacing the three copies and the four non-atomic writers (`Positions.zig:707`, `Sync.zig:321`, `DirStore.zig:49`, `main.zig:392`, `Config.zig:332`, `mcp.zig:119`, `History.zig:57`)
- [x] `main` maps every error to a message and exit code in one place; `re missing.pdf` prints one line, `state import` failure exits non-zero (`src/main.zig:218-225, 328-332`)
- [x] Transmitted image freed when `cache.put` fails; `cache.enabled=false` frees the previous frame's images (`src/Context.zig:811, 933, 796-826`)
- [x] YAML booleans: zig-yaml hands `true`/`false` back as scalars, so every bool option (`colorize`, `statusBar.enabled`, ...) silently kept its default; `yamlToJson` now maps them (`src/config/Config.zig`)
- [x] S3 `list` follows `IsTruncated`/`NextContinuationToken` (`src/services/S3Store.zig:56-81`)

## 2. Dead code and duplication

- [x] Delete `reload_page`, `resetCurrentPage` (22 callers), `current_page`, `page_info_text`, `reload_done` payload, orphan "Animated zoom" comment (`src/Context.zig` + modes)
- [x] Delete `Store.manual` / `GitStore.manual`; replace the `MetadataType` mirror in `main.zig` with the untyped import `mcp.zig` already uses
- [x] `transmitOrDiscard(enc)` replacing four copies; collapse the shm/png_path branches of `transmitEncoded` (`src/Context.zig:795-908`)
- [x] `followLink`, `gotoHit`, `jumpToMark`, `handleControl` go through `gotoPagePdfY` / `restorePosition` instead of inlining the page+scroll sequence (a `jumpTo` wrapper was not worth it: `pushJump` placement differs per caller)
- [x] `freeHighlight` / `tombstone` helpers; `init` calls `rebuildHighlightQuads` instead of inlining it (`src/Context.zig:189-199, 477, 1268-1406, 1538`)
- [x] One retry helper for `PdfHandler` open/render; fold `error.PageLoadFailed` into `DocumentError` (`PdfHandler.zig:186-200, 405-422`)
- [x] One `rasterize(page, zoom, opts)` behind `renderAttempt` and `renderThumb` (`PdfHandler.zig:433-476, 550-581`)
- [x] One per-frame arena on Context reset at the top of `draw`; drop `draw_arena` from Toc/SearchList/Marks/Highlights/Help/Grid
- [x] `setQuads` replacing the three `set*Quads`; `Markdown.closeCodeBlock` sets `write_failed` like the other writers
- [x] Status bar `<path>` uses `doc_abs_path` and a cwd resolved once instead of two `realpath` calls per frame (`src/Context.zig:2067`)
- [x] `Presence` struct instead of the 6-argument `writePresence` calls (`src/Context.zig:365, 554, 1254`)
- [x] `General.parse` / `KeyMap.parse` go through `parseFields` (`src/config/Config.zig:51-63, 101-121`)
- [x] `build.zig`: fixed arg array instead of 11 `catch unreachable`; drop the redundant install dependency

## 3. Structure

- [x] `modes/ListView.zig`: cursor/top, key and wheel handling, delete-and-clamp, popup layout, one theme; used by SearchList, Marks, Highlights, Toc, Help (layout only). Fixes Marks scrolling past one screen
- [x] List-mode keys routed through the keymap so Help cannot drift; a "Lists" help section generated from them
- [x] Split `PdfHandler` into `Document` (owns MuPDF + mutex, renders from explicit `RenderParams`), `View` (plain main-thread zoom/scroll/crop/spread state), `Transfer` (creates, transmits, deletes an `EncodedImage`). Removes the worker-thread writes to `active_zoom`/`rendered_w` and the unlocked `selection_hits` read in `cacheKeyFor`
- [x] Cache owns its `evicted` list and Context drains it once per frame; `take`/`remove` merged
- [x] Prerenderer: one generic mailbox for pages and thumbs; honor a newer request between pages
- [x] Split `Context.zig`: `StatusBar.zig`, `Export.zig`, `Editor.zig` (with one `tempDir(kind)`), `Selection.zig`
- [x] `Paths` resolved once in `main` (state, books, config, downloads, device) replacing the `state_dir_buf` global and the four state-root preambles; History uses it too
- [x] Positions: `HlRec` dropped, `Highlight` is the on-disk record. Kept: `MarkRec`/`TombRec` (the one-char `letter` string and `kind` text are the file format, and a custom JSON hook would cost more than the two small structs) and `View`/`Position` (the bridging is two `inline for` loops; folding `View` into `Position` would ripple through Context for little gain)
- [x] Positions arena reset per reload; `save()` surfaces its first failure
- [x] `mcp.zig`: `Stringify.value` for the JSON-RPC envelopes; tool table carries its handler
- [x] Legacy fancy-cat/pre-0.8.0 `positions.json` migration deleted (no longer supported)

## 4. Tests

- [x] `zig build test` step over a `src/tests.zig` that references the leaf modules and Positions
- [x] Merge tests for `Positions.mergeShards`/`hasProgress`/`viewEql`/`importBundle` using `std.testing.tmpDir`, pinning the on-disk format before the Positions refactor
- [x] CI runs the test step on macOS and Linux; lint pinned to Zig 0.17.0
