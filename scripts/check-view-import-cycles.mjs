// Static value imports must be acyclic. Type-only and deferred imports do not
// participate in module initialization and are deliberately excluded.
import ts from "typescript";
import { readdirSync, readFileSync, realpathSync } from "node:fs";
import { join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export function staticViewImportCycles(directory) {
  const root = realpathSync(directory);
  const graph = new Map();
  function walk(dir) {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const path = join(dir, entry.name);
      if (entry.isDirectory()) {
        if (!["node_modules", ".turbo", "dist"].includes(entry.name)) walk(path);
      } else if (/\.[cm]?tsx?$/.test(path) && !/\.(test|spec|d)\.[cm]?tsx?$/.test(path)) {
        graph.set(path, []);
      }
    }
  }
  walk(root);
  const options = { moduleResolution: ts.ModuleResolutionKind.Bundler, module: ts.ModuleKind.ESNext };
  const cache = ts.createModuleResolutionCache(root, (path) => path, options);
  for (const [path, edges] of graph) {
    const source = ts.createSourceFile(path, readFileSync(path, "utf8"), ts.ScriptTarget.Latest, true);
    for (const node of source.statements) {
      if (!(ts.isImportDeclaration(node) || ts.isExportDeclaration(node)) || !node.moduleSpecifier) continue;
      if (node.isTypeOnly || node.importClause?.isTypeOnly) continue;
      const bindings = node.importClause?.namedBindings;
      if (!node.importClause?.name && bindings && ts.isNamedImports(bindings) && bindings.elements.length && bindings.elements.every((e) => e.isTypeOnly)) continue;
      if (node.exportClause && ts.isNamedExports(node.exportClause) && node.exportClause.elements.length && node.exportClause.elements.every((e) => e.isTypeOnly)) continue;
      // Package self-imports and .js specifiers also create initialization edges.
      const spec = node.moduleSpecifier.text;
      const resolved = ts.resolveModuleName(spec, path, options, ts.sys, cache).resolvedModule;
      if (!resolved) continue; // The dependency-resolution gate owns unresolved imports.
      const target = realpathSync(resolved.resolvedFileName);
      if (graph.has(target)) edges.push(target);
    }
  }

  const visited = new Set(), active = new Set(), stack = [];
  const cycles = [];
  function visit(path) {
    if (active.has(path)) {
      cycles.push([...stack.slice(stack.indexOf(path)), path].map((p) => relative(root, p)));
      return;
    }
    if (visited.has(path)) return;
    visited.add(path); active.add(path); stack.push(path);
    for (const target of graph.get(path)) visit(target);
    stack.pop(); active.delete(path);
  }
  for (const path of graph.keys()) visit(path);
  return cycles;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const cycles = staticViewImportCycles(resolve(import.meta.dirname, "../packages/views"));
  for (const cycle of cycles) console.error("Static views import cycle:", cycle.join(" -> "));
  if (cycles.length) process.exitCode = 1;
  else console.log("Static views value-import graph is acyclic.");
}
