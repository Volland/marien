// Extension shim: LadybugDB's `init`/`name` entry points, Marien's table functions and options.
// It owns no logic beyond marshalling: every check and every statement comes from Lean through
// lean_bridge.h.
//
// Writes (elpi_init, elpi_save, elpi_drop, elpi_import, elpi_recheck) do all checking at bind
// time and return Cypher through rewriteFunc, so they run in the caller's transaction or not at
// all. LadybugDB only rewrites a bare `CALL f(...)`, and only with literal arguments.
//
// Reads that solve (elpi_query, elpi_run, elpi_validate) materialize the facts and run the goal
// in fuel slices on their first call, then hand out the buffered rows. An entry point with an
// accepted partition runs batch by batch, each batch in a fresh store; a narrowed scope restricts
// the rows the scanner reads.
#include <algorithm>
#include <chrono>
#include <dlfcn.h>
#include <optional>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <functional>
#include <mutex>
#include <string>
#include <vector>

#include "binder/binder.h"
#include "catalog/catalog.h"
#include "common/exception/interrupt.h"
#include "common/exception/runtime.h"
#include "common/string_utils.h"
#include "common/types/date_t.h"
#include "common/types/int128_t.h"
#include "common/types/timestamp_t.h"
#include "common/types/uint128_t.h"
#include "common/types/value/nested.h"
#include "extension/extension.h"
#include "function/table/bind_data.h"
#include "function/table/bind_input.h"
#include "function/table/simple_table_function.h"
#include "function/table/table_function.h"
#include "main/client_context.h"
#include "main/database.h"
#include "storage/storage_version_info.h"
#include "processor/execution_context.h"
#include "transaction/transaction.h"
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
    {"elpi_partition_batch", 10000}, // anchors per batch of a partitioned run; key rows per bucket
    {"elpi_max_generated_bytes", 1000000}, // text stage 1 meta-rules may generate per module
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

// A string literal argument. LadybugDB rewrites a standalone CALL while parsing, before a prepared
// statement's parameters are bound (constraint "Standalone CALL rewrites run before parameters are
// bound"), so a write function sees a parameter without its value and says so.
std::string literal(const TableFuncBindInput* input, idx_t i, const char* fn) {
    if (input->params.at(i)->expressionType == ExpressionType::PARAMETER) {
        throw RuntimeException(std::string(fn) + ": arguments must be string literals, not query parameters; " +
                               "LadybugDB rewrites this CALL before parameters are bound (LadybugDB/ladybug#1519)");
    }
    try {
        return input->getLiteralVal<std::string>(i);
    } catch (Exception&) {
        throw RuntimeException(std::string(fn) + ": arguments must be string literals");
    }
}

// The strings of a LIST(STRING) literal argument.
std::vector<std::string> stringList(const TableFuncBindInput* input, idx_t i, const char* fn) {
    auto v = input->getValue(i);
    auto id = v.getDataType().getLogicalTypeID();
    if (v.isNull() || (id != LogicalTypeID::LIST && id != LogicalTypeID::ARRAY)) {
        throw RuntimeException(std::string(fn) + ": the module list must be a list literal such as ['org', 'hr']");
    }
    std::vector<std::string> out;
    for (uint32_t k = 0; k < NestedVal::getChildrenSize(&v); k++) {
        auto* c = NestedVal::getChildVal(&v, k);
        if (c->isNull() || c->getDataType().getLogicalTypeID() != LogicalTypeID::STRING) {
            throw RuntimeException(std::string(fn) + ": module names must be strings");
        }
        out.push_back(c->getValue<std::string>());
    }
    return out;
}

std::vector<const char*> cstrs(const std::vector<std::string>& v) {
    std::vector<const char*> out;
    for (auto& x : v) out.push_back(x.c_str());
    return out;
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
    static std::unique_ptr<TableFuncBindData> bind(const ClientContext* c, const std::string& module,
        const std::string& source) {
        auto& ctx = const_cast<ClientContext&>(*c);
        auto stored = storedModulesJson(ctx);
        auto catalog = catalogJson(ctx);
        return std::make_unique<StatementsBindData>(takeStrings(
            marien_bridge_save(catalog.c_str(), stored.c_str(), module.c_str(), source.data(), source.size()),
            "elpi_save " + module));
    }
    static function_set getFunctionSet() {
        function_set set;
        set.push_back(writeFunction(name, {LogicalTypeID::STRING, LogicalTypeID::STRING},
            [](const ClientContext* c, const TableFuncBindInput* in) {
                return bind(c, literal(in, 0, "elpi_save"), literal(in, 1, "elpi_save"));
            }));
        return set;
    }
};

// @tg: implements:: [[openspec:schema-reflection#Schema annotations]]
struct ElpiAnnotate {
    static constexpr const char* name = "ELPI_ANNOTATE";
    static std::unique_ptr<TableFuncBindData> bind(const ClientContext* c, const std::string& table,
        const std::string& key, const std::string& value) {
        auto& ctx = const_cast<ClientContext&>(*c);
        auto tx = lbug::transaction::Transaction::Get(ctx);
        if (!lbug::catalog::Catalog::Get(ctx)->containsTable(tx, "_elpi_annotation")) {
            throw RuntimeException("elpi_annotate: the annotation table does not exist; run CALL elpi_init() first");
        }
        auto catalog = catalogJson(ctx);
        return std::make_unique<StatementsBindData>(takeStrings(
            marien_bridge_annotate(catalog.c_str(), table.c_str(), key.c_str(), value.c_str()),
            "elpi_annotate " + table));
    }
    static function_set getFunctionSet() {
        function_set set;
        set.push_back(writeFunction(name, {LogicalTypeID::STRING, LogicalTypeID::STRING, LogicalTypeID::STRING},
            [](const ClientContext* c, const TableFuncBindInput* in) {
                return bind(c, literal(in, 0, "elpi_annotate"), literal(in, 1, "elpi_annotate"),
                    literal(in, 2, "elpi_annotate"));
            }));
        return set;
    }
};

