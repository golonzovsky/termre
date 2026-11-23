# Configuration

On startup, termre looks for a configuration file in the following locations:

**Primary**

```
$XDG_CONFIG_HOME/termre/config.yaml
```

**Fallback**

```
$HOME/.config/termre/config.yaml
```

If no configuration file is found in any of these locations, termre writes a commented template listing every section there (everything in it is commented out, so the defaults apply).

The file is YAML; keys are lowerCamelCase. A file that cannot be used is not silent: the reader shows the reason in the status bar at startup (`config.yaml line 3: expected map separator ':': using defaults`), and `re state …` and `re mcp` print it to stderr. That covers a file that does not parse, an unclosed quote, and a key at the top level that is not a section, which is usually a lost indent. An unknown key inside a section is still ignored.

| Key | Type | Description |
| --- | --- | --- |
| `downloadDir` | String | Where `re <url>` saves PDFs (arXiv `abs`/`html`/`pdf` links resolve to the PDF and are named `arxiv-<id>.pdf`; a URL is downloaded once). Default `<stateDir>/downloads` |
| `stateDir` | String | Where reading state (per-book/device records, device name, presence) lives. Default `$XDG_STATE_HOME/termre`, else `~/.local/state/termre`; `~/` is expanded |

## Defaults

Because termre provides sensible defaults, you only need to specify the options you wish to override. Below is an example configuration file that replicates the default settings. You can use this example as a starting point for your customizations:

```yaml
keyMap:
  next:
    key: n
  prev:
    key: p
  scrollUp:
    key: k
  scrollDown:
    key: j
  scrollLeft:
    key: h
  scrollRight:
    key: l
  scrollHalfDown:
    key: d
    modifiers: [ctrl]
  scrollHalfUp:
    key: u
    modifiers: [ctrl]
  zoomIn:
    key: i
  zoomOut:
    key: o
  widthMode:
    key: w
  fitWidth:
    key: W
  cropToContent:
    key: t
  cropMode:
    key: c
  toggleSpread:
    key: d
  hintMode:
    key: ";"
  setMark:
    key: m
  jumpMark:
    key: "'"
  tocMode:
    key: T
  marksMode:
    key: M
  gridMode:
    key: g
  libraryMode:
    key: b
  colorize:
    key: z
  quit:
    key: c
    modifiers: [ctrl]
  fullScreen:
    key: f
  enterCommandMode:
    key: ":"
  exitCommandMode:
    key: escape
  executeCommand:
    key: enter
  completeCommand:
    key: tab
  historyBack:
    key: up
  historyForward:
    key: down
  jumpBack:
    key: o
    modifiers: [ctrl]
  jumpForward:
    key: tab
  openInEditor:
    key: e
  openChapterInEditor:
    key: E
  showHelp:
    key: "?"
  search:
    key: /
  searchNext:
    key: N
  searchPrev:
    key: P
  searchList:
    key: S
  addHighlight:
    key: H
  highlightsMode:
    key: V
  listTop:
    key: g
  listBottom:
    key: G
  listSelect:
    key: enter
  listDelete:
    key: d
  listEdit:
    key: r
fileMonitor:
  enabled: true
  latency: 0.1
  reloadIndicatorDuration: 1.0
general:
  colorize: false
  white: "#000000"
  black: "#ffffff"
  size: 1.0
  zoomStep: 1.1
  zoomMin: 1.0
  scrollStep: 100.0
  retryDelay: 0.2
  timeout: 5.0
  detectDpi: true
  shmTransfer: true
  dpi: 96.0
  history: 1000
statusBar:
  enabled: true
  style:
    bg: "#000000"
    fg: "#ffffff"
  items:
    - " "
    - view:
        text: VIS
      command:
        text: CMD
    - "   <path> "
    - idle:
        text: " "
      reload:
        text: "*"
      watching:
        text: " "
    - " <chapter><separator><search><crop><oddx><fit><hlock><page>:<total_pages> · <percent>% "
cache:
  enabled: true
  lruSize: 14
  budgetMb: 200
sync: []
```

