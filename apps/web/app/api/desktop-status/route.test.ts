// @vitest-environment node
import { afterEach, describe, expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";
import { fetchLatestRelease } from "@/features/landing/utils/github-release";
import * as route from "./route";

vi.mock("@/features/landing/utils/github-release", () => ({
  fetchLatestRelease: vi.fn(),
}));

afterEach(() => {
  vi.unstubAllGlobals();
  vi.resetAllMocks();
});

describe("runtime desktop release status", () => {
  it("opts status and download routes out of build-time/ISR output", () => {
    expect(route.dynamic).toBe("force-dynamic");
    const page = readFileSync(
      new URL("../../(landing)/download/page.tsx", import.meta.url),
      "utf8",
    );
    expect(page).toContain('export const dynamic = "force-dynamic"');
    expect(page).not.toContain("export const revalidate");
  });

  it("reads fresh health and release state on each request", async () => {
    vi.mocked(fetchLatestRelease)
      .mockResolvedValueOnce({ version: null, publishedAt: null, htmlUrl: null, assets: {}, sizes: {} })
      .mockResolvedValueOnce({
        version: "v0.6.2", publishedAt: null, htmlUrl: null,
        assets: { macArm64Dmg: "/new.dmg", macArm64Zip: "/new.zip" }, sizes: {},
      });
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(Response.json({ commit: "old" }))
      .mockResolvedValueOnce(Response.json({ commit: "new" }));
    vi.stubGlobal("fetch", fetchMock);
    const first = await route.GET();
    expect((await first.json()).release.macStatus).toBe("waiting");
    const second = await route.GET();
    expect(await second.json()).toMatchObject({
      health: { status: "healthy", commit: "new" },
      release: { version: "v0.6.2", macStatus: "published" },
    });
    expect(second.headers.get("cache-control")).toBe("no-store");
    expect(fetchMock).toHaveBeenCalledWith(expect.any(String), expect.objectContaining({ cache: "no-store", signal: expect.any(AbortSignal) }));
  });

  it("keeps a published release visible when health is unavailable", async () => {
    vi.mocked(fetchLatestRelease).mockResolvedValue({
      version: "v0.6.2", publishedAt: null, htmlUrl: null,
      assets: { macArm64Dmg: "/new.dmg", macArm64Zip: "/new.zip" }, sizes: {},
    });
    vi.stubGlobal("fetch", vi.fn().mockRejectedValue(new Error("offline")));
    expect(await (await route.GET()).json()).toMatchObject({
      health: { status: "unavailable" },
      release: { version: "v0.6.2", macStatus: "published" },
    });
  });
});
