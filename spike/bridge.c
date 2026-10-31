/* Runtime bridge of the spike: starts the Lean runtime once and turns Lean calls into plain C.
 * Compiled with the system C compiler so it uses the same libc as LadybugDB. */
#include <lean/lean.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#include "bridge.h"

extern void lean_initialize_runtime_module(void);
extern void lean_initialize_thread(void);
extern lean_object *lean_io_error_to_string(lean_object *err);
extern lean_object *initialize_marien_x2dspike_Spike(uint8_t builtin);
extern lean_object *marien_ping(lean_object *unit);

static char *dup_cstr(const char *s) {
    size_t n = strlen(s) + 1;
    char *r = malloc(n);
    if (r) memcpy(r, s, n);
    return r;
}

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

/* Lean 4.35 module initializers call lean_initialize(). The toolchain's version (libleancpp)
 * also initializes the Lean compiler package, which LeanElpi's core never uses and which
 * makes the library 20 times larger. This definition starts only the runtime; libleancpp
 * is not linked, so it is the only one. */
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
    lean_object *res = initialize_marien_x2dspike_Spike(1);
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
    if (getenv("MARIEN_SPIKE_FAIL_INIT")) return "simulated Lean initialization failure";
    pthread_once(&once, init_once);
    return init_error;
}

int marien_bridge_init_runs(void) { return init_runs; }

char *marien_bridge_ping(void) {
    ensure_thread();
    lean_object *s = marien_ping(lean_box(0));
    char *out = dup_cstr(lean_string_cstr(s));
    lean_dec(s);
    return out;
}
