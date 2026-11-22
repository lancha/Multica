"use client";

import { createContext, use } from "react";

export interface OpenAtOptions {
  /** Keep an explicitly requested file visible if it fails to load. */
  stayOnError?: boolean;
}

export interface PreviewSequenceApi {
  /**
   * Open the shared viewer at `key` — the attachment id, or the URL as written
   * in the body for references that don't resolve to a record.
   *
   * Returns false when no provider is mounted or the key is not part of this
   * surface's sequence, so callers can fall back to a single-file preview.
   */
  openAt: (key: string, options?: OpenAtOptions) => boolean;
}

const NO_SEQUENCE: PreviewSequenceApi = { openAt: () => false };

export const PreviewSequenceContext = createContext<PreviewSequenceApi>(NO_SEQUENCE);

/**
 * Returns the surrounding surface's viewer, or a no-op handle when there is
 * no provider. Always safe to call — `openAt` reporting false is the
 * documented "not part of a sequence" answer, not a failure.
 */
export function usePreviewSequence(): PreviewSequenceApi {
  return use(PreviewSequenceContext);
}
