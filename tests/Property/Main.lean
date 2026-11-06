import Property.Model
import SouffleOracle.Translate

/-! `marien-gen`: the workloads of the differential properties, for `tests/differential/run.sh`, and
the rejection measure, and the cases of the Soufflé oracle (`tests/oracle/souffle/run.sh`). -/

open Property

def main (args : List String) : IO UInt32 := do
  match args with
  | ["case", seed, size] => IO.print (workload seed.toNat! size.toNat!).text; return 0
  | ["measure", seed, size] => IO.println (workload seed.toNat! size.toNat!).measure; return 0
  | ["rejections", count, size] => IO.print (rejections count.toNat! size.toNat! 5); return 0
  | ["oracle", seed, size, dir] => Oracle.writeCase seed.toNat! size.toNat! "" dir; return 0
  | ["oracle", seed, size, dir, variant] => Oracle.writeCase seed.toNat! size.toNat! variant dir; return 0
  | _ =>
    IO.eprintln "usage: marien-gen case <seed> <size> | measure <seed> <size> | rejections <count> <size> | oracle <seed> <size> <dir> [rule]"
    return 2
