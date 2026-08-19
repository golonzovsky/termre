#include "mupdf/fitz.h"

fz_document *fz_open_document_z(fz_context *ctx, const char *filename);
int fz_count_pages_z(fz_context *ctx, fz_document *doc);
fz_page *fz_load_page_z(fz_context *ctx, fz_document *doc, int page_number);
fz_link *fz_load_links_z(fz_context *ctx, fz_page *page);
// Resolves a link URI to a page index, also outputting the destination y in PDF units (0 if unknown).
int fz_resolve_link_target_z(fz_context *ctx, fz_document *doc, const char *uri, float *yp);
// Walks the document outline, invoking cb for each entry in pre-order.
typedef void (*fz_outline_visit_fn)(void *userdata, const char *title, int depth, const char *uri);
void fz_walk_outline_z(fz_context *ctx, fz_document *doc, void *userdata, fz_outline_visit_fn cb);
// Writes hex of the first /ID string into out (size out_size). Returns length on success, 0 on missing.
int fz_pdf_id_hex_z(fz_context *ctx, fz_document *doc, char *out, int out_size);
// Computes the tight bounding box of all drawn content on a page. Returns 1 on success.
int fz_page_content_bbox_z(fz_context *ctx, fz_page *page, fz_rect *out);
// Union bbox of the page's text blocks only (rules/images/decoration ignored),
// clipped to the page bound. Returns 1 if any text was found.
int fz_page_text_bbox_z(fz_context *ctx, fz_document *doc, int page_number, fz_rect *out);
// Searches one page for needle (case-insensitive). Fills up to max_quads hit quads;
// returns the hit count (0 on error or no match).
int fz_search_page_z(fz_context *ctx, fz_document *doc, int page_number, const char *needle, fz_quad *quads, int max_quads);
// UTF-8 text of the stext line containing (or nearest to) point (x,y) on the page,
// written NUL-terminated into out. Returns the byte length (0 if no line nearby).
int fz_line_text_at_z(fz_context *ctx, fz_document *doc, int page_number, float x, float y, char *out, int out_size);
// Saves the pixmap as a PNG file at path. Returns 1 on success.
int fz_save_pixmap_png_z(fz_context *ctx, fz_pixmap *pix, const char *path);
// PNG-encodes the pixmap into a malloc'd buffer (caller frees with free()).
// Returns NULL on error; *out_len receives the byte length.
unsigned char *fz_pixmap_png_z(fz_context *ctx, fz_pixmap *pix, size_t *out_len);
// Text selection between points a and b, snapped to characters. Fills up to
// max_quads highlight quads (count in *quad_count) and writes the selected text
// NUL-terminated into text_out. Returns the text byte length.
int fz_selection_z(fz_context *ctx, fz_document *doc, int page_number,
                   float ax, float ay, float bx, float by,
                   fz_quad *quads, int max_quads, int *quad_count,
                   char *text_out, int text_out_size);
// Streaming-style page extractor. The C side walks mupdf's stext, filters footers and
// diagram-vs-text regions, rasterizes vector diagrams to PNG, and surfaces structured events
// to the Zig caller, which is responsible for all markdown formatting.

typedef struct {
    unsigned int codepoint;
    unsigned char bold;
    unsigned char italic;
    unsigned char mono;
    unsigned char _pad;
    float size;
    float origin_y; // baseline y in PDF coords (caller uses this for superscript detection)
} fz_char_z;

// Event kinds delivered to fz_extract_event_fn. The `chars`/`n` payload is non-NULL for LINE
// only; the `str` payload is non-NULL for IMAGE (relative filename of the rendered PNG).
enum {
    FZ_EXTRACT_EVENT_PAGE_START = 0, // chars[0].size carries the body-font size for this page
    FZ_EXTRACT_EVENT_LINE = 1,       // one text line; chars[0..n] is the line content
    FZ_EXTRACT_EVENT_BLOCK_END = 2,  // paragraph boundary
    FZ_EXTRACT_EVENT_IMAGE = 3,      // a diagram PNG was written; str is its basename
    FZ_EXTRACT_EVENT_PAGE_END = 4,
};

typedef void (*fz_extract_event_fn)(void *userdata, int kind, const fz_char_z *chars, int n, const char *str);
typedef void (*fz_progress_fn)(void *userdata, int current, int total);

// Walks pages [start_page, end_page). For each text line emits FZ_EXTRACT_EVENT_LINE; between
// blocks emits BLOCK_END; for non-text regions worth rendering, writes `<image_dir_abs>/img<N>.png`
// and emits IMAGE with the basename `img<N>.png`. `scale` is pixels-per-PDF-point for diagrams.
// `(black, white)` tints diagrams; pass (0x000000, 0xffffff) for identity. `on_progress` may be NULL.
int fz_extract_pages_z(
    fz_context *ctx, fz_document *doc, int start_page, int end_page,
    float scale, int black, int white,
    const char *image_dir_abs,
    fz_extract_event_fn on_event, void *event_userdata,
    fz_progress_fn on_progress, void *progress_userdata);

// Writes a copy of the PDF at src_path to dst_path with each page's
// MediaBox/CropBox set to the crop window: margins inset in PDF points, and
// the window shifted by -odd_shift_x on odd (0-based) pages, matching the
// viewer's aligned-space crop. Lossless (content untouched). keep_id=0 strips
// the trailer /ID so the copy gets its own saved-state identity; keep_id=1
// preserves it (for in-place override). Returns 1 on success.
int fz_export_cropped_z(fz_context *ctx, const char *src_path, const char *dst_path,
                        float left, float right, float top, float bottom, int odd_shift_x,
                        int keep_id);

// Copies the pixmap's RGB rows (stride compacted) into a fresh POSIX shared
// memory object `name` for kitty t=s transfer; the terminal unlinks it after
// reading. Returns 1 on success.
int fz_pixmap_to_shm_z(fz_context *ctx, fz_pixmap *pix, const char *name);
