// Structural facts: `in_cycle.<rel>` from strongly connected components and `component.<rel>`
// from weakly connected components of a rel table over one node table. They are computed from
// the edges read in the caller's transaction on every call that reaches them, never stored, so
// they are never stale (decision "Structural facts from Marien's own graph routines"). The
// official algo extension is not used: its macOS package cannot load, and its routines are not
// callable from another extension without a nested query.
#include <algorithm>
#include <cstdint>
#include <string>
#include <vector>

#include "common/exception/runtime.h"
#include "common/types/value/value.h"

#include "shim.h"

// @lat: [[components#Structural facts]]

using namespace lbug::common;

namespace marien {
namespace {

// The strongly connected component of each node (Tarjan, without recursion).
std::vector<uint32_t> scc(size_t n, const std::vector<std::vector<uint32_t>>& adj) {
    const uint32_t none = UINT32_MAX;
    std::vector<uint32_t> index(n, none), low(n, 0), comp(n, none), stack;
    std::vector<bool> onStack(n, false);
    std::vector<std::pair<uint32_t, size_t>> calls; // node, next edge
    uint32_t next = 0, ncomp = 0;
    for (uint32_t s = 0; s < n; s++) {
        if (index[s] != none) continue;
        calls.emplace_back(s, 0);
        while (!calls.empty()) {
            uint32_t v = calls.back().first;
            if (index[v] == none) {
                index[v] = low[v] = next++;
                stack.push_back(v);
                onStack[v] = true;
            }
            size_t& pos = calls.back().second;
            if (pos < adj[v].size()) {
                uint32_t w = adj[v][pos++];
                if (index[w] == none) {
                    calls.emplace_back(w, 0);
                } else if (onStack[w]) {
                    low[v] = std::min(low[v], index[w]);
                }
                continue;
            }
            if (low[v] == index[v]) {
                uint32_t w;
                do {
                    w = stack.back();
                    stack.pop_back();
                    onStack[w] = false;
                    comp[w] = ncomp;
                } while (w != v);
                ncomp++;
            }
            calls.pop_back();
            if (!calls.empty()) {
                uint32_t u = calls.back().first;
                low[u] = std::min(low[u], low[v]);
            }
        }
    }
    return comp;
}

uint32_t find(std::vector<uint32_t>& parent, uint32_t x) {
    while (parent[x] != x) {
        parent[x] = parent[parent[x]];
        x = parent[x];
    }
    return x;
}

} // namespace

// @tg: implements:: [[openspec:partitioning#Structural facts]]
void scanStructure(lbug::main::ClientContext& ctx, marien_session*& session, size_t scan,
    const std::vector<std::string>& desc, const std::function<void()>& checkInterrupt, const RowFilter* filter) {
    bool cycle = desc.at(0) == "cycle";
    const auto& rel = desc.at(1);
    const auto& node = desc.at(2);
    auto keys = keysByOffset(ctx, node, checkInterrupt);
    auto edges = edgeOffsets(ctx, rel, checkInterrupt);
    size_t n = keys.size();
    std::vector<bool> keep(n, false);
    std::vector<int64_t> ids(n, 0);
    if (cycle) {
        // a node is on a cycle when its component has another node, or it has a self-edge
        std::vector<std::vector<uint32_t>> adj(n);
        std::vector<bool> selfEdge(n, false);
        for (auto [a, b] : edges) {
            adj[a].push_back(static_cast<uint32_t>(b));
            if (a == b) selfEdge[a] = true;
        }
        checkInterrupt();
        auto comp = scc(n, adj);
        std::vector<uint32_t> size(n, 0);
        for (size_t o = 0; o < n; o++) {
            if (keys[o]) size[comp[o]]++;
        }
        for (size_t o = 0; o < n; o++) keep[o] = keys[o] && (size[comp[o]] > 1 || selfEdge[o]);
    } else {
        // components are numbered 0, 1, ... in the order of their first row
        std::vector<uint32_t> parent(n);
        for (uint32_t o = 0; o < n; o++) parent[o] = o;
        for (auto [a, b] : edges) {
            auto ra = find(parent, static_cast<uint32_t>(a));
            auto rb = find(parent, static_cast<uint32_t>(b));
            if (ra != rb) parent[std::max(ra, rb)] = std::min(ra, rb);
        }
        checkInterrupt();
        std::vector<int64_t> number(n, -1);
        int64_t count = 0;
        for (uint32_t o = 0; o < n; o++) {
            if (!keys[o]) continue;
            auto r = find(parent, o);
            if (number[r] < 0) number[r] = count++;
            ids[o] = number[r];
            keep[o] = true;
        }
    }
    bool restricted = filter && filter->restricted(node);
    std::vector<size_t> rows;
    for (size_t o = 0; o < n; o++) {
        if (keep[o] && (!restricted || filter->allows(node, o))) rows.push_back(o);
    }
    const size_t chunk = 2048;
    for (size_t start = 0; start < rows.size(); start += chunk) {
        size_t end = std::min(rows.size(), start + chunk);
        std::vector<marien_values*> cols{marien_bridge_values_new(end - start)};
        if (!cycle) cols.push_back(marien_bridge_values_new(end - start));
        for (size_t i = start; i < end; i++) {
            pushValue(cols[0], *keys[rows[i]]);
            if (!cycle) marien_bridge_push_int64(cols[1], ids[rows[i]]);
        }
        addColumns(session, scan, cols);
    }
}

} // namespace marien
