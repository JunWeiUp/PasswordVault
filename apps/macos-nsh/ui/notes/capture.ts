/** Pull native editor state synchronously before saving, hiding or locking. */
const captures = new Set<() => void>();
export function registerNoteCapture(capture: () => void) {
  captures.add(capture);
  return () => { captures.delete(capture); };
}
export function captureNotes() { for (const capture of captures) capture(); }
