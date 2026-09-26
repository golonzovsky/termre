---
name: termre
description: Read and discuss the PDF book the user is reading in termre (`re`) through its MCP tools — current page, selected text, highlights, outline, page ranges, full-text search. Use when the user refers to "the book I'm reading", "this page/chapter", "what I selected/highlighted", or asks where a book says something.
---

# termre — reading alongside the user

The user reads PDFs in termre (`re`), a terminal reader. Its MCP server (`termre`) exposes the book and the user's reading state. Everything is read-only.

## Re-check the live state on every turn — without losing the thread

The reader keeps moving while you talk, so check, but don't reset:

- On **every** turn that concerns the book, call `current_page` (or `reading_state`) first, even when the previous turn already did.
- Keep the conversation's thread by default. Turning a page — or several — inside the same chapter or topic does not change what "we" are discussing; keep going.
- Follow the live state instead when the question points at it ("this", "here", "what I selected", "where am I", "this chapter", "continue from here") or when the reader has clearly moved to a different chapter or topic and the question would read differently there. Then say so in a few words ("you're on p.42 now, in *Prefill Pool* — switching to that") so the switch is visible.
- If it is genuinely ambiguous whether a question is about the earlier thread or the new position, say which you're taking it as, or ask.
- The selection carries its age ("selected 40s ago"). A fresh selection is what "this" means; an old one with a new question may be stale — name the text you assume, or ask.

## Start from where the user is

- "this page", "what I selected", "where am I", "summarize what I'm reading" → `current_page` with **no arguments**. It returns the page the reader is on, the text last selected with the mouse, and the highlights on that page.
- `reading_state` (no arguments) for the bigger picture: current page and chapter, marks, every highlight with its text, last-read time and device.
- If either tool answers "Several books are open", ask which — or pass the name the user mentioned as `book` (a path substring such as `"Inference"` is enough).
- `list_books` shows what is open and ACTIVE right now versus merely recent; prefer the active one.

## Find before you fetch

- "Where does it say X" → `search` (returns `p.N: matching line`), then `get_pages` for the one to three pages around a hit.
- "Summarize the chapter" → `get_chapter` with the current page (from `current_page`) or a `title` substring.
- Never walk a whole book with `get_pages`; if the user wants everything, tell them `:markdown` in the reader exports it as one file.
- Page markdown carries `<!-- page N -->` markers; diagrams are PNG files in the directory named in the header comment.

## Cite so the user can jump

- Refer to locations as `p.N` — the user types `:N` in the reader to go there. Quote the matching line from `search` when it helps.
- Page numbers are the PDF's 1-based page index, not the printed folio.
- `goto_page` and `select_text` move the user's reader. **Use them only when the user explicitly asks** — "take me there", "show me", "jump to", "select that sentence". Never as a side effect of answering: cite `p.N` and, at most, offer ("want me to jump there?"). With several splits of one book, pick the `[instance N]` from `list_books` via `pid`.

## Selection etiquette

- The selection is the text last copied by a mouse drag; treat "this", "that sentence", "the selected part" as referring to it when present.
- If `current_page` shows no selection, say so rather than guessing which passage is meant.
