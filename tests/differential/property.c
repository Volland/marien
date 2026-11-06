/* Differential properties against an embedded LadybugDB with the built extension.
 *
 * For each seed, `marien-gen case <seed> <size>` prints a workload: schema and graph as Cypher,
 * modules `full` and `part` (the same violation rules, part with a declared anchor partition)
 * and `narrow` (a reasoning predicate q), and a scope. In a fresh in-memory database:
 *
 *   partition equivalence: when elpi_save accepts `part`, its report equals full's as a multiset
 *   at elpi_partition_batch 1, 7 and the default;
 *   narrowing subset: when q is monotone, the rows of q on the scope are a sub-multiset of its
 *   rows at full scope.
 *
 * A failure is shrunk (the same seed regenerated at smaller sizes, keeping the smallest case
 * that still fails) and reported with its seed and size; the case is written to the scratch
 * directory. Usage: property <extension> <marien-gen> <scratch-dir> <cases> [size] */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lbug.h"

static const char *ext_path, *gen_path, *scratch;
static char last_error[8192];

typedef struct {
    lbug_database db;
    lbug_connection conn;
    int open;
} Db;

/* Rows as sorted "col|col" lines, or NULL with last_error set. The caller frees. */
static int cmp_str(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }

typedef struct {
    char **rows;
    size_t n;
} Rows;

static void free_rows(Rows *r) {
    for (size_t i = 0; i < r->n; i++) free(r->rows[i]);
    free(r->rows);
    r->rows = NULL;
    r->n = 0;
}

static int query(Db *d, Rows *out, const char *fmt, ...) {
    static char q[1 << 20];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(q, sizeof q, fmt, ap);
    va_end(ap);
    lbug_query_result r;
    lbug_connection_query(&d->conn, q, &r);
    if (!lbug_query_result_is_success(&r)) {
        char *e = lbug_query_result_get_error_message(&r);
        snprintf(last_error, sizeof last_error, "%s\n  in: %.400s", e, q);
        lbug_destroy_string(e);
        lbug_query_result_destroy(&r);
        return 0;
    }
    if (out) {
        out->rows = NULL;
        out->n = 0;
        size_t cap = 0;
        uint64_t ncols = lbug_query_result_get_num_columns(&r);
        while (lbug_query_result_has_next(&r)) {
            lbug_flat_tuple t;
            lbug_query_result_get_next(&r, &t);
            char line[4096];
            size_t len = 0;
            line[0] = 0;
            for (uint64_t i = 0; i < ncols; i++) {
                lbug_value v;
                lbug_flat_tuple_get_value(&t, i, &v);
                char *s = lbug_value_is_null(&v) ? NULL : lbug_value_to_string(&v);
                len += (size_t)snprintf(line + len, sizeof line - len, "%s%s", i ? "|" : "", s ? s : "NULL");
                if (s) lbug_destroy_string(s);
                lbug_value_destroy(&v);
            }
            lbug_flat_tuple_destroy(&t);
            if (out->n == cap) out->rows = realloc(out->rows, (cap = cap ? 2 * cap : 64) * sizeof *out->rows);
            out->rows[out->n++] = strdup(line);
        }
        qsort(out->rows, out->n, sizeof *out->rows, cmp_str);
    }
    lbug_query_result_destroy(&r);
    return 1;
}

/* Is a (sorted) a sub-multiset of b (sorted)? */
static int sub_multiset(const Rows *a, const Rows *b) {
    size_t j = 0;
    for (size_t i = 0; i < a->n; i++) {
        while (j < b->n && strcmp(b->rows[j], a->rows[i]) < 0) j++;
        if (j == b->n || strcmp(b->rows[j], a->rows[i]) != 0) return 0;
        j++;
    }
    return 1;
}

static int same_rows(const Rows *a, const Rows *b) { return a->n == b->n && sub_multiset(a, b); }

/* --- Workloads ----------------------------------------------------------------------- */

