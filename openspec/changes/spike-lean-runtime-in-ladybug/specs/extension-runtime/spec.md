## ADDED Requirements

### Requirement: Single Lean runtime per process
The extension SHALL be one shared library that statically contains the Marien Lean code, LeanElpi, the Lean runtime libraries (`libleanrt`, `libInit`, `libStd`, `libLean` as needed), GMP and libuv. It SHALL NOT link against a separately distributed `libleanelpi` or any other shared library that embeds a Lean runtime. Loading it SHALL leave exactly one initialized Lean runtime in the LadybugDB process.

#### Scenario: Library has no Lean shared-library dependency
- **WHEN** the dynamic dependencies of the built extension are listed (`otool -L` on macOS, `ldd` on Linux)
- **THEN** no entry names `libleanelpi`, `libleanshared` or another Lean runtime library
- **AND** only the operating system's C and C++ runtime libraries remain

#### Scenario: Runtime starts once across repeated loads
- **WHEN** `LOAD` is run for the extension in two connections of the same database
- **THEN** the Lean runtime initialization runs exactly once
- **AND** both connections can call the extension's functions

### Requirement: Extension init starts the runtime
The extension's init entry point SHALL initialize the Lean runtime and the Lean modules it uses before registering any LadybugDB function. If initialization fails, it SHALL report the failure through LadybugDB's extension loading error and register nothing.

#### Scenario: Load registers the functions
- **WHEN** `LOAD marien` succeeds
- **THEN** `CALL lean_ping() RETURN *` (spike) or the extension's documented functions (later milestones) can be called and return rows

#### Scenario: Failed initialization registers nothing
- **WHEN** Lean module initialization returns an error during `LOAD`
- **THEN** `LOAD` fails with that error message
- **AND** none of the extension's functions are visible in the catalog

### Requirement: Foreign threads are initialized once
Every entry from C++ into Lean SHALL first make sure the calling thread is registered with the Lean runtime, calling `lean_initialize_thread` at most once per thread through a thread-local flag, as LeanElpi's `ensure_thread` does. LadybugDB worker threads SHALL NOT be finalized by the extension.

#### Scenario: Calls from many worker threads
- **WHEN** 16 connections call the extension's function concurrently, 1000 times each
- **THEN** every call returns the correct answer
- **AND** the process neither crashes nor leaks a thread registration per call

### Requirement: Only the init symbol is exported
The extension SHALL be built with hidden symbol visibility, and its dynamic symbol table SHALL export only the entry points LadybugDB's extension loader looks up. Lean, GMP and libuv symbols SHALL stay local, so they cannot bind to or be bound by symbols of LadybugDB or of other loaded extensions.

#### Scenario: Exported symbol list
- **WHEN** the exported dynamic symbols of the built extension are listed (`nm -gU` on macOS, `nm -D --defined-only` on Linux)
- **THEN** the list contains only the extension loader's entry points

#### Scenario: Coexists with another extension
- **WHEN** the extension and LadybugDB's `algo` and `fts` extensions are loaded in the same database and each is used
- **THEN** all three work and none resolves a symbol into another's copy of a library

### Requirement: Size budget is measured
The build SHALL record the size of the extension library, compressed and uncompressed, with and without dead-stripping (`-dead_strip` on macOS, `--gc-sections` on Linux), and CI SHALL fail when the compressed size grows more than 10% over the recorded baseline without the baseline being updated.

#### Scenario: Size report is produced
- **WHEN** the extension is built
- **THEN** a size report lists both sizes for both link modes

#### Scenario: Unnoticed growth fails CI
- **WHEN** a change makes the compressed library 15% larger than the baseline and leaves the baseline file unchanged
- **THEN** the CI size check fails
