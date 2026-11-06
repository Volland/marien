/* C interface between Marien's C++ shim and its Lean code (Marien/Ffi.lean).
 *
 * Only marien_bridge_* symbols cross from the Lean side of the library to the C++ side; on
 * Linux every other symbol of the Lean runtime is localized by scripts/link-extension.sh. The
 * C++ side never sees a Lean object: it gets opaque handles, sized strings and string lists.
 *
 * Ownership: functions that take a handle by pointer-to-handle (`marien_session **`) consume it
 * and store its successor; `marien_bridge_free_*` releases a handle. Every string list returned
 * must be released with marien_bridge_free_strings. Each call initializes the calling thread for
 * Lean if it is new. */
#ifndef MARIEN_LEAN_BRIDGE_H
#define MARIEN_LEAN_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct marien_session marien_session;
typedef struct marien_run marien_run;
typedef struct marien_values marien_values;

/* A UTF-8 string with its length in bytes (it may contain NUL). */
typedef struct {
    char *data;
    size_t len;
} marien_str;

/* A list of strings, or an error. */
typedef struct {
    marien_str error; /* data == NULL on success */
    size_t n;
    marien_str *items;
} marien_strings;

void marien_bridge_free_strings(marien_strings *s);

/* Start the Lean runtime and Marien's Lean modules once per process. NULL on success,
 * otherwise the error text (owned by the bridge). */
const char *marien_bridge_init(void);

/* How many times the runtime initializer actually ran (expected: 1). */
int marien_bridge_init_runs(void);

/* elpi_signature: flattened rows (kind, name, text); table "" for all tables; format "" or "elpi"
   for the ELPI declarations, "json" for the one row (schema, "", canonical schema dump). */
marien_strings marien_bridge_signature(const char *catalog, const char *table, const char *format);

/* Statements for the rewrite of elpi_init, elpi_save, elpi_drop and elpi_import, and the rows of
 * elpi_export (name, version, source) flattened. `modules` is the JSON array of stored modules
 * {name, version, source, derived}. Arguments are NUL-terminated except where a length is given. */
marien_strings marien_bridge_init_statements(void);

/* A statement's CALL form (Marien/Statement.lean): ["none"] for text that is not a Marien
   statement, else "call", function, "1" when it returns rows, its Cypher text, then each argument
   as "s", value or "l", count, items. */
marien_strings marien_bridge_statement(const char *text, size_t len);
marien_strings marien_bridge_save(const char *catalog, const char *modules, const char *name,
                                  const char *source, size_t source_len);
marien_strings marien_bridge_drop(const char *modules, const char *name);
/* The statement of elpi_annotate(table, key, value); an empty value removes the annotation. */
marien_strings marien_bridge_annotate(const char *catalog, const char *table, const char *key,
                                      const char *value);
marien_strings marien_bridge_export(const char *modules);
marien_strings marien_bridge_import(const char *catalog, const char *modules, const char *bundle,
                                    size_t bundle_len);

/* elpi_recheck: the statement persisting the recheck of the listed modules (all when `all`). */
marien_strings marien_bridge_recheck(const char *catalog, const char *modules, const char *const *names,
                                     size_t n, int all);

/* --- Queries -------------------------------------------------------------------------- */

/* Find or compile the module and open a session for `goal`; NULL and *error (free it) on failure. */
marien_session *marien_bridge_prepare(const char *catalog, const char *modules, const char *name,
                                      const char *goal, uint64_t max_facts, uint64_t cache_size,
                                      marien_str *error);

/* elpi_run: a session for `pred` with parameters named `param_names` (as many as values;
 * the values are consumed). NULL and *error on failure. */
marien_session *marien_bridge_run_prepare(const char *catalog, const char *modules, const char *name,
                                          const char *pred, const char *const *param_names,
                                          marien_values *param_values, uint64_t max_facts,
                                          uint64_t cache_size, int narrowed, marien_str *error);

/* The output columns of an elpi_run session: column i is (name, type token...), the type in
 * prefix form (a scalar type name, LIST elem, or STRUCT n then name and type per field). */
size_t marien_bridge_column_count(marien_session *s);
marien_strings marien_bridge_column(marien_session *s, size_t i);

/* elpi_validate: the modules to run, in order (the listed ones, or all when `all`), and a
 * session for one module's `violation S C X`. `narrowed` when the call passes a scope (both
 * prepares then fail unless the entry point is monotone). */
