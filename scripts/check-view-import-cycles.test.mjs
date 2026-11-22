import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";
import { staticViewImportCycles } from "./check-view-import-cycles.mjs";

function fixture(t, files) {
  const root = mkdtempSync(join(tmpdir(), "multica-import-graph-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  for (const [name, content] of Object.entries(files)) {
    const path = join(root, name);
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, content);
  }
  return root;
}

test("detects value cycles through directory barrels and re-exports", (t) => {
  const root = fixture(t, {
    "a.ts": 'import { b } from "./nested"; export const a = b;',
    "nested/index.ts": 'export { b } from "./b";',
    "nested/b.ts": 'import { a } from "../a"; export const b = a;',
  });
  assert.deepEqual(staticViewImportCycles(root), [["a.ts", "nested/index.ts", "nested/b.ts", "a.ts"]]);
});

test("detects package self-import and .js specifier cycles", (t) => {
  const root = fixture(t, {
    "package.json": JSON.stringify({ name: "@multica/views", exports: { "./b": "./b.ts" } }),
    "a.ts": 'import { b } from "@multica/views/b"; export const a = b;',
    "b.ts": 'import { a } from "./a.js"; export const b = a;',
  });
  assert.deepEqual(staticViewImportCycles(root), [["a.ts", "b.ts", "a.ts"]]);
});

test("ignores type-only and deferred edges, declarations, tests and build output", (t) => {
  const root = fixture(t, {
    "a.ts": 'import type { B } from "./b"; export { type B } from "./b"; export const a = () => import("./b");',
    "b.ts": 'import { type A } from "./a"; export type { A } from "./a";',
    "c.ts": 'import "./d";',
    "d.d.ts": 'import "./c";',
    "test.test.ts": 'import "./test.test";',
    "test.spec.ts": 'import "./test.spec";',
    "dist/index.ts": 'import "./index";',
  });
  assert.deepEqual(staticViewImportCycles(root), []);
});

test("retains side effects and value bindings in mixed type imports", (t) => {
  const root = fixture(t, {
    "a.ts": 'import "./b";',
    "b.ts": 'import { type A, a } from "./a";',
  });
  assert.deepEqual(staticViewImportCycles(root), [["a.ts", "b.ts", "a.ts"]]);
});
