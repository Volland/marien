/* Spike harness against liblbug's C API:
 *   load     — LOAD in two connections of one database and in a second database; the Lean
 *              runtime must start exactly once and every connection must answer.
 *   stress   — T connections call LEAN_PING() N times each on their own threads.
 *   failinit — LOAD with MARIEN_SPIKE_FAIL_INIT set must fail and register nothing.
 * Usage: stress <mode> <db-dir> <extension> [threads] [calls] */
#ifdef __APPLE__
#include <mach/mach.h>
#endif
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>

#include "lbug.h"

static const char *ext_path;
static lbug_database db;
static int calls;
static int failures;
static pthread_mutex_t fail_mu = PTHREAD_MUTEX_INITIALIZER;

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

/* Run a query; on success copy column 0 (string) and column 1 (int64) of the first row. */
static int run(lbug_connection *c, const char *q, char *ans, size_t ans_n, int64_t *inits,
               char **err) {
    lbug_query_result r;
    lbug_connection_query(c, q, &r);
    if (!lbug_query_result_is_success(&r)) {
        if (err) *err = lbug_query_result_get_error_message(&r);
        lbug_query_result_destroy(&r);
        return 0;
    }
    if (ans && lbug_query_result_has_next(&r)) {
        lbug_flat_tuple t;
        lbug_query_result_get_next(&r, &t);
        lbug_value v0, v1;
        char *s = NULL;
        lbug_flat_tuple_get_value(&t, 0, &v0);
        lbug_value_get_string(&v0, &s);
        snprintf(ans, ans_n, "%s", s ? s : "");
        lbug_destroy_string(s);
        lbug_flat_tuple_get_value(&t, 1, &v1);
        lbug_value_get_int64(&v1, inits);
        lbug_value_destroy(&v0);
        lbug_value_destroy(&v1);
        lbug_flat_tuple_destroy(&t);
    }
    lbug_query_result_destroy(&r);
    return 1;
}

static int load(lbug_connection *c, char **err) {
    char q[4096];
    snprintf(q, sizeof q, "LOAD EXTENSION '%s'", ext_path);
    return run(c, q, NULL, 0, NULL, err);
}

static int open_db(const char *path, lbug_database *out) {
    return lbug_database_init(path, lbug_default_system_config(), out) == LbugSuccess;
}

static int ping(lbug_connection *c, int64_t *inits) {
    char ans[64];
    char *err = NULL;
    if (!run(c, "CALL lean_ping() RETURN answer, runtime_inits", ans, sizeof ans, inits, &err)) {
        fprintf(stderr, "ping failed: %s\n", err ? err : "?");
        return 0;
    }
    return strcmp(ans, "42") == 0;
}