typedef struct {
    char *text; /* the generator's output */
    char **cypher;
    size_t ncypher;
    char *module[3]; /* full, part, narrow */
    char *scope;
} Workload;

static void free_workload(Workload *w) {
    for (size_t i = 0; i < w->ncypher; i++) free(w->cypher[i]);
    free(w->cypher);
    for (int i = 0; i < 3; i++) free(w->module[i]);
    free(w->scope);
    free(w->text);
    memset(w, 0, sizeof *w);
}

static char *copy(const char *from, const char *to) {
    size_t n = (size_t)(to - from);
    char *s = malloc(n + 1);
    memcpy(s, from, n);
    s[n] = 0;
    return s;
}

static int parse_workload(Workload *w);

static int generate(Workload *w, int seed, int size) {
    memset(w, 0, sizeof *w);
    char cmd[2048];
    snprintf(cmd, sizeof cmd, "'%s' case %d %d", gen_path, seed, size);
    FILE *p = popen(cmd, "r");
    if (!p) return 0;
    size_t cap = 1 << 16, len = 0;
    w->text = malloc(cap);
    for (size_t n; (n = fread(w->text + len, 1, cap - len - 1, p)) > 0;) {
        len += n;
        if (cap - len < 4096) w->text = realloc(w->text, cap *= 2);
    }
    w->text[len] = 0;
    if (pclose(p) != 0) return 0;
    return parse_workload(w);
}

/* The modules, Cypher lines and scope of the generator's text in w->text. */
static int parse_workload(Workload *w) {
    const char *names[3] = {"full", "part", "narrow"};
    for (int i = 0; i < 3; i++) {
        char marker[32];
        snprintf(marker, sizeof marker, "MODULE %s\n", names[i]);
        char *m = strstr(w->text, marker);
        char *end = m ? strstr(m, "\nEND\n") : NULL;
        if (!end) return 0;
        w->module[i] = copy(m + strlen(marker), end);
    }
    size_t ccap = 64;
    w->cypher = malloc(ccap * sizeof *w->cypher);
    for (char *line = w->text; *line;) {
        char *nl = strchr(line, '\n');
        char *eol = nl ? nl : line + strlen(line);
        if (strncmp(line, "CYPHER ", 7) == 0) {
            if (w->ncypher == ccap) w->cypher = realloc(w->cypher, (ccap *= 2) * sizeof *w->cypher);
            w->cypher[w->ncypher++] = copy(line + 7, eol);
        } else if (strncmp(line, "SCOPE ", 6) == 0) {
            w->scope = copy(line + 6, eol);
        }
        line = nl ? nl + 1 : eol;
    }
    return w->scope != NULL;
}

/* A module source as a Cypher string literal body. */
static void escape(const char *s, char *out, size_t n) {
    size_t j = 0;
    for (; *s && j + 3 < n; s++) {
        if (*s == '\'' || *s == '\\') out[j++] = '\\';
        out[j++] = *s;
    }
    out[j] = 0;
}

static int setup(Db *d, const Workload *w) {
    lbug_system_config cfg = lbug_default_system_config();
    cfg.buffer_pool_size = 64ull << 20;
    cfg.max_db_size = 1ull << 30;
    if (lbug_database_init(":memory:", cfg, &d->db) != LbugSuccess) {
        snprintf(last_error, sizeof last_error, "cannot open an in-memory database");
        return 0;
    }
    if (lbug_connection_init(&d->db, &d->conn) != LbugSuccess) {
        lbug_database_destroy(&d->db);
        snprintf(last_error, sizeof last_error, "cannot connect");
        return 0;
    }
    d->open = 1;
    if (!query(d, NULL, "LOAD EXTENSION '%s'", ext_path)) return 0;
    for (size_t i = 0; i < w->ncypher; i++)
        if (!query(d, NULL, "%s", w->cypher[i])) return 0;
    return query(d, NULL, "CALL elpi_init()");
}

static void teardown(Db *d) {
    if (!d->open) return;
    lbug_connection_destroy(&d->conn);
    lbug_database_destroy(&d->db);
    d->open = 0;
}

