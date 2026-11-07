// Shared declarations of Marien's C++ shim: the catalog reader (catalog.cpp) and the table
// scanner (scan.cpp), used by the table functions in extension.cpp. All logic lives in Lean
// behind lean_bridge.h; this side only reads LadybugDB and moves data.
#pragma once

#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#include "common/types/value/value.h"
#include "lean_bridge.h"

namespace lbug::main {
class ClientContext;
class Database;
}
namespace lbug::common {
class Value;
}

namespace marien {

// The catalog as the schema JSON of Marien/Schema.lean (system tables included; Lean removes
// them), with the rows of _elpi_annotation and stage 1's limits (elpi_fuel,
// elpi_max_generated_bytes).
std::string catalogJson(lbug::main::ClientContext& ctx);

// The rows of _elpi_annotation as a JSON array of {table, key, value}; empty when the table does
// not exist yet.
std::string annotationsJson(lbug::main::ClientContext& ctx);

// Throws an error telling the user to run elpi_init() when the system tables are missing.
void requireModuleTables(lbug::main::ClientContext& ctx);

// The rows of _elpi_module as a JSON array of {name, version, source, derived, schema_hash,
// status, error, generated}, read in the caller's transaction.
std::string storedModulesJson(lbug::main::ClientContext& ctx);

// Which rows of node tables a call reads: a narrowed scope, a partition batch's neighbourhood
// or a key bucket. An edge is read only when each of its endpoints is allowed or in a table the
// filter leaves alone.
struct RowFilter {
    // a node table without an entry has no rows (partitions); otherwise it is read in full (scopes)
    bool restrictAll = false;
    std::unordered_map<std::string, std::vector<bool>> allowed; // by table name, by offset
    bool restricted(const std::string& table) const { return restrictAll || allowed.count(table) > 0; }
    bool allows(const std::string& table, uint64_t offset) const {
        auto it = allowed.find(table);
        if (it == allowed.end()) return !restrictAll;
        return offset < it->second.size() && it->second[offset];
    }
    // mark a row; true when it was not marked yet
    bool mark(const std::string& table, uint64_t offset) {
        auto& v = allowed[table];
        if (offset >= v.size()) v.resize(offset + 1, false);
        if (v[offset]) return false;
        v[offset] = true;
        return true;
    }
};

// Scan every table the session asks for, in the caller's transaction, and add the rows the
// filter allows (all rows without one) as facts. Calls `checkInterrupt` between batches.
// Throws on failure.
void materialize(lbug::main::ClientContext& ctx, marien_session*& session,
    const std::function<void()>& checkInterrupt, const RowFilter* filter = nullptr);

// The primary key of each row of a node table, by offset; deleted rows have none.
std::vector<std::optional<lbug::common::Value>> keysByOffset(lbug::main::ClientContext& ctx,
    const std::string& table, const std::function<void()>& checkInterrupt);

// One column of a node table, by offset; deleted rows have none.
std::vector<std::optional<lbug::common::Value>> columnByOffset(lbug::main::ClientContext& ctx,
    const std::string& table, const std::string& column, const std::function<void()>& checkInterrupt);

// The rows within `radius` edges of the anchors (offsets of node table `table`), following each
// rel table of `steps` in its direction (true: outgoing), read in the caller's transaction.
RowFilter neighbourhood(lbug::main::ClientContext& ctx, const std::string& table,
    const std::vector<uint64_t>& anchors, uint64_t radius,
    const std::vector<std::pair<std::string, bool>>& steps, const std::function<void()>& checkInterrupt);

// The filter of a narrowed scope: a STRUCT or MAP from node table names to lists of primary keys.
RowFilter scopeFilter(lbug::main::ClientContext& ctx, const lbug::common::Value& scope,
    const std::function<void()>& checkInterrupt, const std::string& fn);

// The edges of a rel table with one FROM/TO pair over one node table, as (source, target)
// offsets between live rows.
std::vector<std::pair<uint64_t, uint64_t>> edgeOffsets(lbug::main::ClientContext& ctx, const std::string& rel,
    const std::function<void()>& checkInterrupt);

// Add one batch of columns (consumed) to scan `scan` of the session; throws on failure.
void addColumns(marien_session*& s, size_t scan, std::vector<marien_values*>& cols);

// structure.cpp: compute `in_cycle.<rel>` (desc ["cycle", rel, node table]) or
// `component.<rel>` (["component", rel, node table]) and add the facts of the allowed rows.
void scanStructure(lbug::main::ClientContext& ctx, marien_session*& session, size_t scan,
    const std::vector<std::string>& desc, const std::function<void()>& checkInterrupt, const RowFilter* filter);

// Append a database value to a column for Lean (DATE as days, TIMESTAMP as microseconds).
void pushValue(marien_values* out, const lbug::common::Value& v);

// A JSON string literal.
std::string jsonString(const std::string& s);

// Take a bridge string as std::string and free it.
std::string takeString(marien_str s);

// A Marien statement desugared to its CALL form (Marien/Statement.lean): the function, whether it
// returns rows, its Cypher text and its literal arguments. Empty for text that is not a Marien
// statement; a malformed one throws with the parser's message (statements.cpp).
struct Desugared {
    struct Arg {
        bool list = false;
        std::string value;
        std::vector<std::string> items;
    };
    std::string fn;
    bool rows = false;
    std::string cypher;
    std::vector<Arg> args;
};
std::optional<Desugared> desugarStatement(const std::string& text);

} // namespace marien
