// @vitest-environment node
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { expect, it } from "vitest";

// Exercise the installed builder's actual merge and schema validation rules.
const requireBuilder = createRequire(import.meta.resolve("electron-builder"));
const { getConfig, validateConfiguration } = requireBuilder("app-builder-lib/out/util/config/config.js");

it("replaces GitHub publisher properties with a valid self-hosted generic feed", async () => {
  const config = await getConfig(fileURLToPath(new URL("../", import.meta.url)), "electron-builder.selfhost.yml", {
    publish: { url: "https://app.example.test/api/desktop-updates", channel: "latest" },
  });
  await validateConfiguration(config, { add() {} });
  expect(config.publish).toEqual([{ provider: "generic", url: "https://app.example.test/api/desktop-updates", channel: "latest" }]);
  expect(config.mac.target).toEqual(["dmg", "zip"]);
});
