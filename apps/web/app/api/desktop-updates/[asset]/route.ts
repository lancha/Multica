import { NextResponse } from "next/server";
import {
  desktopAssetPath,
  forgejoConfig,
  readForgejoReleases,
  selectReleaseAsset,
  trustedAssetUrl,
} from "../../../../lib/desktop-releases";

export const dynamic = "force-dynamic";

export async function GET(
  request: Request,
  context: { params: Promise<{ asset: string }> },
) {
  // Next has already decoded the parameter. Never decode it twice.
  const { asset } = await context.params;
  if (!desktopAssetPath(asset))
    return NextResponse.json(
      { error: "invalid update asset" },
      { status: 400 },
    );
  const config = forgejoConfig();
  if (!config)
    return NextResponse.json(
      { error: "update feed not configured" },
      { status: 503 },
    );
  try {
    const selected = selectReleaseAsset(
      await readForgejoReleases(config),
      asset,
    );
    if (!selected)
      return NextResponse.json(
        { error: "update asset not found" },
        { status: 404 },
      );
    const url = trustedAssetUrl(selected.browser_download_url, config);
    if (!url) throw new Error("untrusted asset URL");
    const headers = new Headers(config.headers);
    headers.set("Accept-Encoding", "identity");
    const range = request.headers.get("range");
    if (range) headers.set("Range", range);
    const upstream = await fetch(url, {
      cache: "no-store",
      headers,
      // Never forward the private token to a redirect target.
      redirect: "error",
      signal: AbortSignal.timeout(asset.endsWith(".yml") ? 15_000 : 1_800_000),
    });
    if (upstream.status === 416)
      return new Response(null, {
        status: 416,
        headers: {
          "Content-Range": upstream.headers.get("content-range") ?? "bytes */0",
        },
      });
    if (
      !upstream.ok ||
      !upstream.body ||
      upstream.headers.get("content-type")?.includes("text/html")
    ) {
      await upstream.body?.cancel();
      throw new Error("invalid asset response");
    }
    const outgoing = new Headers({
      "Content-Type": asset.endsWith(".yml")
        ? "text/yaml; charset=utf-8"
        : "application/octet-stream",
      "Cache-Control": asset.endsWith(".yml")
        ? "no-cache"
        : "public, max-age=31536000, immutable",
      "Content-Disposition": `attachment; filename="${asset}"`,
      "X-Content-Type-Options": "nosniff",
    });
    for (const name of ["content-length", "content-range", "accept-ranges"]) {
      const value = upstream.headers.get(name);
      if (value) outgoing.set(name, value);
    }
    return new Response(upstream.body, {
      status: upstream.status,
      headers: outgoing,
    });
  } catch {
    // Upstream errors can contain credentials; do not log them.
    return NextResponse.json(
      { error: "update feed unavailable" },
      { status: 502 },
    );
  }
}