marien_strings marien_bridge_validate_order(const char *modules, const char *const *names, size_t n, int all);
marien_session *marien_bridge_validate_prepare(const char *catalog, const char *modules, const char *name,
                                               const char *min_severity, uint64_t max_facts,
                                               uint64_t cache_size, int narrowed, marien_str *error);

/* --- Partitions ----------------------------------------------------------------------- */

/* The partition a session runs in: empty for full scope, ("anchor", table, radius, rel, dir...)
 * or ("key", table, property). */
marien_strings marien_bridge_partition(marien_session *s);

/* A fresh session for the next anchor batch, keeping only rows whose subject is one of `keys`
 * (consumed), or for the next key bucket. `base` stays valid. */
marien_session *marien_bridge_session_batch(marien_session *base, marien_values *keys);
marien_session *marien_bridge_session_fresh(marien_session *base);

/* Batch sizes for `count` anchors in batches of at most `n`, and the bucket of each key value
 * (consumed) among `k` (`k` for NULL). The arrays are malloc'ed; *len is their length. */
uint64_t *marien_bridge_partition_batches(uint64_t n, uint64_t count, size_t *len);
uint64_t *marien_bridge_partition_buckets(uint64_t k, marien_values *keys, size_t *len);

/* The tables to scan: scan i is ("node" | "rel" | "cycle" | "component", table, ...). */
size_t marien_bridge_scan_count(marien_session *s);
marien_strings marien_bridge_scan(marien_session *s, size_t i);

/* Column builders. A finished column is handed to marien_bridge_add_batch, a nested one to
 * marien_bridge_push_list / _struct, which consume it. */
marien_values *marien_bridge_values_new(size_t capacity);
void marien_bridge_push_int64(marien_values *v, int64_t x);
void marien_bridge_push_uint64(marien_values *v, uint64_t x);
void marien_bridge_push_int128(marien_values *v, uint64_t hi, uint64_t lo);
void marien_bridge_push_uint128(marien_values *v, uint64_t hi, uint64_t lo);
void marien_bridge_push_double(marien_values *v, double x);
void marien_bridge_push_bool(marien_values *v, int b);
void marien_bridge_push_str(marien_values *v, const char *data, size_t len);
void marien_bridge_push_null(marien_values *v);
void marien_bridge_push_list(marien_values *v, marien_values *items);
void marien_bridge_push_struct(marien_values *v, marien_values *fields);
void marien_bridge_free_values(marien_values *v);

/* Add one batch of `ncols` columns (consumed) to scan `scan`; on failure returns the error
 * (free its data) and leaves *s valid. */
marien_str marien_bridge_add_batch(marien_session **s, size_t scan, marien_values **cols, size_t ncols);

/* Parse the goal; consumes the session. NULL and *error on failure. */
marien_run *marien_bridge_start(marien_session *s, const char *goal, uint64_t fuel,
                                uint64_t slice_steps, uint64_t max_solutions, marien_str *error);

/* Start the goal of an elpi_run or elpi_validate session; consumes it. */
marien_run *marien_bridge_goal_start(marien_session *s, uint64_t fuel, uint64_t slice_steps,
                                     uint64_t max_solutions, marien_str *error);

enum { MARIEN_STEP_SOLUTION = 0, MARIEN_STEP_PAUSED = 1, MARIEN_STEP_EXHAUSTED = 2,
       MARIEN_STEP_STOPPED = 3, MARIEN_STEP_ERROR = 4 };

/* Run one slice. SOLUTION fills *bindings: (var, json, ...) for elpi_query, the row's cell tokens
 * for elpi_run (n, i<int>, f<float bits>, s<string>, b0/b1, l<count> items, t<count> fields), and
 * (module, version, severity, code, message, label, key) for elpi_validate. ERROR fills *error;
 * after EXHAUSTED, STOPPED or ERROR, *r is NULL. */
int marien_bridge_step(marien_run **r, marien_strings *bindings, marien_str *error);

void marien_bridge_free_session(marien_session *s);
void marien_bridge_free_run(marien_run *r);

/* How often the handle cache missed (tests). */
uint64_t marien_bridge_cache_misses(void);

#ifdef __cplusplus
}
#endif
#endif
