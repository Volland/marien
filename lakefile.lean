import Lake

open System Lake DSL

package marien where
  version := v!"0.0.1"
  description := "LadybugDB extension that stores λProlog (ELPI) rules in the database and runs them with LeanElpi."
  license := "Apache-2.0"
  leanOptions := #[⟨`autoImplicit, false⟩]

-- LeanElpi's host API (lean-elpi change `add-host-api`), pinned by commit until it is released
-- as v0.4.0 (task 3.1 of openspec/changes/add-leanelpi-host-api).
require «lean-elpi» from git "https://github.com/Volland/lean-elpi" @ "d289f58a255dd22ca6c83fa6bcfa3c141de8e477"

@[default_target] lean_lib Marien

/-- The engine contract: one check per scenario of the `engine-host-api` capability, run against
the pinned LeanElpi with `lake test`. -/
@[test_driver] lean_exe «engine-contract» where
  root := `EngineContract
  srcDir := "tests"
