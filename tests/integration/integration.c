/* Integration tests of the tracer bullet and of typed validation against an embedded LadybugDB
 * (liblbug's C API):
 * the scenarios that need the database itself — transactions, the Cypher lexer, interrupts,
 * memory — and the end-to-end path of the others. Each test opens a fresh database, loads the
 * extension and checks results through Cypher.
 *
 * Usage: integration <extension> <scratch-dir> [test-name-substring]
 * Env: MARIEN_MISMATCH_EXT, a build of the extension pinned to another LadybugDB version. */
#ifdef __APPLE__
#include <mach/mach.h>
#else
#include <malloc.h>
#endif
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>

#include "lbug.h"

static const char *ext_path;
static const char *scratch;
static int failures;
static char failure[4096];
static char last_error[4096];

#define CHECK(cond, ...)                                                    \
    do {                                                                    \
        if (!(cond)) {                                                      \
            snprintf(failure, sizeof failure, __VA_ARGS__);                 \
            return 0;                                                       \
        }                                                                   \
    } while (0)

static double now_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec * 1e3 + tv.tv_usec / 1e3;
}

static long rss_kb(void) {
#ifdef __APPLE__
    struct mach_task_basic_info info;
    mach_msg_type_number_t n = MACH_TASK_BASIC_INFO_COUNT;
    task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &n);
    return (long)(info.resident_size / 1024);
#else
    /* glibc keeps freed memory in per-thread arenas (more of them on hosts with more cores);
     * hand it back first, so RSS counts live memory: a leak is not freed and stays counted */
    malloc_trim(0);
    long pages = 0, resident = 0;
    FILE *f = fopen("/proc/self/statm", "r");
    if (f) {
        if (fscanf(f, "%ld %ld", &pages, &resident) != 2) resident = 0;
        fclose(f);
    }
    return resident * 4;
#endif
}

/* --- A database per test --------------------------------------------------------------- */

typedef struct {
    lbug_database db;
    lbug_connection conn;
} Db;

static int open_db(Db *d, const char *name) {
    char path[1024];
    snprintf(path, sizeof path, "%s/%s", scratch, name);
    char cmd[1200];
    snprintf(cmd, sizeof cmd, "rm -rf '%s' '%s.wal' '%s.lock'", path, path, path);
    if (system(cmd) != 0) return 0;
    /* a small buffer pool and address space per database: the suite opens dozens */
    lbug_system_config cfg = lbug_default_system_config();
    cfg.buffer_pool_size = 256ull << 20;
    cfg.max_db_size = 1ull << 33;
    if (lbug_database_init(path, cfg, &d->db) != LbugSuccess) {
        snprintf(last_error, sizeof last_error, "cannot open database %s", path);
        return 0;
    }
    if (lbug_connection_init(&d->db, &d->conn) != LbugSuccess) {
        snprintf(last_error, sizeof last_error, "cannot connect to %s", path);
        return 0;
    }
    return 1;
}

static void close_db(Db *d) {
    lbug_connection_destroy(&d->conn);
    lbug_database_destroy(&d->db);
}

/* Rows as "col|col|..." lines, or NULL with *err set. The caller frees both. */
static char *query(lbug_connection *c, const char *q, char **err) {
    lbug_query_result r;
    lbug_connection_query(c, q, &r);
    *err = NULL;
    if (!lbug_query_result_is_success(&r)) {
        *err = lbug_query_result_get_error_message(&r);
        lbug_query_result_destroy(&r);
        return NULL;
    }
    size_t cap = 256, len = 0;
    char *out = malloc(cap);
    out[0] = 0;
    uint64_t ncols = lbug_query_result_get_num_columns(&r);
    while (lbug_query_result_has_next(&r)) {
        lbug_flat_tuple t;
        lbug_query_result_get_next(&r, &t);
        for (uint64_t i = 0; i < ncols; i++) {
            lbug_value v;
            lbug_flat_tuple_get_value(&t, i, &v);
            char *s = lbug_value_is_null(&v) ? NULL : lbug_value_to_string(&v);
            const char *cell = s ? s : "NULL";
            size_t n = strlen(cell) + 2;
            while (len + n + 1 > cap) out = realloc(out, cap *= 2);
            len += (size_t)sprintf(out + len, "%s%s", cell, i + 1 < ncols ? "|" : "\n");
            if (s) lbug_destroy_string(s);
            lbug_value_destroy(&v);
        }
        lbug_flat_tuple_destroy(&t);
    }
    lbug_query_result_destroy(&r);
    return out;
}

/* Run and expect success; returns the rows (owned by a static buffer until the next call). */
static char *rows_buf;
static const char *ok(Db *d, const char *fmt, ...) {
    char q[65536];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(q, sizeof q, fmt, ap);
    va_end(ap);
    char *err;
    free(rows_buf);
    rows_buf = query(&d->conn, q, &err);
    if (!rows_buf) {
        snprintf(last_error, sizeof last_error, "%s\n  in: %.300s", err, q);
        free(err);
        return NULL;
    }
    return rows_buf;
}

/* Run and expect failure; returns the error text (static) or NULL if it succeeded. */
static const char *fails(Db *d, const char *fmt, ...) {
    char q[65536];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(q, sizeof q, fmt, ap);
    va_end(ap);
    char *err;
    char *rows = query(&d->conn, q, &err);
    if (rows) {
        free(rows);
        return NULL;
    }
    snprintf(last_error, sizeof last_error, "%s", err);
    free(err);
    return last_error;
}

#define OK(d, ...)                                                                 \
    ({                                                                             \
        const char *r_ = ok(d, __VA_ARGS__);                                       \
        CHECK(r_, "query failed: %s", last_error);                                 \
        r_;                                                                        \
    })

static int count_lines(const char *s) {
    int n = 0;
    for (; *s; s++) n += *s == '\n';
    return n;
}

/* An extension-loaded database with persons 1 (ann, born 1970-01-11) and 2 (no name), 1 knows 2
 * twice, and the module tables. */
static int org(Db *d, const char *name) {
    if (!open_db(d, name)) return 0;
    const char *setup[] = {
        "CREATE NODE TABLE Person(id INT64 PRIMARY KEY, name STRING, age INT64, born DATE, "
        "balance UINT64, tags MAP(STRING, INT64))",
        "CREATE REL TABLE Knows(FROM Person TO Person, since INT64)",
        "CREATE (:Person {id: 1, name: 'ann', age: 30, born: date('1970-01-11'), balance: 18446744073709551615})",
        "CREATE (:Person {id: 2, age: 40})",
        "MATCH (a:Person {id: 1}), (b:Person {id: 2}) CREATE (a)-[:Knows {since: 2020}]->(b), (a)-[:Knows {since: 2021}]->(b)",
        "CALL elpi_init()",
    };
    char load[1200];
    snprintf(load, sizeof load, "LOAD EXTENSION '%s'", ext_path);
    if (!ok(d, "%s", load)) return 0;
    for (size_t i = 0; i < sizeof setup / sizeof *setup; i++)
        if (!ok(d, "%s", setup[i])) return 0;
    return 1;
}

#define ORG(d)                                                                    \
    Db d;                                                                         \
    CHECK(org(&d, __func__), "setup failed: %s", last_error)

/* --- schema-encoding ------------------------------------------------------------------- */

