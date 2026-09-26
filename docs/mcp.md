# MCP server

`re mcp` speaks the [Model Context Protocol](https://modelcontextprotocol.io) over stdio (newline-delimited JSON-RPC), so an agent can read a book alongside you instead of you exporting it first. Nothing here modifies the PDF or your annotations; the tools that change anything are `goto_page` and `select_text`, which move the view and the selection.

```sh
re mcp install claude     # runs `claude mcp add --scope user termre -- re mcp` and installs the skill (see below); re-run to update the skill
re mcp install codex      # runs `codex mcp add termre -- re mcp` and installs the skill
re mcp config             # prints the mcpServers JSON snippet for any other client
re mcp skill              # prints the skill (Agent Skills format) for any other client
```

## Skill

The tools give an agent *access*; the skill tells it *how to read with you*: start from `current_page`/`reading_state` with no arguments, search before fetching pages, never walk a whole book, cite as `p.N` (which maps to `:N` in the reader), and treat "this" as the mouse selection. `re mcp install` writes it to `~/.claude/skills/termre/SKILL.md` or `~/.codex/skills/termre/SKILL.md`; the source lives at [src/skill/termre/SKILL.md](../src/skill/termre/SKILL.md).

Any MCP client works the same way: run `re mcp` as the server command.

## Tools

| Tool | Arguments | Returns |
| --- | --- | --- |
| `list_books` | — | Books open in a running `re` first (`ACTIVE` if the reader moved in the last 10 minutes, else idle time), then recent books with page and last-read time; books read on another device are tagged |
| `get_outline` | `book` | Table of contents with page numbers |
| `get_pages` | `book`, `from`, `to` | Pages `from..to` (1-based, inclusive) as markdown; an `<!-- page N -->` marker precedes each page, diagrams are written as PNG files (path in the header comment) |
| `get_chapter` | `book`, `page` or `title` | The top-level chapter containing `page`, or the first outline entry whose title contains `title` (case-insensitive) |
| `search` | `book`, `query`, `limit` | `p.N: <matching line>` per hit (default 20) |
| `reading_state` | `book` (optional) | Current page and chapter, whether it is open right now, the last text selected with the mouse (with page and age), last-read date and device, marks, highlights with their text |
| `current_page` | `book` (optional) | The page the reader is on: header with chapter and open/active state, the current mouse selection, highlights on that page, then the page's markdown |
| `select_text` | `book` (optional), `page`, `text`, `pid` (optional) | Selects `text` (must occur verbatim on that page) in the running reader: shown inverted, scrolled into view, published as the current selection; the user presses `H` to keep it as a highlight. Nothing is copied to the clipboard |
| `goto_page` | `book` (optional), `page`, `pid` (optional) | Moves a running reader to that page (the one write-ish tool: it changes the view, never the book or your state). The user gets an "agent: p.N" note and can return with Ctrl-O. With one book open in several splits, `pid` from `list_books` picks the instance |

`book` is an absolute path, `~/path`, or a case-insensitive substring of a recent book's path — `"Inference"` is enough. `reading_state` and `current_page` accept no `book` at all: they then use the book being read right now — but only when that is unambiguous (exactly one running `re` moved in the last 10 minutes, or only one is open at all). With several books open the tool lists them and asks for `book` instead of guessing, and when it does default while other books sit idle it says so. So "what does the selected text mean?" needs no arguments while you're reading one book.

## Presence

Each running `re` keeps `~/.local/state/termre/open/<pid>.json` (path, start time, last state change, last mouse selection with its page) and polls `open/<pid>.cmd` for agent commands (`goto <page>`, `select <page> <text>`), refreshed whenever your position is saved and removed on exit; entries whose process is gone are pruned. That is what lets `list_books` distinguish the book you are reading now from ones idling in forgotten tabs.
