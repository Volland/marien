/* C interface between the spike's C++ shim and its Lean code. */
#ifndef MARIEN_SPIKE_BRIDGE_H
#define MARIEN_SPIKE_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

/* Start the Lean runtime and the Spike module once per process. NULL on success, otherwise
 * the error text (owned by the bridge). */
const char *marien_bridge_init(void);

/* How many times the runtime initializer actually ran (expected: 1). */
int marien_bridge_init_runs(void);

/* Solve `p X` against `p 42.` with LeanElpi; the caller frees the result. */
char *marien_bridge_ping(void);

#ifdef __cplusplus
}
#endif
#endif
