import { z } from "zod";

const releaseSchema = z.object({
  tag_name: z.string(),
  published_at: z.string().nullable().optional(),
  html_url: z.string().optional(),
  draft: z.boolean().default(false),
  prerelease: z.boolean().default(false),
  assets: z
    .array(z.object({ name: z.string(), browser_download_url: z.string(), size: z.number().optional() }))
    .default([]),
});
export type DesktopRelease = z.infer<typeof releaseSchema>;
const SAFE_ASSET =
  /^(?:latest(?:-x64)?-mac\.yml|multica-desktop-\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?-mac-(?:arm64|x64)\.(?:dmg|zip)(?:\.blockmap)?)$/;

export function desktopAssetPath(name: string): string | undefined {
  return SAFE_ASSET.test(name) ? `/api/desktop-updates/${name}` : undefined;
}

export function forgejoConfig() {
  const base = (process.env.FORGEJO_BASE_URL ?? "").replace(/\/+$/, "");
  const repo = process.env.FORGEJO_REPO ?? "";
  try {
    const url = new URL(base);
    if (
      url.protocol !== "https:" ||
      url.username ||
      url.password ||
      url.search ||
      url.hash ||
      !/^[\w.-]+\/[\w.-]+$/.test(repo)
    )
      return null;
    const headers: Record<string, string> = { Accept: "application/json" };
    if (process.env.FORGEJO_TOKEN)
      headers.Authorization = `token ${process.env.FORGEJO_TOKEN}`;
    return { base, repo, headers };
  } catch {
    return null;
  }
}
type Config = NonNullable<ReturnType<typeof forgejoConfig>>;

export function trustedAssetUrl(
  raw: string,
  config: Config,
): string | undefined {
  try {
    const url = new URL(raw);
    const base = new URL(config.base);
    const prefix = `${base.pathname.replace(/\/$/, "")}/${config.repo}/releases/download/`;
    if (
      url.origin !== base.origin ||
      url.username ||
      url.password ||
      url.search ||
      url.hash ||
      !url.pathname.startsWith(prefix)
    )
      return undefined;
    const parts = url.pathname.slice(prefix.length).split("/");
    if (
      parts.length !== 2 ||
      !/^v\d+\.\d+\.\d+(?:-[\w.-]+)?$/.test(parts[0]!) ||
      !desktopAssetPath(parts[1]!)
    )
      return undefined;
    return url.href;
  } catch {
    return undefined;
  }
}

export async function readForgejoReleases(
  config: Config,
  timeoutMs = 15_000,
): Promise<DesktopRelease[]> {
  const response = await fetch(
    `${config.base}/api/v1/repos/${config.repo}/releases?limit=50`,
    {
      headers: config.headers,
      cache: "no-store",
      redirect: "error",
      signal: AbortSignal.timeout(timeoutMs),
    },
  );
  if (!response.ok) throw new Error("release source unavailable");
  return z.array(releaseSchema).parse(await response.json());
}

export function completeMacRelease(
  release: DesktopRelease,
  arch = "arm64",
): boolean {
  if (release.draft || release.prerelease) return false;
  const prefix = `multica-desktop-${release.tag_name.replace(/^v/, "")}-mac-${arch}`;
  const names = new Set(release.assets.map((asset) => asset.name));
  return (
    [".dmg", ".zip", ".dmg.blockmap", ".zip.blockmap"].every((suffix) =>
      names.has(prefix + suffix),
    ) && names.has(arch === "arm64" ? "latest-mac.yml" : "latest-x64-mac.yml")
  );
}

export function selectReleaseAsset(releases: DesktopRelease[], name: string) {
  return releases
    .filter((r) => !r.draft && !r.prerelease)
    .filter(
      (r) =>
        !name.endsWith(".yml") ||
        completeMacRelease(r, name.includes("x64") ? "x64" : "arm64"),
    )
    .flatMap((r) => r.assets)
    .find((asset) => asset.name === name);
}
