## ADDED Requirements

### Requirement: Out-of-tree build
The repository SHALL build the extension without a LadybugDB source tree: `lake build` SHALL produce one static archive containing the `Marien` Lean package and LeanElpi, and a CMake project under `shim/` SHALL compile the C++ shim against the headers of one pinned LadybugDB version and link it with that archive and the Lean runtime into a single `libmarien.lbug_extension`. The pinned version SHALL be recorded in one file that both the build and the version check read. The library SHALL export only the extension entry points; every other symbol, including the Lean runtime, GMP and libuv, SHALL have hidden visibility.

#### Scenario: One file is produced
- **WHEN** `scripts/build-extension.sh` runs on a clean checkout with the Lean toolchain and a C++ compiler
- **THEN** it produces exactly one extension library and no other shared library

#### Scenario: Only entry points are exported
- **WHEN** the dynamic symbol table of the library is listed
- **THEN** the only exported symbols are the LadybugDB extension entry points

### Requirement: Build matrix
Continuous integration SHALL build and test the extension for every entry of a matrix of supported LadybugDB versions × operating systems (macOS, Linux) × CPU architectures (arm64, x86_64), and SHALL publish one artifact per entry named with all three. A matrix entry that fails SHALL block the release of every entry.

#### Scenario: Artifact names carry the matrix entry
- **WHEN** a release tag is built
- **THEN** every artifact name contains the LadybugDB version, the OS and the CPU

#### Scenario: One failing entry blocks the release
- **WHEN** the Linux x86_64 build fails for one LadybugDB version
- **THEN** no artifact of that release is published

### Requirement: Install from extension server
The release SHALL publish every matrix entry to an extension server laid out the way LadybugDB's `INSTALL <name> FROM '<url>'` fetches, `v<extension version>/<os>_<arch>/marien/libmarien.lbug_extension`, and SHALL attach one zip per entry to the release. A user SHALL be able to download the build matching the running LadybugDB, OS and CPU from that layout and load it with `LOAD EXTENSION '<path>'`. `INSTALL marien FROM '<url>'` with `LOAD marien` is not required while LadybugDB installs only the names on its official list; the layout stays ready for it.

#### Scenario: Download and load
- **WHEN** a user of a supported LadybugDB downloads the library for their OS and CPU from the extension server and runs `LOAD EXTENSION` with its path
- **THEN** `CALL elpi_signature() RETURN *` succeeds

#### Scenario: Every entry is served
- **WHEN** a release is published
- **THEN** the extension server serves the library of every matrix entry at its layout path, byte for byte the artifact that was tested

### Requirement: LadybugDB version check
On load, the extension SHALL compare the running LadybugDB version with the pinned version it was built against and SHALL refuse to register any function when they differ, failing `LOAD` with an error that names both versions.

#### Scenario: Mismatched database is refused
- **WHEN** a build pinned to one LadybugDB version is loaded into another version
- **THEN** `LOAD marien` fails with an error naming both versions
- **AND** no `elpi_*` function is registered
