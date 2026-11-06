## ADDED Requirements

### Requirement: Schema model from the catalog
The extension SHALL read LadybugDB's catalog into a schema model: node tables with their primary key and properties, rel tables with their FROM/TO node table pairs and properties, each property with its LadybugDB type. The model SHALL be a pure Lean value built from a serialized catalog description, so the same model can be built from a file by the offline tool of M5.

#### Scenario: Node and rel tables are read
- **WHEN** the database has `NODE TABLE Person(id INT64 PRIMARY KEY, name STRING, age INT64)` and `REL TABLE Knows(FROM Person TO Person, since INT64)`
- **THEN** the model has node table `Person` with key `id` and properties `name: STRING`, `age: INT64`
- **AND** rel table `Knows` with pair `(Person, Person)` and property `since: INT64`

### Requirement: Injective naming
The generator SHALL map table and property names to ELPI identifiers by converting to lower snake case (`ReportsTo` → `reports_to`, `Person.firstName` → `person.first_name`). When two distinct catalog names map to the same identifier, or a name maps to an ELPI keyword or a builtin, generation SHALL fail with an error that lists the clashing names. Generation SHALL therefore never produce one identifier for two catalog names.

#### Scenario: Snake-case mapping
- **WHEN** the schema has node table `ReportsTo` and property `firstName`
- **THEN** the identifiers are `reports_to` and `<table>.first_name`

#### Scenario: Collision is an error
- **WHEN** the schema has node tables `ReportsTo` and `Reports_To`
- **THEN** generation fails, naming both tables and the shared identifier `reports_to`

### Requirement: Node table encoding
For each node table `T` with primary key type `K`, the signature SHALL declare `kind t type.`, the constructor `type t k -> t.` where `k` is the ELPI type of `K`, a predicate `pred t o:t.` listing every node, and for each non-key property `p` of ELPI type `v` a predicate `pred t.p o:t, o:v.`. A node with a null property SHALL have no fact for that property.

#### Scenario: Generated node declarations
- **WHEN** the signature is generated for `Person(id INT64 PK, name STRING, age INT64)`
- **THEN** it contains `kind person type.`, `type person int -> person.`, `pred person o:person.`, `pred person.name o:person, o:string.` and `pred person.age o:person, o:int.`

#### Scenario: Null is an absent fact
- **WHEN** a Person with id 7 has a null name
- **THEN** materialization emits no `person.name (person 7) _` fact

### Requirement: Rel table encoding
For each rel table `R` with a single FROM/TO pair `(A, B)`, the signature SHALL declare an edge kind `kind r type.` with constructor `type r int -> r.` over the edge's internal id, the predicate `pred r o:a, o:r, o:b.`, and for each property `p` of type `v` the predicate `pred r.p o:r, o:v.`. For a rel table with several FROM/TO pairs, the endpoints SHALL be union kinds `r.src` and `r.dst`, with one constructor per node table (`type r.src.person person -> r.src.`), and the rel predicate SHALL be `pred r o:r.src, o:r, o:r.dst.`. Edge ids SHALL be documented as stable only within one transaction.

#### Scenario: Single-pair rel
- **WHEN** the signature is generated for `Knows(FROM Person TO Person, since INT64)`
- **THEN** it contains `kind knows type.`, `pred knows o:person, o:knows, o:person.` and `pred knows.since o:knows, o:int.`

#### Scenario: Multi-pair rel
- **WHEN** `Owns` has pairs `(Person, Car)` and `(Company, Car)`
- **THEN** the signature declares `kind owns.src type.` with constructors `owns.src.person` and `owns.src.company`, and `pred owns o:owns.src, o:owns, o:owns.dst.`

#### Scenario: Parallel edges stay distinct
- **WHEN** two `Knows` edges connect the same two persons
- **THEN** materialization emits two `knows` facts with different edge terms

### Requirement: Property type mapping
The generator SHALL map LadybugDB types as follows: all signed and unsigned integer types (INT8 to INT128, UINT8 to UINT128) and SERIAL to `int`; FLOAT and DOUBLE to `float`; STRING to `string`; BOOL to `bool`; DATE to `int` days since 1970-01-01; TIMESTAMP to `int` microseconds since 1970-01-01 UTC; LIST of a supported type `x` to `list x`; STRUCT to a generated record kind `t.p.rec` with one constructor whose arguments follow the struct's field order. Properties of any other type SHALL be left out of the signature with a warning that names the table, property and type. The engine's `int` is an unbounded integer, so every integer value, including UINT64 and INT128 values, SHALL keep its exact value; no integer SHALL ever wrap.

#### Scenario: Temporal values as epoch integers
- **WHEN** a Person has `born DATE` equal to `1970-01-11`
- **THEN** the fact is `person.born (person K) 10`

#### Scenario: Unsupported type is skipped with a warning
- **WHEN** a node table has a property `tags MAP(STRING, INT64)`
- **THEN** the signature has no predicate for it
- **AND** `elpi_signature()` and `elpi_save` report a warning naming the table, `tags` and `MAP(STRING, INT64)`

#### Scenario: Large integers keep their value
- **WHEN** a UINT64 property holds 18446744073709551615
- **THEN** the fact holds the `int` 18446744073709551615

### Requirement: System tables are invisible to rules
Tables whose names start with `_elpi_` SHALL never appear in the schema model passed to the signature generator, so no identifier is generated for them and no run loads facts from them. Their names start with `_`, which ELPI reads as a variable, so a module cannot even write them as constants.

#### Scenario: Module cannot read its own storage
- **WHEN** a module mentions `_elpi_module.source`
- **THEN** the signature declares nothing for `_elpi_module`
- **AND** a run of the module scans no `_elpi_*` table

### Requirement: Canonical schema hash
The extension SHALL compute a schema hash from a canonical form of the schema model, with tables, properties and FROM/TO pairs sorted by name and `_elpi_*` tables removed. Two catalogs that describe the same schema in a different order SHALL get the same hash. Any change to a table name, property name, property type, key or FROM/TO pair SHALL change the canonical form.

#### Scenario: Order does not matter
- **WHEN** the same tables are created in two databases in different orders
- **THEN** both report the same schema hash

#### Scenario: Type change changes the hash
- **WHEN** `Person.age` is changed from INT64 to DOUBLE
- **THEN** the schema hash differs

### Requirement: Value codec round-trip
The value codec SHALL convert each supported database value of a given property type to an ELPI term and back. For every supported type and every value of that type, decoding the encoding SHALL give back the original value. Node references SHALL be encoded as the table's constructor applied to the primary key.

#### Scenario: Every supported type round-trips
- **WHEN** generated values of every supported type, including nested LISTs and STRUCTs, are encoded and decoded
- **THEN** each decoded value equals the original

### Requirement: Signature inspection
`CALL elpi_signature()` SHALL return the generated signature text and its warnings, and `CALL elpi_signature(table)` the declarations for one table, so users can see the identifiers their rules must use.

#### Scenario: Show one table
- **WHEN** `CALL elpi_signature('Person') RETURN *` is run
- **THEN** the result contains the declarations for `person` and its properties and nothing for other tables
