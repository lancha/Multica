// @vitest-environment node
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "vitest";
import hook, { rewriteExecutableUuids, uuidOffsets } from "./mac-executable-uuids.mjs";

function thin(cpu = 0x100000c) {
  const data = Buffer.alloc(80, 0xab);
  data.writeUInt32LE(0xfeedfacf, 0);
  data.writeUInt32LE(cpu, 4);
  data.writeUInt32LE(2, 12);
  data.writeUInt32LE(1, 16);
  data.writeUInt32LE(24, 20);
  data.writeUInt32LE(0x1b, 32);
  data.writeUInt32LE(24, 36);
  return data;
}

for (const cpu of [0x100000c, 0x1000007]) {
  test(`only LC_UUID bytes change for CPU ${cpu}`, () => {
    const original = thin(cpu);
    const changed = rewriteExecutableUuids(original);
    assert.deepEqual(changed.subarray(0, 40), original.subarray(0, 40));
    assert.deepEqual(changed.subarray(56), original.subarray(56));
    assert.notDeepEqual(changed.subarray(40, 56), original.subarray(40, 56));
    assert.equal(original[40], 0xab);
    assert.notDeepEqual(rewriteExecutableUuids(original), changed);
  });
}

for (const fat64 of [false, true]) {
  test(`universal ${fat64 ? 64 : 32}-bit header gives each architecture a UUID`, () => {
    const data = Buffer.alloc(240);
    const step = fat64 ? 32 : 20;
    data.writeUInt32BE(fat64 ? 0xcafebabf : 0xcafebabe, 0);
    data.writeUInt32BE(2, 4);
    for (let i = 0; i < 2; i++) {
      if (fat64) {
        data.writeBigUInt64BE(BigInt(80 + 80 * i), 8 + i * step + 8);
        data.writeBigUInt64BE(80n, 8 + i * step + 16);
      } else {
        data.writeUInt32BE(80 + 80 * i, 8 + i * step + 8);
        data.writeUInt32BE(80, 8 + i * step + 12);
      }
      thin(i ? 0x100000c : 0x1000007).copy(data, 80 + 80 * i);
    }
    const changed = rewriteExecutableUuids(data);
    assert.deepEqual(uuidOffsets(changed), [120, 200]);
    assert.notDeepEqual(changed.subarray(120, 136), changed.subarray(200, 216));
    for (const offset of uuidOffsets(changed)) data.copy(changed, offset, offset, offset + 16);
    assert.deepEqual(changed, data);
  });
}

test("malformed or missing UUID fails without modifying the input", () => {
  for (const mutate of [
    (b) => b.writeUInt32LE(0, 0),
    (b) => b.writeUInt32LE(6, 12),
    (b) => b.writeUInt32LE(0xffffffff, 20),
    (b) => b.writeUInt32LE(0, 36),
    (b) => b.writeUInt32LE(0x19, 32),
  ]) {
    const bytes = thin();
    mutate(bytes);
    const saved = Buffer.from(bytes);
    assert.throws(() => rewriteExecutableUuids(bytes));
    assert.deepEqual(bytes, saved);
  }
});

test("non-mac packaging does not touch the filesystem", () => {
  hook({ electronPlatformName: "linux" });
  hook({ electronPlatformName: "win32" });
});

test.skipIf(process.platform !== "darwin")("packed app and helper change while framework and resources stay intact", () => {
  const root = mkdtempSync(join(tmpdir(), "multica-uuid-test-"));
  const app = join(root, "Multica.app");
  const helper = join(app, "Contents/Frameworks/Multica Helper.app");
  const executables = [];
  try {
    for (const [bundle, name] of [[app, "Multica"], [helper, "Multica Helper"]]) {
      mkdirSync(join(bundle, "Contents/MacOS"), { recursive: true });
      writeFileSync(join(bundle, "Contents/Info.plist"),
        `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>${name}</string></dict></plist>`);
      const binary = join(bundle, "Contents/MacOS", name);
      writeFileSync(binary, thin(), { mode: 0o755 });
      executables.push(binary);
    }
    const framework = join(app, "Contents/Frameworks/Electron.framework");
    mkdirSync(framework);
    const library = join(framework, "Electron");
    writeFileSync(library, thin());
    const context = { electronPlatformName: "darwin", appOutDir: root,
      packager: { appInfo: { productFilename: "Multica" } } };
    const plist = readFileSync(join(app, "Contents/Info.plist"));
    hook(context);
    const changed = executables.map((file) => readFileSync(file));
    assert.notDeepEqual(changed[0], thin());
    assert.notDeepEqual(changed[0], changed[1]);
    assert.deepEqual(readFileSync(library), thin());
    assert.deepEqual(readFileSync(join(app, "Contents/Info.plist")), plist);
    // A malformed helper must stop packaging before partially changing the app.
    writeFileSync(executables[1], "not a Mach-O");
    assert.throws(() => hook(context));
    assert.deepEqual(readFileSync(executables[0]), changed[0]);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
