import {
  hasCompleteAssetSet,
  parseReleaseAssets,
  parseReleaseAssetSizes,
  type DownloadAssets,
  type DownloadSizes,
  type GitHubAsset,
} from "./parse-release-assets";
import {
  completeMacRelease,
  desktopAssetPath,
  forgejoConfig,
  readForgejoReleases,
  trustedAssetUrl,
} from "../../../lib/desktop-releases";

/**
 * Server-side fetcher for the latest downloadable Multica release,
 * designed to run inside a Next.js server component. Response is cached
 * by the Next.js fetch cache for 5 minutes (Vercel ISR) so hitting
 * /download costs at most one GitHub API call per region per 5 minutes.
 *
 * Desktop assets don't all land at the same time: CI uploads Linux and
 * Windows within a minute of each other, but macOS is packaged manually
 * (notarization credentials aren't wired into CI yet) and lands tens of
 * minutes later. A packaging job can also fail outright and leave a
 * release permanently short of some platforms. Either way the newest
 * release is not always the newest *downloadable* one, so we pull a
 * short window of recent releases and show the newest whose desktop
 * asset set is complete — every button on the page then resolves to a
 * real file.
 *
 * On any failure (network, timeout, rate limit, malformed payload) returns a
 * `null`-shaped result and logs — the page degrades to a "version
 * unavailable" view rather than 500ing.
 */

export interface LatestRelease {
  version: string | null;
  publishedAt: string | null;
  htmlUrl: string | null;
  assets: DownloadAssets;
  sizes: DownloadSizes;
}

// Five candidates tolerates four consecutive incomplete releases before
// the page has to fall back to showing the newest one as-is. Releases
// ship roughly daily, so that is days of head room — while staying one
// cheap request.
const GITHUB_RELEASES_URL =
  "https://api.github.com/repos/multica-ai/multica/releases?per_page=5";

const REVALIDATE_SECONDS = 300;
export const RELEASE_TIMEOUT_MS = 3000;

/**
 * Where /download reads its release list from.
 *
 * A self-hosted deployment builds the desktop app from its own Git server, so
 * GitHub's releases are the wrong source there — the page would offer upstream
 * installers instead of the build that matches this deployment. Setting
 * `DESKTOP_RELEASES_SOURCE=forgejo` plus `FORGEJO_BASE_URL` and
 * `FORGEJO_REPO` switches the source to a Forgejo/Gitea instance; the release
 * payload shape is close enough to GitHub's (tag_name, published_at, html_url,
 * assets[].browser_download_url) that nothing downstream changes.
 *
 * `FORGEJO_TOKEN` is optional and only needed when the repository is private.
 * Like `GITHUB_TOKEN` it stays server-side, so never prefix it with
 * `NEXT_PUBLIC_`.
 */
function desktopReleasesEndpoint(): {
  url: string;
  headers: Record<string, string>;
} {
  const headers: Record<string, string> = {
    Accept: "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
  };
  // Optional PAT for local development and self-hosted deploys where
  // the shared outbound IP keeps hitting the 60-requests/hour
  // unauthenticated limit. Vercel's fetch cache is shared across all
  // regions so production rarely needs this — but the env var lets
  // anyone running the site locally avoid the rate-limit dance. Never
  // prefix this with `NEXT_PUBLIC_`; the token must stay server-side.
  const token = process.env.GITHUB_TOKEN;
  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }
  return { url: GITHUB_RELEASES_URL, headers };
}

interface GitHubReleasePayload {
  tag_name?: string;
  published_at?: string;
  html_url?: string;
  prerelease?: boolean;
  draft?: boolean;
  assets?: GitHubAsset[];
}

