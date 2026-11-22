// @vitest-environment node
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { GET } from "./route";
import { runtimeRewriteDestination } from "../../../../config/runtime-urls";

const prefix = "multica-desktop-0.6.1-mac-arm64";
const names = [
  `${prefix}.dmg`,
  `${prefix}.zip`,
  `${prefix}.dmg.blockmap`,
  `${prefix}.zip.blockmap`,
  "latest-mac.yml",
];
const release = {
  tag_name: "v0.6.1",
  assets: names.map((name) => ({
    name,
    browser_download_url: `https://forgejo.test/mike/Multica/releases/download/v0.6.1/${name}`,
  })),
};
const get = (name: string, headers = {}) =>
  GET(
    new Request(`https://app.test/api/desktop-updates/${name}`, { headers }),
    { params: Promise.resolve({ asset: name }) },
  );
let fetchMock: ReturnType<typeof vi.fn>;
beforeEach(() => {
  vi.stubEnv("FORGEJO_BASE_URL", "https://forgejo.test");
  vi.stubEnv("FORGEJO_REPO", "mike/Multica");
  vi.stubEnv("FORGEJO_TOKEN", "test-private-token");
  fetchMock = vi.fn();
  vi.stubGlobal("fetch", fetchMock);
});
afterEach(() => {
  vi.unstubAllGlobals();
  vi.unstubAllEnvs();
});

describe("public desktop feed", () => {
  it("stays on Next instead of being rewritten to the backend", () => {
    expect(
      runtimeRewriteDestination("/api/desktop-updates/latest-mac.yml", {
        REMOTE_API_URL: "http://backend:8080",
      }),
    ).toBeUndefined();
    expect(
      runtimeRewriteDestination("/api/desktop-updates-other", {
        REMOTE_API_URL: "http://backend:8080",
      }),
    ).toContain("backend:8080");
  });
  it.each([
    "../secrets",
    "%2e%2e%2fsecrets",
    "latest-mac.yml%",
    "source.zip",
    "foo.yml",
  ])("rejects %s before fetching", async (name) => {
    expect((await get(name)).status).toBe(400);
    expect(fetchMock).not.toHaveBeenCalled();
  });
  it("streams authenticated YAML without exposing the credential", async () => {
    fetchMock
      .mockResolvedValueOnce(Response.json([release]))
      .mockResolvedValueOnce(
        new Response("version: 0.6.1\n", {
          headers: { "content-type": "text/plain" },
        }),
      );
    const result = await get("latest-mac.yml");
    expect(result.status).toBe(200);
    expect(result.headers.get("content-type")).toContain("yaml");
    expect(result.headers.get("authorization")).toBeNull();
    expect(await result.text()).toBe("version: 0.6.1\n");
    const options = fetchMock.mock.calls[1]![1];
    expect(options.headers.get("Authorization")).toBe(
      "token test-private-token",
    );
    expect(options.redirect).toBe("error");
  });
  it("preserves byte ranges for differential downloads", async () => {
    fetchMock
      .mockResolvedValueOnce(Response.json([release]))
      .mockResolvedValueOnce(
        new Response("PK", {
          status: 206,
          headers: { "Content-Range": "bytes 0-1/100", "Content-Length": "2" },
        }),
      );
    const result = await get(`${prefix}.zip`, { Range: "bytes=0-1" });
    expect(result.status).toBe(206);
    expect(result.headers.get("content-range")).toBe("bytes 0-1/100");
    expect(fetchMock.mock.calls[1]![1].headers.get("Range")).toBe("bytes=0-1");
  });
  it("ignores incomplete releases even when metadata was uploaded", async () => {
    fetchMock.mockResolvedValue(
      Response.json([{ ...release, assets: release.assets.slice(-1) }]),
    );
    expect((await get("latest-mac.yml")).status).toBe(404);
  });
  it.each([
    { ...release, draft: true },
    { ...release, prerelease: true },
  ])("ignores non-public releases", async (value) => {
    fetchMock.mockResolvedValue(Response.json([value]));
    expect((await get("latest-mac.yml")).status).toBe(404);
  });
  it.each([null, {}, [{ assets: "invalid" }]])(
    "fails closed on malformed JSON",
    async (value) => {
      fetchMock.mockResolvedValue(Response.json(value));
      expect((await get("latest-mac.yml")).status).toBe(502);
    },
  );
  it.each([
    "https://evil.test/file",
    "https://forgejo.test/other/private/file",
    "https://token@forgejo.test/mike/Multica/releases/download/v0.6.1/latest-mac.yml",
  ])("never sends credentials to %s", async (url) => {
    fetchMock.mockResolvedValue(
      Response.json([
        {
          ...release,
          assets: release.assets.map((a) => ({
            ...a,
            browser_download_url: url,
          })),
        },
      ]),
    );
    expect((await get("latest-mac.yml")).status).toBe(502);
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });
  it("rejects a login HTML response", async () => {
    fetchMock
      .mockResolvedValueOnce(Response.json([release]))
      .mockResolvedValueOnce(
        new Response("login", { headers: { "Content-Type": "text/html" } }),
      );
    expect((await get("latest-mac.yml")).status).toBe(502);
  });
  it("propagates range-not-satisfiable", async () => {
    fetchMock
      .mockResolvedValueOnce(Response.json([release]))
      .mockResolvedValueOnce(
        new Response(null, {
          status: 416,
          headers: { "Content-Range": "bytes */100" },
        }),
      );
    expect((await get(`${prefix}.zip`)).status).toBe(416);
  });
  it("fails closed when config is missing", async () => {
    vi.stubEnv("FORGEJO_BASE_URL", "");
    expect((await get("latest-mac.yml")).status).toBe(503);
  });
});
