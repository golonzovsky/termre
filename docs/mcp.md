# MCP server

`re mcp` speaks the [Model Context Protocol](https://modelcontextprotocol.io) over stdio (newline-delimited JSON-RPC), so an agent can read a book alongside you instead of you exporting it first. Everything is read-only; it never touches the PDF or your reading state.

```sh
re mcp install claude     # runs `claude mcp add termre -- re mcp`
re mcp install codex      # runs `codex mcp add termre -- re mcp`
re mcp config             # prints the mcpServers JSON snippet for any other client
```

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

`book` is an absolute path, `~/path`, or a case-insensitive substring of a recent book's path — `"Inference"` is enough. `reading_state` and `current_page` accept no `book` at all: they then use the book being read right now — but only when that is unambiguous (exactly one running `re` moved in the last 10 minutes, or only one is open at all). With several books open the tool lists them and asks for `book` instead of guessing, and when it does default while other books sit idle it says so. So "what does the selected text mean?" needs no arguments while you're reading one book.

## Presence

Each running `re` keeps `~/.local/state/termre/open/<pid>.json` (path, start time, last state change, last mouse selection with its page), refreshed whenever your position is saved and removed on exit; entries whose process is gone are pruned. That is what lets `list_books` distinguish the book you are reading now from ones idling in forgotten tabs.
