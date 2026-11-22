package main

import (
	"context"
	"log/slog"
	"time"

	"github.com/multica-ai/multica/server/internal/handler"
)

const defaultModelCatalogRefreshInterval = 24 * time.Hour

// runPeriodicModelCatalogRefresh keeps runtime catalogs warm even when nobody
// opens the model picker. Discovery is metadata-only and reuses the handler's
// pending-work queue and last-known-good cache.
func runPeriodicModelCatalogRefresh(ctx context.Context, h *handler.Handler, interval time.Duration) {
	if h == nil || interval <= 0 {
		return
	}
	refresh := func() {
		h.RefreshOnlineProviderModelCatalogs(ctx, "codex")
	}
	refresh()
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			slog.Debug("running periodic runtime model catalog refresh", "provider", "codex")
			refresh()
		}
	}
}
