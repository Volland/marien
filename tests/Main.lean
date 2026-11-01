import EngineContract
import M1
import M2

/-! # Test driver: the engine contract and the M1 and M2 unit tests (`lake test`). -/

def main : IO UInt32 := do
  let suites : List (String × List (String × IO Unit)) :=
    [("engine contract", EngineContract.all), ("M1", M1.all), ("M2", M2.all)]
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
