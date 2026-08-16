<h1>
<p align="center">
  📖
  <br>termre
</h1>
  <p align="center">
    <b>TERM</b>inal <b>RE</b>ader — read books and papers in your terminal, using the Kitty image protocol
    <br />
    <a href="https://term.re">term.re</a>
  </p>
</p>

termre started as a fork of [fancy-cat](https://github.com/freref/fancy-cat), a neat little terminal PDF viewer — thanks to its authors for the inspiration and the foundation. It has since grown into a reading-focused tool: continuous scroll, per-book persistence, marks and highlights, interactive cropping, and print export.

## Features

- **Continuous scroll across pages** — scroll past a page boundary and the next page is rendered in the same viewport; no per-page snap.
- **Smooth in-page scrolling via kitty `clip_region`** — each page is rasterized once at the current zoom and transmitted to the terminal once, then scrolling just updates the placement's source rect (~50 bytes/event) instead of re-rendering. Adjacent pages are stacked with cell-aligned placements; sub-cell page-bottom remainders are scaled to fill (`r=/c=`) so nothing is lost at page boundaries.
- **Mouse / trackpad support** — wheel up/down/left/right scrolls; `Shift+wheel` scrolls horizontally; `Ctrl`/`Alt`+wheel zooms; left-click follows PDF links (internal → goToPage with destination y, URI → `open <uri>`). `:hlock` disables horizontal wheel for reading-mode trackpad use.
- **Half-page smooth scroll** (`Ctrl+D` / `Ctrl+U`) — vim/neoscroll-style; scrolls half the viewport with a short ease-out animation. Cheap because scrolling a cached page only updates the kitty `clip_region`, so each animation frame is a placement update, not a re-render.
- **Render-ahead (±3)** — a background worker prerenders up to three pages forward and back (forward-biased), so fast flipping stays cache-warm.
- **Configurable zoom step** — `i`/`o` zoom by `general.zoom_step` per press (default `1.1` = 10%; set `1.25` for coarser jumps).
- **Full-text search** (`/`, then `N`/`P` for next/prev match, Esc clears) — scans the whole document via mupdf and highlights hits by inverting their rects in the rendered page. `S` opens a search finder: type a query, get the full match list with the containing text line per hit; `Enter` jumps, the needle is emphasized in each row.
- **Mouse text selection → clipboard** — drag with the left button; endpoints map to PDF space and snap to characters via mupdf's structured text, so the selection follows real text lines rather than terminal cells. On release the text is copied to the system clipboard (OSC 52). Esc clears the selection.
- **Highlights** (`H` / `V`) — `H` persists the current selection as a highlight, rendered as a yellow blend baked into the page raster (legible in colorize mode too). Overlapping highlights merge into one by re-selecting the union span, so the stored text stays exact. `V` opens a navigator listing each highlight with its text (`Enter` jumps, `d` deletes). Highlights live in `positions.json` — the PDF file is never modified.
- **Two-column spread** (`d` or `:spread`) — continuous flow for wide monitors: the page strip fills the left column and continues into the right, half pages allowed, so tall pages stay readable without shrinking.
- **Fit-width lock** (`W` or `:fit`) — locks zoom so the *cropped* page width exactly fills the window (or, in spread, the column width = two pages), recomputed on every render so it tracks window resizes and crop changes. A manual zoom (`i`/`o`, `:N%`) releases the lock. Shown as ` FIT ` in the status bar and persisted per document.
- **Auto-crop margins** (`t`) — computes a document-stable text bounding box (samples ~48 pages, trims outliers per edge) so every page shares one crop box; pages without text fall back to the drawn-content bbox.
- **Manual margin crop** (`:crop T R B L`) — trims margins in PDF points with CSS-shorthand value rules (1/2/3/4 values); applied after the odd-page offset; current values shown in the status bar; bare `:crop` resets.
- **Interactive crop mode** (`c`) — adjust the crop with the mouse directly on the page: four draggable lines per visible page, to-be-cropped regions dimmed, click grabs the nearest line. Each page shows its own lines, so "is that gap the bottom margin of this page or the top of the next" answers itself. Wheel still scrolls; live `T R B L` readout in the status bar; `Enter` (or `c`) applies as manual margins, `Esc` cancels, `r` resets; `i`/`o` zoom while cropping. Pages render unshifted in crop mode, and odd pages show a cyan `┆` line for the `oddx` offset — drag it (pure overlay, no re-render) and the crop border on odd pages shows exactly where the aligned window will cut; apply sets margins + offset together, so crop + odd-page alignment tune in one place.
- **Odd-page horizontal alignment** (`:oddx N`) — for books with asymmetric inner margins. Shift is baked into the mupdf CTM during render, so no display gap appears.
- **Print export** (`:export [path]`) — writes a copy of the PDF with the current crop and odd-page offset baked into each page's MediaBox/CropBox. Lossless (vector content untouched), so it prints at native quality without the margins; defaults to `<book>-cropped.pdf` next to the original. `:override` does the same in place: the file itself gets the geometry, saved crop/oddx reset, and reading position is kept.
- **Fast image transfer** — pages are encoded as PNG (10–40× smaller than raw RGB) and handed to the terminal as a temp file via the kitty graphics `t=t` medium, so only a file path crosses the tty; falls back to streamed base64 PNG over SSH.
- **Link hint mode** (`;`) — vim-style overlay labels on every visible link; type the letter(s) to follow. Duplicate links (same target) share a label.
- **Table of contents** (`T` to toggle, or `:toc`) — popup tree of mupdf's outline. Defaults to collapsed-with-current-page-ancestry-expanded, so you see chapters with the section you're in opened. `l`/`h` (or `→`/`←`) expand/collapse; `L`/`H` unfold/fold one level (vim `zr`/`zm`); Space toggles; Enter jumps; mouse wheel, `j`/`k`, and animated `Ctrl+D`/`Ctrl+U` half-page jumps navigate; `g`/`G` for top/bottom.
- **Marks** (vim-style) — `m<letter>` sets a mark at the current page+scroll, `'<letter>` jumps to it. `M` (or `:marks`) opens a popup listing marks alongside the TOC section title for each. `Enter` jumps, `r` renames (opens command line pre-filled with `mark <letter> <current comment>`), `d` deletes; mouse wheel and `j`/`k` navigate. `:mark a some comment` sets a mark with a comment; `:delmark a` removes one. Persisted per document.
- **Link navigation history** — vim-style `Ctrl+O` (back) / `Tab` (forward) jump list. Only link follows and mark jumps push to the list; manual nav doesn't.
- **Per-document position persistence** — page, scroll, zoom, oddx, colorize, crop (including manual margins), spread, hlock, marks, and highlights are saved continuously and restored on next open. Stored at `${XDG_STATE_HOME:-~/.local/state}/termre/positions.json`, keyed by PDF `/ID` (or SHA-256 of first 1MB, or path) so files survive being moved. Opening with an explicit page argument overrides only the position, not the view settings.
- **Recent-files picker** — running `re` with no arguments opens the recently-read list in `fzf` (numbered-prompt fallback when fzf is missing) and restores your exact position.
- **Chapter & progress in the status bar** — `<chapter>` (deepest outline section at the current page) and `<percent>` placeholders, alongside the page/zoom items.
- **Help popup** (`?` or `:help`) — keybinding chips are rendered from the live keymap (so rebinds show correctly) and the `:` command column is generated from the command dispatch table, so the help can't go stale.
- **Command completion** — `Tab` in command mode completes `:` command names to the longest common prefix; a unique match that takes arguments gets a trailing space. Completions are derived from the dispatch table at comptime, so they can't go stale either.
- **Terminal tab title** — set to the book's filename on startup (OSC 2), so terminal tabs are tellable apart.
- **Open page / chapter in `$EDITOR`** (`e` / `E`, or `:edit` / `:edit c`) — extracts as markdown with bold/italic/mono spans, headings, and inline diagram PNGs (pairs well with [image.nvim](https://github.com/3rd/image.nvim)).

## Usage

```sh
re <path-to-pdf> [page]
re                        # pick from recently opened
```

termre uses a modal interface similar to Neovim: view mode and command mode (`:`). Commands are documented in [docs/commands.md](./docs/commands.md).

### Configuration

Optional JSON config at `$XDG_CONFIG_HOME/termre/config.json` (fallback `~/.config/termre/config.json`); an empty one is created on first run. See [docs/config.md](./docs/config.md). An existing fancy-cat config and reading state are picked up automatically.

## Build

Requirements: Zig `0.16.0`, a terminal with the Kitty image protocol (Ghostty, Kitty, WezTerm, …), and on macOS the Xcode command-line tools.

```sh
git clone --recursive https://github.com/golonzovsky/termre.git
cd termre
zig build --release=small     # first build compiles mupdf (~minutes)
mv zig-out/bin/re ~/.local/bin/   # or anywhere on PATH
```

`build.zig` auto-applies the small mupdf header rewrite that Zig 0.16's translate-c needs, so a fresh clone builds with plain `zig build`.

## License

[AGPL-3.0-or-later](https://spdx.org/licenses/AGPL-3.0-or-later.html) — termre links [MuPDF](https://mupdf.com), which is AGPL, and includes code derived from fancy-cat's AGPL-licensed portions.
