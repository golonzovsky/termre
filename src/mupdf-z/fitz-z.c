#include "fitz-z.h"
#include "mupdf/pdf.h"
#include <stdlib.h>
#include <string.h>

fz_document *fz_open_document_z(fz_context *ctx, const char *filename) {
  fz_document *doc = NULL;
  fz_try(ctx) { doc = fz_open_document(ctx, filename); }
  fz_catch(ctx) {}
  return doc;
}

int fz_count_pages_z(fz_context *ctx, fz_document *doc) {
  int count = 0;
  fz_try(ctx) { count = fz_count_pages(ctx, doc); }
  fz_catch(ctx) {}
  return count;
}

fz_page *fz_load_page_z(fz_context *ctx, fz_document *doc, int page_number) {
  fz_page *page = NULL;
  fz_try(ctx) { page = fz_load_page(ctx, doc, page_number); }
  fz_catch(ctx) {}
  return page;
}

fz_link *fz_load_links_z(fz_context *ctx, fz_page *page) {
  fz_link *links = NULL;
  fz_try(ctx) { links = fz_load_links(ctx, page); }
  fz_catch(ctx) {}
  return links;
}

int fz_resolve_link_target_z(fz_context *ctx, fz_document *doc, const char *uri, float *yp) {
  int page = -1;
  float x = 0, y = 0;
  fz_try(ctx) {
    fz_location loc = fz_resolve_link(ctx, doc, uri, &x, &y);
    page = fz_page_number_from_location(ctx, doc, loc);
  }
  fz_catch(ctx) {}
  if (yp) *yp = y;
  return page;
}

static void walk_outline(fz_outline *node, int depth, void *userdata, fz_outline_visit_fn cb) {
  fz_outline *o = node;
  while (o) {
    cb(userdata, o->title ? o->title : "", depth, o->uri ? o->uri : "");
    if (o->down && depth < 32) walk_outline(o->down, depth + 1, userdata, cb);
    o = o->next;
  }
}

void fz_walk_outline_z(fz_context *ctx, fz_document *doc, void *userdata, fz_outline_visit_fn cb) {
  fz_outline *root = NULL;
  fz_try(ctx) { root = fz_load_outline(ctx, doc); }
  fz_catch(ctx) { return; }
  if (!root) return;
  walk_outline(root, 0, userdata, cb);
  fz_drop_outline(ctx, root);
}

#define EXTRACT_MAX_TEXT_BBOXES 128
#define EXTRACT_MAX_LINE_CHARS  4096

typedef struct {
  fz_extract_event_fn on_event;
  void *event_userdata;
  fz_page *page;
  const char *image_dir;
  fz_rect mediabox;
  fz_rect pending_rect;
  fz_rect text_bboxes[EXTRACT_MAX_TEXT_BBOXES];
  fz_char_z line_buf[EXTRACT_MAX_LINE_CHARS];
  int text_bbox_count;
  int pending_active;
  int image_counter;
  float scale;
  int black;
  int white;
} extract_state;

static float md_rect_area(fz_rect r) {
  float w = r.x1 - r.x0;
  float h = r.y1 - r.y0;
  return (w > 0 && h > 0) ? w * h : 0;
}

static float md_intersect_area(fz_rect a, fz_rect b) {
  float x0 = a.x0 > b.x0 ? a.x0 : b.x0;
  float y0 = a.y0 > b.y0 ? a.y0 : b.y0;
  float x1 = a.x1 < b.x1 ? a.x1 : b.x1;
  float y1 = a.y1 < b.y1 ? a.y1 : b.y1;
  if (x1 <= x0 || y1 <= y0) return 0;
  return (x1 - x0) * (y1 - y0);
}

// Fraction of `region` covered by collected text bboxes. Used to decide whether
// a vector region is "text-heavy" (a decorative box around a paragraph — skip
// the raster, keep the text) or sparse (a real diagram with at most a few
// labels — render the raster).
static float md_text_coverage(extract_state *st, fz_rect region) {
  float region_area = md_rect_area(region);
  if (region_area <= 0) return 0;
  float covered = 0;
  for (int i = 0; i < st->text_bbox_count; i++) {
    covered += md_intersect_area(st->text_bboxes[i], region);
  }
  return covered / region_area;
}

