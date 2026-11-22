"use client";

import { useEffect, useState } from "react";
import Link from "next/link";

type Status = {
  health: { status: "healthy" | "unavailable"; commit?: string };
  release: {
    version: string | null;
    publishedAt: string | null;
    macArm64: boolean;
    macX64: boolean;
    macStatus: "published" | "building" | "waiting";
  };
};

export function DesktopReleaseStatus() {
  const [status, setStatus] = useState<Status | null>(null);

  useEffect(() => {
    let cancelled = false;
    fetch("/api/desktop-status", { headers: { Accept: "application/json" } })
      .then((response) => (response.ok ? response.json() : null))
      .then((payload: Status | null) => {
        if (!cancelled && payload) setStatus(payload);
      })
      .catch(() => undefined);
    return () => {
      cancelled = true;
    };
  }, []);

  if (!status) return null;

  const platformCount = Number(status.release.macArm64) + Number(status.release.macX64);
  const releaseLabel = status.release.version ?? "暂无正式版本";
  const healthLabel = status.health.status === "healthy" ? "服务正常" : "服务检查中";
  const buildLabel =
    status.release.macStatus === "published"
      ? "Mac App 已发布"
      : status.release.macStatus === "building"
        ? "Mac App 构建中"
        : "等待 Mac 构建";

  return (
    <section className="border-y border-[#0a0d12]/10 bg-[#f7f7f4] px-4 py-8 text-[#0a0d12] sm:px-6 lg:px-8">
      <div className="mx-auto flex max-w-[1120px] flex-wrap items-center justify-between gap-5">
        <div>
          <p className="text-label uppercase tracking-[0.14em] text-[#0a0d12]/50">本地化发布状态</p>
          <p className="mt-2 text-title font-medium">{releaseLabel}</p>
          <p className="mt-1 text-body-sm text-[#0a0d12]/60">
            {healthLabel} · {buildLabel} · 已提供 {platformCount} 个 Mac 架构安装包
            {status.health.commit ? ` · ${status.health.commit.slice(0, 8)}` : ""}
          </p>
        </div>
        <Link href="/download" className="rounded-full bg-[#0a0d12] px-5 py-3 text-label font-medium text-white transition hover:bg-[#252a31]">
          下载 Mac App
        </Link>
      </div>
    </section>
  );
}
