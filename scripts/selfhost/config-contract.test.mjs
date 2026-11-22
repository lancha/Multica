import { readFileSync } from "node:fs";
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync } from "node:fs";

const root = new URL("../../", import.meta.url);
const read = (path) => readFileSync(new URL(path, root), "utf8");

test("standard frontend Compose passes server-side Forgejo configuration", () => {
  const frontend = read("docker-compose.selfhost.yml").split("  frontend:")[1];
  const example = read(".env.example");
  for (const name of ["DESKTOP_RELEASES_SOURCE", "FORGEJO_BASE_URL", "FORGEJO_REPO", "FORGEJO_TOKEN"]) {
    assert.match(frontend, new RegExp(`^      ${name}: \\$\\{${name}:-[^}]*\\}`, "m"));
    assert.match(example, new RegExp(`^${name}=`, "m"));
    assert.doesNotMatch(frontend, new RegExp(`NEXT_PUBLIC_${name}`));
  }
});

test("pnpm clean delegates to the maintained Makefile cleanup", () => {
  assert.equal(JSON.parse(read("package.json")).scripts.clean, "make clean");
  assert.match(read("Makefile"), /^clean:/m);
});

test("desktop and web declare every shared views runtime peer", () => {
  const peers = JSON.parse(read("packages/views/package.json")).peerDependencies;
  for (const app of ["web", "desktop"]) {
    const deps = JSON.parse(read(`apps/${app}/package.json`)).dependencies;
    for (const name of Object.keys(peers)) assert.ok(deps[name], `${app}: ${name}`);
  }
});

test("lint workspaces declare eslint directly", () => {
  for (const path of ["apps/web", "apps/desktop", "packages/core", "packages/views", "packages/ui", "packages/plugin-sdk"]) {
    const pkg = JSON.parse(read(`${path}/package.json`));
    assert.ok(pkg.devDependencies.eslint, path);
  }
});

test("mobile React types stay SDK-aligned rather than globally overridden", () => {
  const workspace = read("pnpm-workspace.yaml");
  const overrides = workspace.match(/^overrides:\n((?:[ \t].*\n|\n)*)/m);
  assert.ok(overrides, "workspace overrides section");
  assert.doesNotMatch(overrides[1], /^\s*['"]?@types\/react['"]?\s*:/m);
  const mobile = JSON.parse(read("apps/mobile/package.json"));
  assert.equal(mobile.devDependencies["@types/react"], `~${mobile.dependencies.react}`);
});

test("all plain TypeScript markdown modules have exact subpath exports", () => {
  const exports = JSON.parse(read("packages/ui/package.json")).exports;
  for (const name of ["linkify", "mentions", "issue-identifiers", "sanitize", "file-cards"]) {
    const target = exports[`./markdown/${name}`];
    assert.equal(target, `./markdown/${name}.ts`);
    assert.ok(existsSync(new URL(`packages/ui/${target}`, root)));
  }
});
