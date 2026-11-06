// Custom statements: CREATE [OR REPLACE] RULES, DROP RULES, CHECK RULES, VALIDATE and ANNOTATE.
//
// The statement grammar and its desugaring are Lean (Marien/Statement.lean); this file only moves
// text in and a parse tree out. The transformer builds the parse tree LadybugDB's own parser
// builds for the statement's CALL form, with the arguments as literal values, so LadybugDB's
// binder, planner and mapper run the CALL unchanged: the same columns, rows, errors and stored
// state, and the rule source reaches elpi_save as the bytes between its delimiters, never
// re-escaped. Write statements become a StandaloneCallFunction (rewritten like a typed CALL);
// VALIDATE becomes `CALL elpi_validate(...) RETURN *`.
//
// LadybugDB 0.22.1 hands extension transformers only CREATE USER and CREATE ROLE (constraint
// "Only CREATE USER and CREATE ROLE reach extension parsers"); the transformer is registered so
// statements work once the grammar routes them, and returns nothing for any other text, leaving
// it to LadybugDB or other extensions. Until then `CALL elpi_statement('<statement>')` runs a
// statement through the same desugaring (extension.cpp).

#include <memory>
#include <string>
#include <vector>

#include "ParserRuleContext.h"
#include "Token.h"
#include "CharStream.h"
#include "common/exception/runtime.h"
#include "common/types/value/value.h"
#include "extension/transformer_extension.h"
#include "main/database.h"
#include "parser/expression/parsed_expression.h"
#include "parser/expression/parsed_function_expression.h"
#include "parser/expression/parsed_literal_expression.h"
#include "parser/query/reading_clause/in_query_call_clause.h"
#include "parser/query/regular_query.h"
#include "parser/query/return_with_clause/projection_body.h"
#include "parser/query/return_with_clause/return_clause.h"
#include "parser/query/single_query.h"
#include "parser/parser.h"
#include "parser/standalone_call_function.h"
#include "shim.h"

namespace marien {

using namespace lbug::common;
using namespace lbug::parser;

std::optional<Desugared> desugarStatement(const std::string& text) {
    auto s = marien_bridge_statement(text.data(), text.size());
    if (s.error.data) {
        std::string e(s.error.data, s.error.len);
        marien_bridge_free_strings(&s);
        throw RuntimeException(e);
    }
    std::vector<std::string> cells;
    for (size_t i = 0; i < s.n; i++) cells.emplace_back(s.items[i].data, s.items[i].len);
    marien_bridge_free_strings(&s);
    if (cells.empty() || cells[0] == "none") return std::nullopt;
    Desugared d{cells.at(1), cells.at(2) == "1", cells.at(3), {}};
    for (size_t i = 4; i < cells.size();) {
        Desugared::Arg a;
        if (cells[i] == "s") {
            a.value = cells.at(i + 1);
            i += 2;
        } else {
            a.list = true;
            size_t n = std::stoul(cells.at(i + 1));
            for (size_t j = 0; j < n; j++) a.items.push_back(cells.at(i + 2 + j));
            i += 2 + n;
        }
        d.args.push_back(std::move(a));
    }
    return d;
}

namespace {

std::unique_ptr<ParsedExpression> literalArg(const Desugared::Arg& a) {
    if (!a.list) {
        return std::make_unique<ParsedLiteralExpression>(Value(LogicalType::STRING(), a.value), "'...'");
    }
    std::vector<std::unique_ptr<Value>> items;
    for (auto& x : a.items) items.push_back(std::make_unique<Value>(LogicalType::STRING(), x));
    return std::make_unique<ParsedLiteralExpression>(
        Value(LogicalType::LIST(LogicalType::STRING()), std::move(items)), "[...]");
}

// A function expression for `fn` with no arguments. LadybugDB does not export the vtable of
// ParsedFunctionExpression, so the shim cannot construct one; it parses `CALL fn()` with
// LadybugDB's parser (exported) and copies the node through its virtual copy().
std::unique_ptr<ParsedExpression> functionExpression(const std::string& fn) {
    auto parsed = Parser::parseQuery("CALL " + fn + "()", {});
    if (parsed.size() != 1 || parsed[0]->getStatementType() != StatementType::STANDALONE_CALL_FUNCTION) {
        throw RuntimeException("marien: cannot build the CALL form of " + fn);
    }
    return static_cast<const StandaloneCallFunction&>(*parsed[0]).getFunctionExpression()->copy();
}

// The parse tree of a statement's CALL form.
// @tg: implements:: [[openspec:custom-statements#Statements equal their CALL forms]] {note: "the CALL form's parse tree, built from the Lean desugaring"}
std::unique_ptr<Statement> callStatement(const Desugared& d) {
    auto fn = functionExpression(d.fn);
    for (auto& a : d.args) static_cast<ParsedFunctionExpression*>(fn.get())->addChild(literalArg(a));
    if (!d.rows) return std::make_unique<StandaloneCallFunction>(std::move(fn));
    SingleQuery q;
    q.addReadingClause(std::make_unique<InQueryCallClause>(std::move(fn), std::vector<YieldVariable>{}));
    std::vector<std::unique_ptr<ParsedExpression>> star;
    star.push_back(std::make_unique<ParsedExpression>(ExpressionType::STAR, "*"));
    q.setReturnClause(ReturnClause(ProjectionBody(false, std::move(star))));
    return std::make_unique<RegularQuery>(std::move(q));
}

// The text a parse tree covers, as written (comments and whitespace included).
std::string sourceText(antlr4::ParserRuleContext* ctx) {
    auto* start = ctx->getStart();
    auto* stop = ctx->getStop();
    if (!start || !stop || !start->getInputStream()) return ctx->getText();
    return start->getInputStream()->getText(antlr4::misc::Interval(start->getStartIndex(), stop->getStopIndex()));
}

// @tg: implements:: [[openspec:custom-statements#Rule statements]] {confidence: partial, note: "registered; LadybugDB 0.22.1 routes no new syntax to extensions"}
class StatementTransformer final : public lbug::extension::TransformerExtension {
public:
    std::unique_ptr<Statement> transform(antlr4::ParserRuleContext* context) override {
        if (!context) return nullptr;
        auto d = desugarStatement(sourceText(context));
        if (!d) return nullptr;
        return callStatement(*d);
    }
};

} // namespace

void registerStatements(lbug::main::Database& db) {
    db.addTransformerExtension(std::make_unique<StatementTransformer>());
}

} // namespace marien