The rest of this reference provides detailed explanations for each configuration section. 

## Contents

- [Key Map](#key-map)
  - [Keybindings](#keybindings)
    - [Keys](#keys)
    - [Modifiers](#modifiers)
- [File Monitor](#file-monitor)
- [General](#general)
  - [Color](#color)
  - [History](#history)
- [Status Bar](#status-bar)
  - [Style](#style)
    - [Underline](#underline)
  - [Items](#items)
    - [Plain Items](#plain-items)
    - [Styled Items](#styled-items)
    - [Mode-aware Items](#mode-aware-items)
     - [Reload-aware Items](#reload-aware-items)
- [Cache](#cache)
- [Sync](#sync)

---

## Key Map

The `keyMap` section defines keybindings for various actions.

| Action | Description |
| :--- | :--- |
| `next` | Go to the next page |
| `prev` | Go to the previous page |
| `scrollUp` | Move the viewport up |
| `scrollDown` | Move the viewport down |
| `scrollLeft` | Move the viewport left |
| `scrollRight` | Move the viewport right |
| `scrollHalfDown` / `scrollHalfUp` | Scroll half a page (in the page grid and the library: one screen) |
| `zoomIn` | Increase the zoom level |
| `zoomOut` | Decrease the zoom level |
| `widthMode` | Toggle between full-height or full-width mode |
| `fitWidth` | Toggle the fit-width lock (`:fit`) |
| `cropToContent` | Toggle auto-crop to the page content |
| `cropMode` | Interactive crop |
| `toggleSpread` | Toggle the continuous spread (a digit after it sets the column count) |
| `hintMode` | Link hints |
| `setMark` / `jumpMark` | Set / jump to a mark (followed by a letter) |
| `tocMode` | Table of contents popup |
| `marksMode` | Marks popup |
| `gridMode` | Page grid |
| `libraryMode` | Library |
| `colorize` | Toggle color replacement |
| `quit` | Exit the program |
| `fullScreen` | Toggle full screen (i.e. hide status bar) |
| `enterCommandMode` | Enter command mode |
| `exitCommandMode` | Exit command mode |
| `executeCommand` | Execute the entered command |
| `completeCommand` | Complete the command name |
| `historyBack` | Go back one command in history |
| `historyForward` | Go forward one command in history |
| `jumpBack` / `jumpForward` | Step back / forward through the jump list |
| `openInEditor` / `openChapterInEditor` | Open the current page / chapter as markdown in `$EDITOR` |
| `showHelp` | Help popup |
| `search` | Search the document |
| `searchNext` / `searchPrev` | Next / previous match |
| `searchList` | Search finder with the full match list |
| `addHighlight` | Save the current selection as a highlight |
| `highlightsMode` | Highlights popup |
| `listTop` / `listBottom` | Jump to the first / last entry in a list popup (TOC, marks, search, highlights) |
| `listSelect` | Jump to the selected list entry |
| `listDelete` | Delete the selected mark / highlight |
| `listEdit` | Rename the selected mark |

### Keybindings

Each keybinding is an object named after the action it performs. This object includes:

| Property | Type | Description |
| :--- | :--- | :--- |
| `key` | [Key](#keys) | The key that triggers the action |
| `modifiers` (optional) | [Modifiers](#modifiers) | Other keys that must be held down to trigger the action; a binding without it has none, whatever the default binding uses |

#### Keys

The `key` property can be set to either a single character (like `a`, `1`, or `:`) or one of the following keys:

| Key | Description |
| :--- | :--- |
| `escape` | Escape key |
| `enter` | Enter (Return) key |
| `space` | Space bar |
| `tab` | Tab key |
| `backspace` | Backspace key |
| `delete` | Delete key |
| `insert` | Insert key |
| `home` | Home key |
| `end` | End key |
| `pageUp` | Page Up key |
| `pageDown` | Page Down key |
| `up` | Up arrow key |
| `down` | Down arrow key |
| `left` | Left arrow key |
| `right` | Right arrow key |
| `f1`–`f12` | Function keys |

> [!NOTE]
> This reference includes the most commonly used keys. The [complete list](https://github.com/rockorager/libvaxis/blob/main/src/Key.zig) is more extensive, though support may vary by terminal or keyboard.

#### Modifiers

The `modifiers` property can be set to an array that includes any combination of the following keys:

| Modifier | Description |
| :--- | :--- |
| `shift` | Shift key |
| `alt` | Alt (Option) key |
| `ctrl` | Control key |
| `super` | Super (Windows or Command) key |
| `hyper` | An advanced modifier key |
| `meta` | Another advanced modifier key |
| `capsLock` | Caps Lock key |
| `numLock` | Num Lock key |

---

## File Monitor

The `fileMonitor` section controls the automatic reloading feature, useful for live previews. When the changed file cannot be opened (half-written, or not a PDF for a moment), the reader keeps showing the last readable version and says so in the status bar; the next change is picked up as usual.

| Property | Type | Description |
| :--- | :--- | :--- |
| `enabled` | Boolean | Enables file change detection and automatic reloading |
| `latency` | Float (seconds) | The time interval between checking for changes |
| `reloadIndicatorDuration` | Float (seconds) | How long the reload indicator remains visible (`0.0` disables it) |

---

## General

The `general` section includes various display and timing settings.

| Property | Type | Description |
| :--- | :--- | :--- |
| `colorize` | Boolean | Enables color replacement on startup |
| `white` | [Color](#color) | Replacement color for white |
| `black` | [Color](#color) | Replacement color for black |
| `size` | Float | Initial zoom level multiplier (`1.0` fits the full height) |
| `zoomStep` | Float | Zoom multiplier per keystroke |
| `zoomMin` | Float | Minimum zoom level allowed |
| `scrollStep` | Float (pixels) | Distance the viewport moves per scroll keystroke |
| `detectDpi` | Boolean | Enables pixel-density detection so that 100% zoom = actual size |
| `shmTransfer` | Boolean | Raw-RGB page transfer via POSIX shared memory (kitty `t=s`); disable to fall back to PNG temp files for terminals without shm support (done automatically inside zellij; Rex streams the bytes directly) |
| `dpi` | Float | Pixel density to use if `detectDpi` is false, or fallback if detection fails |
| `retryDelay` | Float (seconds) | Delay before retrying to load a document or render a page |
| `timeout` | Float (seconds) | Maximum time to keep retrying before giving up on loading a document or rendering a page |
| `history` | Integer | Maximum number of entries in command history |

>[!TIP]
>The color replacement feature works by replacing white and black with custom colors, which also affects the full color range depending on contrast. By default, `white` is set to black (`#000000`) and `black` is set to white (`#ffffff`). For a seamless look, try setting `white` to match your terminal’s background color and `black` to match the foreground (text) color.

### Color

The following color formats are supported:

| Format  | Description |
| :---  | :--- |
| `"#RRGGBB"` or `"0xRRGGBB"` | `RR`, `GG`, and `BB` are two-digit hexadecimal values |
| `{ "rgb": [R, G, B] }` | `R`, `G`, and `B` are integers between 0 and 255 |

### History

To ensure persistence across sessions, termre saves its command history in one of the following locations:

**Primary**

```
$XDG_STATE_HOME/termre/history
```

**Fallback**

```
$HOME/.local/state/termre/history
```

---

## Status Bar

The `statusBar` section controls the information shown at the bottom of the window.

| Property | Type | Description |
| :--- | :--- |  :--- |
| `enabled` | Boolean | Enables the status bar |
| `style` | [Style](#style) | Default appearance of the entire status bar |
| `items` | [Items](#items) | Status bar items |

### Style

A `style` object can include the following properties:

| Property | Type | Description |
| :--- | :--- | :--- |
| `fg` | [Color](#color) | Foreground (text) color |
| `bg` | [Color](#color) | Background color |
| `ul` | [Color](#color) | Underline color |
| `bold` | Boolean | Bold text |
| `italic` | Boolean | Italic text |
| `ulStyle` | [Underline](#underline) | Underline style |

>[!NOTE]
>This reference provides the most commonly used style properties. The [complete list](https://github.com/rockorager/libvaxis/blob/main/src/Cell.zig) includes others, though support may vary by terminal.

#### Underline

The `ulStyle` property can be set to one of the following styles:

| Style | Description |
| :--- | :--- |
| `off` | No underline |
| `single` | Single underline |
| `double` | Double underline |
| `curly` | Curly underline |
| `dotted` | Dotted underline |
| `dashed` | Dashed underline |

### Items

The `items` property can be set to an array of status bar items, which include:

* **[plain items](#plain-items)**: text with default styling
* **[styled items](#styled-items)**: text with custom [styling](#style)
* **[mode-aware items](#mode-aware-items)**: styled items to be displayed depending on the current mode
* **[reload-aware items](#reload-aware-items)**: styled items to be displayed depending on the file monitor state and the reload activity
#### Plain Items

Plain items are just strings that may include placeholders (e.g., `<page>:<total_pages>`). These placeholders are replaced with dynamic content at runtime.

| Placeholder | Description |
| :--- | :--- |
| `<path>` | The file path |
| `<page>` | The current page number |
| `<total_pages>` | The total number of pages |
| `<separator>` | Inserts a space to separate the left and right sides of the status bar |
| `<chapter>` | Title of the current chapter (from the outline) |
| `<percent>` | Progress through the book, as a number |
| `<search>` | Current match, match count and the search text while a search is active |
| `<crop>` | The crop in effect (`CROP T R B L`, `*` when automatic) |
| `<oddx>` | The odd-page shift when set |
| `<fit>` | `FIT` while the fit-width lock is on |
| `<hlock>` | `HLOCK` while horizontal scroll is locked |

#### Styled Items

Each styled item is an object containing:

| Property | Type | Description |
| :--- | :--- | :--- |
| `text` | [Plain item](#plain-items) | Text to display |
| `style` (optional) | [Style](#style) | Overrides the default appearance |

**Example:** Underline the file path with a single green line:

```yaml
text: <path>
style:
  ul: "#00ff00"
  ulStyle: single
```
>[!NOTE]
>If no style is provided, a styled item behaves just like a plain item.

#### Mode-aware Items

Mode-aware items switch their content based on the current mode. Each item must include at least one of:

| Property | Type | Description |
| :--- | :--- | :--- |
| `view` | [Styled item](#styled-items) | Item to display in view mode |
| `command` | [Styled item](#styled-items) | Item to display in command mode |

**Example:** Display a bold red "VIS" in view mode and a bold blue "CMD" in command mode:

```yaml
view:
  text: VIS
  style:
    fg: "#ff0000"
    bold: true
command:
  text: CMD
  style:
    fg: "#0000ff"
    bold: true
```

#### Reload-aware Items

Reload-aware items switch their content based on the file monitor state and the reload activity. Each item must include at least one of:

| Property | Type | Description |
| :--- | :--- | :--- |
| `idle` | [Styled item](#styled-items) | Item to display when the file monitor is disabled |
| `reload` | [Styled item](#styled-items) | Item to display when the file monitor is enabled and the reload indicator is on |
| `watching` | [Styled item](#styled-items) | Item to display when the file monitor is enabled and the reload indicator is off |

>[!TIP]
>Try using placeholders in mode- and reload-aware items to enhance feedback!

---

## Cache

The `cache` section controls the page rendering cache, which speeds up navigation between recently viewed pages.

| Property | Type | Description |
| :--- | :--- | :--- |
| `enabled` | Boolean | Enables caching |
| `budgetMb` | Integer | Max decoded image bytes (MB) kept alive in the terminal; stays under terminal image-storage quotas so the visible page is never silently evicted |
| `lruSize` | Integer | Maximum number of pages to store in the cache |

## Sync

Reading state (position, zoom, crop, marks, highlights) lives in one small JSON record per book **and per device** under `~/.local/state/termre/books/<book>/<device>.json`. `sync` is a list of backends; any number can be active at once, each with its own mode. Records merge without conflicts: the newest view wins, marks and highlights are a union (deletions carry tombstones). The device name is minted once into `~/.local/state/termre/device`.

`<book>` is the document's identity, not its file name, so a renamed or moved PDF keeps its state: the PDF's own `/ID` when it has one (`pdf-id_…`), otherwise the SHA-256 of its first MiB (`sha256-1mb_…`). Earlier versions keyed a PDF of 1 MiB or more without an `/ID` by its path (`path_…`); the first open of such a book moves its records and cover under the new name, here and, on the next pull, in every sync backend.

```yaml
sync:
  - type: s3
    mode: periodic                 # pull at open, push while reading (every `debounce`) and on quit
    bucket: private
    region: auto
    endpoint: <account>.r2.cloudflarestorage.com
    prefix: termre
    accessKey: "..."            # empty -> AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
    secretKey: "..."
  - type: git
    mode: manual                   # only `:sync` / `re state sync`
    dir: ~/.local/state/termre/git
    remote: git@github.com:you/termre-state.git
```

| Field | Type | Description |
| --- | --- | --- |
| `type` | String | `dir` (a folder — anything that syncs folders: Syncthing, iCloud Drive, rsync, SSHFS), `s3` (AWS S3, Cloudflare R2, Backblaze B2, MinIO, …) or `git` (a folder inside a git repo) |
| `mode` | String | `manual`: only `:sync` in the reader or `re state sync`. `open-close`: pull other devices' records when a book opens, push this device's when it closes, nothing in between. `periodic`: `open-close` plus a push at most every `debounce` while reading. Default: `manual` for `git`, `periodic` otherwise; there is never a periodic *pull* |
| `enabled` | Boolean | `false` parks an entry without deleting it |
| `debounce` | Duration | Minimum time between automatic pushes: `10s`, `5m`, `3h`, `1d`; default `10s`, or `3h` for git |
| `path` | String | `dir`: the folder; `~/` is expanded |
| `bucket`, `region`, `endpoint`, `prefix` | String | `s3`: bucket; SigV4 region (empty → `AWS_REGION`/`AWS_DEFAULT_REGION`, else `us-east-1`; R2: `auto`); host only, empty → `s3.<region>.amazonaws.com` (R2: `<account>.r2.cloudflarestorage.com`, MinIO: `host:9000`); key prefix (default `termre`) |
| `accessKey`, `secretKey` | String | `s3`: empty → `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` (`AWS_SESSION_TOKEN` is honored) from the environment |
| `dir` | String | `git`: a folder inside a repository, e.g. `~/dotfiles/termre` — only that folder is ever staged and committed (`git add -A -- .`, `git commit -- .`), pulls are `--rebase --autostash`, pushes go to the repo's remote. A missing folder is created when its parent is already a work tree |
| `remote` | String | `git`: used only when `dir` does not exist and is not inside a repo — the repo is cloned *as* `dir` (records at its root). For a folder inside a shared repo, clone the repo yourself. All devices must use the same layout |

`:sync` forces a pull and push through every backend; `re state sync` does the same outside the reader for all books (records only, never PDFs). A PDF goes up only on request, `u` in the library or `:upload`, as `books/<book>/book.pdf` plus its `cover.png`, to every `s3` and `dir` backend (never git); the library (`b`) then opens that book on another device by downloading it into `downloadDir` under its file name, or as `<name>-<end of the book key>.pdf` when a different book already has that name there. The `re` picker and the library (`b`) pull the index (records and covers) from automatic backends so books read elsewhere show up. A git entry gets one "termre: reading state" commit per sync, not per page.

`re state purge <book>` removes one book everywhere: its records, PDF and cover from every backend, and its records from this machine (the `<book>` key is the folder name under `~/.local/state/termre/books/`).

Without a store, move state by hand: `re state export [file]` writes every record as one JSON document (stdout by default), and `re state import <file|->` merges it into the local records with the same rules sync uses — safe to re-run, never loses local work.