struct ElpiDrop {
    static constexpr const char* name = "ELPI_DROP";
    static std::unique_ptr<TableFuncBindData> bind(const ClientContext* c, const std::string& module) {
        auto& ctx = const_cast<ClientContext&>(*c);
        auto stored = storedModulesJson(ctx);
        return std::make_unique<StatementsBindData>(takeStrings(
            marien_bridge_drop(stored.c_str(), module.c_str()), "elpi_drop " + module));
    }
    static function_set getFunctionSet() {
        function_set set;
        set.push_back(writeFunction(name, {LogicalTypeID::STRING},
            [](const ClientContext* c, const TableFuncBindInput* in) { return bind(c, literal(in, 0, "elpi_drop")); }));
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

// @tg: implements:: [[openspec:schema-evolution#Explicit recheck]]
struct ElpiRecheck {
    static constexpr const char* name = "ELPI_RECHECK";
    static std::unique_ptr<TableFuncBindData> bind(const ClientContext* c, const std::vector<std::string>& names,
        bool all) {
        auto& ctx = const_cast<ClientContext&>(*c);
        auto stored = storedModulesJson(ctx);
        auto catalog = catalogJson(ctx);
        auto ptrs = cstrs(names);
        return std::make_unique<StatementsBindData>(takeStrings(
            marien_bridge_recheck(catalog.c_str(), stored.c_str(), ptrs.data(), ptrs.size(), all ? 1 : 0),
            "elpi_recheck"));
    }
    static function_set getFunctionSet() {
        function_set set;
        set.push_back(writeFunction(name, {}, [](const ClientContext* c, const TableFuncBindInput*) {
            return bind(c, {}, true);
        }));
        set.push_back(writeFunction(name, {LogicalTypeID::ANY}, [](const ClientContext* c, const TableFuncBindInput* in) {
            return bind(c, stringList(in, 0, "elpi_recheck"), false);
        }));
        return set;
    }
};

/* --- elpi_statement ------------------------------------------------------------------ */

// `CALL elpi_statement('<statement>')`: a custom statement (Marien/Statement.lean) through the bind
// of its CALL form. It is the statement interface: LadybugDB keeps its grammar to itself and prefers
// a function over a string (LadybugDB/ladybug#1519). A write statement binds exactly as its function
// does; VALIDATE rewrites into its `CALL elpi_validate(...) RETURN *`.
// @tg: implements:: [[openspec:custom-statements#Rule statements]]
// @tg: implements:: [[openspec:custom-statements#Statements equal their CALL forms]] {note: "elpi_statement dispatches to the bind of the CALL form"}
struct ElpiStatement {
    static constexpr const char* name = "ELPI_STATEMENT";
    static std::unique_ptr<TableFuncBindData> bind(const ClientContext* c, const std::string& text) {
        auto d = desugarStatement(text);
        if (!d) throw RuntimeException("elpi_statement: not a Marien statement (CREATE RULES, DROP RULES, CHECK RULES, VALIDATE, ANNOTATE)");
        auto arg = [&](size_t i) -> const std::string& { return d->args.at(i).value; };
        if (d->rows) return std::make_unique<StatementsBindData>(std::vector<std::string>{d->cypher});
        if (d->fn == "elpi_save") return ElpiSave::bind(c, arg(0), arg(1));
        if (d->fn == "elpi_drop") return ElpiDrop::bind(c, arg(0));
        if (d->fn == "elpi_recheck") return ElpiRecheck::bind(c, {}, true);
        if (d->fn == "elpi_annotate") return ElpiAnnotate::bind(c, arg(0), arg(1), arg(2));
        throw RuntimeException("elpi_statement: no CALL form " + d->fn);
    }
    static function_set getFunctionSet() {
        function_set set;
        set.push_back(writeFunction(name, {LogicalTypeID::STRING},
            [](const ClientContext* c, const TableFuncBindInput* in) {
                return bind(c, literal(in, 0, "elpi_statement"));
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

// The `format := '...'` option of elpi_signature; "" when it is not given. Any other named
// option is an error rather than ignored.
std::string signatureFormat(const TableFuncBindInput* in) {
    std::string format;
    for (auto& [key, value] : in->optionalParams) {
        if (StringUtils::getLower(key) != "format") {
            throw RuntimeException("elpi_signature: unknown option '" + key + "'; the only option is format");
        }
        if (value.isNull() || value.getDataType().getLogicalTypeID() != LogicalTypeID::STRING) {
            throw RuntimeException("elpi_signature: format must be a string literal, 'elpi' or 'json'");
        }
        format = value.getValue<std::string>();
    }
    if (in->optionalParamsLegacy.size() != in->optionalParams.size()) {
        throw RuntimeException("elpi_signature: format must be a string literal, 'elpi' or 'json'");
    }
    return format;
}

std::unique_ptr<TableFuncBindData> signatureBind(const ClientContext* c, const TableFuncBindInput* in,
    const std::string& table) {
    auto& ctx = const_cast<ClientContext&>(*c);
    auto catalog = catalogJson(ctx);
    auto format = signatureFormat(in);
    auto cells = takeStrings(marien_bridge_signature(catalog.c_str(), table.c_str(), format.c_str()),
        "elpi_signature");
    std::vector<LogicalType> types;
    types.push_back(LogicalType::STRING());
    types.push_back(LogicalType::STRING());
    types.push_back(LogicalType::STRING());
    return std::make_unique<RowsBindData>(columns(in, {"kind", "name", "text"}, std::move(types)), 3,
        std::move(cells));
}

// @tg: implements:: [[openspec:schema-encoding#Signature inspection]]
// @tg: implements:: [[openspec:offline-codegen#Schema dump]]
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

// Throws when the query was interrupted or the elpi_timeout_ms deadline (from now) has passed.
std::function<void()> interruptCheck(ClientContext& ctx) {
    auto timeout = setting(ctx, "elpi_timeout_ms");
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout);
    return [&ctx, timeout, deadline] {
        if (ctx.interrupted()) throw InterruptException{};
        if (timeout > 0 && std::chrono::steady_clock::now() >= deadline) {
            throw RuntimeException("marien: elpi_timeout_ms (" + std::to_string(timeout) + ") exceeded");
        }
    };
}

// Materialize the session's tables (consuming the session), reading the rows `filter` allows,
// and start its typed goal.
marien_run* startTyped(ClientContext& ctx, marien_session* s, const std::function<void()>& check,
    const std::string& fn, const RowFilter* filter, uint64_t maxSolutions) {
    try {
        materialize(ctx, s, check, filter);
    } catch (...) {
        marien_bridge_free_session(s);
        throw;
    }
    marien_str err{nullptr, 0};
    marien_run* r = marien_bridge_goal_start(s, setting(ctx, "elpi_fuel"), setting(ctx, "elpi_slice_steps"),
        maxSolutions, &err);
    if (!r) throw RuntimeException(fn + ": " + takeString(err));
    return r;
}

// Solve to the end in slices, checking the interrupt flag and the deadline between slices;
// `onSolution` gets each solution's items. Returns false when elpi_max_solutions stopped it.
// @tg: implements:: [[openspec:rule-execution#Fuel-sliced execution]]
bool solve(marien_run* r, const std::function<void()>& check,
    const std::function<void(std::vector<std::string>&)>& onSolution, const std::string& fn) {
    marien_str err{nullptr, 0};
    bool exhausted = true;
    while (r) {
        try {
            check();
        } catch (...) {
            marien_bridge_free_run(r);
            throw;
        }
        marien_strings bs{{nullptr, 0}, 0, nullptr};
        switch (marien_bridge_step(&r, &bs, &err)) {
        case MARIEN_STEP_SOLUTION: {
            std::vector<std::string> items;
            for (size_t i = 0; i < bs.n; i++) items.emplace_back(bs.items[i].data, bs.items[i].len);
            marien_bridge_free_strings(&bs);
            try {
                onSolution(items);
            } catch (...) {
                marien_bridge_free_run(r);
                throw;
            }
            break;
        }
        case MARIEN_STEP_PAUSED: break;
        case MARIEN_STEP_EXHAUSTED: exhausted = true; break;
        case MARIEN_STEP_STOPPED: exhausted = false; break;
        default: throw RuntimeException(fn + ": " + takeString(err));
        }
    }
    return exhausted;
}

bool isFactLimit(const std::string& msg) { return msg.find("elpi_max_facts (") != std::string::npos; }

// Solve a typed session (consumed) to the end: at full scope, on the rows `scope` allows, or
// batch by batch when its entry point has an accepted partition. Each batch gets a fresh store
// and its own fuel, fact budget and deadline; a batch whose neighbourhood exceeds elpi_max_facts
// is split, down to one anchor. Any failing batch fails the whole call. `onRow` gets each row.
// @tg: implements:: [[openspec:partitioning#Anchor partitions]]
// @tg: implements:: [[openspec:partitioning#Key partitions]]
// @tg: implements:: [[openspec:partitioning#Dynamic entry points stay whole]] {confidence: partial, note: "a session without an accepted partition runs at full scope"}
void runTyped(ClientContext& ctx, marien_session* s, const RowFilter* scope, const std::string& fn,
    const std::function<void(std::vector<std::string>&)>& onRow) {
    std::vector<std::string> part;
    uint64_t maxSolutions = 0, batch = 0;
    try {
        part = takeStrings(marien_bridge_partition(s), fn);
        maxSolutions = setting(ctx, "elpi_max_solutions");
        batch = std::max<uint64_t>(1, setting(ctx, "elpi_partition_batch"));
    } catch (...) {
        marien_bridge_free_session(s);
        throw;
    }
    uint64_t found = 0;
    auto counted = [&](std::vector<std::string>& items) {
        found++;
        onRow(items);
    };
    if (part.empty()) {
        auto check = interruptCheck(ctx);
        solve(startTyped(ctx, s, check, fn, scope, maxSolutions), check, counted, fn);
        return;
    }
    struct Base {
        marien_session* s;
        ~Base() { marien_bridge_free_session(s); }
    } base{s};
    // errors name the batch (or bucket): "<fn>: batch 3 of 5: ..."
    auto runOne = [&](marien_session* bs, const RowFilter& f, const std::string& where) {
        if (found >= maxSolutions) {
            marien_bridge_free_session(bs);
            return;
        }
        auto check = interruptCheck(ctx);
        auto label = fn + ": " + where;
        solve(startTyped(ctx, bs, check, label, &f, maxSolutions - found), check, counted, label);
    };
    auto check = interruptCheck(ctx);
    if (part.at(0) == "anchor") {
        const auto& table = part.at(1);
        uint64_t radius = std::stoull(part.at(2));
        std::vector<std::pair<std::string, bool>> steps;
        for (size_t i = 3; i + 1 < part.size(); i += 2) steps.emplace_back(part[i], part[i + 1] == "outgoing");
        auto keys = keysByOffset(ctx, table, check);
        std::vector<uint64_t> anchors;
        for (uint64_t o = 0; o < keys.size(); o++) {
            if (keys[o]) anchors.push_back(o);
        }
        size_t nb = 0;
        uint64_t* sizes = marien_bridge_partition_batches(batch, anchors.size(), &nb);
        std::vector<uint64_t> sz(sizes, sizes + nb);
        free(sizes);
        size_t index = 0;
        std::function<void(size_t, size_t)> runAnchors = [&](size_t from, size_t to) {
            std::vector<uint64_t> slice(anchors.begin() + from, anchors.begin() + to);
            auto f = neighbourhood(ctx, table, slice, radius, steps, check);
            auto* kv = marien_bridge_values_new(slice.size());
            for (auto o : slice) pushValue(kv, *keys[o]);
            try {
                runOne(marien_bridge_session_batch(s, kv), f,
                    "batch " + std::to_string(index + 1) + " of " + std::to_string(sz.size()));
            } catch (RuntimeException& e) {
                if (!isFactLimit(e.what())) throw;
                if (to - from == 1) {
                    throw RuntimeException(fn + ": the neighbourhood of " + table + " " + keys[slice[0]]->toString() +
                                           " alone exceeds elpi_max_facts; raise it with CALL elpi_max_facts=<n>");
                }
                size_t mid = from + (to - from) / 2;
                runAnchors(from, mid);
                runAnchors(mid, to);
            }
        };
        size_t at = 0;
        for (; index < sz.size(); index++) {
            runAnchors(at, at + sz[index]);
            at += sz[index];
        }
    } else {
        const auto& table = part.at(1);
        const auto& prop = part.at(2);
        auto values = columnByOffset(ctx, table, prop, check);
        uint64_t nonNull = 0;
        auto* kv = marien_bridge_values_new(values.size());
        for (auto& v : values) {
            if (v && !v->isNull()) {
                nonNull++;
                pushValue(kv, *v);
            } else {
                marien_bridge_push_null(kv);
            }
        }
        uint64_t k = std::max<uint64_t>(1, (nonNull + batch - 1) / batch);
        size_t nk = 0;
        uint64_t* bk = marien_bridge_partition_buckets(k, kv, &nk);
        std::vector<uint64_t> bucket(bk, bk + nk);
        free(bk);
        for (uint64_t b = 0; b < k; b++) {
            RowFilter f;
            f.restrictAll = true;
            auto& allowed = f.allowed[table];
            allowed.assign(bucket.size(), false);
            bool any = false;
            for (size_t o = 0; o < bucket.size(); o++) {
                if (bucket[o] == b) allowed[o] = any = true;
            }
            if (!any) continue;
            try {
                runOne(marien_bridge_session_fresh(s), f, "bucket " + std::to_string(b + 1) + " of " + std::to_string(k));
            } catch (RuntimeException& e) {
                if (!isFactLimit(e.what())) throw;
                throw RuntimeException(fn + ": a bucket of " + table + "." + prop +
                                       " exceeds elpi_max_facts; raise it, or lower elpi_partition_batch");
            }
        }
    }
}

// Run the whole query: materialize, then solve in slices, checking LadybugDB's interrupt flag
// and the elpi_timeout_ms deadline between slices.
// @tg: implements:: [[openspec:rule-execution#Untyped debug query]]
void runQuery(ClientContext& ctx, const QueryBindData& bd, QuerySharedState& st) {
    auto check = interruptCheck(ctx);
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
    try {
        st.exhausted = solve(r, check, [&](std::vector<std::string>& items) {
            if (items.empty()) st.rows.push_back({sol, false, "", ""});
            for (size_t i = 0; i + 1 < items.size(); i += 2) st.rows.push_back({sol, true, items[i], items[i + 1]});
            sol++;
        }, "elpi_query");
    } catch (...) {
        st.rows.clear();
        throw;
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

/* --- elpi_run ------------------------------------------------------------------------ */

// A column type from its prefix tokens (Marien.Encoding.Codec.Col.ltyTokens).
LogicalType parseType(const std::vector<std::string>& t, size_t& i) {
    if (i >= t.size()) throw RuntimeException("elpi_run: truncated column type");
    const auto& n = t[i++];
    if (n == "LIST") return LogicalType::LIST(parseType(t, i));
    if (n == "STRUCT") {
        auto k = std::stoul(t.at(i++));
        std::vector<StructField> fields;
        for (size_t f = 0; f < k; f++) {
            auto name = t.at(i++);
            fields.emplace_back(name, parseType(t, i));
        }
        return LogicalType::STRUCT(std::move(fields));
    }
    if (n == "INT64" || n == "SERIAL") return LogicalType::INT64();
    if (n == "INT32") return LogicalType::INT32();
    if (n == "INT16") return LogicalType::INT16();
    if (n == "INT8") return LogicalType::INT8();
    if (n == "UINT64") return LogicalType::UINT64();
    if (n == "UINT32") return LogicalType::UINT32();
    if (n == "UINT16") return LogicalType::UINT16();
    if (n == "UINT8") return LogicalType::UINT8();
    if (n == "INT128") return LogicalType::INT128();
    if (n == "UINT128") return LogicalType::UINT128();
    if (n == "DOUBLE") return LogicalType::DOUBLE();
    if (n == "FLOAT") return LogicalType::FLOAT();
    if (n == "STRING") return LogicalType::STRING();
    if (n == "BOOL") return LogicalType::BOOL();
    if (n == "DATE") return LogicalType::DATE();
    if (n == "TIMESTAMP") return LogicalType::TIMESTAMP();
    throw RuntimeException("elpi_run: unknown column type " + n);
}

template<typename T>
Value fitting(__int128 x, const std::string& col, const char* type) {
    if (x < static_cast<__int128>(std::numeric_limits<T>::min()) ||
        x > static_cast<__int128>(std::numeric_limits<T>::max())) {
        throw RuntimeException("elpi_run: column " + col + ": the result does not fit " + type);
    }
    return Value(static_cast<T>(x));
}

// A cell from its tokens (Marien.Exec.cellTokens), as a value of `type`.
Value parseCell(const LogicalType& type, const std::vector<std::string>& t, size_t& i, const std::string& col) {
    if (i >= t.size()) throw RuntimeException("elpi_run: truncated row");
    const auto& tok = t[i++];
    if (tok == "n") return Value::createNullValue(type);
    auto body = tok.substr(1);
    switch (tok[0]) {
    case 'i': {
        bool neg = !body.empty() && body[0] == '-';
        unsigned __int128 mag = 0;
        for (size_t k = neg ? 1 : 0; k < body.size(); k++) {
            auto next = mag * 10 + static_cast<unsigned>(body[k] - '0');
            if (next / 10 != mag) throw RuntimeException("elpi_run: column " + col + ": the result does not fit 128 bits");
            mag = next;
        }
        if (type.getLogicalTypeID() == LogicalTypeID::UINT128) {
            if (neg && mag != 0) throw RuntimeException("elpi_run: column " + col + ": the result does not fit UINT128");
            uint128_t u;
            u.low = static_cast<uint64_t>(mag);
            u.high = static_cast<uint64_t>(mag >> 64);
            return Value(u);
        }
        if (mag > static_cast<unsigned __int128>(std::numeric_limits<__int128>::max()) + (neg ? 1 : 0)) {
            throw RuntimeException("elpi_run: column " + col + ": the result does not fit 128 bits");
        }
        __int128 x = neg ? -static_cast<__int128>(mag - 1) - 1 : static_cast<__int128>(mag);
        switch (type.getLogicalTypeID()) {
        case LogicalTypeID::INT64: return fitting<int64_t>(x, col, "INT64");
        case LogicalTypeID::INT32: return fitting<int32_t>(x, col, "INT32");
        case LogicalTypeID::INT16: return fitting<int16_t>(x, col, "INT16");
        case LogicalTypeID::INT8: return fitting<int8_t>(x, col, "INT8");
        case LogicalTypeID::UINT64: return fitting<uint64_t>(x, col, "UINT64");
        case LogicalTypeID::UINT32: return fitting<uint32_t>(x, col, "UINT32");
        case LogicalTypeID::UINT16: return fitting<uint16_t>(x, col, "UINT16");
        case LogicalTypeID::UINT8: return fitting<uint8_t>(x, col, "UINT8");
        case LogicalTypeID::INT128: return Value(int128_t(static_cast<uint64_t>(x), static_cast<int64_t>(x >> 64)));
        case LogicalTypeID::DATE: return Value(date_t(fitting<int32_t>(x, col, "DATE").getValue<int32_t>()));
        case LogicalTypeID::TIMESTAMP: return Value(timestamp_t(fitting<int64_t>(x, col, "TIMESTAMP").getValue<int64_t>()));
        default: break;
        }
        break;
    }
    case 'f': {
        uint64_t bits = std::stoull(body);
        double d;
        std::memcpy(&d, &bits, sizeof d);
        if (type.getLogicalTypeID() == LogicalTypeID::FLOAT) return Value(static_cast<float>(d));
        return Value(d);
    }
    case 's': return Value(LogicalType::STRING(), body);
    case 'b': return Value(body == "1");
    case 'l': {
        auto n = std::stoul(body);
        std::vector<std::unique_ptr<Value>> items;
        for (size_t k = 0; k < n; k++) {
            items.push_back(std::make_unique<Value>(parseCell(ListType::getChildType(type), t, i, col)));
        }
        return Value(type.copy(), std::move(items));
    }
    case 't': {
        auto n = std::stoul(body);
        auto types = StructType::getFieldTypes(type);
        if (types.size() != n) throw RuntimeException("elpi_run: column " + col + ": wrong number of struct fields");
        std::vector<std::unique_ptr<Value>> fields;
        for (size_t k = 0; k < n; k++) fields.push_back(std::make_unique<Value>(parseCell(*types[k], t, i, col)));
        return Value(type.copy(), std::move(fields));
    }
    default: break;
    }
    throw RuntimeException("elpi_run: column " + col + ": a cell does not fit its type");
}

// Parameter names and values from a STRUCT ({in1: 7}) or MAP (map(['in1'], [7])) literal.
void readParams(const Value& v, std::vector<std::string>& names, marien_values* values) {
    auto& type = v.getDataType();
    switch (type.getLogicalTypeID()) {
    case LogicalTypeID::STRUCT: {
        auto fieldNames = StructType::getFieldNames(type);
        for (size_t k = 0; k < fieldNames.size(); k++) {
            names.push_back(fieldNames[k]);
            pushValue(values, *NestedVal::getChildVal(&v, k));
        }
        return;
    }
    case LogicalTypeID::MAP: {
        for (uint32_t k = 0; k < NestedVal::getChildrenSize(&v); k++) {
            auto* entry = NestedVal::getChildVal(&v, k);
            auto* key = NestedVal::getChildVal(entry, 0);
            if (key->isNull() || key->getDataType().getLogicalTypeID() != LogicalTypeID::STRING) {
                throw RuntimeException("elpi_run: parameter names must be strings");
            }
            names.push_back(key->getValue<std::string>());
            pushValue(values, *NestedVal::getChildVal(entry, 1));
        }
        return;
    }
    default:
        throw RuntimeException("elpi_run: parameters must be a struct or map literal such as {in1: 7}");
    }
}

struct RunBindData final : TableFuncBindData {
    std::string module, pred;
    std::vector<std::string> paramNames;
    std::vector<Value> paramValues;
    std::vector<LogicalType> types;
    std::vector<std::string> names;
    // the narrowed scope; its rows get the extra column narrowed = true
    std::optional<Value> scope;
    RunBindData(lbug::binder::expression_vector cols, std::string m, std::string p, std::vector<std::string> pn,
        std::vector<Value> pv, std::vector<LogicalType> ts, std::vector<std::string> ns, std::optional<Value> sc)
        : TableFuncBindData{std::move(cols)}, module{std::move(m)}, pred{std::move(p)}, paramNames{std::move(pn)},
          paramValues{std::move(pv)}, types{std::move(ts)}, names{std::move(ns)}, scope{std::move(sc)} {}
    std::unique_ptr<TableFuncBindData> copy() const override {
        return std::make_unique<RunBindData>(columns, module, pred, paramNames, paramValues, LogicalType::copy(types),
            names, scope);
    }
};

struct RowsSharedState final : TableFuncSharedState {
    bool computed = false;
    std::vector<std::vector<Value>> rows;
    size_t cursor = 0;
    void resetState() override {
        std::lock_guard l{mtx};
        computed = false;
        rows.clear();
        cursor = 0;
    }
};

std::shared_ptr<TableFuncSharedState> rowsInitShared(const TableFuncInitSharedStateInput&) {
    return std::make_shared<RowsSharedState>();
}

// A session for the call; the parameters are converted afresh each time.
marien_session* runSession(ClientContext& ctx, const std::string& module, const std::string& pred,
    const std::vector<std::string>& names, const std::vector<Value>& values, bool narrowed) {
    auto catalog = catalogJson(ctx);
    auto stored = storedModulesJson(ctx);
    auto* vals = marien_bridge_values_new(values.size());
    for (auto& v : values) pushValue(vals, v);
    auto ptrs = cstrs(names);
    marien_str err{nullptr, 0};
    marien_session* s = marien_bridge_run_prepare(catalog.c_str(), stored.c_str(), module.c_str(), pred.c_str(),
        ptrs.data(), vals, setting(ctx, "elpi_max_facts"), setting(ctx, "elpi_cache_size"), narrowed ? 1 : 0, &err);
    if (!s) throw RuntimeException("elpi_run: " + takeString(err));
    return s;
}

// Output columns are fixed here, from the predicate's signature, before anything is solved.
// @tg: implements:: [[openspec:rule-execution#Typed entry points]]
std::unique_ptr<TableFuncBindData> runBind(const ClientContext* c, const TableFuncBindInput* in, bool withParams,
    bool withScope) {
    auto& ctx = const_cast<ClientContext&>(*c);
    auto module = literal(in, 0, "elpi_run");
    auto pred = literal(in, 1, "elpi_run");
    std::vector<std::string> paramNames;
    std::vector<Value> paramValues;
    std::optional<Value> scope;
    if (withScope) scope = in->getValue(3);
    // NULL parameters: none (a call with a scope and no parameters)
    if (withParams && !in->getValue(2).isNull()) {
        auto p = in->getValue(2);
        auto* scratch = marien_bridge_values_new(0);
        try {
            readParams(p, paramNames, scratch);
        } catch (...) {
            marien_bridge_free_values(scratch);
            throw;
        }
        marien_bridge_free_values(scratch);
        if (p.getDataType().getLogicalTypeID() == LogicalTypeID::STRUCT) {
            for (uint32_t k = 0; k < NestedVal::getChildrenSize(&p); k++) paramValues.push_back(*NestedVal::getChildVal(&p, k));
        } else {
            for (uint32_t k = 0; k < NestedVal::getChildrenSize(&p); k++) {
                paramValues.push_back(*NestedVal::getChildVal(NestedVal::getChildVal(&p, k), 1));
            }
        }
    }
    marien_session* s = runSession(ctx, module, pred, paramNames, paramValues, scope.has_value());
    std::vector<std::string> names;
    std::vector<LogicalType> types;
    for (size_t i = 0, n = marien_bridge_column_count(s); i < n; i++) {
        auto toks = takeStrings(marien_bridge_column(s, i), "elpi_run");
        size_t k = 1;
        names.push_back(toks.at(0));
        types.push_back(parseType(toks, k));
    }
    marien_bridge_free_session(s);
    auto colNames = names;
    auto colTypes = LogicalType::copy(types);
    if (scope) {
        colNames.push_back("narrowed");
        colTypes.push_back(LogicalType::BOOL());
    }
    auto cols = columns(in, colNames, std::move(colTypes));
    return std::make_unique<RunBindData>(std::move(cols), module, pred, std::move(paramNames), std::move(paramValues),
        std::move(types), std::move(names), std::move(scope));
}

offset_t runFunc(const TableFuncInput& input, TableFuncOutput& output) {
    auto& st = *input.sharedState->ptrCast<RowsSharedState>();
    auto& bd = *input.bindData->constPtrCast<RunBindData>();
    std::lock_guard l{st.mtx};
    if (!st.computed) {
        st.computed = true;
        auto& ctx = *input.context->clientContext;
        try {
            std::optional<RowFilter> filter;
            if (bd.scope) filter = scopeFilter(ctx, *bd.scope, interruptCheck(ctx), "elpi_run");
            marien_session* s = runSession(ctx, bd.module, bd.pred, bd.paramNames, bd.paramValues, bd.scope.has_value());
            runTyped(ctx, s, filter ? &*filter : nullptr, "elpi_run", [&](std::vector<std::string>& cells) {
                std::vector<Value> row;
                size_t k = 0;
                for (size_t c = 0; c < bd.types.size(); c++) row.push_back(parseCell(bd.types[c], cells, k, bd.names[c]));
                if (bd.scope) row.emplace_back(true);
                st.rows.push_back(std::move(row));
            });
        } catch (...) {
            st.rows.clear();
            throw;
        }
    }
    auto n = std::min<size_t>(DEFAULT_VECTOR_CAPACITY, st.rows.size() - st.cursor);
    for (size_t i = 0; i < n; i++) {
        auto& row = st.rows[st.cursor + i];
        for (size_t c = 0; c < row.size(); c++) output.dataChunk.getValueVectorMutable(c).copyFromValue(i, row[c]);
    }
    st.cursor += n;
    return n;
}

struct ElpiRun {
    static constexpr const char* name = "ELPI_RUN";
    static std::unique_ptr<TableFunction> make(std::vector<LogicalTypeID> args, table_func_bind_t bind) {
        auto f = std::make_unique<TableFunction>(name, std::move(args));
        f->bindFunc = std::move(bind);
        f->tableFunc = runFunc;
        f->initSharedStateFunc = rowsInitShared;
        f->initLocalStateFunc = TableFunction::initEmptyLocalState;
        f->canParallelFunc = [] { return false; };
        return f;
    }
    static function_set getFunctionSet() {
        function_set set;
        set.push_back(make({LogicalTypeID::STRING, LogicalTypeID::STRING},
            [](const ClientContext* c, const TableFuncBindInput* in) { return runBind(c, in, false, false); }));
        set.push_back(make({LogicalTypeID::STRING, LogicalTypeID::STRING, LogicalTypeID::ANY},
            [](const ClientContext* c, const TableFuncBindInput* in) { return runBind(c, in, true, false); }));
        set.push_back(make({LogicalTypeID::STRING, LogicalTypeID::STRING, LogicalTypeID::ANY, LogicalTypeID::ANY},
            [](const ClientContext* c, const TableFuncBindInput* in) { return runBind(c, in, true, true); }));
        return set;
    }
};

/* --- elpi_validate ------------------------------------------------------------------- */

struct ValidateBindData final : TableFuncBindData {
    std::vector<std::string> modules;
    bool all;
    std::string minSeverity;
    std::optional<Value> scope;
    ValidateBindData(lbug::binder::expression_vector cols, std::vector<std::string> m, bool a, std::string s,
        std::optional<Value> sc)
        : TableFuncBindData{std::move(cols)}, modules{std::move(m)}, all{a}, minSeverity{std::move(s)},
          scope{std::move(sc)} {}
    std::unique_ptr<TableFuncBindData> copy() const override { return std::make_unique<ValidateBindData>(*this); }
};

std::unique_ptr<TableFuncBindData> validateBind(const TableFuncBindInput* in, std::vector<std::string> modules,
    bool all, std::string minSeverity, std::optional<Value> scope = std::nullopt) {
    std::vector<LogicalType> types;
    types.push_back(LogicalType::STRING());
    types.push_back(LogicalType::INT64());
    for (int i = 0; i < 5; i++) types.push_back(LogicalType::STRING());
    std::vector<std::string> names{"module", "version", "severity", "code", "message", "subject_label", "subject_pk"};
    if (scope) {
        names.push_back("narrowed");
        types.push_back(LogicalType::BOOL());
    }
    return std::make_unique<ValidateBindData>(columns(in, std::move(names), std::move(types)), std::move(modules), all,
        std::move(minSeverity), std::move(scope));
}

// Every module runs to the end before any row is returned: a module that fails fails the call,
// so a report is never partial.
// @tg: implements:: [[openspec:validation#Uniform validation report]]
offset_t validateFunc(const TableFuncInput& input, TableFuncOutput& output) {
    auto& st = *input.sharedState->ptrCast<RowsSharedState>();
    auto& bd = *input.bindData->constPtrCast<ValidateBindData>();
    std::lock_guard l{st.mtx};
    if (!st.computed) {
        st.computed = true;
        auto& ctx = *input.context->clientContext;
        auto check = interruptCheck(ctx);
        auto catalog = catalogJson(ctx);
        auto stored = storedModulesJson(ctx);
        auto ptrs = cstrs(bd.modules);
        auto order = takeStrings(marien_bridge_validate_order(stored.c_str(), ptrs.data(), ptrs.size(), bd.all ? 1 : 0),
            "elpi_validate");
        try {
            std::optional<RowFilter> filter;
            if (bd.scope) filter = scopeFilter(ctx, *bd.scope, check, "elpi_validate");
            for (auto& m : order) {
                auto fn = "elpi_validate: module " + m;
                marien_str err{nullptr, 0};
                marien_session* s = marien_bridge_validate_prepare(catalog.c_str(), stored.c_str(), m.c_str(),
                    bd.minSeverity.c_str(), setting(ctx, "elpi_max_facts"), setting(ctx, "elpi_cache_size"),
                    bd.scope ? 1 : 0, &err);
                if (!s) throw RuntimeException(fn + ": " + takeString(err));
                try {
                    runTyped(ctx, s, filter ? &*filter : nullptr, fn, [&](std::vector<std::string>& row) {
                        std::vector<Value> out;
                        out.emplace_back(LogicalType::STRING(), row.at(0));
                        out.emplace_back(static_cast<int64_t>(std::stoll(row.at(1))));
                        for (size_t c = 2; c < 7; c++) out.emplace_back(LogicalType::STRING(), row.at(c));
                        if (bd.scope) out.emplace_back(true);
                        st.rows.push_back(std::move(out));
                    });
                } catch (RuntimeException& e) {
                    // a materialization error does not carry the module name yet
                    std::string msg = e.what();
                    if (msg.find(fn) == std::string::npos) throw RuntimeException(fn + ": " + msg);
                    throw;
                }
            }
        } catch (...) {
            st.rows.clear();
            throw;
        }
    }
    auto n = std::min<size_t>(DEFAULT_VECTOR_CAPACITY, st.rows.size() - st.cursor);
    for (size_t i = 0; i < n; i++) {
        auto& row = st.rows[st.cursor + i];
        for (size_t c = 0; c < row.size(); c++) output.dataChunk.getValueVectorMutable(c).copyFromValue(i, row[c]);
    }
    st.cursor += n;
    return n;
}

struct ElpiValidate {
    static constexpr const char* name = "ELPI_VALIDATE";
    static std::unique_ptr<TableFunction> make(std::vector<LogicalTypeID> args, table_func_bind_t bind) {
        auto f = std::make_unique<TableFunction>(name, std::move(args));
        f->bindFunc = std::move(bind);
        f->tableFunc = validateFunc;
        f->initSharedStateFunc = rowsInitShared;
        f->initLocalStateFunc = TableFunction::initEmptyLocalState;
        f->canParallelFunc = [] { return false; };
        return f;
    }
    static function_set getFunctionSet() {
        function_set set;
        set.push_back(make({}, [](const ClientContext*, const TableFuncBindInput* in) {
            return validateBind(in, {}, true, "info");
        }));
        set.push_back(make({LogicalTypeID::ANY}, [](const ClientContext*, const TableFuncBindInput* in) {
            return validateBind(in, stringList(in, 0, "elpi_validate"), false, "info");
        }));
        set.push_back(make({LogicalTypeID::ANY, LogicalTypeID::STRING}, [](const ClientContext*, const TableFuncBindInput* in) {
            return validateBind(in, stringList(in, 0, "elpi_validate"), false, literal(in, 1, "elpi_validate"));
        }));
        set.push_back(make({LogicalTypeID::ANY, LogicalTypeID::STRING, LogicalTypeID::ANY},
            [](const ClientContext*, const TableFuncBindInput* in) {
                return validateBind(in, stringList(in, 0, "elpi_validate"), false, literal(in, 1, "elpi_validate"),
                    in->getValue(2));
            }));
        return set;
    }
};

/* --- Version check -------------------------------------------------------------------- */

// An extension only works in the LadybugDB release whose headers it was compiled against. The
// release version is read through liblbug's Version::getVersion when the host exports it; the
// CLI does not, and then the host's storage version must be the pinned release's. Symbols are
// looked up at run time so that a host without them can still load the library and refuse it.
void checkVersion() {
    const std::string pinned = MARIEN_LADYBUG_VERSION;
    auto refuse = [&](const std::string& running) {
        throw RuntimeException("marien: this build is for LadybugDB " + pinned +
                               " and cannot be loaded into LadybugDB " + running);
    };
    using version_fn = const char* (*)();
    if (auto f = reinterpret_cast<version_fn>(dlsym(RTLD_DEFAULT, "_ZN4lbug4main7Version10getVersionEv"))) {
        std::string running = f();
        if (running != pinned) refuse(running);
        return;
    }
    using storage_fn = uint64_t (*)();
    auto g = reinterpret_cast<storage_fn>(dlsym(RTLD_DEFAULT, "_ZN4lbug7storage18StorageVersionInfo17getStorageVersionEv"));
    auto known = lbug::storage::StorageVersionInfo::getStorageVersionInfo();
    auto it = known.find(pinned);
    if (!g || it == known.end()) {
        throw RuntimeException("marien: cannot tell which LadybugDB version this is; this build is for LadybugDB " + pinned);
    }
    auto running = g();
    if (running != it->second) {
        std::string names;
        for (auto& [v, sv] : known) {
            if (sv == running) names += (names.empty() ? "" : " or ") + v;
        }
        refuse(names.empty() ? "with storage version " + std::to_string(running) : names);
    }
}

} // namespace
} // namespace marien

extern "C" {

// @tg: implements:: [[openspec:extension-runtime#Extension init starts the runtime]]
// @tg: implements:: [[openspec:distribution#LadybugDB version check]]
__attribute__((visibility("default"))) void init(ClientContext* context) {
    marien::checkVersion();
    if (const char* err = marien_bridge_init()) {
        throw RuntimeException(std::string("marien: Lean initialization failed: ") + err);
    }
    auto& db = *context->getDatabase();
    for (auto& o : marien::options) db.addExtensionOption(o.name, LogicalTypeID::INT64, Value(o.def));
    using lbug::extension::ExtensionUtils;
    ExtensionUtils::addStandaloneTableFunc<marien::ElpiInit>(db);
    ExtensionUtils::addStandaloneTableFunc<marien::ElpiSave>(db);
    ExtensionUtils::addStandaloneTableFunc<marien::ElpiDrop>(db);
    ExtensionUtils::addStandaloneTableFunc<marien::ElpiAnnotate>(db);
    ExtensionUtils::addStandaloneTableFunc<marien::ElpiImport>(db);
    ExtensionUtils::addStandaloneTableFunc<marien::ElpiRecheck>(db);
    ExtensionUtils::addTableFunc<marien::ElpiExport>(db);
    ExtensionUtils::addTableFunc<marien::ElpiSignature>(db);
    ExtensionUtils::addTableFunc<marien::ElpiQuery>(db);
    ExtensionUtils::addTableFunc<marien::ElpiRun>(db);
    ExtensionUtils::addTableFunc<marien::ElpiValidate>(db);
    ExtensionUtils::addStandaloneTableFunc<marien::ElpiStatement>(db);
}

__attribute__((visibility("default"))) const char* name() {
    return "MARIEN";
}
}