static void md_collect_text_bboxes(fz_stext_block *blocks, fz_rect *out, int *count, int cap) {
  for (fz_stext_block *b = blocks; b; b = b->next) {
    if (b->type == FZ_STEXT_BLOCK_TEXT) {
      if (*count < cap) out[(*count)++] = b->bbox;
    } else if (b->type == FZ_STEXT_BLOCK_STRUCT && b->u.s.down) {
      md_collect_text_bboxes(b->u.s.down->first_block, out, count, cap);
    }
  }
}

static int md_is_bold(fz_context *ctx, fz_stext_char *c) {
  if (c->flags & FZ_STEXT_BOLD) return 1;
  return c->font && fz_font_is_bold(ctx, c->font);
}
static int md_is_italic(fz_context *ctx, fz_stext_char *c) {
  return c->font && fz_font_is_italic(ctx, c->font);
}
static int md_name_contains_ci(const char *name, const char *needle) {
  if (!name || !needle) return 0;
  size_t nl = strlen(needle);
  for (const char *p = name; *p; p++) {
    size_t i = 0;
    while (i < nl && p[i]) {
      char a = p[i], b = needle[i];
      if (a >= 'A' && a <= 'Z') a += 32;
      if (b >= 'A' && b <= 'Z') b += 32;
      if (a != b) break;
      i++;
    }
    if (i == nl) return 1;
  }
  return 0;
}

static int md_is_mono(fz_context *ctx, fz_stext_char *c) {
  if (!c->font) return 0;
  if (fz_font_is_monospaced(ctx, c->font)) return 1;
  // PDF embedding often strips the monospaced flag; fall back to font-name match.
  const char *name = fz_font_name(ctx, c->font);
  return md_name_contains_ci(name, "mono") ||
         md_name_contains_ci(name, "courier") ||
         md_name_contains_ci(name, "consolas") ||
         md_name_contains_ci(name, "menlo") ||
         md_name_contains_ci(name, "lettergothic") ||
         md_name_contains_ci(name, "typewriter") ||
         md_name_contains_ci(name, "cmtt");
}

static void md_collect_sizes(fz_stext_block *blocks, int counts[], int cap) {
  for (fz_stext_block *b = blocks; b; b = b->next) {
    if (b->type == FZ_STEXT_BLOCK_TEXT) {
      for (fz_stext_line *l = b->u.t.first_line; l; l = l->next) {
        for (fz_stext_char *c = l->first_char; c; c = c->next) {
          if (c->c <= 32) continue;
          int idx = (int)(c->size + 0.5f);
          if (idx >= 0 && idx < cap) counts[idx]++;
        }
      }
    } else if (b->type == FZ_STEXT_BLOCK_STRUCT && b->u.s.down) {
      md_collect_sizes(b->u.s.down->first_block, counts, cap);
    }
  }
}

static float md_body_size(fz_stext_page *page) {
  int counts[200] = {0};
  md_collect_sizes(page->first_block, counts, 200);
  int best_idx = 10, best = 0;
  for (int i = 4; i < 200; i++) {
    if (counts[i] > best) { best = counts[i]; best_idx = i; }
  }
  return (float)best_idx;
}

// Emit a text line as a structured event by copying its chars into the scratch buffer.
static void extract_emit_line(fz_context *ctx, extract_state *st, fz_stext_line *l) {
  int n = 0;
  for (fz_stext_char *c = l->first_char; c && n < EXTRACT_MAX_LINE_CHARS; c = c->next) {
    fz_char_z *out = &st->line_buf[n++];
    out->codepoint = (unsigned int)c->c;
    out->bold = (unsigned char)md_is_bold(ctx, c);
    out->italic = (unsigned char)md_is_italic(ctx, c);
    out->mono = (unsigned char)md_is_mono(ctx, c);
    out->_pad = 0;
    out->size = c->size;
    out->origin_y = c->origin.y;
  }
  st->on_event(st->event_userdata, FZ_EXTRACT_EVENT_LINE, st->line_buf, n, NULL);
}

static void extract_emit_block_end(extract_state *st) {
  st->on_event(st->event_userdata, FZ_EXTRACT_EVENT_BLOCK_END, NULL, 0, NULL);
}

