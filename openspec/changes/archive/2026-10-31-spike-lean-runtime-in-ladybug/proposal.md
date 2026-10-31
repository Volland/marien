## Why

Linking a Lean runtime into LadybugDB is the likeliest way this project fails. Each part has been done separately: LeanElpi ships a self-contained shared library with the Lean runtime inside, and LadybugDB loads C++ extensions. Nobody has yet loaded the first into the second. Four things can break: two Lean runtimes in one process, worker threads that Lean never initialized, GMP or libuv symbols clashing with LadybugDB's own bundled libraries, and an extension around 45 MB. A spike of about 50 lines finds out cheaply, before any other milestone builds on the linking model.

**Milestone:** Spike (before M0).

**Depends on:** nothing. It uses LeanElpi 0.3.3 as published and a pinned LadybugDB release.

## What Changes

- A throwaway LadybugDB extension, `spike/`, whose init function starts the Lean runtime and registers one table function `lean_ping()`. The function calls a Lean `@[export]` function that runs a one-clause LeanElpi query and returns its answer as a row.
- A build script that links the Lean code, LeanElpi, the Lean runtime libraries, GMP and libuv statically into one shared library, with every symbol hidden except the extension init entry point.
- Measurements: library size before and after dead-stripping, the list of exported symbols, and a check for clashes with LadybugDB's bundled libraries.
- A go/no-go note recording the results. It updates [[constraints#One Lean runtime per process]] and [[decisions#Out-of-tree extension with its own repository]] if the findings change them.
- The lasting requirements the spike proves become the `extension-runtime` capability, which M1's real shim must also meet.

## Capabilities

### New Capabilities
- `extension-runtime`: loading the extension into LadybugDB with exactly one Lean runtime, initializing foreign threads, hiding symbols, and measuring the size budget.

## Impact

**Motivating decisions:**
- [[decisions#Logic in Lean behind a thin C++ shim]] ([[adr:0013]]): the shim and the Lean code share one library.
- [[decisions#Out-of-tree extension with its own repository]] ([[adr:0017]]): the build runs outside LadybugDB's CMake tree.
- [[decisions#Milestone order]] ([[adr:0019]]): the spike comes first because linking is the main risk.

**Binding constraints:**
- [[constraints#One Lean runtime per process]]
- [[constraints#Extensions are C++ shared libraries]]

**Components introduced (prototype form):**
- [[components#Extension shim]]
- [[components#Runtime bridge]]

**Requirements added:**
- [[openspec:extension-runtime#Single Lean runtime per process]]
- [[openspec:extension-runtime#Extension init starts the runtime]]
- [[openspec:extension-runtime#Foreign threads are initialized once]]
- [[openspec:extension-runtime#Only the init symbol is exported]]
- [[openspec:extension-runtime#Size budget is measured]]

**Change register:** [[changes#spike-lean-runtime-in-ladybug]]
