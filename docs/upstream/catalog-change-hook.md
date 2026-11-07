Feature: a catalog-change hook for extensions

### API

C++ (the extension API)

### Description

**Problem.** An extension that keeps state derived from the catalog has no way to learn that the catalog changed. LadybugDB's extension interfaces let an extension add functions, options, and transformer/binder/planner/mapper extensions, but nothing is called when a DDL statement (`CREATE`/`DROP`/`ALTER TABLE`, renames, added or dropped properties) changes the catalog.

Our case is [Marien](https://github.com/Volland/marien), an out-of-tree extension that stores logic-programming rule modules in the database (`_elpi_module`) and typechecks each one against a signature generated from the schema. After `ALTER TABLE Person DROP name`, a module that reads `person.name` is broken. Today we detect that lazily: every call recomputes a hash of the tables a module reaches and compares it with the stored one. That works, but the module is marked broken only when it next runs, and every call pays for reading the catalog.

**Proposal.** A listener an extension registers at load time, called for every DDL statement after it has changed the catalog and inside the same transaction:

```cpp
namespace lbug::extension {
struct CatalogChange {
    enum class Kind { CREATE_TABLE, DROP_TABLE, ALTER_TABLE, RENAME_TABLE };
    Kind kind;
    std::string tableName;      // the old name for RENAME_TABLE
    std::string newTableName;   // RENAME_TABLE only
};

class LBUG_API CatalogListener {
public:
    virtual ~CatalogListener() = default;
    // Runs in the DDL's transaction, after the catalog change; an exception aborts the statement.
    virtual void onCatalogChange(main::ClientContext& context, const CatalogChange& change) = 0;
};
} // namespace lbug::extension

// main::Database
void addCatalogListener(std::unique_ptr<extension::CatalogListener> listener);
```

Running inside the DDL's transaction is what makes it useful: the listener can update the extension's own tables (mark modules broken) atomically with the change, so no reader ever sees the new schema with stale derived state.

**Where it would be called.** The DDL operators in `src/processor/operator/ddl/` (`create_table.cpp`, `drop.cpp`, `alter.cpp`), after they call `Catalog::createTableEntry`, `Catalog::dropTableEntry` and `Catalog::alterTableEntry` (`src/catalog/catalog.cpp:655`, `:213`, `:255` at v0.22.1). Calling it from the operators rather than from `Catalog` keeps internal catalog writes (recovery, replaying the WAL, `IMPORT DATABASE`) out of it.

**Scope.** Only the notification. Extensions without a listener see no change, and an extension like ours keeps its lazy check as a fallback for databases opened without it loaded.

We would be glad to send a pull request if the shape above (or another one you prefer) is acceptable.

---

Filed as https://github.com/LadybugDB/ladybug/issues/1518 on 2026-11-06 (task 4.1 of `openspec/changes/add-ecosystem`).

## Answer (2026-11-07)

Declined by adsharma (LadybugDB): catalog-specific hooks are untenable because of MVCC and ordering; the suggested alternative is tailing the WAL, as in [adsharma/print-wal-demo](https://github.com/adsharma/print-wal-demo) (a pinned read transaction keeps the WAL from being checkpointed away while a thread deserializes each committed record).

Why Marien does not adopt it:

- It sees a DDL only after commit and on another thread, so it cannot mark modules `broken` in the DDL's transaction; a reader could still see the new schema with the old status. The lazy recheck has no such window: each call compares the hash of the tables a module reaches in the caller's own snapshot.
- Pinning the WAL makes it grow without bound, and it needs an on-disk database and internal headers (`storage/wal/*`, record classes whose RTTI is hidden across the extension boundary).
- The catalog's version counter is not a safe cache key for the lazy check either: it is global and bumped at commit (`Transaction::publishCommit`), so a snapshot older than a DDL sees the new number with the old schema.

Outcome: task 4.2 closed; the lazy recheck is the only path. A reply explaining this was posted on 2026-11-07; the maintainers had already closed the issue.
