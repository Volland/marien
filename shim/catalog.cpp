// Catalog reader: LadybugDB's catalog as the schema JSON that Marien/Schema.lean decodes.
// Read in the caller's transaction, so a table created earlier in the same transaction is seen.
#include <cstdlib>
#include <functional>
#include <string>

#include "catalog/catalog.h"
#include "catalog/catalog_entry/node_table_catalog_entry.h"
#include "catalog/catalog_entry/rel_group_catalog_entry.h"
#include "common/exception/runtime.h"
#include "common/types/types.h"
#include "main/client_context.h"
#include "transaction/transaction.h"

#include "shim.h"

// @lat: [[components#Catalog reader]]

using namespace lbug;
using namespace lbug::common;

namespace marien {

std::string jsonString(const std::string& s) {
    std::string out = "\"";
    for (unsigned char c : s) {
        switch (c) {
        case '"': out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        default:
            if (c < 0x20) {
                char buf[8];
                snprintf(buf, sizeof buf, "\\u%04x", c);
                out += buf;
            } else {
                out += static_cast<char>(c);
            }
        }
    }
    return out + "\"";
}

std::string takeString(marien_str s) {
    std::string out = s.data ? std::string(s.data, s.len) : std::string();
    free(s.data);
    return out;
}

static std::string typeJson(const LogicalType& t) {
    switch (t.getLogicalTypeID()) {
    case LogicalTypeID::INT8: case LogicalTypeID::INT16: case LogicalTypeID::INT32:
    case LogicalTypeID::INT64: case LogicalTypeID::INT128: case LogicalTypeID::UINT8:
    case LogicalTypeID::UINT16: case LogicalTypeID::UINT32: case LogicalTypeID::UINT64:
    case LogicalTypeID::UINT128: case LogicalTypeID::SERIAL: case LogicalTypeID::FLOAT:
    case LogicalTypeID::DOUBLE: case LogicalTypeID::STRING: case LogicalTypeID::BOOL:
    case LogicalTypeID::DATE: case LogicalTypeID::TIMESTAMP:
        return jsonString(t.toString());
    case LogicalTypeID::LIST:
        return "{\"list\": " + typeJson(ListType::getChildType(t)) + "}";
    case LogicalTypeID::ARRAY:
        return "{\"list\": " + typeJson(ArrayType::getChildType(t)) + "}";
    case LogicalTypeID::STRUCT: {
        std::string out = "{\"struct\": [";
        bool first = true;
        for (auto& f : StructType::getFields(t)) {
            if (!first) out += ", ";
            first = false;
            out += "[" + jsonString(f.getName()) + ", " + typeJson(f.getType()) + "]";
        }
        return out + "]}";
    }
    default:
        return "{\"other\": " + jsonString(t.toString()) + "}";
    }
}

static std::string propsJson(const catalog::TableCatalogEntry& e) {
    std::string out = "[";
    bool first = true;
    for (auto& p : e.getProperties()) {
        if (p.getName() == InternalKeyword::ID) continue;
        if (!first) out += ", ";
        first = false;
        out += "{\"name\": " + jsonString(p.getName()) + ", \"type\": " + typeJson(p.getType()) + "}";
    }
    return out + "]";
}

// @tg: implements:: [[openspec:schema-encoding#Schema model from the catalog]]
std::string catalogJson(main::ClientContext& ctx) {
    auto tx = transaction::Transaction::Get(ctx);
    auto cat = catalog::Catalog::Get(ctx);
    std::string out = "{\"nodes\": [";
    bool first = true;
    for (auto* n : cat->getNodeTableEntries(tx, false)) {
        if (!n->getForeignDatabaseName().empty()) continue;
        if (!first) out += ", ";
        first = false;
        out += "{\"name\": " + jsonString(n->getName()) + ", \"key\": " +
               jsonString(n->getPrimaryKeyName()) + ", \"properties\": " + propsJson(*n) + "}";
    }
    out += "], \"rels\": [";
    first = true;
    for (auto* r : cat->getRelGroupEntries(tx, false)) {
        if (!first) out += ", ";
        first = false;
        std::string pairs = "[";
        bool firstPair = true;
        for (auto& info : r->getRelEntryInfos()) {
            if (!firstPair) pairs += ", ";
            firstPair = false;
            pairs += "[" + jsonString(cat->getTableCatalogEntry(tx, info.nodePair.srcTableID)->getName()) +
                     ", " + jsonString(cat->getTableCatalogEntry(tx, info.nodePair.dstTableID)->getName()) + "]";
        }
        out += "{\"name\": " + jsonString(r->getName()) + ", \"pairs\": " + pairs +
               "], \"properties\": " + propsJson(*r) + "}";
    }
    return out + "]}";
}

// @tg: implements:: [[openspec:rule-storage#Module system tables]]
void requireModuleTables(main::ClientContext& ctx) {
    auto tx = transaction::Transaction::Get(ctx);
    auto cat = catalog::Catalog::Get(ctx);
    if (!cat->containsTable(tx, "_elpi_module") || !cat->containsTable(tx, "_elpi_accumulates")) {
        throw RuntimeException(
            "marien: the module tables do not exist; run CALL elpi_init() first");
    }
}

} // namespace marien
