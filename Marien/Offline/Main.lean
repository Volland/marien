import Marien.Offline.Codegen

/-!
# `lake exe marien-codegen`

```
lake exe marien-codegen <dump.json> -o <Module.lean> [--namespace <Ns>]
```

Reads a schema dump, writes the Lean module, elaborates it and checks that the ELPI declarations
`deriving Elpi` produced equal the runtime signature. Exits 0 when they agree; otherwise 1 with
the first difference, or 2 on a usage error. The module is written only when the check passes.
-/

open Marien.Offline

def usage : String :=
  "usage: marien-codegen <dump.json> -o <Module.lean> [--namespace <Ns>]\n" ++
  "  <dump.json> is the text of CALL elpi_signature(format := 'json')"

structure Args where
  dump : Option String := none
  out : Option String := none
  ns : String := "Schema"

partial def parseArgs : List String → Args → Except String Args
  | [], a => .ok a
  | "-o" :: f :: rest, a => parseArgs rest { a with out := some f }
  | "--namespace" :: n :: rest, a => parseArgs rest { a with ns := n }
  | f :: rest, a =>
    if f.startsWith "-" then .error s!"unknown option {f}"
    else if a.dump.isSome then .error s!"one dump at a time, got {f} too"
    else parseArgs rest { a with dump := some f }

unsafe def main (argv : List String) : IO UInt32 := do
  let a ← match parseArgs argv {} with
    | .ok a => pure a
    | .error e => IO.eprintln s!"{e}\n{usage}"; return 2
  let (some dump, some out) := (a.dump, a.out)
    | IO.eprintln usage; return 2
  Lean.initSearchPath (← Lean.findSysroot)
  Lean.enableInitializersExecution
  let text ← IO.FS.readFile dump
  match ← run { ns := a.ns, source := dump } text with
  | .error e =>
    IO.eprintln s!"marien-codegen: {e}"
    return 1
  | .ok o =>
    IO.FS.writeFile out o.module
    IO.println s!"wrote {out}: the derived ELPI kinds and constructors equal the runtime signature"
    return 0
