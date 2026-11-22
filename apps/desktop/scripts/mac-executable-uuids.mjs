// Electron's stock executables share LC_UUID across unrelated applications.
// macOS local-network privacy can then apply another app's permission to ours.
// Run after packing and before signing; frameworks retain their upstream UUIDs.
import { randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

export function uuidOffsets(buffer) {
  const offsets = [];
  function thin(start, size) {
    if (size < 32 || start + size > buffer.length) throw new Error("Truncated Mach-O");
    const magic = buffer.readUInt32LE(start);
    if (magic !== 0xfeedfacf) throw new Error("Expected little-endian 64-bit Mach-O");
    if (buffer.readUInt32LE(start + 12) !== 2) throw new Error("Expected MH_EXECUTE");
    const count = buffer.readUInt32LE(start + 16);
    const end = start + 32 + buffer.readUInt32LE(start + 20);
    if (end > start + size || count > (end - start - 32) / 8) {
      throw new Error("Invalid Mach-O load commands");
    }
    let cursor = start + 32;
    const found = [];
    for (let i = 0; i < count; i++) {
      if (cursor + 8 > end) throw new Error("Truncated load command");
      const command = buffer.readUInt32LE(cursor);
      const length = buffer.readUInt32LE(cursor + 4);
      if (length < 8 || length % 8 || cursor + length > end) {
        throw new Error("Invalid load command length");
      }
      if (command === 0x1b) {
        if (length !== 24) throw new Error("Invalid LC_UUID size");
        found.push(cursor + 8);
      }
      cursor += length;
    }
    if (cursor !== end || found.length !== 1) throw new Error("Expected exactly one LC_UUID");
    offsets.push(found[0]);
  }
  if (buffer.length < 8) throw new Error("Truncated Mach-O");
  const magic = buffer.readUInt32BE(0);
  if (magic === 0xcafebabe || magic === 0xcafebabf) {
    const fat64 = magic === 0xcafebabf;
    const count = buffer.readUInt32BE(4);
    const entrySize = fat64 ? 32 : 20;
    const headerEnd = 8 + count * entrySize;
    if (!count || headerEnd > buffer.length) throw new Error("Invalid universal header");
    const ranges = [];
    for (let i = 0; i < count; i++) {
      const cursor = 8 + i * entrySize;
      const start = fat64 ? Number(buffer.readBigUInt64BE(cursor + 8)) : buffer.readUInt32BE(cursor + 8);
      const size = fat64 ? Number(buffer.readBigUInt64BE(cursor + 16)) : buffer.readUInt32BE(cursor + 12);
      if (!Number.isSafeInteger(start) || !Number.isSafeInteger(size) ||
          start < headerEnd || start + size > buffer.length ||
          ranges.some(([a, b]) => start < b && start + size > a)) {
        throw new Error("Invalid universal slice");
      }
      ranges.push([start, start + size]);
      thin(start, size);
    }
  } else {
    thin(0, buffer.length);
  }
  return offsets;
}

export function rewriteExecutableUuids(buffer) {
  // Validate every slice before changing any byte.
  const offsets = uuidOffsets(buffer);
  const result = Buffer.from(buffer);
  offsets.forEach((offset) => {
    Buffer.from(randomUUID().replaceAll("-", ""), "hex").copy(result, offset);
  });
  return result;
}

function bundleExecutable(bundle) {
  const name = execFileSync("/usr/bin/plutil", [
    "-extract", "CFBundleExecutable", "raw", "-o", "-", path.join(bundle, "Contents/Info.plist"),
  ], { encoding: "utf8" }).trim();
  if (!name || path.basename(name) !== name) throw new Error("Invalid bundle executable name");
  return path.join(bundle, "Contents/MacOS", name);
}

export function patchAppExecutables(app) {
  const frameworks = path.join(app, "Contents/Frameworks");
  const bundles = [app, ...fs.readdirSync(frameworks, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && entry.name.endsWith(".app"))
    .map((entry) => path.join(frameworks, entry.name))];
  const plans = bundles.map((bundle) => {
    const executable = bundleExecutable(bundle);
    return { executable, bytes: rewriteExecutableUuids(fs.readFileSync(executable)) };
  });
  for (const { executable, bytes } of plans) fs.writeFileSync(executable, bytes);
  return bundles;
}

export default function afterPack(context) {
  if (context.electronPlatformName !== "darwin") return;
  const app = path.join(context.appOutDir, `${context.packager.appInfo.productFilename}.app`);
  const bundles = patchAppExecutables(app);
  console.log(`[mac-executable-uuids] assigned distinct UUIDs to ${bundles.length} executables before signing`);
}