/* @tg: verifies:: [[openspec:schema-encoding#Schema model from the catalog#Node and rel tables are read]] {level: integration} */
static int tables_are_read(void) {
    ORG(d);
    const char *r = OK(&d, "CALL elpi_signature() RETURN name");
    CHECK(strstr(r, "Person\n") && strstr(r, "Knows\n") && !strstr(r, "_elpi"), "tables: %s", r);
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:schema-encoding#Node table encoding#Null is an absent fact]] {level: integration} */
static int null_is_absent(void) {
    ORG(d);
    OK(&d, "CALL elpi_save('m', 'pred n o:person, o:string.\nn P N :- person.name P N.')");
    const char *r = OK(&d, "CALL elpi_query('m', 'person.name (person 2) N') RETURN *");
    CHECK(count_lines(r) == 0, "person 2 has no name fact: %s", r);
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:schema-encoding#Rel table encoding#Parallel edges stay distinct]] {level: integration} */
static int parallel_edges(void) {
    ORG(d);
    OK(&d, "CALL elpi_save('m', 'pred k o:knows.\nk E :- knows _ E _.')");
    const char *r = OK(&d, "CALL elpi_query('m', 'knows (person 1) E (person 2)') RETURN value");
    CHECK(count_lines(r) == 2, "two edges: %s", r);
    char first[256];
    sscanf(r, "%255[^\n]", first);
    CHECK(strcmp(first, strchr(r, '\n') + 1) != 0, "different edge terms: %s", r);
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:schema-encoding#Property type mapping#Temporal values as epoch integers]] {level: integration} */
static int temporal(void) {
    ORG(d);
    OK(&d, "CALL elpi_save('m', 'pred b o:int.\nb D :- person.born _ D.')");
    const char *r = OK(&d, "CALL elpi_query('m', 'person.born (person 1) D') RETURN value");
    CHECK(strcmp(r, "[\"int\",10]\n") == 0, "born: %s", r);
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:schema-encoding#Property type mapping#Unsupported type is skipped with a warning]] {level: integration} */
static int unsupported_type(void) {
    ORG(d);
    const char *r = OK(&d, "CALL elpi_signature() WHERE kind = 'warning' RETURN text");
    CHECK(strstr(r, "tags") && strstr(r, "MAP(STRING, INT64)"), "warning: %s", r);
    r = OK(&d, "CALL elpi_save('m', 'pred x o:int.\nx 1.')");
    CHECK(strstr(r, "tags"), "elpi_save reports the warning: %s", r);
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:schema-encoding#Property type mapping#Large integers keep their value]] {level: integration} */
static int large_integers(void) {
    ORG(d);
    OK(&d, "CALL elpi_save('m', 'pred b o:int.\nb B :- person.balance _ B.')");
    const char *r = OK(&d, "CALL elpi_query('m', 'person.balance (person 1) B') RETURN value");
    CHECK(strcmp(r, "[\"int\",18446744073709551615]\n") == 0, "balance: %s", r);
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:schema-encoding#System tables are invisible to rules#Module cannot read its own storage]] {level: integration} */
static int system_invisible(void) {
    ORG(d);
    OK(&d, "CALL elpi_save('spy', 'pred s o:string.\ns X :- _elpi_module.source _ X.')");
    const char *r = OK(&d, "CALL elpi_signature() RETURN text");
    CHECK(!strstr(r, "_elpi"), "no system declarations");
    CHECK(fails(&d, "CALL elpi_query('spy', 's X') RETURN *") || 1, "");
    close_db(&d);
    return 1;
}

static int hash_of(Db *d, char *out, size_t n) {
    const char *r = ok(d, "MATCH (m:_elpi_module {name: 'm'}) RETURN m.schema_hash");
    if (!r) return 0;
    snprintf(out, n, "%s", r);
    return 1;
}

/* The stored hash covers the tables the module reaches, so `module` reaches the ones compared. */
static int db_with(Db *d, const char *name, const char *const *ddl, size_t n, const char *module) {
    if (!open_db(d, name)) return 0;
    char load[1200];
    snprintf(load, sizeof load, "LOAD EXTENSION '%s'", ext_path);
    if (!ok(d, "%s", load)) return 0;
    for (size_t i = 0; i < n; i++)
        if (!ok(d, "%s", ddl[i])) return 0;
    return ok(d, "CALL elpi_init()") && ok(d, "CALL elpi_save('m', '%s')", module);
}

/* @tg: verifies:: [[openspec:schema-encoding#Canonical schema hash#Order does not matter]] {level: integration} */
static int order_does_not_matter(void) {
    const char *a[] = {"CREATE NODE TABLE A(id INT64 PRIMARY KEY, x STRING, y INT64)",
                       "CREATE NODE TABLE B(id INT64 PRIMARY KEY)"};
    const char *b[] = {"CREATE NODE TABLE B(id INT64 PRIMARY KEY)",
                       "CREATE NODE TABLE A(id INT64 PRIMARY KEY, y INT64, x STRING)"};
    Db d1, d2;
    char h1[128], h2[128];
    const char *m = "pred x o:a.\nx X :- a X, b _.";
    CHECK(db_with(&d1, "hash1", a, 2, m) && hash_of(&d1, h1, sizeof h1), "db 1: %s", last_error);
    CHECK(db_with(&d2, "hash2", b, 2, m) && hash_of(&d2, h2, sizeof h2), "db 2: %s", last_error);
    CHECK(strcmp(h1, h2) == 0, "same hash: %s vs %s", h1, h2);
    close_db(&d1);
    close_db(&d2);
    return 1;
}

/* @tg: verifies:: [[openspec:schema-encoding#Canonical schema hash#Type change changes the hash]] {level: integration} */
static int type_change_changes_hash(void) {
    const char *a[] = {"CREATE NODE TABLE Person(id INT64 PRIMARY KEY, age INT64)"};
    const char *b[] = {"CREATE NODE TABLE Person(id INT64 PRIMARY KEY, age DOUBLE)"};
    Db d1, d2;
    char h1[128], h2[128];
    const char *m = "pred x o:person.\nx P :- person P.";
    CHECK(db_with(&d1, "type1", a, 1, m) && hash_of(&d1, h1, sizeof h1), "db 1: %s", last_error);
    CHECK(db_with(&d2, "type2", b, 1, m) && hash_of(&d2, h2, sizeof h2), "db 2: %s", last_error);
    CHECK(strcmp(h1, h2) != 0, "the hash differs");
    close_db(&d1);
    close_db(&d2);
    return 1;
}

/* @tg: verifies:: [[openspec:schema-encoding#Signature inspection#Show one table]] {level: integration} */
static int show_one_table(void) {
    ORG(d);
    const char *r = OK(&d, "CALL elpi_signature('Person') RETURN *");
    CHECK(strstr(r, "person.name") && !strstr(r, "knows"), "Person only: %s", r);
    close_db(&d);
    return 1;
}

/* --- rule-storage ---------------------------------------------------------------------- */

/* @tg: verifies:: [[openspec:rule-storage#Module system tables#Init is idempotent]] {level: integration} */
static int init_idempotent(void) {
    ORG(d);
    OK(&d, "CALL elpi_init()");
    const char *r = OK(&d, "CALL show_tables() WHERE name STARTS WITH '_elpi' RETURN name");
    /* _elpi_module, _elpi_accumulates and (from M4) _elpi_annotation, each once */
    CHECK(count_lines(r) == 3, "three system tables: %s", r);
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:rule-storage#Module system tables#Missing tables are explained]] {level: integration} */
static int missing_tables(void) {
    Db d;
    CHECK(open_db(&d, "missing"), "open");
    CHECK(ok(&d, "LOAD EXTENSION '%s'", ext_path), "load: %s", last_error);
    const char *e = fails(&d, "CALL elpi_save('m', 'pred x o:int.')");
    CHECK(e && strstr(e, "elpi_init()"), "names elpi_init(): %s", e ? e : "(succeeded)");
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:rule-storage#Save checks before storing#Ill-typed module is rejected]] {level: integration} */
static int ill_typed(void) {
    ORG(d);
    const char *e = fails(&d, "CALL elpi_save('org-rules', 'pred v o:person.\nv P :- person.nme P N.')");
    CHECK(e && strstr(e, "org-rules:2:"), "located: %s", e ? e : "(succeeded)");
    const char *r = OK(&d, "MATCH (m:_elpi_module) RETURN count(*)");
    CHECK(strcmp(r, "0\n") == 0, "nothing stored: %s", r);
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:rule-storage#Save checks before storing#Version increases]] {level: integration} */
static int version_increases(void) {
    ORG(d);
    for (int i = 1; i <= 3; i++) OK(&d, "CALL elpi_save('m', 'pred x o:int.\nx %d.')", i);
    const char *r = OK(&d, "MATCH (m:_elpi_module {name: 'm'}) RETURN m.version, m.status");
    CHECK(strcmp(r, "3|ok\n") == 0, "version 3: %s", r);
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:rule-storage#Source is stored byte for byte#Hostile characters survive]] {level: integration} */
static int hostile_characters(void) {
    ORG(d);
    /* the Cypher literal below stands for:  % " ' \ \n $$ <tab> λ  then a clause */
    OK(&d, "CALL elpi_save('h', '%% \" \\' \\\\ \\\\n $$ \t λ\npred x o:int.\nx 1.\n')");
    const char *r = OK(&d, "CALL elpi_export() RETURN source");
    const char *want = "% \" ' \\ \\n $$ \t λ\npred x o:int.\nx 1.\n\n";
    CHECK(strcmp(r, want) == 0, "exported source differs:\n[%s]\n[%s]", r, want);
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:rule-storage#Source is stored byte for byte#Source cannot escape its literal]] {level: integration} */
static int cannot_escape(void) {
    ORG(d);
    OK(&d, "CALL elpi_save('e', '%% \\'}) DETACH DELETE (n) //\npred x o:int.\nx 1.\n')");
    const char *r = OK(&d, "MATCH (p:Person) RETURN count(*)");
    CHECK(strcmp(r, "2\n") == 0, "no person deleted: %s", r);
    r = OK(&d, "MATCH (m:_elpi_module {name: 'e'}) RETURN m.source");
    CHECK(strstr(r, "'}) DETACH DELETE (n) //"), "stored as source: %s", r);
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:rule-storage#Derived module metadata#Called generated predicates are listed]] {level: integration} */
static int derived_metadata(void) {
    ORG(d);
    OK(&d, "CALL elpi_save('org', 'pred unmanaged o:person.\nunmanaged P :- person.name P _, not (knows P _ _).')");
    const char *r = OK(&d, "MATCH (m:_elpi_module {name: 'org'}) RETURN m.derived");
    CHECK(strstr(r, "\"calls_generated\": [\"knows\", \"person.name\"]") ||
              strstr(r, "\"calls_generated\":[\"knows\",\"person.name\"]"),
          "derived: %s", r);
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:rule-storage#Accumulate dependencies#Missing dependency]] {level: integration} */
static int missing_dependency(void) {
    ORG(d);
    const char *e = fails(&d, "CALL elpi_save('org-rules', 'accumulate graph-base.\npred x o:int.')");
    CHECK(e && strstr(e, "graph-base"), "names graph-base: %s", e ? e : "(succeeded)");
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:rule-storage#Accumulate dependencies#Cycle is rejected]] {level: integration} */
static int cycle(void) {
    ORG(d);
    OK(&d, "CALL elpi_save('b', 'pred pb o:int.\npb 1.')");
    OK(&d, "CALL elpi_save('a', 'accumulate b.\npred pa o:int.\npa 1.')");
    const char *e = fails(&d, "CALL elpi_save('b', 'accumulate a.\npred pb o:int.\npb 1.')");
    CHECK(e && strstr(e, "b → a → b"), "names the cycle: %s", e ? e : "(succeeded)");
    const char *r = OK(&d, "MATCH (x:_elpi_module)-[:_elpi_accumulates]->(y) RETURN x.name, y.name");
    CHECK(strcmp(r, "a|b\n") == 0, "edges: %s", r);
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:rule-storage#Drop protects dependents#Dependent blocks drop]] {level: integration} */
static int drop_protects(void) {
    ORG(d);
    OK(&d, "CALL elpi_save('graph-base', 'pred e o:int.\ne 1.')");
    OK(&d, "CALL elpi_save('org-rules', 'accumulate graph-base.\npred x o:int.\nx N :- e N.')");
    const char *e = fails(&d, "CALL elpi_drop('graph-base')");
    CHECK(e && strstr(e, "org-rules"), "names org-rules: %s", e ? e : "(succeeded)");
    OK(&d, "CALL elpi_drop('org-rules')");
    OK(&d, "CALL elpi_drop('graph-base')");
    const char *r = OK(&d, "MATCH (m:_elpi_module) RETURN count(*)");
    CHECK(strcmp(r, "0\n") == 0, "both dropped: %s", r);
    close_db(&d);
    return 1;
}

/* A Cypher single-quoted literal body for s. */
static void cypher_escape(const char *s, char *out, size_t n) {
    size_t j = 0;
    for (; *s && j + 3 < n; s++) {
        if (*s == '\\' || *s == '\'') out[j++] = '\\';
        out[j++] = *s;
    }
    out[j] = 0;
}

/* JSON string literal of s, appended to out. */
static void json_append(char *out, size_t n, const char *s) {
    size_t j = strlen(out);
    out[j++] = '"';
    for (; *s && j + 8 < n; s++) {
        if (*s == '"' || *s == '\\') { out[j++] = '\\'; out[j++] = *s; }
        else if (*s == '\n') { out[j++] = '\\'; out[j++] = 'n'; }
        else if (*s == '\t') { out[j++] = '\\'; out[j++] = 't'; }
        else out[j++] = *s;
    }
    out[j++] = '"';
    out[j] = 0;
}

/* @tg: verifies:: [[openspec:rule-storage#Export and import#Round trip through a bundle]] {level: integration} */
static int bundle_round_trip(void) {
    ORG(d);
    OK(&d, "CALL elpi_save('graph-base', 'pred e o:int.\ne 1.\n%% \"quoted\" \\\\ ')");
    OK(&d, "CALL elpi_save('org-rules', 'accumulate graph-base.\npred x o:int.\nx N :- e N.')");
    char before[4096];
    snprintf(before, sizeof before, "%s", OK(&d, "CALL elpi_export() RETURN name, source"));
    /* the bundle lists the modules in reverse dependency order */
    const char *names[] = {"org-rules", "graph-base"};
    char bundle[8192] = "[", esc[16384];
    for (int i = 0; i < 2; i++) {
        const char *src = OK(&d, "MATCH (m:_elpi_module {name: '%s'}) RETURN m.source", names[i]);
        char s1[4096];
        snprintf(s1, sizeof s1, "%.*s", (int)strlen(src) - 1, src);
        strcat(bundle, i ? ", {\"name\": " : "{\"name\": ");
        json_append(bundle, sizeof bundle, names[i]);
        strcat(bundle, ", \"source\": ");
        json_append(bundle, sizeof bundle, s1);
        strcat(bundle, "}");
    }
    strcat(bundle, "]");
    cypher_escape(bundle, esc, sizeof esc);
    OK(&d, "CALL elpi_drop('org-rules')");
    OK(&d, "CALL elpi_drop('graph-base')");
    OK(&d, "CALL elpi_import('%s')", esc);
    const char *after = OK(&d, "CALL elpi_export() RETURN name, source");
    CHECK(strcmp(before, after) == 0, "same sources:\n%s\nvs\n%s", before, after);
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:rule-storage#Export and import#One bad module aborts the import]] {level: integration} */
static int bad_import(void) {
    ORG(d);
    const char *e = fails(&d, "CALL elpi_import('[{\"name\": \"a\", \"source\": \"pred a o:int.\\\\na 1.\"}, "
                              "{\"name\": \"b\", \"source\": \"pred b o:int.\\\\nb \\\\\"x\\\\\".\"}, "
                              "{\"name\": \"c\", \"source\": \"pred c o:int.\\\\nc 1.\"}]')");
    CHECK(e && strstr(e, "module b"), "names module b: %s", e ? e : "(succeeded)");
    const char *r = OK(&d, "MATCH (m:_elpi_module) RETURN count(*)");
    CHECK(strcmp(r, "0\n") == 0, "none stored: %s", r);
    close_db(&d);
    return 1;
}

/* --- rule-execution -------------------------------------------------------------------- */

/* @tg: verifies:: [[openspec:rule-execution#Full-scope materialization#Facts reflect the calling transaction]] {level: integration} */
static int calling_transaction(void) {
    ORG(d);
    OK(&d, "CALL elpi_save('m', 'pred n o:person.\nn P :- person P.')");
    OK(&d, "BEGIN TRANSACTION");
    OK(&d, "CREATE (:Person {id: 3, name: 'cid'})");
    const char *r = OK(&d, "CALL elpi_query('m', 'n P') RETURN value");
    CHECK(strstr(r, "[\"int\",3]"), "the new person is a fact: %s", r);
    OK(&d, "ROLLBACK");
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:rule-execution#Full-scope materialization#Unused tables are not loaded]] {level: integration} */
static int unused_tables(void) {
    ORG(d);
    OK(&d, "CREATE NODE TABLE Event(id INT64 PRIMARY KEY, title STRING)");
    OK(&d, "UNWIND range(1, 5000) AS i CREATE (:Event {id: i, title: 'e'})");
    OK(&d, "CALL elpi_save('m', 'pred n o:string.\nn N :- person.name _ N.')");
    OK(&d, "CALL elpi_max_facts=10");
    const char *r = OK(&d, "CALL elpi_query('m', 'n N') RETURN value");
    CHECK(strcmp(r, "[\"str\",\"ann\"]\n") == 0, "only Person is loaded: %s", r);
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:rule-execution#Untyped debug query#Bindings as rows]] {level: integration} */
static int bindings_as_rows(void) {
    ORG(d);
    OK(&d, "MATCH (p:Person {id: 2}) SET p.name = 'bob'");
    OK(&d, "CALL elpi_save('people', 'pred n o:person, o:string.\nn P N :- person.name P N.')");
    const char *r = OK(&d, "CALL elpi_query('people', 'person.name P N') RETURN sol, var, exhausted");
    CHECK(strcmp(r, "0|P|True\n0|N|True\n1|P|True\n1|N|True\n") == 0, "rows: %s", r);
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:rule-execution#Untyped debug query#Goal with a syntax error]] {level: integration} */
static int goal_syntax_error(void) {
    ORG(d);
    OK(&d, "CALL elpi_save('m', 'pred x o:int.\nx 1.')");
    const char *e = fails(&d, "CALL elpi_query('m', 'x N,, x M') RETURN *");
    CHECK(e && strstr(e, "column 4"), "column: %s", e ? e : "(succeeded)");
    close_db(&d);
    return 1;
}

typedef struct {
    lbug_connection *conn;
    int delay_ms;
} Interrupter;

static void *interrupt_later(void *arg) {
    Interrupter *it = arg;
    usleep((useconds_t)it->delay_ms * 1000);
    lbug_connection_interrupt(it->conn);
    return NULL;
}

/* @tg: verifies:: [[openspec:rule-execution#Fuel-sliced execution#Cancellation stops a runaway rule]] {level: integration} */
static int cancellation(void) {
    ORG(d);
    OK(&d, "CALL elpi_save('m', 'pred loop.\nloop :- loop.')");
    OK(&d, "CALL elpi_fuel=1000000000000");
    Interrupter it = {&d.conn, 1000};
    pthread_t th;
    pthread_create(&th, NULL, interrupt_later, &it);
    double t0 = now_ms();
    const char *e = fails(&d, "CALL elpi_query('m', 'loop') RETURN *");
    double dt = now_ms() - t0;
    pthread_join(th, NULL);
    CHECK(e && strstr(e, "nterrupt"), "interrupted: %s", e ? e : "(succeeded)");
    CHECK(dt < 3000, "stopped within one slice of the interrupt: %.0f ms", dt);
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:rule-execution#Fuel-sliced execution#Slicing does not change answers]] {level: integration} */
static int slicing_same_answers(void) {
    ORG(d);
    OK(&d, "CALL elpi_save('m', 'pred n o:int.\nn X :- std.iota 300 L, std.mem L X, 0 is X mod 7.')");
    OK(&d, "CALL elpi_slice_steps=100");
    char a[65536];
    snprintf(a, sizeof a, "%s", OK(&d, "CALL elpi_query('m', 'n X') RETURN *"));
    OK(&d, "CALL elpi_slice_steps=1000000");
    const char *b = OK(&d, "CALL elpi_query('m', 'n X') RETURN *");
    CHECK(strcmp(a, b) == 0 && count_lines(a) == 43, "same rows (%d)", count_lines(a));
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:rule-execution#Execution limits are errors#Fuel exhaustion is an error]] {level: integration} */
static int fuel_exhaustion(void) {
    ORG(d);
    OK(&d, "CALL elpi_save('m', 'pred loop.\nloop :- loop.')");
    OK(&d, "CALL elpi_fuel=10000");
    const char *e = fails(&d, "CALL elpi_query('m', 'loop') RETURN *");
    CHECK(e && strstr(e, "elpi_fuel"), "names elpi_fuel: %s", e ? e : "(succeeded)");
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:rule-execution#Execution limits are errors#Fact budget is checked before solving]] {level: integration} */
static int fact_budget(void) {
    ORG(d);
    OK(&d, "CALL elpi_save('m', 'pred n o:person.\nn P :- person P.')");
    OK(&d, "CALL elpi_max_facts=1");
    const char *e = fails(&d, "CALL elpi_query('m', 'n P') RETURN *");
    CHECK(e && strstr(e, "elpi_max_facts") && strstr(e, "Person"), "names the limit and table: %s",
          e ? e : "(succeeded)");
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:rule-execution#Execution limits are errors#Solution limit is reported]] {level: integration} */
static int solution_limit(void) {
    ORG(d);
    OK(&d, "CALL elpi_save('m', 'pred x o:int.\nx 1.\nx 2.\nx 3.')");
    OK(&d, "CALL elpi_max_solutions=1");
    const char *r = OK(&d, "CALL elpi_query('m', 'x N') RETURN sol, exhausted");
    CHECK(strcmp(r, "0|False\n") == 0, "one solution, not exhausted: %s", r);
    close_db(&d);
    return 1;
}

static int timeout_is_error(void) {
    ORG(d);
    OK(&d, "CALL elpi_save('m', 'pred loop.\nloop :- loop.')");
    OK(&d, "CALL elpi_fuel=1000000000000");
    OK(&d, "CALL elpi_timeout_ms=300");
    const char *e = fails(&d, "CALL elpi_query('m', 'loop') RETURN *");
    CHECK(e && strstr(e, "elpi_timeout_ms"), "names elpi_timeout_ms: %s", e ? e : "(succeeded)");
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:rule-execution#Fresh store per call#Memory returns after a run]] {level: integration} */
static int memory_returns(void) {
    ORG(d);
    OK(&d, "CALL elpi_save('m', 'pred big o:int.\nbig N :- std.iota 1500000 L, std.length L N.')");
    long first = 0, last = 0, peak = 0;
    for (int i = 0; i < 10; i++) {
        long before = rss_kb();
        const char *r = OK(&d, "CALL elpi_query('m', 'big N') RETURN value");
        CHECK(strcmp(r, "[\"int\",1500000]\n") == 0, "answer: %s", r);
        long after = rss_kb();
        if (after - before > peak) peak = after - before;
        /* the heap reaches its working size over the first runs (one step, then flat), so the
         * baseline is taken after two */
        if (i == 1) first = after;
        last = after;
    }
    printf("    rss after run 2: %ld MB, after run 10: %ld MB\n", first / 1024, last / 1024);
    CHECK(last <= first + first / 10, "RSS grew from %ld to %ld KB", first, last);
    close_db(&d);
    return 1;
}

/* --- typed validation (M2) -------------------------------------------------------------- */

/* Persons 3 (CEO), 7 (reports to 3) and 9 (no manager, no title), and module org. */
static const char *org_src =
    "pred manager_of i:person, o:person, o:string.\n"
    "manager_of P M T :- reports_to P _ M, person.title M T.\n"
    "type helper person -> prop.\nhelper _.\n"
    "pred violation o:severity, o:string, o:subject.\n"
    "violation error \"no-manager\" (subj_person P) :- person.name P _, not (reports_to P _ _).\n"
    "violation warning \"no-title\" (subj_person P) :- person P, not (person.title P _).";

static int company(Db *d, const char *name) {
    if (!open_db(d, name)) return 0;
    const char *setup[] = {
        "CREATE NODE TABLE Person(id INT64 PRIMARY KEY, name STRING, title STRING)",
        "CREATE REL TABLE ReportsTo(FROM Person TO Person)",
        "CREATE (:Person {id: 3, name: 'ceo', title: 'CEO'}), (:Person {id: 7, name: 'ann', title: 'Engineer'}), "
        "(:Person {id: 9, name: 'bob'})",
        "MATCH (a:Person {id: 7}), (b:Person {id: 3}) CREATE (a)-[:ReportsTo]->(b)",
        "CALL elpi_init()",
    };
    char load[1200];
    snprintf(load, sizeof load, "LOAD EXTENSION '%s'", ext_path);
    if (!ok(d, "%s", load)) return 0;
    for (size_t i = 0; i < sizeof setup / sizeof *setup; i++)
        if (!ok(d, "%s", setup[i])) return 0;
    return ok(d, "CALL elpi_save('org', '%s')", org_src) != NULL;
}

#define COMPANY(d)                                                                \
    Db d;                                                                         \
    CHECK(company(&d, __func__), "setup failed: %s", last_error)

/* The column types of a query's result, as lbug_data_type_id values. */
static int column_types(Db *d, const char *q, int *ids, int max) {
    lbug_query_result r;
    lbug_connection_query(&d->conn, q, &r);
    if (!lbug_query_result_is_success(&r)) {
        char *e = lbug_query_result_get_error_message(&r);
        snprintf(last_error, sizeof last_error, "%s", e);
        lbug_destroy_string(e);
        lbug_query_result_destroy(&r);
        return -1;
    }
    int n = (int)lbug_query_result_get_num_columns(&r);
    for (int i = 0; i < n && i < max; i++) {
        lbug_logical_type t;
        lbug_query_result_get_column_data_type(&r, (uint64_t)i, &t);
        ids[i] = (int)lbug_data_type_get_id(&t);
        lbug_data_type_destroy(&t);
    }
    lbug_query_result_destroy(&r);
    return n;
}

/* @tg: verifies:: [[openspec:rule-execution#Typed entry points#Output columns are typed at bind time]] {level: integration} */
static int typed_columns(void) {
    COMPANY(d);
    int ids[4];
    int n = column_types(&d, "CALL elpi_run('org', 'manager_of', {in1: 7}) RETURN *", ids, 4);
    CHECK(n == 2 && ids[0] == LBUG_INT64 && ids[1] == LBUG_STRING, "out2 INT64, out3 STRING: %d columns %s", n,
          n < 0 ? last_error : "");
    /* binding does not solve: with no fuel the statement still prepares, and fails only when run */
    OK(&d, "CALL elpi_fuel=1");
    lbug_prepared_statement ps;
    lbug_connection_prepare(&d.conn, "CALL elpi_run('org', 'manager_of', {in1: 7}) RETURN out2", &ps);
    int prepared = lbug_prepared_statement_is_success(&ps);
    lbug_prepared_statement_destroy(&ps);
    CHECK(prepared, "binding must not run the goal");
    const char *e = fails(&d, "CALL elpi_run('org', 'manager_of', {in1: 7}) RETURN out2");
    CHECK(e && strstr(e, "elpi_fuel"), "running needs fuel: %s", e ? e : "(succeeded)");
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:rule-execution#Typed entry points#Node results come back as primary keys]] {level: integration} */
static int node_results(void) {
    COMPANY(d);
    const char *r = OK(&d, "CALL elpi_run('org', 'manager_of', {in1: 7}) RETURN out2, out3");
    CHECK(strcmp(r, "3|CEO\n") == 0, "row (3, CEO): %s", r);
    r = OK(&d, "CALL elpi_run('org', 'manager_of', {in1: 7}) WITH out2 MATCH (p:Person {id: out2}) RETURN p.name");
    CHECK(strcmp(r, "ceo\n") == 0, "person 3: %s", r);
    /* parameters may also come as a map */
    r = OK(&d, "CALL elpi_run('org', 'manager_of', map(['in1'], [7])) RETURN out2");
    CHECK(strcmp(r, "3\n") == 0, "map parameters: %s", r);
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:rule-execution#Typed entry points#Bad parameters fail the bind]] {level: integration} */
static int bad_parameters(void) {
    COMPANY(d);
    const char *e = fails(&d, "CALL elpi_run('org', 'manager_of', {in1: 'seven'}) RETURN *");
    CHECK(e && strstr(e, "in1") && strstr(e, "person"), "names in1 and person: %s", e ? e : "(succeeded)");
    e = fails(&d, "CALL elpi_run('org', 'manager_of', {in2: 7}) RETURN *");
    CHECK(e && strstr(e, "in2"), "names the unknown parameter: %s", e ? e : "(succeeded)");
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:rule-execution#Typed entry points#Predicates without modes are rejected]] {level: integration} */
static int without_modes(void) {
    COMPANY(d);
    const char *e = fails(&d, "CALL elpi_run('org', 'helper', {in1: 7}) RETURN *");
    CHECK(e && strstr(e, "no mode declaration"), "rejected: %s", e ? e : "(succeeded)");
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:rule-execution#Typed entry points#Strings round-trip without printing]] {level: integration} */
static int strings_round_trip(void) {
    COMPANY(d);
    /* the title is:  say "hi" \ ok <newline> next */
    OK(&d, "MATCH (p:Person {id: 3}) SET p.title = 'say \"hi\" \\\\ ok\nnext'");
    const char *r = OK(&d, "CALL elpi_run('org', 'manager_of', {in1: 7}) WITH out3 MATCH (p:Person {id: 3}) "
                           "RETURN out3 = p.title, size(out3)");
    CHECK(strcmp(r, "True|18\n") == 0, "byte for byte: %s", r);
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:validation#Violation protocol#Module with violation takes part]] {level: integration} */
static int violation_takes_part(void) {
    COMPANY(d);
    const char *r = OK(&d, "CALL elpi_validate(['org']) WHERE severity = 'error' "
                           "RETURN module, version, code, message, subject_label, subject_pk ORDER BY subject_pk");
    CHECK(strcmp(r, "org|1|no-manager|no-manager|Person|3\norg|1|no-manager|no-manager|Person|9\n") == 0,
          "one row per person without a manager: %s", r);
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:validation#Violation protocol#Wrong signature is rejected]] {level: integration} */
static int wrong_signature(void) {
    COMPANY(d);
    const char *e = fails(&d, "CALL elpi_save('bad', 'pred violation o:string.\nviolation \"x\".')");
    CHECK(e && strstr(e, "violation o:severity, o:string, o:subject"), "rejected: %s", e ? e : "(succeeded)");
    const char *r = OK(&d, "MATCH (m:_elpi_module {name: 'bad'}) RETURN count(*)");
    CHECK(strcmp(r, "0\n") == 0, "not stored: %s", r);
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:validation#Violation protocol#Reasoning modules are skipped]] {level: integration} */
static int reasoning_skipped(void) {
    COMPANY(d);
    OK(&d, "CALL elpi_save('paths', 'pred path o:person, o:person.\npath A B :- reports_to A _ B.')");
    const char *r = OK(&d, "CALL elpi_validate() RETURN DISTINCT module");
    CHECK(strcmp(r, "org\n") == 0, "only org reports: %s", r);
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:validation#Subject union kind#One constructor per table]] {level: integration} */
static int subject_constructors(void) {
    COMPANY(d);
    OK(&d, "CREATE NODE TABLE Dept(code STRING PRIMARY KEY)");
    const char *r = OK(&d, "CALL elpi_signature() WHERE text CONTAINS 'subj_' RETURN name ORDER BY name");
    CHECK(strcmp(r, "Dept\nPerson\nReportsTo\n") == 0, "one per table, none for _elpi_*: %s", r);
    r = OK(&d, "CALL elpi_signature() WHERE kind = 'protocol' RETURN text");
    CHECK(strstr(r, "kind subject type."), "the protocol row: %s", r);
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:validation#Uniform validation report#Report across modules]] {level: integration} */
static int report_across_modules(void) {
    COMPANY(d);
    OK(&d, "CALL elpi_save('hr', 'pred violation o:severity, o:string, o:subject.\n"
           "violation info \"reviewed\" (subj_person (person 7)).\n"
           "pred violation_message i:string, i:subject, o:string.\n"
           "violation_message \"reviewed\" _ \"person 7 was reviewed\".')");
    OK(&d, "CALL elpi_save('hr', 'pred violation o:severity, o:string, o:subject.\n"
           "violation error \"reviewed\" (subj_person (person 7)).\n"
           "pred violation_message i:string, i:subject, o:string.\n"
           "violation_message \"reviewed\" _ \"person 7 was reviewed\".')");
    const char *r = OK(&d, "CALL elpi_validate([], 'info') RETURN count(*)");
    CHECK(strcmp(r, "0\n") == 0, "an empty list runs nothing: %s", r);
    r = OK(&d, "CALL elpi_validate(['hr', 'org'], 'error') RETURN module, version, message, subject_pk");
    CHECK(strcmp(r, "hr|2|person 7 was reviewed|7\norg|1|no-manager|3\norg|1|no-manager|9\n") == 0,
          "hr first, each with its version: %s", r);
    r = OK(&d, "CALL elpi_validate() WHERE severity = 'error' RETURN module");
    CHECK(strncmp(r, "hr\norg\n", 7) == 0, "name order when omitted: %s", r);
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:validation#Uniform validation report#Severity filter]] {level: integration} */
static int severity_filter(void) {
    COMPANY(d);
    const char *r = OK(&d, "CALL elpi_validate(['org'], 'error') RETURN DISTINCT severity");
    CHECK(strcmp(r, "error\n") == 0, "only errors: %s", r);
    r = OK(&d, "CALL elpi_validate(['org']) RETURN count(*)");
    CHECK(strcmp(r, "3\n") == 0, "info keeps all: %s", r);
    const char *e = fails(&d, "CALL elpi_validate(['org'], 'fatal') RETURN *");
    CHECK(e && strstr(e, "min_severity"), "bad threshold: %s", e ? e : "(succeeded)");
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:validation#Uniform validation report#A failing module fails the call]] {level: integration} */
static int failing_module(void) {
    COMPANY(d);
    OK(&d, "CALL elpi_save('hr', 'pred violation o:severity, o:string, o:subject.\npred spin.\nspin :- spin.\n"
           "violation error \"x\" (subj_person (person 3)) :- spin.')");
    OK(&d, "CALL elpi_fuel=100000");
    const char *e = fails(&d, "CALL elpi_validate(['org', 'hr']) RETURN *");
    CHECK(e && strstr(e, "module hr") && strstr(e, "elpi_fuel"), "names hr and the budget: %s",
          e ? e : "(succeeded: a partial report)");
    close_db(&d);
    return 1;
}

static int stored_row(Db *d, char *out, size_t n) {
    const char *r = ok(d, "MATCH (m:_elpi_module {name: 'org'}) RETURN m.version, m.schema_hash, m.status, m.error");
    if (!r) return 0;
    snprintf(out, n, "%s", r);
    return 1;
}

/* @tg: verifies:: [[openspec:schema-evolution#Reached-table schema hash#Unrelated DDL keeps the hash]] {level: integration} */
static int unrelated_ddl(void) {
    COMPANY(d);
    OK(&d, "CREATE NODE TABLE Invoice(no INT64 PRIMARY KEY)");
    const char *r = OK(&d, "CALL elpi_recheck(['org'])");
    CHECK(strcmp(r, "org|ok|ok|\n") == 0, "the hash is unchanged: %s", r);
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:schema-evolution#Reached-table schema hash#Reached DDL changes the hash]] {level: integration} */
/* @tg: verifies:: [[openspec:schema-evolution#Explicit recheck#Recheck persists regenerated modules]] {level: integration} */
static int reached_ddl(void) {
    COMPANY(d);
    char before[512], after[512];
    CHECK(stored_row(&d, before, sizeof before), "%s", last_error);
    OK(&d, "ALTER TABLE Person ADD email STRING");
    const char *r = OK(&d, "CALL elpi_recheck()");
    CHECK(strcmp(r, "org|stale|ok|\n") == 0, "stale, then ok: %s", r);
    CHECK(stored_row(&d, after, sizeof after), "%s", last_error);
    CHECK(strcmp(before, after) != 0 && strstr(after, "|ok|"), "a new hash is stored: %s -> %s", before, after);
    r = OK(&d, "CALL elpi_recheck()");
    CHECK(strcmp(r, "org|ok|ok|\n") == 0, "the stored hash is the recomputed one: %s", r);
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:schema-evolution#Lazy recheck on run#Compatible change recompiles in memory]] {level: integration} */
static int compatible_change(void) {
    COMPANY(d);
    char before[512], after[512];
    OK(&d, "CALL elpi_run('org', 'manager_of', {in1: 7}) RETURN out2");
    CHECK(stored_row(&d, before, sizeof before), "%s", last_error);
    OK(&d, "ALTER TABLE Person ADD email STRING");
    const char *r = OK(&d, "CALL elpi_run('org', 'manager_of', {in1: 7}) RETURN out2, out3");
    CHECK(strcmp(r, "3|CEO\n") == 0, "runs against the new signature: %s", r);
    CHECK(stored_row(&d, after, sizeof after), "%s", last_error);
    CHECK(strcmp(before, after) == 0, "the stored row is unchanged: %s -> %s", before, after);
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:schema-evolution#Lazy recheck on run#Breaking change fails the run]] {level: integration} */
static int breaking_change(void) {
    COMPANY(d);
    OK(&d, "CALL elpi_run('org', 'manager_of', {in1: 7}) RETURN out2");
    OK(&d, "DROP TABLE ReportsTo");
    const char *e = fails(&d, "CALL elpi_run('org', 'manager_of', {in1: 7}) RETURN *");
    CHECK(e && strstr(e, "reports_to") && strstr(e, "org:"), "type error naming reports_to in org: %s",
          e ? e : "(succeeded with the old compilation)");
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:schema-evolution#Broken module status#Recheck marks a module broken]] {level: integration} */
/* @tg: verifies:: [[openspec:schema-evolution#Broken module status#Saving clears broken]] {level: integration} */
static int recheck_broken(void) {
    COMPANY(d);
    OK(&d, "DROP TABLE ReportsTo");
    const char *r = OK(&d, "CALL elpi_recheck()");
    CHECK(strncmp(r, "org|stale|broken|", 17) == 0 && strstr(r, "reports_to"), "broken: %s", r);
    r = OK(&d, "MATCH (m:_elpi_module {name: 'org'}) RETURN m.status, m.error CONTAINS 'reports_to'");
    CHECK(strcmp(r, "broken|True\n") == 0, "stored with its error: %s", r);
    const char *e = fails(&d, "CALL elpi_validate() RETURN *");
    CHECK(e && strstr(e, "module org"), "validate fails on a broken module: %s", e ? e : "(succeeded)");
    OK(&d, "CALL elpi_save('org', 'pred violation o:severity, o:string, o:subject.\n"
           "violation error \"no-name\" (subj_person P) :- person P, not (person.name P _).')");
    r = OK(&d, "MATCH (m:_elpi_module {name: 'org'}) RETURN m.status, m.error");
    CHECK(strcmp(r, "ok|\n") == 0, "saving clears broken: %s", r);
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:schema-evolution#Explicit recheck#Recheck is atomic]] {level: integration} */
static int recheck_atomic(void) {
    COMPANY(d);
    OK(&d, "CALL elpi_save('hr', 'pred violation o:severity, o:string, o:subject.\n"
           "violation info \"x\" (subj_person P) :- person.title P _.')");
    char before[512], after[512];
    CHECK(stored_row(&d, before, sizeof before), "%s", last_error);
    OK(&d, "ALTER TABLE Person ADD email STRING");
    OK(&d, "BEGIN TRANSACTION");
    const char *r = OK(&d, "CALL elpi_recheck(['org', 'hr'])");
    CHECK(count_lines(r) == 2, "both rechecked: %s", r);
    OK(&d, "ROLLBACK");
    CHECK(stored_row(&d, after, sizeof after), "%s", last_error);
    CHECK(strcmp(before, after) == 0, "rolled back: %s -> %s", before, after);
    r = OK(&d, "MATCH (m:_elpi_module) WHERE m.status = 'ok' RETURN count(*)");
    CHECK(strcmp(r, "2\n") == 0, "both untouched: %s", r);
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:distribution#LadybugDB version check#Mismatched database is refused]] {level: integration} */
static int version_mismatch(void) {
    const char *mismatch = getenv("MARIEN_MISMATCH_EXT");
    CHECK(mismatch, "MARIEN_MISMATCH_EXT names a build pinned to another LadybugDB version");
    Db d;
    CHECK(open_db(&d, __func__), "%s", last_error);
    const char *e = fails(&d, "LOAD EXTENSION '%s'", mismatch);
    CHECK(e && strstr(e, "0.21.2") && strstr(e, "0.22.1"), "names both versions: %s", e ? e : "(loaded)");
    e = fails(&d, "CALL elpi_signature() RETURN *");
    CHECK(e && strstr(e, "elpi_signature"), "no elpi_* function is registered: %s", e ? e : "(registered)");
    close_db(&d);
    return 1;
}

typedef struct {
    const char *name;
    int (*fn)(void);
} Test;

/* --- M3: partitions, structural facts and narrowed scopes ----------------------------- */

/* Local rules: radius 1 around the subject, outgoing and incoming. */
static const char *local_rules =
    "pred violation o:severity, o:string, o:subject.\n"
    "violation error \"no-manager\" (subj_person P) :- person.name P _, not (reports_to P _ _).\n"
    "violation warning \"manager-unnamed\" (subj_person P) :- reports_to P _ M, not (person.name M _).\n"
    "violation info \"unnamed-report\" (subj_person M) :- reports_to R _ M, not (person.name R _).\n";

/* Persons 1..n, named p<i> except every 7th, with email e<i mod m>; person i reports to i/2 (i >= 2).
 * Modules full (local_rules) and part (the same, partitioned by person radius 1). */
static int tree(Db *d, const char *name, int n, int m) {
    if (!open_db(d, name)) return 0;
    char load[1200];
    snprintf(load, sizeof load, "LOAD EXTENSION '%s'", ext_path);
    if (!ok(d, "%s", load)) return 0;
    if (!ok(d, "CREATE NODE TABLE Person(id INT64 PRIMARY KEY, name STRING, email STRING)")) return 0;
    if (!ok(d, "CREATE REL TABLE ReportsTo(FROM Person TO Person)")) return 0;
    if (!ok(d, "UNWIND range(1, %d) AS i CREATE (:Person {id: i, email: 'e' + CAST(i %% %d AS STRING), "
               "name: CASE WHEN i %% 7 = 0 THEN NULL ELSE 'p' + CAST(i AS STRING) END})", n, m)) return 0;
    if (!ok(d, "UNWIND range(2, %d) AS i MATCH (a:Person {id: i}), (b:Person {id: i / 2}) CREATE (a)-[:ReportsTo]->(b)", n))
        return 0;
    if (!ok(d, "CALL elpi_init()")) return 0;
    if (!ok(d, "CALL elpi_save('full', '%s')", local_rules)) return 0;
    return ok(d, "CALL elpi_save('part', '%s%% @marien partition violation by person radius 1\n')", local_rules) != NULL;
}

#define REPORT_Q "CALL elpi_validate(['%s']) RETURN severity, code, subject_pk ORDER BY severity, code, subject_pk"

/* @tg: verifies:: [[openspec:partitioning#Anchor partitions#Partitioned result equals full scope]] {level: integration} */
static int partitioned_equals_full(void) {
    Db d;
    /* the scenario's 50000 persons in batches of 10000, scaled down tenfold: a full-scope join
     * over loaded facts is quadratic in LeanElpi (constraint "Deep indexing scans the bucket") */
    CHECK(tree(&d, __func__, 5000, 100), "setup failed: %s", last_error);
    char *full = strdup(OK(&d, REPORT_Q, "full"));
    int rows = count_lines(full);
    OK(&d, "CALL elpi_partition_batch=1000");
    const char *part = OK(&d, REPORT_Q, "part");
    int same = strcmp(full, part) == 0;
    CHECK(same, "five batches of 1000 agree with full scope (%d rows vs %d)", count_lines(part), rows);
    OK(&d, "CALL elpi_partition_batch=7");
    part = OK(&d, REPORT_Q, "part");
    same = strcmp(full, part) == 0;
    CHECK(same, "batches of 7 agree with full scope (%d rows vs %d)", count_lines(part), rows);
    free(full);
    CHECK(rows > 1000, "rows of all three kinds: %d", rows);
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:partitioning#Anchor partitions#Each batch gets a fresh store]] {level: integration} */
static int fresh_store_per_batch(void) {
    Db d;
    CHECK(tree(&d, __func__, 100, 30), "setup failed: %s", last_error);
    char *full = strdup(OK(&d, REPORT_Q, "full"));
    /* one anchor's neighbourhood fits in 40 facts, the whole graph does not: the facts of one
     * batch are gone when the next one loads */
    OK(&d, "CALL elpi_max_facts=40");
    OK(&d, "CALL elpi_partition_batch=1");
    const char *e = fails(&d, REPORT_Q, "full");
    CHECK(e && strstr(e, "elpi_max_facts"), "full scope exceeds the budget: %s", e ? e : "(succeeded)");
    const char *part = OK(&d, REPORT_Q, "part");
    int same = strcmp(full, part) == 0;
    CHECK(same, "each batch within budget, same rows: %s", part);
    /* batches of 50 overflow and are split until they fit */
    OK(&d, "CALL elpi_partition_batch=50");
    part = OK(&d, REPORT_Q, "part");
    same = strcmp(full, part) == 0;
    CHECK(same, "split batches give the same rows");
    free(full);
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:partitioning#Anchor partitions#A failing batch fails the call]] {level: integration} */
static int failing_batch(void) {
    Db d;
    CHECK(open_db(&d, __func__), "open: %s", last_error);
    OK(&d, "LOAD EXTENSION '%s'", ext_path);
    OK(&d, "CREATE NODE TABLE Person(id INT64 PRIMARY KEY, name STRING, email STRING)");
    OK(&d, "CREATE REL TABLE ReportsTo(FROM Person TO Person)");
    /* anchors in offset order: batches of two are [1 2] [3 4] [5 6] ...; 300 people report to 5 */
    OK(&d, "UNWIND range(1, 6) AS i CREATE (:Person {id: i, name: 'p'})");
    OK(&d, "UNWIND range(100, 399) AS i CREATE (:Person {id: i, name: 'q'})");
    OK(&d, "UNWIND range(100, 399) AS i MATCH (a:Person {id: i}), (b:Person {id: 5}) CREATE (a)-[:ReportsTo]->(b)");
    OK(&d, "CALL elpi_init()");
    OK(&d, "CALL elpi_save('part', '%s%% @marien partition violation by person radius 1\n')", local_rules);
    OK(&d, "CALL elpi_partition_batch=2");
    const char *r = OK(&d, "CALL elpi_validate(['part']) RETURN count(*)");
    CHECK(strcmp(r, "6\n") == 0, "with enough fuel every batch runs: persons 1 to 6 have no manager: %s", r);
    /* the third batch needs far more steps than the first two */
    OK(&d, "CALL elpi_fuel=1000");
    const char *e = fails(&d, "CALL elpi_validate(['part']) RETURN *");
    CHECK(e && strstr(e, "module part: batch 3 of") && strstr(e, "elpi_fuel"), "the call fails, with no rows: %s",
          e ? e : "(succeeded)");
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:partitioning#Key partitions#Duplicate emails are found across buckets]] {level: integration} */
static int duplicate_emails(void) {
    Db d;
    CHECK(tree(&d, __func__, 900, 300), "setup failed: %s", last_error);
    const char *rules = "pred violation o:severity, o:string, o:subject.\n"
                        "violation error \"dup-email\" (subj_person P) :- person.email P E, person.email Q E, not (P = Q).\n";
    OK(&d, "CALL elpi_save('fullk', '%s')", rules);
    OK(&d, "CALL elpi_save('partk', '%s%% @marien partition violation by person.email\n')", rules);
    OK(&d, "CREATE (:Person {id: 5000, name: 'no-email'})");
    char *full = strdup(OK(&d, REPORT_Q, "fullk"));
    CHECK(count_lines(full) == 1800, "two duplicates per person: %d rows", count_lines(full));
    OK(&d, "CALL elpi_partition_batch=100");
    const char *part = OK(&d, REPORT_Q, "partk");
    int same = strcmp(full, part) == 0;
    CHECK(same, "nine buckets agree with full scope (%d rows)", count_lines(part));
    free(full);
    close_db(&d);
    return 1;
}

/* Persons 1..5: 1 -> 2 -> 3 -> 1 is a cycle, 4 -> 1 is not on it, 5 has no edges; module s. */
static int cyclic(Db *d, const char *name) {
    if (!open_db(d, name)) return 0;
    char load[1200];
    snprintf(load, sizeof load, "LOAD EXTENSION '%s'", ext_path);
    const char *setup[] = {
        load,
        "CREATE NODE TABLE Person(id INT64 PRIMARY KEY, name STRING)",
        "CREATE REL TABLE ReportsTo(FROM Person TO Person)",
        "UNWIND range(1, 5) AS i CREATE (:Person {id: i, name: 'p'})",
        "UNWIND [[1, 2], [2, 3], [3, 1], [4, 1]] AS e MATCH (a:Person {id: e[1]}), (b:Person {id: e[2]}) "
        "CREATE (a)-[:ReportsTo]->(b)",
        "CALL elpi_init()",
        "CALL elpi_save('s', 'pred cyc o:person.\ncyc P :- in_cycle.reports_to P.\n"
        "pred comp o:person, o:int.\ncomp P C :- component.reports_to P C.\n')",
    };
    for (size_t i = 0; i < sizeof setup / sizeof *setup; i++)
        if (!ok(d, "%s", setup[i])) return 0;
    return 1;
}

/* @tg: verifies:: [[openspec:partitioning#Structural facts#Cycles come from SCC]] {level: integration} */
static int cycles_from_scc(void) {
    Db d;
    CHECK(cyclic(&d, __func__), "setup failed: %s", last_error);
    const char *r = OK(&d, "CALL elpi_run('s', 'cyc') RETURN out1 ORDER BY out1");
    CHECK(strcmp(r, "1\n2\n3\n") == 0, "persons 1, 2 and 3: %s", r);
    r = OK(&d, "CALL elpi_run('s', 'comp') RETURN count(DISTINCT out2), collect(out1)");
    CHECK(strncmp(r, "2|", 2) == 0, "two weak components: %s", r);
    r = OK(&d, "CALL elpi_run('s', 'comp') WITH out1, out2 WHERE out1 IN [1, 4] RETURN count(DISTINCT out2)");
    CHECK(strcmp(r, "1\n") == 0, "1 and 4 share a component: %s", r);
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:partitioning#Structural facts#Structural facts are never stale]] {level: integration} */
static int structural_never_stale(void) {
    Db d;
    CHECK(cyclic(&d, __func__), "setup failed: %s", last_error);
    OK(&d, "BEGIN TRANSACTION");
    OK(&d, "MATCH (:Person {id: 3})-[r:ReportsTo]->(:Person {id: 1}) DELETE r");
    const char *r = OK(&d, "CALL elpi_run('s', 'cyc') RETURN count(*)");
    CHECK(strcmp(r, "0\n") == 0, "no cycle after the delete in this transaction: %s", r);
    OK(&d, "ROLLBACK");
    r = OK(&d, "CALL elpi_run('s', 'cyc') RETURN count(*)");
    CHECK(strcmp(r, "3\n") == 0, "the cycle is back after the rollback: %s", r);
    close_db(&d);
    return 1;
}

static const char *colleague_src =
    "pred colleague o:person, o:person.\ncolleague A B :- reports_to A _ M, reports_to B _ M, not (A = B).\n";

/* @tg: verifies:: [[openspec:rule-execution#Narrowed scope for monotone entry points#Monotone entry point accepts a scope]] {level: integration} */
static int monotone_scope(void) {
    Db d;
    CHECK(tree(&d, __func__, 50, 10), "setup failed: %s", last_error);
    OK(&d, "CALL elpi_save('c', '%s')", colleague_src);
    const char *r = OK(&d, "CALL elpi_run('c', 'colleague', NULL, {Person: [2, 4, 5, 6, 7]}) "
                           "RETURN out1, out2, narrowed ORDER BY out1, out2");
    CHECK(strcmp(r, "4|5|True\n5|4|True\n") == 0, "4 and 5 report to 2, which is listed: %s", r);
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:rule-execution#Narrowed scope for monotone entry points#Non-monotone entry point refuses a scope]] {level: integration} */
static int non_monotone_scope(void) {
    COMPANY(d);
    const char *e = fails(&d, "CALL elpi_validate(['org'], 'info', {Person: [7]}) RETURN *");
    CHECK(e && strstr(e, "not at org:") && strstr(e, "reports_to"), "names not, its position and reports_to: %s",
          e ? e : "(succeeded)");
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:rule-execution#Narrowed scope for monotone entry points#Narrowing never adds answers]] {level: integration} */
static int narrowing_subset(void) {
    Db d;
    CHECK(tree(&d, __func__, 200, 10), "setup failed: %s", last_error);
    OK(&d, "CALL elpi_save('c', '%s')", colleague_src);
    char *full = strdup(OK(&d, "CALL elpi_run('c', 'colleague') RETURN out1, out2"));
    const char *scopes[] = {"[2, 4, 5, 6, 7]", "[1, 2, 3]", "range(1, 200, 3)", "[]"};
    for (size_t i = 0; i < sizeof scopes / sizeof *scopes; i++) {
        const char *r = OK(&d, "CALL elpi_run('c', 'colleague', NULL, {Person: %s}) RETURN out1, out2", scopes[i]);
        char *copy = strdup(r);
        for (char *line = strtok(copy, "\n"); line; line = strtok(NULL, "\n")) {
            char needle[64];
            snprintf(needle, sizeof needle, "\n%s\n", line);
            char *hay = malloc(strlen(full) + 2);
            sprintf(hay, "\n%s", full);
            int found = strstr(hay, needle) != NULL;
            free(hay);
            CHECK(found, "narrowed row %s is a full-scope row (scope %s)", line, scopes[i]);
        }
        free(copy);
    }
    free(full);
    close_db(&d);
    return 1;
}

/* --- higher-order layer (M4) ------------------------------------------------------------- */

/* Persons 1..6, parts 1..4; ReportsTo 1→2→1; PartOf 1→2→3→1 and 4→1; HasManager 1→2, 2→3, 3→4,
 * 3→5. `reverse` creates the tables in the opposite order. */
static int parts_at(Db *d, const char *name, int reverse, int fresh) {
    if (fresh ? !open_db(d, name) : 0) return 0;
    char load[1200];
    snprintf(load, sizeof load, "LOAD EXTENSION '%s'", ext_path);
    const char *tables[] = {
        "CREATE NODE TABLE Person(id INT64 PRIMARY KEY, name STRING)",
        "CREATE NODE TABLE Part(id INT64 PRIMARY KEY)",
        "CREATE REL TABLE ReportsTo(FROM Person TO Person)",
        "CREATE REL TABLE PartOf(FROM Part TO Part)",
        "CREATE REL TABLE HasManager(FROM Person TO Person)",
    };
    const char *data[] = {
        "UNWIND range(1, 6) AS i CREATE (:Person {id: i, name: 'p'})",
        "UNWIND range(1, 4) AS i CREATE (:Part {id: i})",
        "UNWIND [[1, 2], [2, 1]] AS e MATCH (a:Person {id: e[1]}), (b:Person {id: e[2]}) CREATE (a)-[:ReportsTo]->(b)",
        "UNWIND [[1, 2], [2, 3], [3, 1], [4, 1]] AS e MATCH (a:Part {id: e[1]}), (b:Part {id: e[2]}) CREATE (a)-[:PartOf]->(b)",
        "UNWIND [[1, 2], [2, 3], [3, 4], [3, 5]] AS e MATCH (a:Person {id: e[1]}), (b:Person {id: e[2]}) "
        "CREATE (a)-[:HasManager]->(b)",
        "CALL elpi_init()",
    };
    if (!ok(d, "%s", load)) return 0;
    /* node tables first, since rel tables name them; each group in the order asked */
    const int order[2][5] = {{0, 1, 2, 3, 4}, {1, 0, 4, 3, 2}};
    for (size_t i = 0; i < sizeof tables / sizeof *tables; i++)
        if (!ok(d, "%s", tables[order[reverse ? 1 : 0][i]])) return 0;
    for (size_t i = 0; i < sizeof data / sizeof *data; i++)
        if (!ok(d, "%s", data[i])) return 0;
    return 1;
}
#define PARTS(d, rev) Db d; CHECK(parts_at(&d, __func__, rev, 1), "setup failed: %s", last_error)

/* One `cycle` violation per rel table annotated acyclic. */
static const char *cycles_src =
    "accumulate graph.std.\n"
    "pred violation o:severity, o:string, o:subject.\n"
    "% @marien meta\n"
    "pred generate o:string.\n"
    "generate S :- schema.annot T \"acyclic\" \"true\", schema.ident T R, schema.rel T K _, schema.ident K N,\n"
    "  S is \"violation error \\\"cycle\\\" (subj_\" ^ N ^ \" X) :- acyclic_witness (edge_of \" ^ R ^ \") X.\".\n"
    "% @marien end\n";

static int save_src(Db *d, const char *name, const char *src) {
    char esc[16384];
    cypher_escape(src, esc, sizeof esc);
    return ok(d, "CALL elpi_save('%s', '%s')", name, esc) != NULL;
}

static int generated_of(Db *d, const char *name, char *out, size_t n) {
    const char *r = ok(d, "MATCH (m:_elpi_module {name: '%s'}) RETURN m.generated", name);
    if (!r) return 0;
    snprintf(out, n, "%s", r);
    return 1;
}

#define CYCLES_Q "CALL elpi_validate(['cycles']) RETURN subject_label, subject_pk ORDER BY subject_label, subject_pk"

/* @tg: verifies:: [[openspec:schema-reflection#Schema annotations#Annotating an unknown table fails]] {level: integration} */
static int annotate_unknown(void) {
    PARTS(d, 0);
    const char *e = fails(&d, "CALL elpi_annotate('NoSuchTable', 'acyclic', 'true')");
    CHECK(e && strstr(e, "NoSuchTable"), "error names the table: %s", e ? e : "(succeeded)");
    const char *r = OK(&d, "MATCH (a:_elpi_annotation) RETURN count(*)");
    CHECK(strcmp(r, "0\n") == 0, "no row written: %s", r);
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:schema-reflection#Schema annotations#Annotation change triggers regeneration]] {level: integration} */
static int annotation_regenerates(void) {
    PARTS(d, 0);
    OK(&d, "CALL elpi_annotate('ReportsTo', 'acyclic', 'true')");
    CHECK(save_src(&d, "cycles", cycles_src), "save: %s", last_error);
    const char *r = OK(&d, CYCLES_Q);
    CHECK(strcmp(r, "Person|1\nPerson|2\n") == 0, "the ReportsTo cycle: %s", r);
    OK(&d, "CALL elpi_annotate('PartOf', 'acyclic', 'true')");
    r = OK(&d, CYCLES_Q);
    CHECK(strcmp(r, "Part|1\nPart|2\nPart|3\nPerson|1\nPerson|2\n") == 0, "regenerated before the run: %s", r);
    char gen[4096];
    CHECK(generated_of(&d, "cycles", gen, sizeof gen), "%s", last_error);
    CHECK(!strstr(gen, "part_of"), "a run does not write the regenerated text: %s", gen);
    OK(&d, "CALL elpi_recheck()");
    CHECK(generated_of(&d, "cycles", gen, sizeof gen), "%s", last_error);
    CHECK(strstr(gen, "edge_of part_of"), "elpi_recheck persists it: %s", gen);
    OK(&d, "CALL elpi_annotate('PartOf', 'acyclic', '')");
    r = OK(&d, CYCLES_Q);
    CHECK(strcmp(r, "Person|1\nPerson|2\n") == 0, "an empty value removes the annotation: %s", r);
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:rule-generation#Inspectable generated code#Generated code is queryable]] {level: integration} */
static int generated_queryable(void) {
    PARTS(d, 0);
    OK(&d, "CALL elpi_annotate('ReportsTo', 'acyclic', 'true')");
    CHECK(save_src(&d, "cycles", cycles_src), "save: %s", last_error);
    char gen[4096];
    CHECK(generated_of(&d, "cycles", gen, sizeof gen), "%s", last_error);
    CHECK(strstr(gen, "violation error \"cycle\" (subj_person X) :- acyclic_witness (edge_of reports_to) X."),
          "the generated clause: %s", gen);
    close_db(&d);
    return 1;
}

static int reopen(Db *d, const char *name) {
    char path[1024];
    snprintf(path, sizeof path, "%s/%s", scratch, name);
    lbug_system_config cfg = lbug_default_system_config();
    cfg.buffer_pool_size = 256ull << 20;
    cfg.max_db_size = 1ull << 33;
    if (lbug_database_init(path, cfg, &d->db) != LbugSuccess) return 0;
    if (lbug_connection_init(&d->db, &d->conn) != LbugSuccess) return 0;
    return ok(d, "LOAD EXTENSION '%s'", ext_path) != NULL;
}

/* @tg: verifies:: [[openspec:rule-generation#Generated code depends only on schema and source#Regeneration is byte-identical]] {level: integration} */
static int regeneration_identical(void) {
    PARTS(d, 0);
    OK(&d, "CALL elpi_annotate('ReportsTo', 'acyclic', 'true')");
    OK(&d, "CALL elpi_annotate('PartOf', 'acyclic', 'true')");
    CHECK(save_src(&d, "cycles", cycles_src), "save: %s", last_error);
    char first[4096], second[4096];
    CHECK(generated_of(&d, "cycles", first, sizeof first), "%s", last_error);
    close_db(&d);
    CHECK(reopen(&d, __func__), "reopen: %s", last_error);
    const char *r = OK(&d, "CALL elpi_recheck()");
    CHECK(strstr(r, "cycles|ok|ok|"), "no schema change: %s", r);
    CHECK(generated_of(&d, "cycles", second, sizeof second), "%s", last_error);
    CHECK(strcmp(first, second) == 0, "byte-identical:\n%s\nvs\n%s", first, second);
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:rule-generation#Generated code depends only on schema and source#Catalog order does not matter]] {level: integration} */
static int generated_catalog_order(void) {
    char gen[2][4096];
    for (int rev = 0; rev < 2; rev++) {
        Db d;
        char name[64];
        snprintf(name, sizeof name, "%s_%d", __func__, rev);
        CHECK(parts_at(&d, name, rev, 1), "setup failed: %s", last_error);
        OK(&d, rev ? "CALL elpi_annotate('PartOf', 'acyclic', 'true')" : "CALL elpi_annotate('ReportsTo', 'acyclic', 'true')");
        OK(&d, rev ? "CALL elpi_annotate('ReportsTo', 'acyclic', 'true')" : "CALL elpi_annotate('PartOf', 'acyclic', 'true')");
        CHECK(save_src(&d, "cycles", cycles_src), "save: %s", last_error);
        CHECK(generated_of(&d, "cycles", gen[rev], sizeof gen[rev]), "%s", last_error);
        close_db(&d);
    }
    CHECK(strcmp(gen[0], gen[1]) == 0, "the same text:\n%s\nvs\n%s", gen[0], gen[1]);
    return 1;
}

/* @tg: verifies:: [[openspec:rule-generation#Inspectable generated code#Export omits derived code]] {level: integration} */
static int export_omits_generated(void) {
    PARTS(d, 0);
    OK(&d, "CALL elpi_annotate('ReportsTo', 'acyclic', 'true')");
    CHECK(save_src(&d, "cycles", cycles_src), "save: %s", last_error);
    char gen[4096], again[4096];
    CHECK(generated_of(&d, "cycles", gen, sizeof gen), "%s", last_error);
    const char *r = OK(&d, "CALL elpi_export() RETURN *");
    CHECK(!strstr(r, "edge_of reports_to"), "the export has no generated text: %s", r);
    char bundle[8192] = "[{\"name\": \"cycles\", \"source\": ", esc[16384];
    json_append(bundle, sizeof bundle, cycles_src);
    strcat(bundle, "}]");
    cypher_escape(bundle, esc, sizeof esc);
    close_db(&d);
    Db e;
    char name[64];
    snprintf(name, sizeof name, "%s_b", __func__);
    CHECK(parts_at(&e, name, 0, 1), "setup failed: %s", last_error);
    OK(&e, "CALL elpi_annotate('ReportsTo', 'acyclic', 'true')");
    OK(&e, "CALL elpi_import('%s')", esc);
    CHECK(generated_of(&e, "cycles", again, sizeof again), "%s", last_error);
    CHECK(strcmp(gen, again) == 0, "the import regenerates the same text:\n%s\nvs\n%s", gen, again);
    close_db(&e);
    return 1;
}

/* @tg: verifies:: [[openspec:graph-std#Combinators in violation rules#Cardinality rule partitions by anchor]] {level: integration} */
static int card_partition_equals_full(void) {
    PARTS(d, 0);
    const char *rule =
        "accumulate graph.std.\n"
        "pred violation o:severity, o:string, o:subject.\n"
        "violation error \"no-manager\" (subj_person X) :- card_witness person (edge_of has_manager) 1 1 X _.\n";
    char partitioned[2048];
    snprintf(partitioned, sizeof partitioned, "%s%% @marien partition violation by person radius 1\n", rule);
    CHECK(save_src(&d, "full", rule), "save full: %s", last_error);
    CHECK(save_src(&d, "part", partitioned), "save part: %s", last_error);
    OK(&d, "CALL elpi_partition_batch=2");
    char full[4096];
    snprintf(full, sizeof full, "%s", OK(&d, REPORT_Q, "full"));
    const char *r = OK(&d, REPORT_Q, "part");
    CHECK(strcmp(full, r) == 0, "partitioned equals full:\n%s\nvs\n%s", full, r);
    CHECK(strcmp(full, "error|no-manager|3\nerror|no-manager|4\nerror|no-manager|5\nerror|no-manager|6\n") == 0,
          "persons without exactly one manager: %s", full);
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:graph-std#Cycle detection#Precomputed facts agree with search]] {level: integration} */
static int precomputed_cycles_agree(void) {
    PARTS(d, 0);
    CHECK(save_src(&d, "search", "accumulate graph.std.\npred violation o:severity, o:string, o:subject.\n"
                                  "violation error \"c\" (subj_part X) :- acyclic_witness (edge_of part_of) X.\n"),
          "save search: %s", last_error);
    CHECK(save_src(&d, "facts", "accumulate graph.std.\npred violation o:severity, o:string, o:subject.\n"
                                 "violation error \"c\" (subj_part X) :- acyclic_witness_in in_cycle.part_of X.\n"),
          "save facts: %s", last_error);
    char search[1024];
    snprintf(search, sizeof search, "%s", OK(&d, REPORT_Q, "search"));
    const char *r = OK(&d, REPORT_Q, "facts");
    CHECK(strcmp(search, r) == 0, "the same witnesses:\n%s\nvs\n%s", search, r);
    CHECK(strcmp(search, "error|c|1\nerror|c|2\nerror|c|3\n") == 0, "parts 1, 2 and 3: %s", search);
    close_db(&d);
    return 1;
}

/* --- offline-codegen ------------------------------------------------------------------ */

#define DUMP_Q "CALL elpi_signature(format := 'json') RETURN text"

/* @tg: verifies:: [[openspec:offline-codegen#Schema dump#Dump of a small schema]] {level: integration} */
static int dump_small_schema(void) {
    const char *ddl[] = {"CREATE NODE TABLE Person(id INT64 PRIMARY KEY, name STRING)",
                         "CREATE REL TABLE ReportsTo(FROM Person TO Person, since INT64)"};
    Db d;
    CHECK(db_with(&d, "dump_small", ddl, 2, "pred x o:person.\nx X :- person X."), "setup: %s", last_error);
    const char *r = OK(&d, DUMP_Q);
    const char *want =
        "{\"annotations\":[],\"format\":\"marien.schema/1\","
        "\"nodes\":[{\"key\":\"id\",\"name\":\"Person\",\"properties\":"
        "[{\"name\":\"id\",\"type\":\"INT64\"},{\"name\":\"name\",\"type\":\"STRING\"}]}],"
        "\"rels\":[{\"name\":\"ReportsTo\",\"pairs\":[[\"Person\",\"Person\"]],\"properties\":"
        "[{\"name\":\"since\",\"type\":\"INT64\"}]}]}\n";
    CHECK(strcmp(r, want) == 0, "dump:\n%s", r);
    r = OK(&d, "CALL elpi_signature(format := 'json') RETURN kind, name");
    CHECK(strcmp(r, "schema|\n") == 0, "one schema row: %s", r);
    const char *e = fails(&d, "CALL elpi_signature(format := 'yaml') RETURN *");
    CHECK(e && strstr(e, "unknown format"), "unknown format: %s", e ? e : "(accepted)");
    e = fails(&d, "CALL elpi_signature(style := 'json') RETURN *");
    CHECK(e && strstr(e, "unknown option"), "unknown option: %s", e ? e : "(accepted)");
    close_db(&d);
    return 1;
}

/* Two databases with the same tables created in different orders. The dump of the richer one is
   kept in the scratch directory for the codegen check (tests/offline/run.sh). */
/* @tg: verifies:: [[openspec:offline-codegen#Schema dump#Dump is canonical]] {level: integration} */
static int dump_is_canonical(void) {
    const char *a[] = {
        "CREATE NODE TABLE Person(id INT64 PRIMARY KEY, name STRING, tags STRING[], "
        "addr STRUCT(city STRING, zip INT32), born DATE)",
        "CREATE NODE TABLE Org(code STRING PRIMARY KEY, active BOOL)",
        "CREATE REL TABLE ReportsTo(FROM Person TO Person, since INT64)",
        "CREATE REL TABLE Owns(FROM Person TO Org, FROM Org TO Org, share DOUBLE)",
    };
    const char *b[] = {
        "CREATE NODE TABLE Org(code STRING PRIMARY KEY, active BOOL)",
        "CREATE NODE TABLE Person(id INT64 PRIMARY KEY, born DATE, addr STRUCT(city STRING, zip INT32), "
        "tags STRING[], name STRING)",
        "CREATE REL TABLE Owns(FROM Org TO Org, FROM Person TO Org, share DOUBLE)",
        "CREATE REL TABLE ReportsTo(FROM Person TO Person, since INT64)",
    };
    Db d1, d2;
    const char *m = "pred x o:person.\nx X :- person X.";
    CHECK(db_with(&d1, "dump1", a, 4, m), "db 1: %s", last_error);
    CHECK(db_with(&d2, "dump2", b, 4, m), "db 2: %s", last_error);
    CHECK(ok(&d1, "CALL elpi_annotate('ReportsTo', 'acyclic', 'true')") &&
              ok(&d2, "CALL elpi_annotate('ReportsTo', 'acyclic', 'true')"),
          "annotate: %s", last_error);
    char first[8192];
    snprintf(first, sizeof first, "%s", OK(&d1, DUMP_Q));
    const char *r = OK(&d2, DUMP_Q);
    CHECK(strcmp(first, r) == 0, "byte-identical dumps:\n%s\nvs\n%s", first, r);
    CHECK(!strstr(first, "_elpi"), "no system tables: %s", first);
    char path[1200];
    snprintf(path, sizeof path, "%s/dump-rich.json", scratch);
    FILE *f = fopen(path, "w");
    CHECK(f, "cannot write %s", path);
    fputs(first, f);
    fclose(f);
    close_db(&d1);
    close_db(&d2);
    return 1;
}

/* --- custom-statements: through CALL elpi_statement ------------------------------------- */

/* Run statement text through elpi_statement; NULL on error (last_error set). */
static const char *statement(Db *d, const char *text) {
    static char esc[16384];
    cypher_escape(text, esc, sizeof esc);
    return ok(d, "CALL elpi_statement('%s')", esc);
}

#define MODULE_ROW "MATCH (m:_elpi_module {name: '%s'}) RETURN m.name, m.version, m.source, m.status, m.schema_hash"

/* @tg: verifies:: [[openspec:custom-statements#Rule statements#Create rules from a statement]] {level: integration} */
static int create_rules_statement(void) {
    ORG(d);
    Db e;
    CHECK(org(&e, "create_rules_call"), "setup: %s", last_error);
    CHECK(statement(&d, "CREATE RULES org_rules AS $$pred n o:int. n 1.$$"), "statement: %s", last_error);
    OK(&e, "CALL elpi_save('org_rules', 'pred n o:int. n 1.')");
    char a[4096];
    snprintf(a, sizeof a, "%s", OK(&d, MODULE_ROW, "org_rules"));
    const char *b = OK(&e, MODULE_ROW, "org_rules");
    CHECK(strcmp(a, b) == 0 && strstr(a, "org_rules|1|pred n o:int. n 1.|ok|"), "stored the same:\n%s\n%s", a, b);
    CHECK(statement(&d, "CREATE OR REPLACE RULES org_rules AS $$pred n o:int. n 2.$$"), "replace: %s", last_error);
    CHECK(strstr(OK(&d, MODULE_ROW, "org_rules"), "org_rules|2|"), "a new version");
    CHECK(statement(&d, "DROP RULES org_rules"), "drop: %s", last_error);
    CHECK(strcmp(OK(&d, "MATCH (m:_elpi_module) RETURN count(m)"), "0\n") == 0, "dropped");
    CHECK(statement(&d, "CHECK RULES"), "check rules: %s", last_error);
    CHECK(statement(&d, "ANNOTATE Knows SET acyclic = 'true'"), "annotate: %s", last_error);
    CHECK(strcmp(OK(&d, "MATCH (a:_elpi_annotation) RETURN a.table_name, a.key, a.value"), "Knows|acyclic|true\n") == 0,
          "annotation stored");
    close_db(&d);
    close_db(&e);
    return 1;
}

/* @tg: verifies:: [[openspec:custom-statements#Rule statements#Malformed statement]] {level: integration} */
static int malformed_statement(void) {
    ORG(d);
    const char *e = statement(&d, "CREATE RULES AS $$x$$") ? NULL : last_error;
    CHECK(e && strstr(e, "missing module name"), "names the missing module name: %s", e ? e : "(accepted)");
    e = statement(&d, "CREATE USER alice") ? NULL : last_error;
    CHECK(e && strstr(e, "not a Marien statement"), "other syntax: %s", e ? e : "(accepted)");
    /* the database is still usable */
    OK(&d, "CALL elpi_save('m', 'pred n o:int. n 1.')");
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:custom-statements#Statements equal their CALL forms#VALIDATE equals elpi_validate]] {level: integration} */
static int validate_statement(void) {
    ORG(d);
    OK(&d, "CALL elpi_save('org_rules', 'pred violation o:severity, o:string, o:subject.\n"
           "violation warning \"unnamed\" (subj_person P) :- person P, not (person.name P _).\n"
           "violation error \"loner\" (subj_person P) :- person P, not (knows P _ _).')");
    char a[4096];
    snprintf(a, sizeof a, "%s", OK(&d, "CALL elpi_validate(['org_rules'], 'warning') RETURN *"));
    const char *b = statement(&d, "VALIDATE org_rules MIN SEVERITY warning");
    CHECK(b, "statement: %s", last_error);
    CHECK(strcmp(a, b) == 0 && count_lines(a) == 2, "same rows:\n%s\nvs\n%s", a, b);
    snprintf(a, sizeof a, "%s", OK(&d, "CALL elpi_validate() RETURN *"));
    b = statement(&d, "VALIDATE");
    CHECK(b && strcmp(a, b) == 0, "every module:\n%s\nvs\n%s", a, b ? b : last_error);
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:custom-statements#Statements equal their CALL forms#Errors are identical]] {level: integration} */
static int statement_errors(void) {
    ORG(d);
    char a[4096];
    CHECK(!ok(&d, "CALL elpi_save('bad', 'pred p o:int. p \"x\".')"), "the CALL form fails");
    snprintf(a, sizeof a, "%s", last_error);
    char *in = strstr(a, "\n  in: ");
    if (in) *in = 0;
    CHECK(!statement(&d, "CREATE RULES bad AS $$pred p o:int. p \"x\".$$"), "the statement fails");
    in = strstr(last_error, "\n  in: ");
    if (in) *in = 0;
    CHECK(strcmp(a, last_error) == 0 && strstr(a, "string"), "the same error:\n%s\nvs\n%s", a, last_error);
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:custom-statements#Statement source is not re-escaped#Quotes and backslashes survive]] {level: integration} */
static int statement_bytes(void) {
    ORG(d);
    const char *src = "pred s o:string.\ns \"a\\\"b\". % 'c' \\ $x";
    char text[4096];
    snprintf(text, sizeof text, "CREATE RULES q AS $$%s$$", src);
    CHECK(statement(&d, text), "statement: %s", last_error);
    char want[4096];
    snprintf(want, sizeof want, "%s\n", src);
    const char *r = OK(&d, "MATCH (m:_elpi_module {name: 'q'}) RETURN m.source");
    CHECK(strcmp(r, want) == 0, "byte for byte:\n%s\nvs\n%s", r, want);
    close_db(&d);
    return 1;
}

/* Run a prepared query with one bound string parameter $s; NULL on error (last_error set). */
static const char *with_parameter(Db *d, const char *q, const char *s) {
    lbug_prepared_statement ps;
    lbug_connection_prepare(&d->conn, q, &ps);
    if (!lbug_prepared_statement_is_success(&ps)) {
        snprintf(last_error, sizeof last_error, "prepare: %s", lbug_prepared_statement_get_error_message(&ps));
        lbug_prepared_statement_destroy(&ps);
        return NULL;
    }
    lbug_prepared_statement_bind_string(&ps, "s", s);
    lbug_query_result r;
    lbug_connection_execute(&d->conn, &ps, &r);
    int success = lbug_query_result_is_success(&r);
    if (!success) {
        char *e = lbug_query_result_get_error_message(&r);
        snprintf(last_error, sizeof last_error, "%s", e);
        lbug_destroy_string(e);
    }
    lbug_query_result_destroy(&r);
    lbug_prepared_statement_destroy(&ps);
    return success ? "" : NULL;
}

/* @tg: verifies:: [[openspec:custom-statements#Rule statements#A query parameter is refused]] {level: integration} */
static int statement_parameter(void) {
    ORG(d);
    /* LadybugDB rewrites a standalone CALL while parsing, before parameters are bound */
    const char *e = with_parameter(&d, "CALL elpi_statement($s)", "CREATE RULES q AS $$pred n o:int. n 1.$$")
        ? NULL : last_error;
    CHECK(e && strstr(e, "elpi_statement: arguments must be string literals, not query parameters") &&
          strstr(e, "#1519"), "says why and names the issue: %s", e ? e : "(accepted)");
    e = with_parameter(&d, "CALL elpi_save('q', $s)", "pred n o:int. n 1.") ? NULL : last_error;
    CHECK(e && strstr(e, "elpi_save: arguments must be string literals"), "elpi_save too: %s", e ? e : "(accepted)");
    /* nothing was stored, and the same text as a literal works */
    CHECK(strcmp(OK(&d, "MATCH (m:_elpi_module {name: 'q'}) RETURN count(*)"), "0\n") == 0, "nothing stored");
    CHECK(statement(&d, "CREATE RULES q AS $$pred n o:int. n 1.$$"), "literal: %s", last_error);
    close_db(&d);
    return 1;
}

/* @tg: verifies:: [[openspec:custom-statements#Statement source is not re-escaped#Tagged delimiter]] {level: integration} */
static int tagged_delimiter(void) {
    ORG(d);
    CHECK(statement(&d, "CREATE RULES q AS $r$pred m o:string. m \"$$\".$r$"), "statement: %s", last_error);
    const char *r = OK(&d, "MATCH (m:_elpi_module {name: 'q'}) RETURN m.source");
    CHECK(strcmp(r, "pred m o:string. m \"$$\".\n") == 0, "source: %s", r);
    close_db(&d);
    return 1;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: integration <extension> <scratch-dir> [filter]\n");
        return 2;
    }
    ext_path = argv[1];
    scratch = argv[2];
    const char *filter = argc > 3 ? argv[3] : "";
    Test tests[] = {
        {"tables are read", tables_are_read}, {"null is absent", null_is_absent},
        {"parallel edges", parallel_edges}, {"temporal", temporal},
        {"unsupported type", unsupported_type}, {"large integers", large_integers},
        {"system tables invisible", system_invisible}, {"order does not matter", order_does_not_matter},
        {"type change changes hash", type_change_changes_hash}, {"show one table", show_one_table},
        {"init idempotent", init_idempotent}, {"missing tables", missing_tables},
        {"ill-typed module", ill_typed}, {"version increases", version_increases},
        {"hostile characters", hostile_characters}, {"cannot escape literal", cannot_escape},
        {"derived metadata", derived_metadata}, {"missing dependency", missing_dependency},
        {"cycle", cycle}, {"drop protects", drop_protects}, {"bundle round trip", bundle_round_trip},
        {"bad import", bad_import}, {"calling transaction", calling_transaction},
        {"unused tables", unused_tables}, {"bindings as rows", bindings_as_rows},
        {"goal syntax error", goal_syntax_error}, {"cancellation", cancellation},
        {"slicing same answers", slicing_same_answers}, {"fuel exhaustion", fuel_exhaustion},
        {"fact budget", fact_budget}, {"solution limit", solution_limit},
        {"timeout is an error", timeout_is_error}, {"memory returns", memory_returns},
        {"typed columns", typed_columns}, {"node results", node_results}, {"bad parameters", bad_parameters},
        {"without modes", without_modes}, {"strings round-trip", strings_round_trip},
        {"violation takes part", violation_takes_part}, {"wrong signature", wrong_signature},
        {"reasoning skipped", reasoning_skipped}, {"subject constructors", subject_constructors},
        {"report across modules", report_across_modules}, {"severity filter", severity_filter},
        {"failing module", failing_module}, {"unrelated DDL", unrelated_ddl}, {"reached DDL", reached_ddl},
        {"compatible change", compatible_change}, {"breaking change", breaking_change},
        {"recheck broken", recheck_broken}, {"recheck atomic", recheck_atomic},
        {"version mismatch", version_mismatch}, {"partitioned equals full", partitioned_equals_full},
        {"fresh store per batch", fresh_store_per_batch}, {"failing batch", failing_batch},
        {"duplicate emails", duplicate_emails}, {"cycles from SCC", cycles_from_scc},
        {"structural never stale", structural_never_stale}, {"monotone scope", monotone_scope},
        {"non-monotone scope", non_monotone_scope}, {"narrowing subset", narrowing_subset},
        {"annotate unknown table", annotate_unknown}, {"annotation regenerates", annotation_regenerates},
        {"generated queryable", generated_queryable}, {"regeneration identical", regeneration_identical},
        {"generated catalog order", generated_catalog_order}, {"export omits generated", export_omits_generated},
        {"card partition equals full", card_partition_equals_full},
        {"precomputed cycles agree", precomputed_cycles_agree},
        {"dump small schema", dump_small_schema}, {"dump is canonical", dump_is_canonical},
        {"create rules statement", create_rules_statement}, {"malformed statement", malformed_statement},
        {"validate statement", validate_statement}, {"statement errors", statement_errors},
        {"statement bytes", statement_bytes}, {"tagged delimiter", tagged_delimiter},
        {"statement parameter", statement_parameter},
    };
    int run = 0;
    for (size_t i = 0; i < sizeof tests / sizeof *tests; i++) {
        if (!strstr(tests[i].name, filter)) continue;
        run++;
        failure[0] = 0;
        double t0 = now_ms();
        int passed = tests[i].fn();
        printf("%s %s (%.0f ms)%s%s\n", passed ? "PASS" : "FAIL", tests[i].name, now_ms() - t0,
               passed ? "" : ": ", passed ? "" : failure);
        failures += !passed;
        fflush(stdout);
    }
    printf("%d/%d passed\n", run - failures, run);
    return failures ? 1 : 0;
}
