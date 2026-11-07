// Custom statements: CREATE [OR REPLACE] RULES, DROP RULES, CHECK RULES, VALIDATE and ANNOTATE,
// run as `CALL elpi_statement('<statement>')` (extension.cpp).
//
// The statement grammar and its desugaring are Lean (Marien/Statement.lean); this file only moves
// the text in and the CALL form out. elpi_statement then binds exactly as that CALL form does.
//
// There is no statement transformer: LadybugDB parses every statement with its own grammar and
// hands extension transformers only CREATE USER and CREATE ROLE, and its maintainers prefer a
// function taking the statement as a string over extensions adding grammar
// (LadybugDB/ladybug#1519; decision "Statements are a string function").

#include <string>
#include <vector>

#include "common/exception/runtime.h"
#include "shim.h"

namespace marien {

using namespace lbug::common;

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

} // namespace marien