static int save(Db *d, const char *name, const char *src) {
    static char esc[1 << 18];
    escape(src, esc, sizeof esc);
    return query(d, NULL, "CALL elpi_save('%s', '%s')", name, esc);
}

/* --- Properties ------------------------------------------------------------------------- */

enum { SKIPPED = 0, HOLDS = 1, FAILS = 2 };

#define REPORT "CALL elpi_validate(['%s']) RETURN severity, code, subject_pk"

/* @tg: implements:: [[openspec:differential-testing#Partition equivalence property]] */
/* @tg: verifies:: [[openspec:differential-testing#Partition equivalence property#Accepted partitions agree with full scope]] {level: e2e} */
static int partition_equivalence(const Workload *w, char *why, size_t n) {
    Db d = {0};
    int result = SKIPPED;
    Rows full = {0}, part = {0};
    if (!setup(&d, w) || !save(&d, "full", w->module[0])) {
        snprintf(why, n, "setup: %s", last_error);
        result = FAILS;
        goto done;
    }
    if (!save(&d, "part", w->module[1])) goto done; /* rejected: not this property's case */
    if (!query(&d, &full, REPORT, "full")) {
        snprintf(why, n, "full scope failed: %s", last_error);
        result = FAILS;
        goto done;
    }
    const char *batches[] = {"1", "7", "10000"};
    for (int b = 0; b < 3; b++) {
        if (!query(&d, NULL, "CALL elpi_partition_batch=%s", batches[b]) || !query(&d, &part, REPORT, "part")) {
            snprintf(why, n, "batch %s failed: %s", batches[b], last_error);
            result = FAILS;
            goto done;
        }
        if (!same_rows(&full, &part)) {
            snprintf(why, n, "batch %s: %zu rows, full scope %zu", batches[b], part.n, full.n);
            result = FAILS;
            goto done;
        }
        free_rows(&part);
    }
    result = HOLDS;
done:
    free_rows(&full);
    free_rows(&part);
    teardown(&d);
    return result;
}

/* @tg: implements:: [[openspec:differential-testing#Narrowing subset property]] */
/* @tg: verifies:: [[openspec:differential-testing#Narrowing subset property#Narrowed runs are subsets]] {level: e2e} */
static int narrowing_subset(const Workload *w, char *why, size_t n) {
    Db d = {0};
    int result = SKIPPED;
    Rows full = {0}, narrow = {0};
    if (!setup(&d, w) || !save(&d, "narrow", w->module[2])) {
        snprintf(why, n, "setup: %s", last_error);
        result = FAILS;
        goto done;
    }
    if (!query(&d, &full, "CALL elpi_run('narrow', 'q') RETURN out1, out2")) {
        snprintf(why, n, "full scope failed: %s", last_error);
        result = FAILS;
        goto done;
    }
    if (!query(&d, &narrow, "CALL elpi_run('narrow', 'q', NULL, %s) RETURN out1, out2", w->scope)) {
        if (strstr(last_error, "not monotone")) goto done; /* refused: not this property's case */
        snprintf(why, n, "narrowed run failed: %s", last_error);
        result = FAILS;
        goto done;
    }
    if (!sub_multiset(&narrow, &full)) {
        snprintf(why, n, "%zu narrowed rows are not within the %zu full-scope rows", narrow.n, full.n);
        result = FAILS;
        goto done;
    }
    result = HOLDS;
done:
    free_rows(&full);
    free_rows(&narrow);
    teardown(&d);
    return result;
}

/* One step run in both databases: both succeed with the same rows, or both fail with the same
 * error (the query text the error quotes left out). */
