import Elpi.Runtime.Api

/-!
# Spike: LeanElpi behind a C entry point

`marien_ping` loads a one-clause program and solves one query, so a call from a LadybugDB
worker thread exercises the parser, typechecker and machine of LeanElpi.
-/

namespace Marien.Spike

open Elpi

/-- Loads `p 42.`, solves `p X` and returns the binding of `X`, or the error text. -/
@[export marien_ping]
def ping (_ : Unit) : String :=
  match Program.load "pred p o:int.\np 42." with
  | .error e => s!"error: {e}"
  | .ok prog =>
    match solve prog "p X" with
    | .cons (.ok s) _ => (s.find? "X").map s.show |>.getD "error: X unbound"
    | .cons (.error e) _ => s!"error: {e}"
    | .nil => "error: no solution"

end Marien.Spike
