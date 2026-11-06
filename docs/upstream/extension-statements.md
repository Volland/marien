Feature: let extensions parse their own statements

### API

C++ (the extension API)

### Description

**Problem.** `TransformerExtension` exists, but LadybugDB parses every statement with its own ANTLR grammar first and calls the extension transformers only for `CREATE USER` and `CREATE ROLE` (`Transformer::transformExtensionStatement`, called from `src/parser/transformer.cpp:54-56` at v0.22.1 and on `main`). Any other syntax an extension wants to add is a parser error before an extension sees it, so the binder, planner and mapper extension hooks only ever receive `CREATE USER`/`CREATE ROLE`.

Our case is [Marien](https://github.com/Volland/marien), an out-of-tree extension that stores rule modules in the database. Its interface is a set of table functions (`CALL elpi_save('org_rules', '<source>')`), and we would like statement syntax over them:

```
CREATE RULES org_rules AS $$
  violation error "no-manager" (subj_person P) :- person P, not (reports_to P _ _).
$$
VALIDATE org_rules MIN SEVERITY warning
```

The rule source is a program in another language, with quotes and backslashes of its own, so a dollar-quoted body that is taken byte for byte matters: inside a Cypher string literal every source has to be escaped. The statement parser and the desugaring to the `CALL` form are written and tested in Marien already, and a transformer is registered; what is missing is a way for the text to reach it.

**Proposal.** Offer extension transformers the statement text when LadybugDB's grammar does not accept it:

```cpp
class LBUG_API TransformerExtension {
public:
    virtual std::unique_ptr<parser::Statement> transform(antlr4::ParserRuleContext* context) = 0;
    // New: called with the text of a query LadybugDB's grammar rejected, before the parser error is
    // reported. Returning statements replaces the parse; returning none keeps the original error.
    virtual std::vector<std::unique_ptr<parser::Statement>> transformText(std::string_view query) {
        return {};
    }
};
```

`Parser::parseQuery` (`src/parser/parser.cpp`) would try it when the ANTLR parse fails, so the existing grammar keeps priority and queries that parse today are unaffected. A text-level hook rather than a grammar rule is deliberate: a dollar-quoted body cannot be lexed as Cypher tokens.

**Related: building parse trees from an extension.** A transformer has to return LadybugDB parse nodes, but their vtables are not exported from liblbug or the CLI. An extension that `new`s a `ParsedFunctionExpression` fails to load with `symbol not found ... __ZTVN4lbug6parser24ParsedFunctionExpressionE`. We work around it by parsing `CALL <fn>()` with the exported `Parser::parseQuery` and copying the node through its virtual `copy()`. Marking the parse node classes `LBUG_API` (`ParsedExpression` and its subclasses, `StandaloneCallFunction`, `RegularQuery` and the clauses) would make extension transformers straightforward.

We would be glad to send a pull request for either part if the shape is acceptable.

---

Filed as https://github.com/LadybugDB/ladybug/issues/1519 on 2026-11-06 (task 4.5 of `openspec/changes/add-ecosystem`).
