---
type: Concept
---
# Architecture

How Marien is put together: the system context, the layers inside the one shared library, how a call flows through them, and how it ships. Components are in [[components]], detailed UML in [[uml]].

- [[components]] — one section per module or tool, with dependencies, motivating decisions and the introducing change
- [[uml]] — data model, save, run and partitioned-validation sequences, module status and analysis pipeline

Marien is one LadybugDB extension library. A thin C++ shim speaks LadybugDB's table-function interfaces; everything with meaning — encoding, staging, analysis, execution, decoding — is Lean in the `Marien` package, linked statically with LeanElpi and the Lean runtime ([[decisions#Logic in Lean behind a thin C++ shim]]).

## System context

Users and CI talk Cypher to LadybugDB; LadybugDB loads Marien and calls its table functions; Marien never talks to anything outside the database process.

```mermaid
flowchart LR
  user([Analyst / app]) -- "Cypher: CALL elpi_*" --> db
  ci([CI pipeline]) -- "CALL elpi_validate / elpi_recheck" --> db
  dev([Rule author]) -- "elpi_save / elpi_export" --> db
  subgraph proc[LadybugDB process]
    db[(LadybugDB<br/>catalog + storage)]
    ext[[libmarien.lbug_extension]]
    db <-- "table functions<br/>bind · execute · rewriteFunc" --> ext
  end
  git[(git repo of rules)] <-. "elpi_export / elpi_import" .-> dev
  offline[[marien-codegen<br/>offline Lean tool]] -. "schema dump → Lean inductives" .-> lean[(Lean project<br/>proofs about rules)]
```

- illustrates:: [[decisions#CALL functions first]]
- illustrates:: [[decisions#Schema types at runtime and Lean inductives offline]]

## Layers

Four layers inside one library: the C++ shim, the Marien Lean package, the LeanElpi engine and the Lean runtime; only the shim touches LadybugDB internals, only Marien calls LeanElpi.

```mermaid
flowchart TB
  subgraph L0[LadybugDB internals]
    cat[(Catalog)]
    sto[(Storage / graph API)]
    tf{{Table-function framework<br/>bind · exec · rewriteFunc}}
  end
  subgraph L1[C++ shim — shim/]
    sh[Extension shim]
    cr[Catalog reader]
    ts[Table scanner]
    sf[Structural facts]
    st[Statement extension · M5]
  end
  subgraph L2[Marien Lean package — Marien/]
    rb[Runtime bridge]
    sm[Schema model]
    sg[Signature generator]
    vc[Value codec]
    ms[Module store]
    hc[Handle cache]
    ex[Executor]
    va[Validator]
    ra[Rule analyzer]
    pp[Partition planner]
    rf[Schema reflector]
    rg[Rule generator]
  end
  subgraph L3[LeanElpi engine]
    eng[Parser · typechecker · abstract machine]
    gs[graph.std library]
  end
  L4[Lean runtime · GMP · libuv]
  tf --> sh
  sh --> cr --> cat
  sh --> ts --> sto
  sf --> sto
  sh -- "C ABI, JSON / byte buffers" --> rb
  rb --> ms & ex & va
  ms --> rg --> rf --> sm
  ms --> ra
  ex --> hc --> eng
  ex --> vc
  va --> pp --> ra
  sg --> sm
  hc --> sg
  eng --> gs
  L2 --> L4
  L3 --> L4
```

The C ABI between shim and Lean carries only handles, UTF-8 strings and flat byte buffers of facts and rows, as LeanElpi's own C API does; no Lean object crosses into C++.

- illustrates:: [[decisions#Logic in Lean behind a thin C++ shim]]
- illustrates:: [[constraints#One Lean runtime per process]]

## Call lifecycle

Every function call follows LadybugDB's two phases: bind (fix output columns, compile or fetch the program) and execute (scan, encode, solve in fuel slices, decode); writes go through `rewriteFunc`.

```mermaid
flowchart LR
  A[CALL elpi_run] --> B{bind}
  B --> B1[read catalog<br/>schema hash of reached tables]
  B1 --> B2{handle cache hit?}
  B2 -- yes --> B4
  B2 -- no --> B3[load module · stage · typecheck · analyse]
  B3 --> B4[entry-point signature<br/>→ output columns]
  B4 --> C{execute}
  C --> C1[scan reached tables<br/>in calling transaction]
  C1 --> C2[encode facts]
  C2 --> C3[solve one fuel slice]
  C3 --> C4{interrupt / deadline / budget?}
  C4 -- exceeded --> E[error, no rows]
  C4 -- ok, more --> C3
  C4 -- done --> C5[decode solutions → rows]
  S[CALL elpi_save] --> SB[bind: compile + check] --> SR[rewriteFunc → MERGE _elpi_module]
```

- illustrates:: [[decisions#Materialize facts per call]]
- illustrates:: [[decisions#Scan tables in the calling transaction]]
- illustrates:: [[decisions#Fuel-sliced execution that fails loudly]]

## Data model in the database

Marien keeps its state in three system tables, which the generated signature never exposes to rules.

```mermaid
erDiagram
  _elpi_module ||--o{ _elpi_accumulates : "from"
  _elpi_module ||--o{ _elpi_accumulates : "to"
  _elpi_module {
    STRING name PK
    INT64 version
    STRING source "byte-exact"
    STRING schema_hash "of reached tables"
    STRING generated "stage-1 output"
    STRING analysis "reach, monotone, dynamic, locality"
    STRING status "ok | broken"
    TIMESTAMP checked_at
  }
  _elpi_accumulates {
    STRING kind "accumulate"
  }
  _elpi_annotation {
    STRING table
    STRING key
    STRING value
  }
```

- illustrates:: [[decisions#Rules stored in system tables]]

## Correctness guards

Each guarantee about answers has one guard that enforces it and one test or proof that checks the guard.

| Guarantee | Guard | Checked by |
|---|---|---|
| Negation sees all facts | full scope unless proved monotone | narrowing subset property |
| Partitions do not change answers | locality check, subject = anchor | partition equivalence property; coverage theorem |
| Generated code is checked | staging before typecheck and analysis | determinism theorem |
| No truncated results | budgets are errors | e2e tests |
| Rules match the schema | lazy recheck by schema hash | hash locality theorem |
| Encoding is faithful | codec | round-trip theorems |

- illustrates:: [[decisions#Closed-world scope]]
- illustrates:: [[decisions#Partitioned validation]]
- illustrates:: [[decisions#Proofs where practical]]

## Deployment

One file, `libmarien.lbug_extension`, built per LadybugDB version, OS and CPU, served from Marien's own extension server, downloaded and loaded with `LOAD EXTENSION '<path>'` (`INSTALL marien FROM <url>` once LadybugDB accepts third-party names).

```mermaid
flowchart LR
  subgraph build[CI build per LadybugDB version × OS × CPU]
    lake[lake build → libMarien.a<br/>+ LeanElpi + Lean runtime] --> link
    cmake[CMake → shim objects<br/>against pinned LadybugDB headers] --> link
    link[link, hidden visibility,<br/>export init only] --> lib[[libmarien.lbug_extension]]
  end
  lib --> srv[(extension server)]
  srv -- "download" --> file[local file]
  file -- "LOAD EXTENSION path" --> db[(LadybugDB)]
```

- illustrates:: [[decisions#Out-of-tree extension with its own repository]]
- illustrates:: [[constraints#Extensions are C++ shared libraries]]
