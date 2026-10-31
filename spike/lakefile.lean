import Lake

open System Lake DSL

-- Throwaway spike: proves one Lean runtime with LeanElpi can live inside LadybugDB.
-- See openspec/changes/archive/2026-10-31-spike-lean-runtime-in-ladybug.
package «marien-spike» where
  leanOptions := #[⟨`autoImplicit, false⟩]

require «lean-elpi» from git "https://github.com/Volland/lean-elpi" @ "v0.3.3"

lean_lib Spike where
  roots := #[`Spike]
