import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

test("same-second milestones stay ordered and are not posted twice", () => {
  const root = mkdtempSync(join(tmpdir(), "multica-progress-test-"));
  try {
    const bin = join(root, "bin");
    mkdirSync(bin);
    const config = join(root, "config.json");
    const comments = join(root, "comments.jsonl");
    const requests = join(root, "requests.jsonl");
    const relay = join(root, "relay.log");
    writeFileSync(config, JSON.stringify({ server_url: "https://test.invalid", token: "test", workspace_id: "workspace" }));
    const records = [80, 90, 100].map(value => `2026-09-30T07:35:29Z PROGRESS v0.6.2 ${value} stage ${value}`);
    writeFileSync(relay, [...records, ...records].join("\n") + "\n");
    writeFileSync(comments, "");
    writeFileSync(join(bin, "ssh"), "#!/bin/sh\nexit 1\n", { mode: 0o755 });
    writeFileSync(join(bin, "python3"), '#!/bin/sh\nprintf "%s\\n" "$*" >>"$TEST_RETRIES"\n', { mode: 0o755 });
    writeFileSync(join(bin, "curl"), `#!/usr/bin/env node
const fs = require("node:fs");
const args = process.argv.slice(2);
const url = args.at(-1);
const method = args.includes("-X") ? args[args.indexOf("-X") + 1] : "GET";
fs.appendFileSync(process.env.TEST_REQUESTS, url + "\\n");
if (method === "POST" && url.includes("/comments?")) {
  fs.appendFileSync(process.env.TEST_COMMENTS, args[args.indexOf("--data") + 1] + "\\n");
  console.log("{}");
} else if (url.includes("/comments?")) {
  console.log(process.env.TEST_RETRY ? '[{"id":"retry-1","content":"重新运行"}]' : "[]");
} else if (method === "PUT") {
  console.log("{}");
} else if (url.includes("/api/projects/")) {
  console.log(JSON.stringify({id:"homelab-project",workspace_id:process.env.TEST_PROJECT_WORKSPACE || "homelab"}));
} else if (url.includes("/api/issues/issue?")) {
  console.log(JSON.stringify({id:"issue",status:"in_progress",revision:1}));
} else {
  console.log(JSON.stringify({issues:[{id:"issue", identifier:"TEST-1", title:"Mac App 自动构建 · v0.6.2", status:process.env.TEST_RETRY ? "blocked" : "in_progress", revision:1}]}));
}
`, { mode: 0o755 });
    const env = {
      ...process.env,
      PATH: bin + ":" + process.env.PATH,
      MULTICA_CONFIG: config,
      MULTICA_WORKSPACE_ID: "homelab",
      MULTICA_BUILD_PROJECT_ID: "homelab-project",
      MULTICA_DEPLOY_STATE_DIR: join(root, "state"),
      MULTICA_MAC_PROGRESS_LOG: relay,
      TEST_COMMENTS: comments,
      TEST_REQUESTS: requests,
      TEST_RETRIES: join(root, "retries"),
      MULTICA_GITHUB_PIPELINE: "/test/github/pipeline.py",
    };
    const script = fileURLToPath(new URL("./desktop-build-progress.sh", import.meta.url));
    execFileSync("bash", [script], { env });
    const first = readFileSync(comments, "utf8");
    assert.deepEqual(first.trim().split("\n").map(line => JSON.parse(line).content.match(/(\d+)%/)[1]), ["80", "90", "100"]);
    execFileSync("bash", [script], { env });
    assert.equal(readFileSync(comments, "utf8"), first);
    assert.ok(readFileSync(requests, "utf8").trim().split("\n").every(url => url.includes("workspace_id=homelab")));
    assert.equal(JSON.parse(readFileSync(config, "utf8")).workspace_id, "workspace");
    assert.throws(() => execFileSync("bash", [script], { env: { ...env, TEST_PROJECT_WORKSPACE: "wrong" }, stdio: "pipe" }));
    assert.equal(readFileSync(comments, "utf8"), first);
    execFileSync("bash", [script], { env: { ...env, TEST_RETRY: "1" } });
    assert.equal(readFileSync(env.TEST_RETRIES, "utf8").trim(), "/test/github/pipeline.py --retry v0.6.2");
    const afterRetry = readFileSync(comments, "utf8");
    assert.match(afterRetry, /GitHub/);
    execFileSync("bash", [script], { env: { ...env, TEST_RETRY: "1" } });
    assert.equal(readFileSync(env.TEST_RETRIES, "utf8").trim().split("\n").length, 1);
    assert.equal(readFileSync(comments, "utf8"), afterRetry);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
