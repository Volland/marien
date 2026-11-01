// Table scanner: reads node and rel tables through LadybugDB's storage and graph API in the
// caller's transaction, never through a nested query, and hands the rows to Lean as column
// batches (decision "Scan tables in the calling transaction"). Uncommitted rows of the calling
// transaction are seen; deleted rows are not.
#include <algorithm>
#include <cstdlib>
#include <functional>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

#include "catalog/catalog.h"
#include "catalog/catalog_entry/node_table_catalog_entry.h"
#include "catalog/catalog_entry/rel_group_catalog_entry.h"
#include "common/exception/runtime.h"
#include "common/types/date_t.h"
#include "common/types/int128_t.h"
#include "common/types/timestamp_t.h"
#include "common/types/uint128_t.h"
#include "common/types/value/nested.h"
#include "common/types/value/value.h"
#include "graph/graph_entry.h"
#include "graph/on_disk_graph.h"
#include "main/client_context.h"
#include "storage/storage_manager.h"
#include "storage/storage_utils.h"
#include "storage/table/node_table.h"
#include "transaction/transaction.h"

#include "shim.h"

// @lat: [[components#Table scanner]]

using namespace lbug;
using namespace lbug::common;

namespace marien {

// Append a database value to a column for Lean. DATE becomes days and TIMESTAMP microseconds
// since 1970-01-01 UTC; integers keep their exact value at any width.
void pushValue(marien_values* out, const Value& v) {
    if (v.isNull()) {
        marien_bridge_push_null(out);
        return;
    }
    switch (v.getDataType().getLogicalTypeID()) {
    case LogicalTypeID::SERIAL:
    case LogicalTypeID::INT64: marien_bridge_push_int64(out, v.getValue<int64_t>()); break;
    case LogicalTypeID::INT32: marien_bridge_push_int64(out, v.getValue<int32_t>()); break;
    case LogicalTypeID::INT16: marien_bridge_push_int64(out, v.getValue<int16_t>()); break;
    case LogicalTypeID::INT8: marien_bridge_push_int64(out, v.getValue<int8_t>()); break;
    case LogicalTypeID::UINT64: marien_bridge_push_uint64(out, v.getValue<uint64_t>()); break;
    case LogicalTypeID::UINT32: marien_bridge_push_uint64(out, v.getValue<uint32_t>()); break;
    case LogicalTypeID::UINT16: marien_bridge_push_uint64(out, v.getValue<uint16_t>()); break;
    case LogicalTypeID::UINT8: marien_bridge_push_uint64(out, v.getValue<uint8_t>()); break;
    case LogicalTypeID::INT128: {
        auto x = v.getValue<int128_t>();
        marien_bridge_push_int128(out, static_cast<uint64_t>(x.high), x.low);
        break;
    }
    case LogicalTypeID::UINT128: {
        auto x = v.getValue<uint128_t>();
        marien_bridge_push_uint128(out, x.high, x.low);
        break;
    }
    case LogicalTypeID::DOUBLE: marien_bridge_push_double(out, v.getValue<double>()); break;
    case LogicalTypeID::FLOAT: marien_bridge_push_double(out, v.getValue<float>()); break;
    case LogicalTypeID::BOOL: marien_bridge_push_bool(out, v.getValue<bool>()); break;
    case LogicalTypeID::STRING: {
        auto s = v.getValue<std::string>();
        marien_bridge_push_str(out, s.data(), s.size());
        break;
    }
    case LogicalTypeID::DATE: marien_bridge_push_int64(out, v.getValue<date_t>().days); break;
    case LogicalTypeID::TIMESTAMP: marien_bridge_push_int64(out, v.getValue<timestamp_t>().value); break;
    case LogicalTypeID::LIST:
    case LogicalTypeID::ARRAY:
    case LogicalTypeID::STRUCT: {
        auto n = NestedVal::getChildrenSize(&v);
        auto* items = marien_bridge_values_new(n);
        for (uint32_t i = 0; i < n; i++) pushValue(items, *NestedVal::getChildVal(&v, i));
        if (v.getDataType().getLogicalTypeID() == LogicalTypeID::STRUCT) {
            marien_bridge_push_struct(out, items);
        } else {
            marien_bridge_push_list(out, items);
        }
        break;
    }
    default:
        // the signature never asks for a column of another type
        marien_bridge_push_null(out);
    }
}

namespace {

// Scan the visible rows of a node table in the caller's transaction, a vector at a time:
// `onBatch(offsets, columns)` gets each row's offset and its values, one vector per column.
void scanNodes(main::ClientContext& ctx, catalog::NodeTableCatalogEntry& entry,
    const std::vector<std::string>& columns, const std::function<void()>& checkInterrupt,
    const std::function<void(const std::vector<offset_t>&, const std::vector<std::vector<Value>>&)>& onBatch) {
    auto tx = transaction::Transaction::Get(ctx);
    auto* mm = storage::MemoryManager::Get(ctx);
    auto& table = storage::StorageManager::Get(ctx)->getTable(entry.getTableID())->cast<storage::NodeTable>();
    std::vector<column_id_t> colIDs;
    std::vector<LogicalType> types;
    for (auto& c : columns) {
        colIDs.push_back(entry.getColumnID(c));
        types.push_back(entry.getProperty(c).getType().copy());
    }
    auto chunk = storage::Table::constructDataChunk(mm, std::move(types));
    ValueVector nodeIDs(LogicalType::INTERNAL_ID(), mm, chunk.state);
    std::vector<ValueVector*> outs;
    for (auto i = 0u; i < chunk.getNumValueVectors(); i++) outs.push_back(&chunk.getValueVectorMutable(i));
    storage::NodeTableScanState st(&nodeIDs, outs, chunk.state);
    st.setToTable(tx, &table, colIDs, {});
    offset_t total = table.getNumTotalRows(tx);
    offset_t cur = 0;
    while (cur < total) {
        checkInterrupt();
        nodeIDs.getSelVectorPtr()->setToUnfiltered(0);
        for (auto* v : outs) v->resetAuxiliaryBuffer();
        table.initScanState(tx, st, table.getTableID(), cur);
        auto nextGroup = storage::StorageUtils::getStartOffsetOfNodeGroup(st.nodeGroupIdx + 1);
        auto end = std::min<offset_t>(total, st.source == storage::TableScanSource::COMMITTED ?
                                                 nextGroup :
                                                 nextGroup + tx->getUncommittedOffset(*st.table, cur));
        auto n = std::min<offset_t>(end - cur, DEFAULT_VECTOR_CAPACITY);
        auto res = st.scanNext(tx, cur, n);
        if (res == storage::NODE_GROUP_SCAN_EMPTY_RESULT) break;
        cur += res.numRows;
        auto& sel = chunk.state->getSelVector();
        std::vector<offset_t> offsets;
        std::vector<std::vector<Value>> cols(outs.size());
        for (auto i = 0u; i < sel.getSelSize(); i++) {
            auto pos = sel[i];
            offsets.push_back(nodeIDs.getValue<nodeID_t>(pos).offset);
            for (auto c = 0u; c < outs.size(); c++) cols[c].push_back(*outs[c]->getAsValue(pos));
        }
        if (!offsets.empty()) onBatch(offsets, cols);
    }
}

catalog::NodeTableCatalogEntry* nodeEntry(main::ClientContext& ctx, const std::string& name) {
    auto* e = catalog::Catalog::Get(ctx)->getTableCatalogEntry(transaction::Transaction::Get(ctx), name);
    return e->ptrCast<catalog::NodeTableCatalogEntry>();
}

void addBatch(marien_session*& s, size_t scan, std::vector<marien_values*>& cols) { addColumns(s, scan, cols); }

// One column of a node table by offset; deleted rows have none.
std::vector<std::optional<Value>> byOffset(main::ClientContext& ctx, catalog::NodeTableCatalogEntry& e,
    const std::string& column, const std::function<void()>& checkInterrupt) {
    std::vector<std::optional<Value>> out;
    scanNodes(ctx, e, {column}, checkInterrupt,
        [&](const std::vector<offset_t>& offs, const std::vector<std::vector<Value>>& cols) {
            for (size_t i = 0; i < offs.size(); i++) {
                if (offs[i] >= out.size()) out.resize(offs[i] + 1);
                out[offs[i]] = cols[0][i];
            }
        });
    return out;
}

std::vector<std::optional<Value>> keysByOffset(main::ClientContext& ctx, catalog::NodeTableCatalogEntry& e,
    const std::function<void()>& checkInterrupt) {
    return byOffset(ctx, e, e.getPrimaryKeyName(), checkInterrupt);
}

void scanNodeTable(main::ClientContext& ctx, marien_session*& s, size_t scan,
    const std::vector<std::string>& desc, const std::function<void()>& checkInterrupt, const RowFilter* filter) {
    auto* e = nodeEntry(ctx, desc[1]);
    bool restricted = filter && filter->restricted(desc[1]);
    std::vector<std::string> columns{e->getPrimaryKeyName()};
    columns.insert(columns.end(), desc.begin() + 2, desc.end());
    scanNodes(ctx, *e, columns, checkInterrupt,
        [&](const std::vector<offset_t>& offs, const std::vector<std::vector<Value>>& cols) {
            std::vector<size_t> rows;
            for (size_t i = 0; i < offs.size(); i++) {
                if (!restricted || filter->allows(desc[1], offs[i])) rows.push_back(i);
            }
            if (rows.empty()) return;
            std::vector<marien_values*> batch;
            for (auto& col : cols) {
                auto* v = marien_bridge_values_new(rows.size());
                for (auto i : rows) pushValue(v, col[i]);
                batch.push_back(v);
            }
            addBatch(s, scan, batch);
        });
}

// A rel batch: [src tables, src keys, internal ids, dst tables, dst keys, props...].
struct RelBatch {
    size_t rows = 0;
    std::vector<marien_values*> cols;
    explicit RelBatch(size_t nprops) {
        for (size_t i = 0; i < 5 + nprops; i++) cols.push_back(marien_bridge_values_new(DEFAULT_VECTOR_CAPACITY));
    }
};

void scanRelTable(main::ClientContext& ctx, marien_session*& s, size_t scan,
    const std::vector<std::string>& desc, const std::function<void()>& checkInterrupt, const RowFilter* filter) {
    auto tx = transaction::Transaction::Get(ctx);
    auto cat = catalog::Catalog::Get(ctx);
    auto* rel = cat->getTableCatalogEntry(tx, desc[1])->ptrCast<catalog::RelGroupCatalogEntry>();
    size_t npairs = std::stoul(desc[2]);
    std::vector<std::pair<std::string, std::string>> pairs;
    for (size_t i = 0; i < npairs; i++) pairs.emplace_back(desc[3 + 2 * i], desc[4 + 2 * i]);
    std::vector<std::string> props(desc.begin() + 3 + 2 * npairs, desc.end());
    std::unordered_map<std::string, std::vector<std::optional<Value>>> keys;
    auto keysOf = [&](const std::string& t) -> std::vector<std::optional<Value>>& {
        auto it = keys.find(t);
        if (it == keys.end()) it = keys.emplace(t, keysByOffset(ctx, *nodeEntry(ctx, t), checkInterrupt)).first;
        return it->second;
    };
    std::vector<std::string> relProps{InternalKeyword::ID};
    relProps.insert(relProps.end(), props.begin(), props.end());
    auto batch = std::make_unique<RelBatch>(props.size());
    auto flush = [&]() {
        if (batch->rows == 0) return;
        addBatch(s, scan, batch->cols);
        batch = std::make_unique<RelBatch>(props.size());
    };
    for (auto& info : rel->getRelEntryInfos()) {
        auto* src = cat->getTableCatalogEntry(tx, info.nodePair.srcTableID);
        auto* dst = cat->getTableCatalogEntry(tx, info.nodePair.dstTableID);
        if (std::find(pairs.begin(), pairs.end(), std::make_pair(src->getName(), dst->getName())) == pairs.end()) {
            continue;
        }
        auto& srcKeys = keysOf(src->getName());
        auto& dstKeys = keysOf(dst->getName());
        bool srcRestricted = filter && filter->restricted(src->getName());
        bool dstRestricted = filter && filter->restricted(dst->getName());
        std::vector<catalog::TableCatalogEntry*> nodes{src};
        if (dst != src) nodes.push_back(dst);
        graph::OnDiskGraph g(&ctx, graph::NativeGraphEntry(nodes, {rel}));
        auto ns = g.prepareRelScan(*rel, info.oid, info.nodePair.dstTableID, relProps);
        for (offset_t o = 0; o < srcKeys.size(); o++) {
            if ((o & 1023) == 0) checkInterrupt();
            if (!srcKeys[o]) continue;
            if (srcRestricted && !filter->allows(src->getName(), o)) continue;
            for (auto chunk : g.scanFwd(nodeID_t{o, info.nodePair.srcTableID}, *ns)) {
                chunk.forEach([&](auto nbrs, auto propVecs, auto i) {
                    nodeID_t d = nbrs[i];
                    if (d.offset >= dstKeys.size() || !dstKeys[d.offset]) return;
                    if (dstRestricted && !filter->allows(dst->getName(), d.offset)) return;
                    auto id = propVecs[0]->template getValue<internalID_t>(i);
                    auto& c = batch->cols;
                    marien_bridge_push_str(c[0], src->getName().data(), src->getName().size());
                    pushValue(c[1], *srcKeys[o]);
                    marien_bridge_push_int64(c[2], (static_cast<int64_t>(id.tableID) << 40) | static_cast<int64_t>(id.offset));
                    marien_bridge_push_str(c[3], dst->getName().data(), dst->getName().size());
                    pushValue(c[4], *dstKeys[d.offset]);
                    for (size_t j = 0; j < props.size(); j++) pushValue(c[5 + j], *propVecs[1 + j]->getAsValue(i));
                    batch->rows++;
                });
                if (batch->rows >= DEFAULT_VECTOR_CAPACITY) flush();
            }
        }
    }
    flush();
    for (auto* v : batch->cols) marien_bridge_free_values(v);
}

std::vector<std::string> toVector(marien_strings& s) {
    std::vector<std::string> out;
    for (size_t i = 0; i < s.n; i++) out.emplace_back(s.items[i].data, s.items[i].len);
    marien_bridge_free_strings(&s);
    return out;
}

} // namespace

void addColumns(marien_session*& s, size_t scan, std::vector<marien_values*>& cols) {
    auto err = marien_bridge_add_batch(&s, scan, cols.data(), cols.size());
    cols.clear();
    if (err.data) throw RuntimeException("marien: " + takeString(err));
}

std::vector<std::optional<Value>> keysByOffset(main::ClientContext& ctx, const std::string& table,
    const std::function<void()>& checkInterrupt) {
    return keysByOffset(ctx, *nodeEntry(ctx, table), checkInterrupt);
}

std::vector<std::optional<Value>> columnByOffset(main::ClientContext& ctx, const std::string& table,
    const std::string& column, const std::function<void()>& checkInterrupt) {
    return byOffset(ctx, *nodeEntry(ctx, table), column, checkInterrupt);
}

// @tg: implements:: [[openspec:rule-execution#Full-scope materialization]]
void materialize(main::ClientContext& ctx, marien_session*& session, const std::function<void()>& checkInterrupt,
    const RowFilter* filter) {
    size_t n = marien_bridge_scan_count(session);
    for (size_t i = 0; i < n; i++) {
        auto ms = marien_bridge_scan(session, i);
        auto desc = toVector(ms);
        if (desc[0] == "node") {
            scanNodeTable(ctx, session, i, desc, checkInterrupt, filter);
        } else if (desc[0] == "rel") {
            scanRelTable(ctx, session, i, desc, checkInterrupt, filter);
        } else {
            scanStructure(ctx, session, i, desc, checkInterrupt, filter);
        }
    }
}

// Breadth first from the anchors, one hop per round, through the graph API.
// @tg: implements:: [[openspec:partitioning#Anchor partitions]] {confidence: partial, note: "the neighbourhood scan; extension.cpp drives the batches"}
RowFilter neighbourhood(main::ClientContext& ctx, const std::string& table, const std::vector<uint64_t>& anchors,
    uint64_t radius, const std::vector<std::pair<std::string, bool>>& steps,
    const std::function<void()>& checkInterrupt) {
    auto tx = transaction::Transaction::Get(ctx);
    auto cat = catalog::Catalog::Get(ctx);
    RowFilter f;
    f.restrictAll = true;
    struct Hop {
        table_id_t from;
        std::string to;
        bool fwd;
        std::unique_ptr<graph::OnDiskGraph> g;
        std::unique_ptr<graph::NbrScanState> state;
    };
    std::vector<Hop> hops;
    for (auto& [relName, out] : steps) {
        auto* rel = cat->getTableCatalogEntry(tx, relName)->ptrCast<catalog::RelGroupCatalogEntry>();
        for (auto& info : rel->getRelEntryInfos()) {
            auto* src = cat->getTableCatalogEntry(tx, info.nodePair.srcTableID);
            auto* dst = cat->getTableCatalogEntry(tx, info.nodePair.dstTableID);
            std::vector<catalog::TableCatalogEntry*> nodes{src};
            if (dst != src) nodes.push_back(dst);
            auto g = std::make_unique<graph::OnDiskGraph>(&ctx, graph::NativeGraphEntry(nodes, {rel}));
            auto st = g->prepareRelScan(*rel, info.oid, out ? info.nodePair.dstTableID : info.nodePair.srcTableID,
                {InternalKeyword::ID});
            hops.push_back({out ? info.nodePair.srcTableID : info.nodePair.dstTableID,
                (out ? dst : src)->getName(), out, std::move(g), std::move(st)});
        }
    }
    auto* anchorEntry = nodeEntry(ctx, table);
    std::vector<nodeID_t> frontier;
    for (auto o : anchors) {
        if (f.mark(table, o)) frontier.push_back(nodeID_t{o, anchorEntry->getTableID()});
    }
    // a table the neighbourhood never reaches is still restricted (no rows)
    f.allowed[table];
    for (uint64_t depth = 0; depth < radius && !frontier.empty(); depth++) {
        std::vector<nodeID_t> next;
        size_t k = 0;
        for (auto n : frontier) {
            if ((k++ & 1023) == 0) checkInterrupt();
            for (auto& h : hops) {
                if (h.from != n.tableID) continue;
                auto it = h.fwd ? h.g->scanFwd(n, *h.state) : h.g->scanBwd(n, *h.state);
                for (auto chunk : it) {
                    chunk.forEach([&](auto nbrs, auto, auto i) {
                        nodeID_t m = nbrs[i];
                        if (f.mark(h.to, m.offset)) next.push_back(m);
                    });
                }
            }
        }
        frontier = std::move(next);
    }
    return f;
}

// @tg: implements:: [[openspec:rule-execution#Narrowed scope for monotone entry points]] {confidence: partial, note: "the scope filter; Lean checks monotonicity"}
RowFilter scopeFilter(main::ClientContext& ctx, const Value& scope, const std::function<void()>& checkInterrupt,
    const std::string& fn) {
    auto tx = transaction::Transaction::Get(ctx);
    auto cat = catalog::Catalog::Get(ctx);
    std::vector<std::pair<std::string, const Value*>> entries;
    auto& type = scope.getDataType();
    if (type.getLogicalTypeID() == LogicalTypeID::STRUCT) {
        auto names = StructType::getFieldNames(type);
        for (size_t k = 0; k < names.size(); k++) entries.emplace_back(names[k], NestedVal::getChildVal(&scope, k));
    } else if (type.getLogicalTypeID() == LogicalTypeID::MAP) {
        for (uint32_t k = 0; k < NestedVal::getChildrenSize(&scope); k++) {
            auto* e = NestedVal::getChildVal(&scope, k);
            auto* key = NestedVal::getChildVal(e, 0);
            if (key->isNull() || key->getDataType().getLogicalTypeID() != LogicalTypeID::STRING) {
                throw RuntimeException(fn + ": scope table names must be strings");
            }
            entries.emplace_back(key->getValue<std::string>(), NestedVal::getChildVal(e, 1));
        }
    } else {
        throw RuntimeException(fn + ": the scope must be a map from node tables to key lists, such as {Person: [1, 2]}");
    }
    RowFilter f;
    for (auto& [name, list] : entries) {
        if (!cat->containsTable(tx, name) ||
            cat->getTableCatalogEntry(tx, name)->getTableType() != TableType::NODE) {
            throw RuntimeException(fn + ": scope: " + name + " is not a node table");
        }
        auto id = list->getDataType().getLogicalTypeID();
        if (list->isNull() || (id != LogicalTypeID::LIST && id != LogicalTypeID::ARRAY)) {
            throw RuntimeException(fn + ": scope: the keys of " + name + " must be a list");
        }
        std::unordered_map<std::string, bool> listed;
        for (uint32_t k = 0; k < NestedVal::getChildrenSize(list); k++) {
            auto* c = NestedVal::getChildVal(list, k);
            if (!c->isNull()) listed[c->toString()] = true;
        }
        auto* e = nodeEntry(ctx, name);
        auto keys = keysByOffset(ctx, *e, checkInterrupt);
        auto& v = f.allowed[e->getName()];
        v.assign(keys.size(), false);
        for (size_t o = 0; o < keys.size(); o++) v[o] = keys[o] && listed.count(keys[o]->toString()) > 0;
    }
    return f;
}

std::vector<std::pair<uint64_t, uint64_t>> edgeOffsets(main::ClientContext& ctx, const std::string& relName,
    const std::function<void()>& checkInterrupt) {
    auto tx = transaction::Transaction::Get(ctx);
    auto cat = catalog::Catalog::Get(ctx);
    auto* rel = cat->getTableCatalogEntry(tx, relName)->ptrCast<catalog::RelGroupCatalogEntry>();
    std::vector<std::pair<uint64_t, uint64_t>> out;
    for (auto& info : rel->getRelEntryInfos()) {
        auto* node = cat->getTableCatalogEntry(tx, info.nodePair.srcTableID);
        auto live = keysByOffset(ctx, *node->ptrCast<catalog::NodeTableCatalogEntry>(), checkInterrupt);
        graph::OnDiskGraph g(&ctx, graph::NativeGraphEntry({node}, {rel}));
        auto ns = g.prepareRelScan(*rel, info.oid, info.nodePair.dstTableID, {InternalKeyword::ID});
        for (offset_t o = 0; o < live.size(); o++) {
            if ((o & 1023) == 0) checkInterrupt();
            if (!live[o]) continue;
            for (auto chunk : g.scanFwd(nodeID_t{o, info.nodePair.srcTableID}, *ns)) {
                chunk.forEach([&](auto nbrs, auto, auto i) {
                    nodeID_t d = nbrs[i];
                    if (d.offset < live.size() && live[d.offset]) out.emplace_back(o, d.offset);
                });
            }
        }
    }
    return out;
}

std::string storedModulesJson(main::ClientContext& ctx) {
    requireModuleTables(ctx);
    auto* e = nodeEntry(ctx, "_elpi_module");
    std::string out = "[";
    bool first = true;
    // a table made by the tracer bullet has no error column until elpi_init runs again
    std::vector<std::string> cols{"name", "version", "source", "derived", "schema_hash", "status"};
    bool hasError = e->containsProperty("error");
    if (hasError) cols.push_back("error");
    scanNodes(ctx, *e, cols, [] {},
        [&](const std::vector<offset_t>&, const std::vector<std::vector<Value>>& cols) {
            for (size_t i = 0; i < cols[0].size(); i++) {
                auto str = [&](size_t c) { return cols[c][i].isNull() ? std::string() : cols[c][i].getValue<std::string>(); };
                auto version = cols[1][i].isNull() ? 0 : cols[1][i].getValue<int64_t>();
                if (!first) out += ", ";
                first = false;
                out += "{\"name\": " + jsonString(str(0)) + ", \"version\": " + std::to_string(version) +
                       ", \"source\": " + jsonString(str(2)) + ", \"derived\": " + jsonString(str(3)) +
                       ", \"schema_hash\": " + jsonString(str(4)) + ", \"status\": " + jsonString(str(5)) +
                       ", \"error\": " + jsonString(hasError ? str(6) : std::string()) + "}";
            }
        });
    return out + "]";
}

} // namespace marien
