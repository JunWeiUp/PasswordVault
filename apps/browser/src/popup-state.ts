// Popup presentation helpers kept free of DOM and extension APIs for tests.
export type SyncTone = "pending" | "off" | "done";
/** Pending work is orange, a disconnected Mac with nothing pending is neutral, otherwise green. */
export function syncTone(state: { queued?: number; available?: boolean }): SyncTone {
  if (state.queued) return "pending";
  return state.available === false ? "off" : "done";
}