export async function fetchLatestRelease(): Promise<LatestRelease> {
  const source = (process.env.DESKTOP_RELEASES_SOURCE || "github").trim().toLowerCase();
  if (source !== "github" && source !== "forgejo") return emptyRelease();
  if (source === "forgejo") {
    try {
      const config = forgejoConfig();
      if (!config) return emptyRelease();
      const release = (await readForgejoReleases(config, RELEASE_TIMEOUT_MS)).find((candidate) =>
        completeMacRelease(candidate),
      );
      if (!release) return emptyRelease();
      const assets = release.assets
        .filter(
          (asset) =>
            desktopAssetPath(asset.name) &&
            trustedAssetUrl(asset.browser_download_url, config),
        )
        .map((asset) => ({
          ...asset,
          browser_download_url: desktopAssetPath(asset.name)!,
        }));
      return {
        version: release.tag_name,
        publishedAt: release.published_at ?? null,
        htmlUrl: release.html_url ?? null,
        assets: parseReleaseAssets(assets),
        sizes: parseReleaseAssetSizes(assets),
      };
    } catch {
      return emptyRelease();
    }
  }
  const endpoint = desktopReleasesEndpoint();

  const controller = new AbortController();
  const timer = setTimeout(
    () => controller.abort(new Error(`GitHub API timed out after ${RELEASE_TIMEOUT_MS}ms`)),
    RELEASE_TIMEOUT_MS,
  );
  try {
    const res = await fetch(endpoint.url, {
      next: { revalidate: REVALIDATE_SECONDS },
      headers: endpoint.headers,
      signal: controller.signal,
    });
    if (!res.ok) {
      throw new Error(`releases API responded ${res.status}`);
    }
    const data = (await res.json()) as GitHubReleasePayload[];

    // Defensive filter — Multica doesn't publish prereleases or drafts
    // today, but the endpoint returns them if that ever changes. A
    // prerelease shadowing a stable version on /download would be a
    // regression.
    const stable = data.filter((r) => !r.prerelease && !r.draft);
    const chosen = pickRelease(stable);
    if (!chosen) {
      return emptyRelease();
    }

    return {
      version: chosen.release.tag_name ?? null,
      publishedAt: chosen.release.published_at ?? null,
      htmlUrl: chosen.release.html_url ?? null,
      assets: chosen.assets,
      sizes: parseReleaseAssetSizes(chosen.release.assets ?? []),
    };
  } catch (err) {
    console.warn("[download] fetchLatestRelease failed:", err);
    return emptyRelease();
  } finally {
    clearTimeout(timer);
  }
}

interface PickedRelease {
  release: GitHubReleasePayload;
  assets: DownloadAssets;
}

/**
 * Newest release whose desktop assets are all present. Falls back to the
 * newest release overall when no candidate is complete — the page then
 * shows what does exist plus its "all releases" escape hatch, which
 * still beats reporting no version at all.
 */
function pickRelease(
  candidates: GitHubReleasePayload[],
): PickedRelease | undefined {
  const parsed = candidates.map((release) => ({
    release,
    assets: parseReleaseAssets(release.assets ?? []),
  }));

  const complete = parsed.find((c) => hasCompleteAssetSet(c.assets));
  if (complete) {
    if (complete !== parsed[0]) {
      // Worth a line in the logs: a release that never completes its
      // asset set is invisible on /download until someone notices.
      console.warn(
        `[download] skipping ${parsed[0]?.release.tag_name ?? "latest release"}` +
          ` — incomplete desktop assets; showing ${complete.release.tag_name}`,
      );
    }
    return complete;
  }
  // During a rolling self-hosted release, the newest release can exist before
  // its desktop assets are uploaded. Keep serving the newest candidate that
  // has at least one usable installer instead of replacing working downloads
  // with disabled buttons while the build is in progress.
  const withAssets = parsed.find((c) => Object.keys(c.assets).length > 0);
  return withAssets ?? parsed[0];
}

function emptyRelease(): LatestRelease {
  return {
    version: null,
    publishedAt: null,
    htmlUrl: null,
    assets: {},
    sizes: {},
  };
}
