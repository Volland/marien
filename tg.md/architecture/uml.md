---
type: Concept
---
# UML

Class, sequence and state diagrams for Marien's main flows; the layer view is in [[architecture#Layers]] and the modules in [[components]].

## Lean data model

The core Lean types: the schema read from the catalog, the signature generated from it, stored modules with their analysis, and partition plans.

```mermaid
classDiagram
  class Schema {
    nodes : Array NodeTable
    rels : Array RelTable
    hashOf(tables) : Hash
  }
  class NodeTable { name : String; pk : Property; props : Array Property }
  class RelTable { name : String; ends : Array (String × String); props : Array Property }
  class Property { name : String; ty : PType }
  class PType { <<inductive>> int · float · string · bool · date · timestamp · list PType · struct · unsupported }
  class Signature {
    kinds : Array Kind
    preds : Array PredDecl
    ofSchema(Schema) : Signature
    render() : String
  }
  class Module {
    name : String
    version : Nat
    source : String
    generated : Option String
    schemaHash : Hash
    status : ok | broken
  }
  class Analysis {
    reaches : EntryPoint → Set Pred
    monotone : EntryPoint → Bool
    dynamic : EntryPoint → Bool
    locality : EntryPoint → Option Anchor
  }
  class EntryPoint { pred : String; modes : Array Mode; types : Array Ty }
  class PartitionPlan { <<inductive>> full · anchor(kind, radius, dirs) · key(table, prop) }
  Schema "1" o-- "*" NodeTable
  Schema "1" o-- "*" RelTable
  NodeTable o-- Property
  RelTable o-- Property
  Property --> PType
  Signature ..> Schema : generated from
  Module --> Analysis
  Analysis --> EntryPoint
  Analysis ..> PartitionPlan : permits
```

- illustrates:: [[decisions#Predicate-per-property encoding]]
- illustrates:: [[decisions#Closed-world scope]]

## Save sequence

`elpi_save` compiles and checks everything in bind, then rewrites itself into a `MERGE` that stores the module; a module that fails any check is never stored.

```mermaid
sequenceDiagram
  autonumber
  actor U as User
  participant DB as LadybugDB
  participant SH as Extension shim
  participant MS as Module store (Lean)
  participant RG as Rule generator
  participant EL as LeanElpi
  participant RA as Rule analyzer
  U->>DB: CALL elpi_save('org-rules', $src)
  DB->>SH: bind(args)
  SH->>SH: read catalog → schema JSON
  SH->>MS: save(name, src, schema)
  MS->>RG: stage 1 over reflected schema
  RG-->>MS: generated clause text
  MS->>EL: load(signature ++ src ++ generated)
  EL-->>MS: typed program or type errors
  MS->>RA: analyse(program)
  RA-->>MS: reaches, monotone, dynamic, locality
  MS-->>SH: escaped MERGE text or error
  SH-->>DB: rewriteFunc → MERGE (m:_elpi_module {...})
  DB-->>U: saved row (name, version, status)
```

- illustrates:: [[decisions#CALL functions first]]
- illustrates:: [[decisions#Staged rule generation over a reflected schema]]

## Run sequence

`elpi_run` fixes typed columns in bind, then scans, solves in fuel slices and decodes in execute; an exceeded budget is an error with no rows.

```mermaid
sequenceDiagram
  autonumber
  participant DB as LadybugDB
  participant SH as Extension shim
  participant EX as Executor (Lean)
  participant HC as Handle cache
  participant TS as Table scanner
  participant EL as LeanElpi
  DB->>SH: bind(module, pred, params)
  SH->>EX: prepare(module, pred, schema hash)
  EX->>HC: lookup(version, hash)
  alt miss or hash changed
    HC->>EX: recompile + recheck in memory
  end
  EX-->>SH: output column types
  DB->>SH: execute()
  SH->>TS: scan reached tables (calling transaction)
  TS-->>SH: fact buffers
  SH->>EX: encode + start query
  loop each fuel slice
    EX->>EL: run N steps
    EL-->>EX: yield / paused / exhausted
    EX->>SH: rows so far
    SH->>SH: check interrupt, deadline, budgets
  end
  SH-->>DB: typed rows, or error
```

- illustrates:: [[decisions#Typed entry points and an untyped debug query]]
- illustrates:: [[decisions#Fuel-sliced execution that fails loudly]]

## Partitioned validation sequence

`elpi_validate` on a large graph plans partitions from the analysis, computes structural facts once, then solves anchor batches in fresh stores and concatenates the reports.

```mermaid
sequenceDiagram
  autonumber
  participant SH as Extension shim
  participant VA as Validator
  participant PP as Partition planner
  participant SF as Structural facts
  participant TS as Table scanner
  participant EL as LeanElpi
  SH->>VA: validate(modules, min_severity)
  VA->>PP: plan(entry point, analysis)
  PP-->>VA: anchor(kind, radius, dirs) | key | full
  opt rules use in_cycle / component
    VA->>SF: SCC / WCC in calling transaction
    SF-->>VA: structural facts
  end
  loop each batch of anchors
    VA->>TS: neighbourhood(batch, radius, dirs)
    TS-->>VA: facts
    VA->>EL: solve violation in a fresh store
    EL-->>VA: violations whose subject is in the batch
  end
  VA-->>SH: uniform report rows
```

- illustrates:: [[decisions#Partitioned validation]]
- illustrates:: [[decisions#Validation protocol]]

## Module status

A stored module is `ok` or `broken`; a schema change makes it stale, which a run resolves in memory and `elpi_recheck` persists.

```mermaid
stateDiagram-v2
  [*] --> ok : elpi_save passes all checks
  [*] --> rejected : elpi_save fails (nothing stored)
  ok --> stale : schema hash of reached tables changes
  stale --> ok : run regenerates + rechecks in memory
  stale --> broken : regeneration or typecheck fails
  broken --> ok : elpi_save new source, or schema fixed + elpi_recheck
  ok --> [*] : elpi_drop
  broken --> [*] : elpi_drop
  note right of stale
    stale is not stored: it is a
    hash mismatch seen at bind time
  end note
```

- illustrates:: [[decisions#Lazy recheck by schema hash]]
- illustrates:: [[constraints#No DDL hooks for extensions]]

## Analysis pipeline

The rule analyzer turns a typed program into per-entry-point verdicts that decide which scopes and partitions a call may use.

```mermaid
flowchart LR
  P[typed program<br/>source + generated] --> R[reachability<br/>preds per entry point]
  R --> M{negation, cut or forall<br/>over a DB predicate?}
  M -- no --> MO[monotone:<br/>narrowed scope allowed]
  M -- yes --> FS[full scope or partition]
  R --> D{=> adds a clause with<br/>a DB predicate head?}
  D -- yes --> DY[dynamic:<br/>full scope only]
  R --> L{every DB atom guarded by<br/>anchor within radius,<br/>subject = anchor?}
  L -- yes --> LO[anchor partition allowed]
  L -- no --> FS
```

- illustrates:: [[decisions#Closed-world scope]]
- illustrates:: [[decisions#Partitioned validation]]
