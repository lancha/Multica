// @vitest-environment node
import { afterEach, expect, it } from "vitest";
import { useSearchStore } from "../command-bar/search-store";

afterEach(() => useSearchStore.setState({ open: false }));

it("owns the shared search dialog state without platform dependencies", () => {
  expect(useSearchStore.getState().open).toBe(false);
  useSearchStore.getState().toggle();
  expect(useSearchStore.getState().open).toBe(true);
  useSearchStore.getState().setOpen(false);
  expect(useSearchStore.getState().open).toBe(false);
});