static int same_outcome(Db *a, Db *b, const char *qa, const char *qb, char *why, size_t n, const char *step) {
    Rows ra = {0}, rb = {0};
    char ea[8192] = "", eb[8192] = "";
    int oka = query(a, &ra, "%s", qa);
    if (!oka) snprintf(ea, sizeof ea, "%s", last_error);
    int okb = query(b, &rb, "%s", qb);
    if (!okb) snprintf(eb, sizeof eb, "%s", last_error);
    char *in;
    if ((in = strstr(ea, "\n  in: "))) *in = 0;
    if ((in = strstr(eb, "\n  in: "))) *in = 0;
    int same = oka == okb && (oka ? same_rows(&ra, &rb) : strcmp(ea, eb) == 0);
    if (!same) {
        if (oka != okb) snprintf(why, n, "%s: CALL %s, statement %s (%s%s)", step, oka ? "succeeds" : "fails",
                                 okb ? "succeeds" : "fails", ea, eb);
        else if (oka) snprintf(why, n, "%s: %zu rows from the CALL form, %zu from the statement", step, ra.n, rb.n);
        else snprintf(why, n, "%s: different errors:\n  %s\n  %s", step, ea, eb);
    }
    free_rows(&ra);
    free_rows(&rb);
    return same;
}

#define MODULES "MATCH (m:_elpi_module) RETURN m.name, m.version, m.source, m.status, m.error, m.schema_hash, m.derived"

/* A statement as the argument of elpi_statement. */
static void statement_call(char *out, size_t n, const char *fmt, ...) {
    static char text[1 << 18], esc[1 << 19];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(text, sizeof text, fmt, ap);
    va_end(ap);
    escape(text, esc, sizeof esc);
    snprintf(out, n, "CALL elpi_statement('%s')", esc);
}

/* @tg: verifies:: [[openspec:custom-statements#Statements equal their CALL forms]] {level: e2e} */
static int statement_equivalence(const Workload *w, char *why, size_t n) {
    Db a = {0}, b = {0};
    int result = FAILS;
    static char qa[1 << 19], qb[1 << 19], esc[1 << 18];
    if (!setup(&a, w) || !setup(&b, w)) {
        snprintf(why, n, "setup: %s", last_error);
        goto done;
    }
    const char *names[2] = {"full", "part"};
    for (int i = 0; i < 2; i++) {
        const char *src = w->module[i];
        const char *delim = strstr(src, "$$") ? "$m$" : "$$";
        escape(src, esc, sizeof esc);
        snprintf(qa, sizeof qa, "CALL elpi_save('%s', '%s')", names[i], esc);
        statement_call(qb, sizeof qb, "CREATE RULES %s AS %s%s%s", names[i], delim, src, delim);
        if (!same_outcome(&a, &b, qa, qb, why, n, names[i])) goto done;
    }
    if (!same_outcome(&a, &b, MODULES, MODULES, why, n, "stored modules")) goto done;
    statement_call(qb, sizeof qb, "ANNOTATE R0 SET acyclic = 'true'");
    if (!same_outcome(&a, &b, "CALL elpi_annotate('R0', 'acyclic', 'true')", qb, why, n, "annotate")) goto done;
    statement_call(qb, sizeof qb, "CHECK RULES");
    if (!same_outcome(&a, &b, "CALL elpi_recheck()", qb, why, n, "recheck")) goto done;
    if (!same_outcome(&a, &b, MODULES, MODULES, why, n, "modules after recheck")) goto done;
    statement_call(qb, sizeof qb, "VALIDATE full, part MIN SEVERITY warning");
    if (!same_outcome(&a, &b, "CALL elpi_validate(['full', 'part'], 'warning') RETURN *", qb, why, n, "validate")) goto done;
    statement_call(qb, sizeof qb, "VALIDATE");
    if (!same_outcome(&a, &b, "CALL elpi_validate() RETURN *", qb, why, n, "validate all")) goto done;
    statement_call(qb, sizeof qb, "DROP RULES part");
    if (!same_outcome(&a, &b, "CALL elpi_drop('part')", qb, why, n, "drop")) goto done;
    if (!same_outcome(&a, &b, MODULES, MODULES, why, n, "modules after drop")) goto done;
    result = HOLDS;
done:
    teardown(&a);
    teardown(&b);
    return result;
}

