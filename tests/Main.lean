import EngineContract
import M1
import M2
import M3
import M4
import M5
import SouffleOracle.Tests
import GraphStd.Tests
import Property.Tests

/-! # Test driver: the engine contract and the M1 to M5 unit tests (`lake test`).

M5 elaborates generated Lean modules in process, so the driver sets the search path (from
`LEAN_PATH`, which `lake test` sets) and enables the initializers of imported modules. -/

unsafe def main : IO UInt32 := do
  Lean.initSearchPath (← Lean.findSysroot)
  Lean.enableInitializersExecution
  let suites : List (String × List (String × IO Unit)) :=
    [("engine contract", EngineContract.all), ("M1", M1.all), ("M2", M2.all), ("M3", M3.all), ("M4", M4.all), ("M5", M5.all), ("souffle oracle", OracleTests.all), ("graph.std", GraphStd.Tests.all), ("property", PropertyTests.all)]
  let mut failed := 0
  let mut total := 0
  for (suite, tests) in suites do
    for (name, t) in tests do
      total := total + 1
      try
        t
        IO.println s!"PASS {suite}: {name}"
      catch e =>
        failed := failed + 1
        IO.println s!"FAIL {suite}: {name}: {e}"
  IO.println s!"{total - failed}/{total} passed"
  return if failed == 0 then 0 else 1
