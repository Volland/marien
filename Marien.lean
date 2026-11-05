import Marien.Engine
import Marien.Schema
import Marien.Ffi
import Marien.Analysis.Semantics

/-!
# Marien

A LadybugDB extension that stores λProlog (ELPI) programs in the database and runs them with
LeanElpi to reason about and validate the graph. Architecture and decisions: `tg.md/`;
requirements: `openspec/`.
-/
