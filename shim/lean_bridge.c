/* Runtime bridge: starts the Lean runtime once per process, initializes LadybugDB's worker
 * threads for Lean, and turns the Lean entry points of Marien/Ffi.lean into the plain C API of
 * lean_bridge.h. Compiled with the system C compiler so it uses the same libc as LadybugDB.
 * Prototype: spike/bridge.c. */
#include <lean/lean.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#include "lean_bridge.h"

/* @lat: [[components#Runtime bridge]] */

extern void lean_initialize_runtime_module(void);
extern void lean_initialize_thread(void);
extern lean_object *lean_io_error_to_string(lean_object *err);
extern lean_object *initialize_marien_Marien(uint8_t builtin);

/* Marien/Ffi.lean; every argument is owned. */
extern lean_object *marien_signature(lean_object *, lean_object *);
extern lean_object *marien_init_statements(lean_object *);
extern lean_object *marien_save(lean_object *, lean_object *, lean_object *, lean_object *);
extern lean_object *marien_drop(lean_object *, lean_object *);
extern lean_object *marien_export(lean_object *);
extern lean_object *marien_import(lean_object *, lean_object *, lean_object *);
extern lean_object *marien_v_int(lean_object *);
extern lean_object *marien_v_nat(lean_object *);
extern lean_object *marien_v_int128(uint64_t, uint64_t);
extern lean_object *marien_v_uint128(uint64_t, uint64_t);
extern lean_object *marien_v_float(double);
extern lean_object *marien_v_str(lean_object *);
extern lean_object *marien_v_bool(uint8_t);
extern lean_object *marien_v_null(lean_object *);
extern lean_object *marien_v_list(lean_object *);
extern lean_object *marien_v_struct(lean_object *);
extern lean_object *marien_query_prepare(lean_object *, lean_object *, lean_object *, lean_object *, uint64_t, uint64_t);
extern lean_object *marien_session_scans(lean_object *);
extern lean_object *marien_add_batch(lean_object *, size_t, lean_object *);
extern lean_object *marien_query_start(lean_object *, lean_object *, uint64_t, uint64_t, uint64_t);
extern lean_object *marien_query_step(lean_object *);
extern lean_object *marien_cache_misses(lean_object *);

/* --- Runtime ------------------------------------------------------------------------- */

/* @tg: implements:: [[openspec:extension-runtime#Foreign threads are initialized once]] */
static _Thread_local int thread_ready = 0;
static void ensure_thread(void) {
    if (!thread_ready) {
        lean_initialize_thread();
        thread_ready = 1;
    }
}

static pthread_once_t once = PTHREAD_ONCE_INIT;
static char *init_error = NULL;
static int init_runs = 0;

static char *dup_cstr(const char *s) {
    size_t n = strlen(s) + 1;
    char *r = malloc(n);
    if (r) memcpy(r, s, n);
    return r;
}

/* Lean 4.35 module initializers call lean_initialize(). The toolchain's version (libleancpp)
 * also initializes the Lean compiler package, which Marien never uses and which makes the
 * library 20 times larger (ADR 0022). This definition starts only the runtime; libleancpp is
 * not linked, so it is the only one. */
static int runtime_started = 0;
void lean_initialize(void) {
    if (!runtime_started) {
        runtime_started = 1;
        lean_initialize_runtime_module();
    }
}

static void init_once(void) {
    init_runs++;
    lean_initialize();
    lean_init_task_manager();
    lean_object *res = initialize_marien_Marien(1);
    if (!lean_io_result_is_ok(res)) {
        lean_object *e = lean_io_result_get_error(res);
        lean_inc(e);
        lean_object *s = lean_io_error_to_string(e);
        init_error = dup_cstr(lean_string_cstr(s));
        lean_dec(s);
        lean_dec(res);
        return;
    }
    lean_dec(res);
    lean_io_mark_end_initialization();
    thread_ready = 1;
}

/* @tg: implements:: [[openspec:extension-runtime#Single Lean runtime per process]] */
const char *marien_bridge_init(void) {
    if (getenv("MARIEN_FAIL_INIT")) return "simulated Lean initialization failure";
    pthread_once(&once, init_once);
    return init_error;
}

int marien_bridge_init_runs(void) { return init_runs; }

/* --- Strings ------------------------------------------------------------------------- */

static lean_object *mk_str(const char *s) { return lean_mk_string(s ? s : ""); }

static lean_object *mk_str_n(const char *s, size_t n) {
    return lean_mk_string_unchecked(s, n, lean_utf8_n_strlen(s, n));
}

static marien_str take_str(lean_object *o) {
    marien_str r;
    r.len = lean_string_size(o) - 1;
    r.data = malloc(r.len + 1);
    memcpy(r.data, lean_string_cstr(o), r.len + 1);
    return r;
}

