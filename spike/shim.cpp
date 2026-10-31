// Extension shim of the spike: LadybugDB's init/name entry points and one table function,
// LEAN_PING(), returning the answer LeanElpi computes and how often the runtime started.
#include <cstdlib>
#include <string>

#include "binder/binder.h"
#include "common/exception/runtime.h"
#include "extension/extension.h"
#include "function/table/bind_data.h"
#include "function/table/bind_input.h"
#include "function/table/simple_table_function.h"
#include "main/client_context.h"
#include "main/database.h"

#include "bridge.h"

using namespace lbug::common;
using namespace lbug::function;
using namespace lbug::main;

namespace {

offset_t pingFunc(const TableFuncMorsel&, const TableFuncInput&, DataChunk& output) {
    char* answer = marien_bridge_ping();
    auto pos = output.state->getSelVector()[0];
    output.getValueVectorMutable(0).setValue(pos, std::string(answer));
    output.getValueVectorMutable(1).setValue(pos, (int64_t)marien_bridge_init_runs());
    std::free(answer);
    return 1;
}

std::unique_ptr<TableFuncBindData> bindFunc(const ClientContext*, const TableFuncBindInput* input) {
    std::vector<std::string> names{"answer", "runtime_inits"};
    std::vector<LogicalType> types;
    types.emplace_back(LogicalType::STRING());
    types.emplace_back(LogicalType::INT64());
    names = TableFunction::extractYieldVariables(names, input->yieldVariables);
    auto columns = input->binder->createVariables(names, types);
    return std::make_unique<TableFuncBindData>(std::move(columns), 1);
}

struct LeanPingFunction {
    static constexpr const char* name = "LEAN_PING";
    static function_set getFunctionSet() {
        function_set set;
        auto f = std::make_unique<TableFunction>(name, std::vector<LogicalTypeID>{});
        f->tableFunc = SimpleTableFunc::getTableFunc(pingFunc);
        f->bindFunc = bindFunc;
        f->initSharedStateFunc = SimpleTableFunc::initSharedState;
        f->initLocalStateFunc = TableFunction::initEmptyLocalState;
        set.push_back(std::move(f));
        return set;
    }
};

} // namespace

extern "C" {

// @tg: implements:: [[openspec:extension-runtime#Extension init starts the runtime]]
__attribute__((visibility("default"))) void init(ClientContext* context) {
    if (const char* err = marien_bridge_init()) {
        throw RuntimeException(std::string("marien: Lean initialization failed: ") + err);
    }
    lbug::extension::ExtensionUtils::addTableFunc<LeanPingFunction>(*context->getDatabase());
}

__attribute__((visibility("default"))) const char* name() {
    return "MARIEN_SPIKE";
}
}