typedef int (*Property)(const Workload *, char *, size_t);

static int check_case(Property p, int seed, int size, char *why, size_t n) {
    Workload w;
    if (!generate(&w, seed, size)) {
        snprintf(why, n, "marien-gen failed for seed %d size %d", seed, size);
        free_workload(&w);
        return FAILS;
    }
    int r = p(&w, why, n);
    free_workload(&w);
    return r;
}

static int measure(int seed, int size) {
    char cmd[2048];
    snprintf(cmd, sizeof cmd, "'%s' measure %d %d", gen_path, seed, size);
    FILE *p = popen(cmd, "r");
    int m = 0;
    if (p) {
        if (fscanf(p, "%d", &m) != 1) m = 0;
        pclose(p);
    }
    return m;
}

/* Report a failure after shrinking it: the smallest case of the same seed that still fails. */
static void report(const char *name, Property p, int seed, int size, const char *why) {
    int best = size, best_m = measure(seed, size);
    char best_why[8192];
    snprintf(best_why, sizeof best_why, "%s", why);
    for (int s = 0; s < size; s++) {
        char w2[8192];
        if (check_case(p, seed, s, w2, sizeof w2) != FAILS) continue;
        int m = measure(seed, s);
        if (m < best_m) {
            best = s;
            best_m = m;
            snprintf(best_why, sizeof best_why, "%s", w2);
        }
    }
    char path[1024];
    snprintf(path, sizeof path, "%s/%s-seed%d-size%d.txt", scratch, name, seed, best);
    char cmd[3072];
    snprintf(cmd, sizeof cmd, "'%s' case %d %d > '%s'", gen_path, seed, best, path);
    if (system(cmd) != 0) path[0] = 0;
    printf("FAIL %s: seed %d size %d (shrunk from size %d, %d nodes and edges): %s\n  case: %s\n", name, seed, best,
           size, best_m, best_why, path);
}

/* --- Rows for the Soufflé oracle ------------------------------------------------------- */

/* `property rows <extension> <case-dir> [drop-one]` (tests/oracle/souffle/run.sh): run the case
 * written by `marien-gen oracle` and write Marien's answers, one sorted row per line, to
 * <target>/marien.rows for the targets full, part (partitioned at batch 1; part/marien-default.rows
 * at the default batch), narrow-full and narrow; a refused save or scope writes <target>/refused
 * instead. `drop-one` is the injected fault of the oracle's self-test: the first full-scope row is
 * dropped. */
static int write_rows(const char *dir, const char *target, const char *file, const Rows *r, int drop) {
    char path[2048];
    snprintf(path, sizeof path, "%s/%s/%s", dir, target, file);
    FILE *f = fopen(path, "w");
    if (!f) return 0;
    for (size_t i = drop && r->n > 0 ? 1 : 0; i < r->n; i++) fprintf(f, "%s\n", r->rows[i]);
    fclose(f);
    return 1;
}

static int write_refused(const char *dir, const char *target, const char *why) {
    char path[2048];
    snprintf(path, sizeof path, "%s/%s/refused", dir, target);
    FILE *f = fopen(path, "w");
    if (!f) return 0;
    fprintf(f, "%s\n", why);
    fclose(f);
    return 1;
}

