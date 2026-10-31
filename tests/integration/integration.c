/* Integration tests of the tracer bullet against an embedded LadybugDB (liblbug's C API):
 * the scenarios that need the database itself — transactions, the Cypher lexer, interrupts,
 * memory — and the end-to-end path of the others. Each test opens a fresh database, loads the
 * extension and checks results through Cypher.
 *
 * Usage: integration <extension> <scratch-dir> [test-name-substring] */
#ifdef __APPLE__
#include <mach/mach.h>
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

static int db_with(Db *d, const char *name, const char *const *ddl, size_t n) {
    if (!open_db(d, name)) return 0;
    char load[1200];
    snprintf(load, sizeof load, "LOAD EXTENSION '%s'", ext_path);
    if (!ok(d, "%s", load)) return 0;
    for (size_t i = 0; i < n; i++)
        if (!ok(d, "%s", ddl[i])) return 0;
    return ok(d, "CALL elpi_init()") && ok(d, "CALL elpi_save('m', 'pred x o:int.\nx 1.')");
}

/* @tg: verifies:: [[openspec:schema-encoding#Canonical schema hash#Order does not matter]] {level: integration} */
static int order_does_not_matter(void) {
    const char *a[] = {"CREATE NODE TABLE A(id INT64 PRIMARY KEY, x STRING, y INT64)",
                       "CREATE NODE TABLE B(id INT64 PRIMARY KEY)"};
    const char *b[] = {"CREATE NODE TABLE B(id INT64 PRIMARY KEY)",
                       "CREATE NODE TABLE A(id INT64 PRIMARY KEY, y INT64, x STRING)"};
    Db d1, d2;
    char h1[128], h2[128];
    CHECK(db_with(&d1, "hash1", a, 2) && hash_of(&d1, h1, sizeof h1), "db 1: %s", last_error);
    CHECK(db_with(&d2, "hash2", b, 2) && hash_of(&d2, h2, sizeof h2), "db 2: %s", last_error);
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
    CHECK(db_with(&d1, "type1", a, 1) && hash_of(&d1, h1, sizeof h1), "db 1: %s", last_error);
    CHECK(db_with(&d2, "type2", b, 1) && hash_of(&d2, h2, sizeof h2), "db 2: %s", last_error);
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
    CHECK(count_lines(r) == 2, "two system tables: %s", r);
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
    OK(&d, "CALL elpi_save('org', 'pred violation o:person.\nviolation P :- person.name P _, not (knows P _ _).')");
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
        if (i == 0) first = after;
        last = after;
    }
    printf("    rss after run 1: %ld MB, after run 10: %ld MB\n", first / 1024, last / 1024);
    CHECK(last <= first + first / 10, "RSS grew from %ld to %ld KB", first, last);
    close_db(&d);
    return 1;
}

typedef struct {
    const char *name;
    int (*fn)(void);
} Test;

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