static void extract_flush_pending(fz_context *ctx, extract_state *st) {
  if (!st->pending_active) return;
  fz_rect r = st->pending_rect;
  st->pending_active = 0;
  st->pending_rect = fz_empty_rect;

  float w = r.x1 - r.x0;
  float h = r.y1 - r.y0;
  if (w < 30 || h < 30) return; // single rule / glyph trace
  float page_w = st->mediabox.x1 - st->mediabox.x0;
  float page_h = st->mediabox.y1 - st->mediabox.y0;
  if (page_w > 0 && page_h > 0 && w > 0.95f * page_w && h > 0.95f * page_h) return;
  if (md_text_coverage(st, r) > 0.25f) return; // text-heavy region — caller keeps copyable text

  st->image_counter++;
  char img_basename[64];
  snprintf(img_basename, sizeof(img_basename), "img%d.png", st->image_counter);
  char img_path[1024];
  snprintf(img_path, sizeof(img_path), "%s/%s", st->image_dir, img_basename);

  fz_pixmap *pix = NULL;
  fz_device *dev = NULL;
  int saved_ok = 0;
  fz_try(ctx) {
    float scale = st->scale > 0 ? st->scale : 4.0f;
    fz_matrix ctm = fz_pre_translate(fz_scale(scale, scale), -r.x0, -r.y0);
    fz_irect ibox = fz_make_irect(0, 0, (int)(w * scale + 0.5f), (int)(h * scale + 0.5f));
    pix = fz_new_pixmap_with_bbox(ctx, fz_device_rgb(ctx), ibox, NULL, 0);
    fz_clear_pixmap_with_value(ctx, pix, 0xff);
    dev = fz_new_draw_device(ctx, ctm, pix);
    fz_run_page(ctx, st->page, dev, fz_identity, NULL);
    fz_close_device(ctx, dev);
    fz_tint_pixmap(ctx, pix, st->black, st->white);
    fz_save_pixmap_as_png(ctx, pix, img_path);
    saved_ok = 1;
  }
  fz_always(ctx) {
    if (dev) fz_drop_device(ctx, dev);
    if (pix) fz_drop_pixmap(ctx, pix);
  }
  fz_catch(ctx) { saved_ok = 0; }

  if (saved_ok) {
    st->on_event(st->event_userdata, FZ_EXTRACT_EVENT_IMAGE, NULL, 0, img_basename);
  } else {
    st->image_counter--;
  }
}

static void extract_walk(fz_context *ctx, extract_state *st, fz_stext_block *blocks) {
  float page_h = st->mediabox.y1 - st->mediabox.y0;
  float footer_y = (page_h > 0) ? st->mediabox.y1 - 0.05f * page_h : 0;
  for (fz_stext_block *b = blocks; b; b = b->next) {
    if (b->type == FZ_STEXT_BLOCK_TEXT) {
      if (page_h > 0 && b->bbox.y0 >= footer_y) continue;
      extract_flush_pending(ctx, st);
      for (fz_stext_line *l = b->u.t.first_line; l; l = l->next) {
        extract_emit_line(ctx, st, l);
      }
      extract_emit_block_end(st);
    } else if (b->type == FZ_STEXT_BLOCK_STRUCT && b->u.s.down) {
      extract_walk(ctx, st, b->u.s.down->first_block);
    } else if (b->type == FZ_STEXT_BLOCK_IMAGE || b->type == FZ_STEXT_BLOCK_VECTOR) {
      if (page_h > 0 && b->bbox.y0 >= footer_y) continue;
      if (!st->pending_active) {
        st->pending_rect = b->bbox;
        st->pending_active = 1;
      } else {
        st->pending_rect = fz_union_rect(st->pending_rect, b->bbox);
      }
    }
  }
  extract_flush_pending(ctx, st);
}

