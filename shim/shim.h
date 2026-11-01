// Shared declarations of Marien's C++ shim: the catalog reader (catalog.cpp) and the table
// scanner (scan.cpp), used by the table functions in extension.cpp. All logic lives in Lean
// behind lean_bridge.h; this side only reads LadybugDB and moves data.
#pragma once

#include <functional>
#include <string>

#include "lean_bridge.h"

namespace lbug::main {
class ClientContext;
}
namespace lbug::common {
class Value;
}

namespace marien {

// The catalog as the schema JSON of Marien/Schema.lean (system tables included; Lean removes
// them).
std::string catalogJson(lbug::main::ClientContext& ctx);

// Throws an error telling the user to run elpi_init() when the system tables are missing.
void requireModuleTables(lbug::main::ClientContext& ctx);

// The rows of _elpi_module as a JSON array of {name, version, source, derived, schema_hash,
// status, error}, read in the caller's transaction.
std::string storedModulesJson(lbug::main::ClientContext& ctx);

// Scan every table the session asks for, in the caller's transaction, and add the rows as
// facts. Calls `checkInterrupt` between batches. Throws on failure.
void materialize(lbug::main::ClientContext& ctx, marien_session*& session,
    const std::function<void()>& checkInterrupt);

// Append a database value to a column for Lean (DATE as days, TIMESTAMP as microseconds).
void pushValue(marien_values* out, const lbug::common::Value& v);

// A JSON string literal.
std::string jsonString(const std::string& s);

// Take a bridge string as std::string and free it.
std::string takeString(marien_str s);

} // namespace marien