static marien_str c_err(const char *msg) {
    marien_str r;
    r.len = strlen(msg);
    r.data = dup_cstr(msg);
    return r;
}

/* Except String (Array String), consumed. */
static marien_strings take_strings(lean_object *ex) {
    marien_strings out = {{NULL, 0}, 0, NULL};
    lean_object *v = lean_ctor_get(ex, 0);
    if (lean_obj_tag(ex) == 0) {
        out.error = take_str(v);
    } else {
        size_t n = lean_array_size(v);
        out.n = n;
        out.items = calloc(n ? n : 1, sizeof(marien_str));
        for (size_t i = 0; i < n; i++) out.items[i] = take_str(lean_array_get_core(v, i));
    }
    lean_dec(ex);
    return out;
}

static marien_strings array_strings(lean_object *arr) {
    marien_strings out = {{NULL, 0}, 0, NULL};
    size_t n = lean_array_size(arr);
    out.n = n;
    out.items = calloc(n ? n : 1, sizeof(marien_str));
    for (size_t i = 0; i < n; i++) out.items[i] = take_str(lean_array_get_core(arr, i));
    lean_dec(arr);
    return out;
}

void marien_bridge_free_strings(marien_strings *s) {
    free(s->error.data);
    for (size_t i = 0; i < s->n; i++) free(s->items[i].data);
    free(s->items);
    s->error.data = NULL;
    s->items = NULL;
    s->n = 0;
}

/* --- Signature and module store ------------------------------------------------------ */

marien_strings marien_bridge_signature(const char *catalog, const char *table) {
    ensure_thread();
    return take_strings(marien_signature(mk_str(catalog), mk_str(table)));
}

marien_strings marien_bridge_init_statements(void) {
    ensure_thread();
    return array_strings(marien_init_statements(lean_box(0)));
}

marien_strings marien_bridge_save(const char *catalog, const char *modules, const char *name,
                                  const char *source, size_t source_len) {
    ensure_thread();
    return take_strings(marien_save(mk_str(catalog), mk_str(modules), mk_str(name),
                                    mk_str_n(source, source_len)));
}

marien_strings marien_bridge_drop(const char *modules, const char *name) {
    ensure_thread();
    return take_strings(marien_drop(mk_str(modules), mk_str(name)));
}

marien_strings marien_bridge_export(const char *modules) {
    ensure_thread();
    return take_strings(marien_export(mk_str(modules)));
}

marien_strings marien_bridge_import(const char *catalog, const char *modules, const char *bundle,
                                    size_t bundle_len) {
    ensure_thread();
    return take_strings(marien_import(mk_str(catalog), mk_str(modules), mk_str_n(bundle, bundle_len)));
}

/* --- Queries ------------------------------------------------------------------------- */

struct marien_session { lean_object *obj; };
struct marien_run { lean_object *obj; };
struct marien_values { lean_object *arr; };

marien_session *marien_bridge_prepare(const char *catalog, const char *modules, const char *name,
                                      const char *goal, uint64_t max_facts, uint64_t cache_size,
                                      marien_str *error) {
    ensure_thread();
    lean_object *res = marien_query_prepare(mk_str(catalog), mk_str(modules), mk_str(name),
                                            mk_str(goal), max_facts, cache_size);
    if (!lean_io_result_is_ok(res)) {
        lean_dec(res);
        *error = c_err("marien: query preparation raised an IO error");
        return NULL;
    }
    lean_object *ex = lean_io_result_take_value(res);
    lean_object *v = lean_ctor_get(ex, 0);
    if (lean_obj_tag(ex) == 0) {
        *error = take_str(v);
        lean_dec(ex);
        return NULL;
    }
    lean_inc(v);
    lean_dec(ex);
    marien_session *s = malloc(sizeof *s);
    s->obj = v;
    return s;
}

size_t marien_bridge_scan_count(marien_session *s) {
    ensure_thread();
    lean_inc(s->obj);
    lean_object *scans = marien_session_scans(s->obj);
    size_t n = lean_array_size(scans);
    lean_dec(scans);
    return n;
}

marien_strings marien_bridge_scan(marien_session *s, size_t i) {
    ensure_thread();
    lean_inc(s->obj);
    lean_object *scans = marien_session_scans(s->obj);
    lean_object *one = lean_array_get_core(scans, i);
    lean_inc(one);
    lean_dec(scans);
    return array_strings(one);
}

marien_values *marien_bridge_values_new(size_t capacity) {
    ensure_thread();
    marien_values *v = malloc(sizeof *v);
    v->arr = lean_mk_empty_array_with_capacity(lean_box(capacity));
    return v;
}

static void push(marien_values *v, lean_object *x) { v->arr = lean_array_push(v->arr, x); }

