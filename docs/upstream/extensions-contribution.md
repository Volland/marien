Proposal: host Marien in ladybugdb/extensions with a prebuilt Lean archive

### Description

[Marien](https://github.com/Volland/marien) is an extension that stores logic-programming (λProlog/ELPI) rule modules in the database and runs them against the graph, for typed validation and reasoning: `CALL elpi_save(...)`, `CALL elpi_validate(...)`, `CALL elpi_run(...)`. It is written in Lean 4 behind a thin C++ shim and is built out of tree today, one build per LadybugDB release, published as downloads for `LOAD EXTENSION` (`INSTALL` accepts official names only).

We would like to propose it for `ladybugdb/extensions`, in a form that needs **no Lean toolchain** in your CI.

**How it would build.** A `marien/` directory with the C++ shim (about 2,400 lines: table functions, catalog reader, table scanner) compiled like the other extensions with `build_extension_lib`, linked with one prebuilt static archive:

- `libmarien_lean.a`: the runtime bridge, Marien's Lean code, the LeanElpi engine and the Lean runtime, partially linked into one object whose only global symbols are the bridge's C API (`marien_bridge_*`); on macOS the GMP and libuv functions it calls stay global in a second object and are hidden by the extension's export list.
- `lean_bridge.h` and a CMake package (`find_package(marien_lean CONFIG)`, target `marien::lean`).

Marien's releases publish the archive per platform (`marien-lean-<version>-<os>-<cpu>.tar.gz` for `osx-arm64`, `osx-amd64`, `linux-arm64`, `linux-amd64`) with `SHA256SUMS-lean`; the extension's CMake would fetch the archive pinned by version and checksum. The archive does not depend on the LadybugDB version, only on Marien's. Building from the archive is in Marien's repository today (`scripts/build-lean-archive.sh`, `shim/CMakeLists.txt -DMARIEN_LEAN_ARCHIVE=…`, tested by `scripts/test-lean-archive.sh` on macOS and Linux in every CI run and release: the extension built without Lean on `PATH` passes the same 78 integration tests).

**What it relies on.** Table functions with `rewriteFunc`, the catalog and table scans in the calling transaction, and extension options. No transformer, binder or grammar hooks: statements are a function over a string, as discussed in LadybugDB/ladybug#1519. One Lean runtime lives inside the extension, so loading it with other extensions is safe; it exports only `init` and `name`.

**Licences.** Marien (`LICENSE` in its repository) and LeanElpi are Apache-2.0; the Lean runtime is Apache-2.0; GMP (LGPL-3.0) and libuv (MIT) are linked statically, as in Lean's own binaries.

**Questions for you.** Is a prebuilt archive acceptable in your build, or would you rather build the Lean side in a separate CI job? Which platforms must it cover? Should it stay out of `EXTENSION_LIST` until it has run in your CI for a release?

---

Draft for task 4.4 of `openspec/changes/add-ecosystem`; not filed. Before filing: add a LICENSE file to Marien's repository, run `scripts/test-lean-archive.sh` on Linux, and publish the archive from the release workflow.