static int rows_mode(const char *dir, int drop) {
    Workload w;
    memset(&w, 0, sizeof w);
    char path[2048];
    snprintf(path, sizeof path, "%s/case.txt", dir);
    FILE *f = fopen(path, "r");
    if (!f) {
        fprintf(stderr, "cannot read %s\n", path);
        return 2;
    }
    size_t cap = 1 << 16, len = 0;
    w.text = malloc(cap);
    for (size_t n; (n = fread(w.text + len, 1, cap - len - 1, f)) > 0;) {
        len += n;
        if (cap - len < 4096) w.text = realloc(w.text, cap *= 2);
    }
    w.text[len] = 0;
    fclose(f);
    if (!parse_workload(&w)) {
        fprintf(stderr, "%s: not a workload\n", path);
        return 2;
    }
    Db d = {0};
    Rows r = {0};
    int ok = 0;
    if (!setup(&d, &w) || !save(&d, "full", w.module[0]) || !save(&d, "narrow", w.module[2])) goto done;
    if (!query(&d, &r, REPORT, "full") || !write_rows(dir, "full", "marien.rows", &r, drop)) goto done;
    free_rows(&r);
    if (!save(&d, "part", w.module[1])) {
        write_refused(dir, "part", last_error);
    } else {
        if (!query(&d, NULL, "CALL elpi_partition_batch=1") || !query(&d, &r, REPORT, "part") ||
            !write_rows(dir, "part", "marien.rows", &r, 0))
            goto done;
        free_rows(&r);
        if (!query(&d, NULL, "CALL elpi_partition_batch=10000") || !query(&d, &r, REPORT, "part") ||
            !write_rows(dir, "part", "marien-default.rows", &r, 0))
            goto done;
        free_rows(&r);
    }
    if (!query(&d, &r, "CALL elpi_run('narrow', 'q') RETURN out1, out2") ||
        !write_rows(dir, "narrow-full", "marien.rows", &r, 0))
        goto done;
    free_rows(&r);
    if (!query(&d, &r, "CALL elpi_run('narrow', 'q', NULL, %s) RETURN out1, out2", w.scope)) {
        if (!strstr(last_error, "not monotone")) goto done;
        write_refused(dir, "narrow", last_error);
    } else if (!write_rows(dir, "narrow", "marien.rows", &r, 0)) {
        goto done;
    }
    ok = 1;
done:
    if (!ok) fprintf(stderr, "%s: %s\n", dir, last_error);
    free_rows(&r);
    teardown(&d);
    free_workload(&w);
    return ok ? 0 : 1;
}

int main(int argc, char **argv) {
    if (argc >= 4 && strcmp(argv[1], "rows") == 0) {
        ext_path = argv[2];
        return rows_mode(argv[3], argc > 4 && strcmp(argv[4], "drop-one") == 0);
    }
    if (argc < 5) {
        fprintf(stderr, "usage: property <extension> <marien-gen> <scratch-dir> <cases> [size]\n");
        return 2;
    }
    ext_path = argv[1];
    gen_path = argv[2];
    scratch = argv[3];
    int cases = atoi(argv[4]);
    int size = argc > 5 ? atoi(argv[5]) : 4;
    struct {
        const char *name;
        Property p;
        int holds, skipped, failed;
        int cases;
    } props[] = {{"partition equivalence", partition_equivalence, 0, 0, 0, cases},
                 {"narrowing subset", narrowing_subset, 0, 0, 0, cases},
                 /* two databases per case: a tenth of the cases, at least 10 */
                 {"statements equal their CALL forms", statement_equivalence, 0, 0, 0, cases / 10 > 10 ? cases / 10 : 10}};
    int failures = 0;
    for (int i = 0; i < 3; i++) {
        int target = props[i].cases;
        /* until `target` cases hold or fail, from at most 4 x target seeds */
        for (int seed = 1; props[i].holds + props[i].failed < target && seed <= 4 * target; seed++) {
            char why[8192];
            int r = check_case(props[i].p, seed, size, why, sizeof why);
            if (r == HOLDS) props[i].holds++;
            else if (r == SKIPPED) props[i].skipped++;
            else {
                props[i].failed++;
                failures++;
                report(props[i].name, props[i].p, seed, size, why);
            }
        }
        printf("%s: %d cases hold, %d fail, %d rejected by the analysis\n", props[i].name, props[i].holds,
               props[i].failed, props[i].skipped);
        fflush(stdout);
        if (props[i].holds + props[i].failed < target) {
            printf("FAIL %s: only %d cases in %d seeds\n", props[i].name, props[i].holds + props[i].failed, 4 * target);
            failures++;
        }
    }
    return failures ? 1 : 0;
}
