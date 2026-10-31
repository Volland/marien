// Extension shim: LadybugDB's `init`/`name` entry points, Marien's table functions and options.
// It owns no logic beyond marshalling: every check and every statement comes from Lean through
// lean_bridge.h.
//
// Writes (elpi_init, elpi_save, elpi_drop, elpi_import) do all checking at bind time and return
// Cypher through rewriteFunc, so they run in the caller's transaction or not at all. LadybugDB
// only rewrites a bare `CALL f(...)`, and only with literal arguments.
#include <chrono>
#include <cstdlib>
#include <functional>
#include <mutex>
#include <string>
#include <vector>

#include "binder/binder.h"
#include "common/exception/interrupt.h"
#include "common/exception/runtime.h"
#include "extension/extension.h"
#include "function/table/bind_data.h"
#include "function/table/bind_input.h"
#include "function/table/simple_table_function.h"
#include "function/table/table_function.h"
#include "main/client_context.h"
#include "main/database.h"
#include "processor/execution_context.h"
#include "transaction/transaction_context.h"

#include "shim.h"

// @lat: [[components#Extension shim]]

using namespace lbug::common;
using namespace lbug::function;
using namespace lbug::main;

namespace marien {
namespace {

/* --- Options ------------------------------------------------------------------------- */

struct Option {
    const char* name;
    int64_t def;
};

// @tg: implements:: [[openspec:rule-execution#Execution limits are errors]]
constexpr Option options[] = {
    {"elpi_fuel", 100000000},       // resolution steps per call
    {"elpi_timeout_ms", 0},         // 0: no deadline
    {"elpi_max_solutions", 100000}, // solutions per call; more stop the search (exhausted = false)
    {"elpi_max_facts", 10000000},   // facts materialized per call
    {"elpi_slice_steps", 100000},   // steps between interrupt and deadline checks
    {"elpi_cache_size", 64},        // compiled modules kept in memory
};

uint64_t setting(ClientContext& ctx, const char* name) {
    auto v = ctx.getCurrentSetting(name).getValue<int64_t>();
    if (v < 0) throw RuntimeException(std::string("marien: ") + name + " must not be negative");
    return static_cast<uint64_t>(v);
}

/* --- Helpers ------------------------------------------------------------------------- */

std::vector<std::string> takeStrings(marien_strings s, const std::string& fn) {
    if (s.error.data) {
        std::string e(s.error.data, s.error.len);
        marien_bridge_free_strings(&s);
        throw RuntimeException(fn + ": " + e);
    }
    std::vector<std::string> out;
    for (size_t i = 0; i < s.n; i++) out.emplace_back(s.items[i].data, s.items[i].len);
    marien_bridge_free_strings(&s);
    return out;
}

std::string literal(const TableFuncBindInput* input, idx_t i, const char* fn) {
    try {
        return input->getLiteralVal<std::string>(i);
    } catch (Exception&) {
        throw RuntimeException(std::string(fn) +
                               ": arguments must be string literals (parameters are not supported)");
    }
}

offset_t mustBeStandalone(const TableFuncInput&, TableFuncOutput&) {
    throw RuntimeException("marien: this function writes and must be called on its own: CALL elpi_...(...)");
}

/* --- Writes through rewriteFunc ------------------------------------------------------ */

struct StatementsBindData final : TableFuncBindData {
    std::vector<std::string> statements;
    explicit StatementsBindData(std::vector<std::string> s) : statements{std::move(s)} {}
    std::unique_ptr<TableFuncBindData> copy() const override {
        return std::make_unique<StatementsBindData>(*this);
    }
};

// One statement is atomic on its own; several are wrapped in a transaction unless the caller
// already runs one.
std::string rewrite(ClientContext& ctx, const TableFuncBindData& bd) {
    auto& stmts = bd.constPtrCast<StatementsBindData>()->statements;
    bool wrap = stmts.size() > 1 && lbug::transaction::TransactionContext::Get(ctx)->isAutoTransaction();
    std::string q = wrap ? "BEGIN TRANSACTION;" : "";
    for (size_t i = 0; i < stmts.size(); i++) {
        if (wrap && i + 1 == stmts.size()) q += "COMMIT;";
        q += stmts[i] + ";";
    }
    return q;
}

std::unique_ptr<TableFunction> writeFunction(const char* name, std::vector<LogicalTypeID> args,
    table_func_bind_t bind) {
    auto f = std::make_unique<TableFunction>(name, std::move(args));
    f->bindFunc = std::move(bind);
    f->rewriteFunc = rewrite;
    f->tableFunc = mustBeStandalone;
    f->initSharedStateFunc = SimpleTableFunc::initSharedState;
    f->initLocalStateFunc = TableFunction::initEmptyLocalState;
    f->canParallelFunc = [] { return false; };
    return f;
}

struct ElpiInit {
    static constexpr const char* name = "ELPI_INIT";
    static function_set getFunctionSet() {
        function_set set;
        set.push_back(writeFunction(name, {}, [](const ClientContext*, const TableFuncBindInput*) {
            return std::make_unique<StatementsBindData>(
                takeStrings(marien_bridge_init_statements(), "elpi_init"));
        }));
        return set;
    }
};

struct ElpiSave {
    static constexpr const char* name = "ELPI_SAVE";
    static function_set getFunctionSet() {
        function_set set;
        set.push_back(writeFunction(name, {LogicalTypeID::STRING, LogicalTypeID::STRING},
            [](const ClientContext* c, const TableFuncBindInput* in) {
                auto& ctx = const_cast<ClientContext&>(*c);
                auto module = literal(in, 0, "elpi_save");
                auto source = literal(in, 1, "elpi_save");
                auto stored = storedModulesJson(ctx);
                auto catalog = catalogJson(ctx);
                return std::make_unique<StatementsBindData>(takeStrings(
                    marien_bridge_save(catalog.c_str(), stored.c_str(), module.c_str(), source.data(),
                        source.size()),
                    "elpi_save " + module));
            }));
        return set;
    }
};

struct ElpiDrop {
    static constexpr const char* name = "ELPI_DROP";
    static function_set getFunctionSet() {
        function_set set;
        set.push_back(writeFunction(name, {LogicalTypeID::STRING},
            [](const ClientContext* c, const TableFuncBindInput* in) {
                auto& ctx = const_cast<ClientContext&>(*c);
                auto module = literal(in, 0, "elpi_drop");
                auto stored = storedModulesJson(ctx);
                return std::make_unique<StatementsBindData>(takeStrings(
                    marien_bridge_drop(stored.c_str(), module.c_str()), "elpi_drop " + module));
            }));
        return set;
    }
};

struct ElpiImport {
    static constexpr const char* name = "ELPI_IMPORT";
    static function_set getFunctionSet() {
        function_set set;
        set.push_back(writeFunction(name, {LogicalTypeID::STRING},
            [](const ClientContext* c, const TableFuncBindInput* in) {
                auto& ctx = const_cast<ClientContext&>(*c);
                auto bundle = literal(in, 0, "elpi_import");
                auto stored = storedModulesJson(ctx);
                auto catalog = catalogJson(ctx);
                return std::make_unique<StatementsBindData>(takeStrings(
                    marien_bridge_import(catalog.c_str(), stored.c_str(), bundle.data(), bundle.size()),
                    "elpi_import"));
            }));
        return set;
    }
};

/* --- Reads computed at bind: elpi_export, elpi_signature ----------------------------- */

struct RowsBindData final : TableFuncBindData {
    size_t width;
    std::vector<std::string> cells; // row-major
    RowsBindData(lbug::binder::expression_vector cols, size_t width, std::vector<std::string> cells)
        : TableFuncBindData{std::move(cols), cells.size() / width}, width{width}, cells{std::move(cells)} {}
    std::unique_ptr<TableFuncBindData> copy() const override { return std::make_unique<RowsBindData>(*this); }
};

lbug::binder::expression_vector columns(const TableFuncBindInput* in, std::vector<std::string> names,
    std::vector<LogicalType> types) {
    names = TableFunction::extractYieldVariables(names, in->yieldVariables);
    return in->binder->createVariables(names, types);
}

offset_t rowsFunc(const TableFuncMorsel& morsel, const TableFuncInput& input, DataChunk& output) {
    auto& bd = *input.bindData->constPtrCast<RowsBindData>();
    auto n = morsel.endOffset - morsel.startOffset;
    for (offset_t i = 0; i < n; i++) {
        auto row = morsel.startOffset + i;
        for (size_t c = 0; c < bd.width; c++) {
            auto& cell = bd.cells[row * bd.width + c];
            auto& vec = output.getValueVectorMutable(c);
            if (vec.dataType.getLogicalTypeID() == LogicalTypeID::INT64) {
                vec.setValue(i, static_cast<int64_t>(std::stoll(cell)));
            } else {
                vec.setValue(i, cell);
            }
        }
    }
    return n;
}

std::unique_ptr<TableFunction> rowsFunction(const char* name, std::vector<LogicalTypeID> args,
    table_func_bind_t bind) {
    auto f = std::make_unique<TableFunction>(name, std::move(args));
    f->bindFunc = std::move(bind);
    f->tableFunc = SimpleTableFunc::getTableFunc(rowsFunc);
    f->initSharedStateFunc = SimpleTableFunc::initSharedState;
    f->initLocalStateFunc = TableFunction::initEmptyLocalState;
    return f;
}

// @tg: implements:: [[openspec:rule-storage#Export and import]]
struct ElpiExport {
    static constexpr const char* name = "ELPI_EXPORT";
    static function_set getFunctionSet() {
        function_set set;
        set.push_back(rowsFunction(name, {}, [](const ClientContext* c, const TableFuncBindInput* in) {
            auto& ctx = const_cast<ClientContext&>(*c);
            auto stored = storedModulesJson(ctx);
            auto cells = takeStrings(marien_bridge_export(stored.c_str()), "elpi_export");
            std::vector<LogicalType> types;
            types.push_back(LogicalType::STRING());
            types.push_back(LogicalType::INT64());
            types.push_back(LogicalType::STRING());
            return std::make_unique<RowsBindData>(columns(in, {"name", "version", "source"}, std::move(types)), 3,
                std::move(cells));
        }));
        return set;
    }
};

std::unique_ptr<TableFuncBindData> signatureBind(const ClientContext* c, const TableFuncBindInput* in,
    const std::string& table) {
    auto& ctx = const_cast<ClientContext&>(*c);
    auto catalog = catalogJson(ctx);
    auto cells = takeStrings(marien_bridge_signature(catalog.c_str(), table.c_str()), "elpi_signature");
    std::vector<LogicalType> types;
    types.push_back(LogicalType::STRING());
    types.push_back(LogicalType::STRING());
    types.push_back(LogicalType::STRING());
    return std::make_unique<RowsBindData>(columns(in, {"kind", "name", "text"}, std::move(types)), 3,
        std::move(cells));
}

// @tg: implements:: [[openspec:schema-encoding#Signature inspection]]
struct ElpiSignature {
    static constexpr const char* name = "ELPI_SIGNATURE";
    static function_set getFunctionSet() {
        function_set set;
        set.push_back(rowsFunction(name, {}, [](const ClientContext* c, const TableFuncBindInput* in) {
            return signatureBind(c, in, "");
        }));
        set.push_back(rowsFunction(name, {LogicalTypeID::STRING},
            [](const ClientContext* c, const TableFuncBindInput* in) {
                return signatureBind(c, in, literal(in, 0, "elpi_signature"));
            }));
        return set;
    }
};

/* --- elpi_query ---------------------------------------------------------------------- */

struct QueryBindData final : TableFuncBindData {
    std::string module, goal;
    QueryBindData(lbug::binder::expression_vector cols, std::string m, std::string g)
        : TableFuncBindData{std::move(cols)}, module{std::move(m)}, goal{std::move(g)} {}
    std::unique_ptr<TableFuncBindData> copy() const override { return std::make_unique<QueryBindData>(*this); }
};

struct QueryRow {
    int64_t sol;
    bool hasVar;
    std::string var, value;
};

struct QuerySharedState final : TableFuncSharedState {
    bool computed = false;
    bool exhausted = false;
    std::vector<QueryRow> rows;
    size_t cursor = 0;
    void resetState() override {
        std::lock_guard l{mtx};
        computed = false;
        rows.clear();
        cursor = 0;
    }
};

std::shared_ptr<TableFuncSharedState> queryInitShared(const TableFuncInitSharedStateInput&) {
    return std::make_shared<QuerySharedState>();
}

// Run the whole query: materialize, then solve in slices, checking LadybugDB's interrupt flag
// and the elpi_timeout_ms deadline between slices.
// @tg: implements:: [[openspec:rule-execution#Untyped debug query]]
// @tg: implements:: [[openspec:rule-execution#Fuel-sliced execution]]
void runQuery(ClientContext& ctx, const QueryBindData& bd, QuerySharedState& st) {
    auto timeout = setting(ctx, "elpi_timeout_ms");
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout);
    auto check = [&] {
        if (ctx.interrupted()) throw InterruptException{};
        if (timeout > 0 && std::chrono::steady_clock::now() >= deadline) {
            throw RuntimeException("marien: elpi_timeout_ms (" + std::to_string(timeout) + ") exceeded");
        }
    };
    auto catalog = catalogJson(ctx);
    auto stored = storedModulesJson(ctx);
    marien_str err{nullptr, 0};
    marien_session* s = marien_bridge_prepare(catalog.c_str(), stored.c_str(), bd.module.c_str(),
        bd.goal.c_str(), setting(ctx, "elpi_max_facts"), setting(ctx, "elpi_cache_size"), &err);
    if (!s) throw RuntimeException("elpi_query: " + takeString(err));
    try {
        materialize(ctx, s, check);
    } catch (...) {
        marien_bridge_free_session(s);
        throw;
    }
    marien_run* r = marien_bridge_start(s, bd.goal.c_str(), setting(ctx, "elpi_fuel"),
        setting(ctx, "elpi_slice_steps"), setting(ctx, "elpi_max_solutions"), &err);
    if (!r) throw RuntimeException("elpi_query: " + takeString(err));
    int64_t sol = 0;
    while (r) {
        try {
            check();
        } catch (...) {
            marien_bridge_free_run(r);
            throw;
        }
        marien_strings bs{{nullptr, 0}, 0, nullptr};
        switch (marien_bridge_step(&r, &bs, &err)) {
        case MARIEN_STEP_SOLUTION:
            if (bs.n == 0) st.rows.push_back({sol, false, "", ""});
            for (size_t i = 0; i + 1 < bs.n; i += 2) {
                st.rows.push_back({sol, true, std::string(bs.items[i].data, bs.items[i].len),
                    std::string(bs.items[i + 1].data, bs.items[i + 1].len)});
            }
            marien_bridge_free_strings(&bs);
            sol++;
            break;
        case MARIEN_STEP_PAUSED: break;
        case MARIEN_STEP_EXHAUSTED: st.exhausted = true; break;
        case MARIEN_STEP_STOPPED: st.exhausted = false; break;
        default: st.rows.clear(); throw RuntimeException("elpi_query: " + takeString(err));
        }
    }
}

offset_t queryFunc(const TableFuncInput& input, TableFuncOutput& output) {
    auto& st = *input.sharedState->ptrCast<QuerySharedState>();
    auto& bd = *input.bindData->constPtrCast<QueryBindData>();
    std::lock_guard l{st.mtx};
    if (!st.computed) {
        st.computed = true;
        runQuery(*input.context->clientContext, bd, st);
    }
    auto n = std::min<size_t>(DEFAULT_VECTOR_CAPACITY, st.rows.size() - st.cursor);
    auto& out = output.dataChunk;
    for (size_t i = 0; i < n; i++) {
        auto& row = st.rows[st.cursor + i];
        out.getValueVectorMutable(0).setValue(i, row.sol);
        if (row.hasVar) {
            out.getValueVectorMutable(1).setNull(i, false);
            out.getValueVectorMutable(2).setNull(i, false);
            out.getValueVectorMutable(1).setValue(i, row.var);
            out.getValueVectorMutable(2).setValue(i, row.value);
        } else {
            out.getValueVectorMutable(1).setNull(i, true);
            out.getValueVectorMutable(2).setNull(i, true);
        }
        out.getValueVectorMutable(3).setValue(i, st.exhausted);
    }
    st.cursor += n;
    return n;
}

struct ElpiQuery {
    static constexpr const char* name = "ELPI_QUERY";
    static function_set getFunctionSet() {
        function_set set;
        auto f = std::make_unique<TableFunction>(name,
            std::vector<LogicalTypeID>{LogicalTypeID::STRING, LogicalTypeID::STRING});
        f->bindFunc = [](const ClientContext*, const TableFuncBindInput* in) {
            std::vector<LogicalType> types;
            types.push_back(LogicalType::INT64());
            types.push_back(LogicalType::STRING());
            types.push_back(LogicalType::STRING());
            types.push_back(LogicalType::BOOL());
            return std::make_unique<QueryBindData>(columns(in, {"sol", "var", "value", "exhausted"}, std::move(types)),
                literal(in, 0, "elpi_query"), literal(in, 1, "elpi_query"));
        };
        f->tableFunc = queryFunc;
        f->initSharedStateFunc = queryInitShared;
        f->initLocalStateFunc = TableFunction::initEmptyLocalState;
        f->canParallelFunc = [] { return false; };
        set.push_back(std::move(f));
        return set;
    }
};

} // namespace
} // namespace marien

extern "C" {

// @tg: implements:: [[openspec:extension-runtime#Extension init starts the runtime]]
__attribute__((visibility("default"))) void init(ClientContext* context) {
    if (const char* err = marien_bridge_init()) {
        throw RuntimeException(std::string("marien: Lean initialization failed: ") + err);
    }
    auto& db = *context->getDatabase();
    for (auto& o : marien::options) db.addExtensionOption(o.name, LogicalTypeID::INT64, Value(o.def));
    using lbug::extension::ExtensionUtils;
    ExtensionUtils::addStandaloneTableFunc<marien::ElpiInit>(db);
    ExtensionUtils::addStandaloneTableFunc<marien::ElpiSave>(db);
    ExtensionUtils::addStandaloneTableFunc<marien::ElpiDrop>(db);
    ExtensionUtils::addStandaloneTableFunc<marien::ElpiImport>(db);
    ExtensionUtils::addTableFunc<marien::ElpiExport>(db);
    ExtensionUtils::addTableFunc<marien::ElpiSignature>(db);
    ExtensionUtils::addTableFunc<marien::ElpiQuery>(db);
}

__attribute__((visibility("default"))) const char* name() {
    return "MARIEN";
}
}