int fz_extract_pages_z(
    fz_context *ctx, fz_document *doc, int start_page, int end_page,
    float scale, int black, int white,
    const char *image_dir_abs,
    fz_extract_event_fn on_event, void *event_userdata,
    fz_progress_fn on_progress, void *progress_userdata) {
  extract_state st = {
    .on_event = on_event,
    .event_userdata = event_userdata,
    .image_dir = image_dir_abs,
    .scale = scale,
    .black = black,
    .white = white,
  };

  fz_stext_options opts = { .flags = FZ_STEXT_PRESERVE_IMAGES | FZ_STEXT_COLLECT_VECTORS | FZ_STEXT_DEHYPHENATE };
  int ok = 0;
  fz_try(ctx) {
    int total = end_page - start_page;
    for (int p = start_page; p < end_page; p++) {
      if (on_progress) on_progress(progress_userdata, p - start_page, total);
      fz_page *page = NULL;
      fz_stext_page *stext = NULL;
      fz_try(ctx) {
        page = fz_load_page(ctx, doc, p);
        stext = fz_new_stext_page_from_page(ctx, page, &opts);
        st.page = page;
        st.mediabox = stext->mediabox;
        st.pending_active = 0;
        st.text_bbox_count = 0;
        md_collect_text_bboxes(stext->first_block, st.text_bboxes, &st.text_bbox_count, EXTRACT_MAX_TEXT_BBOXES);

        // Surface the body-font size so the caller can size headings.
        fz_char_z body = { .codepoint = 0, .size = md_body_size(stext) };
        on_event(event_userdata, FZ_EXTRACT_EVENT_PAGE_START, &body, 1, NULL);

        extract_walk(ctx, &st, stext->first_block);

        on_event(event_userdata, FZ_EXTRACT_EVENT_PAGE_END, NULL, 0, NULL);
      }
      fz_always(ctx) {
        if (stext) fz_drop_stext_page(ctx, stext);
        if (page) fz_drop_page(ctx, page);
      }
      fz_catch(ctx) {
        // Skip this page on error.
      }
    }
    if (on_progress) on_progress(progress_userdata, total, total);
    ok = 1;
  }
  fz_catch(ctx) { ok = 0; }
  return ok;
}

int fz_page_content_bbox_z(fz_context *ctx, fz_page *page, fz_rect *out) {
  int ok = 0;
  fz_device *dev = NULL;
  fz_rect bbox = fz_empty_rect;
  fz_try(ctx) {
    dev = fz_new_bbox_device(ctx, &bbox);
    fz_run_page(ctx, page, dev, fz_identity, NULL);
    fz_close_device(ctx, dev);
    *out = bbox;
    ok = 1;
  }
  fz_always(ctx) { if (dev) fz_drop_device(ctx, dev); }
  fz_catch(ctx) { ok = 0; }
  return ok;
}

int fz_page_text_bbox_z(fz_context *ctx, fz_document *doc, int page_number, fz_rect *out) {
  int ok = 0;
  fz_page *page = NULL;
  fz_stext_page *st = NULL;
  fz_try(ctx) {
    page = fz_load_page(ctx, doc, page_number);
    fz_rect pb = fz_bound_page(ctx, page);
    fz_stext_options opts = {0};
    st = fz_new_stext_page_from_page(ctx, page, &opts);
    fz_rect acc = fz_empty_rect;
    int found = 0;
    for (fz_stext_block *b = st->first_block; b; b = b->next) {
      if (b->type != FZ_STEXT_BLOCK_TEXT) continue;
      // skip blocks entirely outside the visible page (clipped/bleed text)
      if (b->bbox.x1 < pb.x0 || b->bbox.x0 > pb.x1 || b->bbox.y1 < pb.y0 || b->bbox.y0 > pb.y1) continue;
      fz_rect r = fz_intersect_rect(b->bbox, pb);
      acc = found ? fz_union_rect(acc, r) : r;
      found = 1;
    }
    if (found) {
      *out = acc;
      ok = 1;
    }
  }
  fz_always(ctx) {
    if (st) fz_drop_stext_page(ctx, st);
    if (page) fz_drop_page(ctx, page);
  }
  fz_catch(ctx) { ok = 0; }
  return ok;
}

int fz_search_page_z(fz_context *ctx, fz_document *doc, int page_number, const char *needle, fz_quad *quads, int max_quads) {
  int count = 0;
  fz_try(ctx) { count = fz_search_page_number(ctx, doc, page_number, needle, NULL, quads, max_quads); }
  fz_catch(ctx) { count = 0; }
  return count;
}

typedef struct {
  fz_stext_line *line;
  float d;
} line_find;

static void find_line_at(fz_stext_block *blocks, float x, float y, line_find *bf) {
  for (fz_stext_block *b = blocks; b; b = b->next) {
    if (b->type == FZ_STEXT_BLOCK_TEXT) {
      for (fz_stext_line *l = b->u.t.first_line; l; l = l->next) {
        fz_rect r = l->bbox;
        if (x >= r.x0 && x <= r.x1 && y >= r.y0 && y <= r.y1) {
          bf->line = l;
          bf->d = 0;
          return;
        }
        float cy = (r.y0 + r.y1) * 0.5f;
        float dy = cy > y ? cy - y : y - cy;
        if (dy < bf->d) {
          bf->d = dy;
          bf->line = l;
        }
      }
    } else if (b->type == FZ_STEXT_BLOCK_STRUCT && b->u.s.down) {
      find_line_at(b->u.s.down->first_block, x, y, bf);
      if (bf->d == 0) return;
    }
  }
}

