<h1 align="center">📖 termre</h1>
<p align="center">
  <b>TERM</b>inal <b>RE</b>ader — read books and papers in your terminal
  <br />
  <a href="https://term.re">term.re</a>
</p>

A PDF reader for terminals with the Kitty graphics protocol (Ghostty, kitty, WezTerm, Konsole; zellij ≥ 0.45). It started as a fork of [fancy-cat](https://github.com/freref/fancy-cat) and grew into a reading tool: continuous scroll, per-book state, marks, highlights, cropping, print export.

## Install

```sh
brew tap golonzovsky/tap
brew trust golonzovsky/tap   # Homebrew requires trusting third-party taps
brew install termre          # installs the `re` binary
```

Binaries for macOS arm64 and Linux x86_64 are on the [releases page](https://github.com/golonzovsky/termre/releases). Optional: `fzf` for the recent-books picker.

## Usage

```sh
re <path-to-pdf> [page]
re                        # pick from recently opened
re state export > s.json  # all reading state; `re state import s.json` merges it in elsewhere
```

Modal, vim-like: `?` lists every key and `:` command. Details in [docs/commands.md](./docs/commands.md); configuration (`~/.config/termre/config.json`) in [docs/config.md](./docs/config.md).

## Features

- Continuous scroll with smooth half-page jumps (`Ctrl+D`/`Ctrl+U`); mouse and trackpad
- Zoom (`i`/`o`), fit-width lock (`W`), multi-column spread for wide monitors (`d`, `d3` for three, `:spread N`)
- Margin cropping: auto (`t`), manual (`:crop`), or interactive with mouse-draggable lines (`c`); odd-page alignment (`:oddx`)
- Print export (`:export`) — a lossless copy of the PDF with the crop baked in
- Full-text search (`/`, `S`), link following (click, or hint mode `;`), table of contents (`T`)
- Text selection to clipboard by mouse drag; persistent highlights (`H`, `V`)
- Vim-style marks (`m`/`'`, `M`) and jump list (`Ctrl+O`/`Tab`)
- Page grid overview (`g`)
- Everything remembered per book — position, zoom, crop, colorize, marks, highlights — keyed by PDF ID, so files can move
- Sync across devices through S3-compatible storage or any synced folder — per-device records that merge without conflicts ([config](./docs/config.md#sync))
- Markdown out: a page or chapter into `$EDITOR` (`e`/`E`), or the whole book with chapter headings and page markers (`:markdown`) — handy for pointing an agent at a book

## Agents

`re mcp` serves the reader over the Model Context Protocol (stdio), so an agent can work alongside a book:

```sh
re mcp install claude      # or: re mcp install codex; registers the server and installs the termre skill
                           # `re mcp config` / `re mcp skill` print both for other clients
```

Tools: `list_books` (what's open and active right now, then recents), `get_outline`, `get_pages` / `get_chapter` (markdown with `<!-- page N -->` markers), `search` (full-text, page + line), `reading_state` and `current_page` (the page you're on, the text you just selected with the mouse, marks, highlights — no arguments needed while one book is open), `goto_page` / `select_text` (the agent moves your reader to the passage it's citing, or selects it so one `H` keeps it as a highlight; Ctrl-O brings you back). Details in [docs/mcp.md](./docs/mcp.md).

## Build

Requires Zig `0.16.0` (and the Xcode command-line tools on macOS).

```sh
git clone --recursive https://github.com/golonzovsky/termre.git
cd termre
zig build --release=small     # first build compiles mupdf (~minutes)
mv zig-out/bin/re ~/.local/bin/
```

## License

[AGPL-3.0-or-later](https://spdx.org/licenses/AGPL-3.0-or-later.html) — termre links [MuPDF](https://mupdf.com) (AGPL) and includes code derived from fancy-cat.