/* @tg: verifies:: [[openspec:extension-runtime#Single Lean runtime per process#Runtime starts once across repeated loads]] {level: integration} */
/* @tg: verifies:: [[openspec:extension-runtime#Extension init starts the runtime#Load registers the functions]] {level: integration} */
static int mode_load(const char *dir) {
    char p1[2048], p2[2048];
    snprintf(p1, sizeof p1, "%s/a", dir);
    snprintf(p2, sizeof p2, "%s/b", dir);
    lbug_connection c1, c2, c3;
    lbug_database db2;
    char *err = NULL;
    int ok = open_db(p1, &db) && lbug_connection_init(&db, &c1) == LbugSuccess &&
             lbug_connection_init(&db, &c2) == LbugSuccess;
    double t0 = now_ms();
    ok = ok && load(&c1, &err);
    double load_ms = now_ms() - t0;
    ok = ok && load(&c2, &err);
    int64_t i1 = -1, i2 = -1, i3 = -1;
    ok = ok && ping(&c1, &i1) && ping(&c2, &i2);
    ok = ok && open_db(p2, &db2) && lbug_connection_init(&db2, &c3) == LbugSuccess &&
         load(&c3, &err) && ping(&c3, &i3);
    printf("load: first LOAD %.1f ms; runtime_inits conn1=%lld conn2=%lld second-db=%lld\n",
           load_ms, (long long)i1, (long long)i2, (long long)i3);
    if (err) fprintf(stderr, "error: %s\n", err);
    ok = ok && i1 == 1 && i2 == 1 && i3 == 1;
    printf("load: %s\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}

static void *worker(void *arg) {
    (void)arg;
    lbug_connection c;
    if (lbug_connection_init(&db, &c) != LbugSuccess) {
        pthread_mutex_lock(&fail_mu);
        failures += calls;
        pthread_mutex_unlock(&fail_mu);
        return NULL;
    }
    int bad = 0;
    for (int i = 0; i < calls; i++) {
        int64_t inits = -1;
        if (!ping(&c, &inits) || inits != 1) bad++;
    }
    lbug_connection_destroy(&c);
    pthread_mutex_lock(&fail_mu);
    failures += bad;
    pthread_mutex_unlock(&fail_mu);
    return NULL;
}

/* @tg: verifies:: [[openspec:extension-runtime#Foreign threads are initialized once#Calls from many worker threads]] {level: integration} */
static int mode_stress(const char *dir, int threads) {
    char p[2048];
    snprintf(p, sizeof p, "%s/s", dir);
    lbug_connection c;
    char *err = NULL;
    if (!open_db(p, &db) || lbug_connection_init(&db, &c) != LbugSuccess || !load(&c, &err)) {
        fprintf(stderr, "setup failed: %s\n", err ? err : "?");
        return 1;
    }
    int64_t inits;
    ping(&c, &inits); /* warm up */
    long rss0 = rss_kb();
    double t0 = now_ms();
    pthread_t *ts = calloc(threads, sizeof *ts);
    for (int i = 0; i < threads; i++) pthread_create(&ts[i], NULL, worker, NULL);
    for (int i = 0; i < threads; i++) pthread_join(ts[i], NULL);
    double ms = now_ms() - t0;
    long rss1 = rss_kb();
    printf("stress: %d threads x %d calls in %.0f ms; failures=%d; rss %ld -> %ld KB (+%ld)\n",
           threads, calls, ms, failures, rss0, rss1, rss1 - rss0);
    printf("stress: %s\n", failures == 0 ? "PASS" : "FAIL");
    return failures == 0 ? 0 : 1;
}

/* @tg: verifies:: [[openspec:extension-runtime#Extension init starts the runtime#Failed initialization registers nothing]] {level: integration} */
static int mode_failinit(const char *dir) {
    char p[2048];
    snprintf(p, sizeof p, "%s/f", dir);
    lbug_connection c;
    char *err = NULL;
    if (!open_db(p, &db) || lbug_connection_init(&db, &c) != LbugSuccess) return 1;
    int loaded = load(&c, &err);
    printf("failinit: LOAD %s: %s\n", loaded ? "succeeded" : "failed", err ? err : "");
    char *err2 = NULL;
    int callable = run(&c, "CALL lean_ping() RETURN *", NULL, 0, NULL, &err2);
    printf("failinit: LEAN_PING %s: %s\n", callable ? "callable" : "not callable", err2 ? err2 : "");
    int ok = !loaded && err && strstr(err, "Lean initialization failed") && !callable;
    printf("failinit: %s\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s load|stress|failinit <db-dir> <extension> [threads] [calls]\n",
                argv[0]);
        return 2;
    }
    ext_path = argv[3];
    int threads = argc > 4 ? atoi(argv[4]) : 16;
    calls = argc > 5 ? atoi(argv[5]) : 1000;
    if (!strcmp(argv[1], "load")) return mode_load(argv[2]);
    if (!strcmp(argv[1], "stress")) return mode_stress(argv[2], threads);
    if (!strcmp(argv[1], "failinit")) return mode_failinit(argv[2]);
    return 2;
}
