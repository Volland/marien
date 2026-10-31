## 1. Spike

- [x] 1.1 Read LadybugDB's extension loader (`src/extension/extension_loader.cpp`, `src/include/extension/extension.h`) and record the exact init entry-point contract
- [x] 1.2 Write `spike/Spike.lean`: `@[export marien_init]` and `@[export marien_ping]`, the second loading `p 42.` with LeanElpi and solving `p X`
- [x] 1.3 Write `spike/shim.cpp` (about 50 lines): init entry point, `std::call_once` around `marien_init`, `thread_local` `ensure_thread`, table function `lean_ping()` returning one STRING row
- [x] 1.4 Write `spike/build.sh`: Lake builds the static archive, then the shim is linked with LeanElpi, the Lean runtime libraries, GMP and libuv into one library with `-fvisibility=hidden` and an export list
- [x] 1.5 Build on macOS arm64; then try Linux x86_64 and record what static linking needed — macOS go; Linux tried on aarch64 in Docker (same toolchain build as x86_64): needs `libleanrt.a` rebuilt with -fPIC and dlopen-safe TLS, see `spike/RESULT.md`

## 2. Measurements

- [x] 2.1 List dynamic dependencies (`otool -L` or `ldd`); confirm no Lean shared library
- [x] 2.2 List exported symbols; confirm only the loader entry points
- [x] 2.3 Load the spike together with `algo` and `fts`, use all three, and check for symbol clashes (`DYLD_PRINT_BINDINGS` or `LD_DEBUG=bindings`) — done with `fts` and `vector`: the official `algo` 0.22 macOS package cannot load (rpath to the build machine); see `spike/RESULT.md`
- [x] 2.4 Stress test: 16 connections × 1000 calls of `lean_ping()`; record crashes, wrong answers and memory growth
- [x] 2.5 Record library size compressed and uncompressed, with and without `-dead_strip` or `--gc-sections`, and the time `LOAD` takes
- [x] 2.6 Write the go/no-go note `spike/RESULT.md`: per platform, go or no-go with the evidence

## 3. Carry-over

- [x] 3.1 Move the build recipe, the dependency check, the export check and the size check into `scripts/` for M1 to reuse
- [x] 3.2 Add the size baseline file and a CI job that fails on more than 10% unrecorded growth — baseline and check verified locally by `scripts/test-check-size.sh`; the workflow has not yet run on GitHub

## 4. Traceability

- [x] 4.1 Annotate the shim's library target or build script with `@tg: implements:: [[openspec:extension-runtime#Single Lean runtime per process]]`, and the dependency check with `@tg: verifies:: [[openspec:extension-runtime#Single Lean runtime per process#Library has no Lean shared-library dependency]]` and `...#Runtime starts once across repeated loads`
- [x] 4.2 Annotate the init entry point with `@tg: implements:: [[openspec:extension-runtime#Extension init starts the runtime]]`, and its tests with `verifies` for `#Load registers the functions` and `#Failed initialization registers nothing`
- [x] 4.3 Annotate `ensure_thread` with `@tg: implements:: [[openspec:extension-runtime#Foreign threads are initialized once]]`, and the stress test with `verifies` for `#Calls from many worker threads`
- [x] 4.4 Annotate the export list with `@tg: implements:: [[openspec:extension-runtime#Only the init symbol is exported]]`, and the checks with `verifies` for `#Exported symbol list` and `#Coexists with another extension`
- [x] 4.5 Annotate the size check with `@tg: implements:: [[openspec:extension-runtime#Size budget is measured]]`, and its tests with `verifies` for `#Size report is produced` and `#Unnoticed growth fails CI`
- [x] 4.6 Record the spike's findings in lat.md: update [[constraints#One Lean runtime per process]] and [[constraints#Extensions are C++ shared libraries]] with measured facts (`source::` the spike note), and add constraints for any new limit found (entry-point contract, Linux linking)
- [x] 4.7 Update the [[components#Extension shim]] and [[components#Runtime bridge]] sections and add `extension-runtime` to the `openspec:` frontmatter of `tg.md/architecture/components.md`
- [x] 4.8 Run `tg check`, `tg ontology check` and `tg trace extension-runtime --gaps`, and close every gap they report