int fz_line_text_at_z(fz_context *ctx, fz_document *doc, int page_number, float x, float y, char *out, int out_size) {
  int written = 0;
  fz_page *page = NULL;
  fz_stext_page *st = NULL;
  fz_try(ctx) {
    page = fz_load_page(ctx, doc, page_number);
    fz_stext_options opts = {0};
    st = fz_new_stext_page_from_page(ctx, page, &opts);
    line_find bf = { NULL, 24.0f };
    find_line_at(st->first_block, x, y, &bf);
    if (bf.line) {
      int n = 0;
      for (fz_stext_char *c = bf.line->first_char; c; c = c->next) {
        char buf[8];
        int len = fz_runetochar(buf, c->c);
        if (n + len >= out_size) break;
        memcpy(out + n, buf, len);
        n += len;
      }
      out[n] = 0;
      written = n;
    }
  }
  fz_always(ctx) {
    if (st) fz_drop_stext_page(ctx, st);
    if (page) fz_drop_page(ctx, page);
  }
  fz_catch(ctx) { written = 0; }
  return written;
}

int fz_selection_z(fz_context *ctx, fz_document *doc, int page_number,
                   float ax, float ay, float bx, float by,
                   fz_quad *quads, int max_quads, int *quad_count,
                   char *text_out, int text_out_size) {
  int written = 0;
  fz_page *page = NULL;
  fz_stext_page *st = NULL;
  char *sel = NULL;
  *quad_count = 0;
  fz_try(ctx) {
    page = fz_load_page(ctx, doc, page_number);
    fz_stext_options opts = {0};
    st = fz_new_stext_page_from_page(ctx, page, &opts);
    fz_point a = fz_make_point(ax, ay);
    fz_point b = fz_make_point(bx, by);
    fz_snap_selection(ctx, st, &a, &b, FZ_SELECT_CHARS);
    *quad_count = fz_highlight_selection(ctx, st, a, b, quads, max_quads);
    sel = fz_copy_selection(ctx, st, a, b, 0);
    if (sel) {
      int len = (int)strlen(sel);
      if (len >= text_out_size) len = text_out_size - 1;
      memcpy(text_out, sel, len);
      text_out[len] = 0;
      written = len;
    }
  }
  fz_always(ctx) {
    if (sel) fz_free(ctx, sel);
    if (st) fz_drop_stext_page(ctx, st);
    if (page) fz_drop_page(ctx, page);
  }
  fz_catch(ctx) {
    written = 0;
    *quad_count = 0;
  }
  return written;
}

int fz_save_pixmap_png_z(fz_context *ctx, fz_pixmap *pix, const char *path) {
  int ok = 0;
  fz_try(ctx) {
    fz_save_pixmap_as_png(ctx, pix, path);
    ok = 1;
  }
  fz_catch(ctx) { ok = 0; }
  return ok;
}

unsigned char *fz_pixmap_png_z(fz_context *ctx, fz_pixmap *pix, size_t *out_len) {
  fz_buffer *buf = NULL;
  unsigned char *out = NULL;
  *out_len = 0;
  fz_try(ctx) {
    buf = fz_new_buffer_from_pixmap_as_png(ctx, pix, fz_default_color_params);
    unsigned char *data;
    size_t len = fz_buffer_storage(ctx, buf, &data);
    out = malloc(len);
    if (out) {
      memcpy(out, data, len);
      *out_len = len;
    }
  }
  fz_always(ctx) {
    if (buf) fz_drop_buffer(ctx, buf);
  }
  fz_catch(ctx) {
    if (out) {
      free(out);
      out = NULL;
    }
    *out_len = 0;
  }
  return out;
}

