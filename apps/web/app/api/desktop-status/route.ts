import { NextResponse } from "next/server";
import { fetchLatestRelease } from "@/features/landing/utils/github-release";

// Release credentials and deployment state exist only at runtime. ISR can
// swallow the no-store bailout in the release reader and cache an empty result.
export const dynamic = "force-dynamic";

const HEALTH_URL =
  process.env.MULTICA_HEALTH_URL ?? "https://ca.mikeux.com:188/health";

export async function GET() {
  const release = await fetchLatestRelease();
  let health: { status: "healthy" | "unavailable"; commit?: string } = {
    status: "unavailable",
  };

  try {
    const response = await fetch(HEALTH_URL, {
      cache: "no-store",
      signal: AbortSignal.timeout(15_000),
      headers: { Accept: "application/json" },
    });
    if (response.ok) {
      const payload = (await response.json()) as { commit?: unknown };
      health = {
        status: "healthy",
        ...(typeof payload.commit === "string" ? { commit: payload.commit } : {}),
      };
    }
  } catch {
    // The public status endpoint degrades to an unavailable badge during restarts.
  }

  return NextResponse.json(
    {
      health,
      release: {
        version: release.version,
        publishedAt: release.publishedAt,
        macArm64: Boolean(release.assets.macArm64Dmg),
        macX64: Boolean(release.assets.macX64Dmg),
        macStatus:
          release.assets.macArm64Dmg && release.assets.macArm64Zip
            ? "published"
            : release.version
              ? "building"
              : "waiting",
      },
      checkedAt: new Date().toISOString(),
    },
    { headers: { "Cache-Control": "no-store" } },
  );
}