void marien_bridge_push_int64(marien_values *v, int64_t x) { push(v, marien_v_int(lean_int64_to_int(x))); }
void marien_bridge_push_uint64(marien_values *v, uint64_t x) { push(v, marien_v_nat(lean_uint64_to_nat(x))); }
void marien_bridge_push_int128(marien_values *v, uint64_t hi, uint64_t lo) { push(v, marien_v_int128(hi, lo)); }
void marien_bridge_push_uint128(marien_values *v, uint64_t hi, uint64_t lo) { push(v, marien_v_uint128(hi, lo)); }
void marien_bridge_push_double(marien_values *v, double x) { push(v, marien_v_float(x)); }
void marien_bridge_push_bool(marien_values *v, int b) { push(v, marien_v_bool(b ? 1 : 0)); }
void marien_bridge_push_str(marien_values *v, const char *data, size_t len) { push(v, marien_v_str(mk_str_n(data, len))); }
void marien_bridge_push_null(marien_values *v) { push(v, marien_v_null(lean_box(0))); }

void marien_bridge_push_list(marien_values *v, marien_values *items) {
    push(v, marien_v_list(items->arr));
    free(items);
}

void marien_bridge_push_struct(marien_values *v, marien_values *fields) {
    push(v, marien_v_struct(fields->arr));
    free(fields);
}

void marien_bridge_free_values(marien_values *v) {
    if (!v) return;
    ensure_thread();
    lean_dec(v->arr);
    free(v);
}

marien_str marien_bridge_add_batch(marien_session **s, size_t scan, marien_values **cols, size_t ncols) {
    ensure_thread();
    marien_str none = {NULL, 0};
    lean_object *arr = lean_mk_empty_array_with_capacity(lean_box(ncols));
    for (size_t i = 0; i < ncols; i++) {
        arr = lean_array_push(arr, cols[i]->arr);
        free(cols[i]);
        cols[i] = NULL;
    }
    lean_inc((*s)->obj); /* keep the old session valid if the batch fails */
    lean_object *ex = marien_add_batch((*s)->obj, scan, arr);
    lean_object *v = lean_ctor_get(ex, 0);
    if (lean_obj_tag(ex) == 0) {
        marien_str e = take_str(v);
        lean_dec(ex);
        return e;
    }
    lean_inc(v);
    lean_dec(ex);
    lean_dec((*s)->obj);
    (*s)->obj = v;
    return none;
}

marien_run *marien_bridge_start(marien_session *s, const char *goal, uint64_t fuel,
                                uint64_t slice_steps, uint64_t max_solutions, marien_str *error) {
    ensure_thread();
    lean_object *ex = marien_query_start(s->obj, mk_str(goal), fuel, slice_steps, max_solutions);
    free(s);
    lean_object *v = lean_ctor_get(ex, 0);
    if (lean_obj_tag(ex) == 0) {
        *error = take_str(v);
        lean_dec(ex);
        return NULL;
    }
    lean_inc(v);
    lean_dec(ex);
    marien_run *r = malloc(sizeof *r);
    r->obj = v;
    return r;
}

/* @tg: implements:: [[openspec:rule-execution#Fuel-sliced execution]] */
int marien_bridge_step(marien_run **r, marien_strings *bindings, marien_str *error) {
    ensure_thread();
    lean_object *st = marien_query_step((*r)->obj);
    /* CStep: solution (bindings, next) | paused next | error msg | exhausted | stopped */
    if (lean_is_scalar(st)) {
        free(*r);
        *r = NULL;
        return lean_unbox(st) == 3 ? MARIEN_STEP_EXHAUSTED : MARIEN_STEP_STOPPED;
    }
    unsigned tag = lean_obj_tag(st);
    if (tag == 0) {
        lean_object *bs = lean_ctor_get(st, 0);
        lean_object *next = lean_ctor_get(st, 1);
        lean_inc(bs);
        lean_inc(next);
        lean_dec(st);
        *bindings = array_strings(bs);
        (*r)->obj = next;
        return MARIEN_STEP_SOLUTION;
    }
    if (tag == 1) {
        lean_object *next = lean_ctor_get(st, 0);
        lean_inc(next);
        lean_dec(st);
        (*r)->obj = next;
        return MARIEN_STEP_PAUSED;
    }
    *error = take_str(lean_ctor_get(st, 0));
    lean_dec(st);
    free(*r);
    *r = NULL;
    return MARIEN_STEP_ERROR;
}

void marien_bridge_free_session(marien_session *s) {
    if (!s) return;
    ensure_thread();
    lean_dec(s->obj);
    free(s);
}

void marien_bridge_free_run(marien_run *r) {
    if (!r) return;
    ensure_thread();
    lean_dec(r->obj);
    free(r);
}

uint64_t marien_bridge_cache_misses(void) {
    ensure_thread();
    lean_object *res = marien_cache_misses(lean_box(0));
    uint64_t n = lean_unbox_uint64(lean_io_result_get_value(res));
    lean_dec(res);
    return n;
}