int fz_pdf_id_hex_z(fz_context *ctx, fz_document *doc, char *out, int out_size) {
  int written = 0;
  fz_try(ctx) {
    pdf_document *pdoc = pdf_specifics(ctx, doc);
    if (!pdoc) fz_throw(ctx, FZ_ERROR_GENERIC, "not a pdf");
    pdf_obj *trailer = pdf_trailer(ctx, pdoc);
    if (!trailer) fz_throw(ctx, FZ_ERROR_GENERIC, "no trailer");
    pdf_obj *id_array = pdf_dict_gets(ctx, trailer, "ID");
    if (!id_array) fz_throw(ctx, FZ_ERROR_GENERIC, "no /ID");
    pdf_obj *first = pdf_array_get(ctx, id_array, 0);
    if (!first) fz_throw(ctx, FZ_ERROR_GENERIC, "no /ID[0]");
    size_t len = 0;
    const char *bytes = pdf_to_string(ctx, first, &len);
    if (!bytes || len == 0) fz_throw(ctx, FZ_ERROR_GENERIC, "empty /ID");
    int need = (int)(len * 2);
    if (need + 1 > out_size) fz_throw(ctx, FZ_ERROR_GENERIC, "buf too small");
    static const char hex[] = "0123456789abcdef";
    for (size_t i = 0; i < len; i++) {
      out[2 * i] = hex[(unsigned char)bytes[i] >> 4];
      out[2 * i + 1] = hex[(unsigned char)bytes[i] & 0xF];
    }
    out[need] = 0;
    written = need;
  }
  fz_catch(ctx) { written = 0; }
  return written;
}

int fz_export_cropped_z(fz_context *ctx, const char *src_path, const char *dst_path,
                        float left, float right, float top, float bottom, int odd_shift_x,
                        int keep_id) {
  pdf_document *pdf = NULL;
  int ok = 0;
  fz_var(pdf);
  fz_var(ok);
  fz_try(ctx) {
    pdf = pdf_open_document(ctx, src_path);
    int n = pdf_count_pages(ctx, pdf);
    for (int i = 0; i < n; i++) {
      pdf_obj *pageobj = pdf_lookup_page_obj(ctx, pdf, i);
      fz_rect mediabox;
      fz_matrix ctm;
      pdf_page_obj_transform(ctx, pageobj, &mediabox, &ctm);
      fz_rect bound = fz_transform_rect(mediabox, ctm);
      float shift = (i % 2 == 1) ? (float)odd_shift_x : 0.0f;
      fz_rect want;
      want.x0 = bound.x0 + left - shift;
      want.x1 = bound.x1 - right - shift;
      want.y0 = bound.y0 + top;
      want.y1 = bound.y1 - bottom;
      if (want.x1 <= want.x0 || want.y1 <= want.y0) continue;
      // Back through the page transform so rotation and the y-flip are honored.
      fz_rect box = fz_transform_rect(want, fz_invert_matrix(ctm));
      pdf_dict_put_rect(ctx, pageobj, PDF_NAME(MediaBox), box);
      pdf_dict_put_rect(ctx, pageobj, PDF_NAME(CropBox), box);
    }
    // Unless the caller wants the same identity (in-place :override), the
    // copy must not share the source's /ID: the viewer keys saved state
    // (position, crop, oddx) on it, and inherited state would re-apply the
    // crop on top of the baked-in one. Without an ID the viewer falls back
    // to a content hash, which is unique to the exported file.
    if (!keep_id) pdf_dict_del(ctx, pdf_trailer(ctx, pdf), PDF_NAME(ID));
    pdf_write_options opts = pdf_default_write_options;
    pdf_save_document(ctx, pdf, dst_path, &opts);
    ok = 1;
  }
  fz_always(ctx) { pdf_drop_document(ctx, pdf); }
  fz_catch(ctx) { ok = 0; }
  return ok;
}

#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>

int fz_pixmap_to_shm_z(fz_context *ctx, fz_pixmap *pix, const char *name) {
  int w = fz_pixmap_width(ctx, pix);
  int h = fz_pixmap_height(ctx, pix);
  int stride = fz_pixmap_stride(ctx, pix);
  unsigned char *samples = fz_pixmap_samples(ctx, pix);
  if (w <= 0 || h <= 0 || !samples || fz_pixmap_components(ctx, pix) != 3) return 0;
  size_t row = (size_t)w * 3;
  size_t size = row * (size_t)h;
  int fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600);
  if (fd < 0) return 0;
  if (ftruncate(fd, (off_t)size) != 0) {
    close(fd);
    shm_unlink(name);
    return 0;
  }
  unsigned char *dst = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  close(fd);
  if (dst == MAP_FAILED) {
    shm_unlink(name);
    return 0;
  }
  for (int y = 0; y < h; y++)
    memcpy(dst + (size_t)y * row, samples + (size_t)y * (size_t)stride, row);
  munmap(dst, size);
  return 1;
}
