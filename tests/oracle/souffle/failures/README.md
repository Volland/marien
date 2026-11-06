# Soufflé oracle reproducers

`tests/oracle/souffle/run.sh` writes one directory here per comparison where Marien and Soufflé
disagree, named `seed<N>-size<S>[-rule]-<target>`:

- `schema.cypher`: the DDL and the graph, as Cypher
- `case.txt`: the whole workload, as `property rows` reads it
- `module.elpi`, `query.txt`: the module and the query Marien answered
- `prog.dl`, `facts/`: the Soufflé program and its facts
- `marien.rows`, `souffle.rows`: both answer multisets, sorted

Rerun one case with `.lake/build/bin/marien-gen oracle <seed> <size> <dir> [rule]` followed by
`build/oracle/property rows build/libmarien.lbug_extension <dir>`.
