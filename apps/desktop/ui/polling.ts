/** Periodic async work with at most one request in flight and scoped results. */
export function pollEvery(
  milliseconds: number,
  task: (isActive: () => boolean) => Promise<void>,
  onError: (error: unknown) => void = () => {},
): () => void {
  let active = true;
  let pending = false;
  const tick = async () => {
    if (!active || pending) return;
    pending = true;
    try { await task(() => active); }
    catch (error) { if (active) onError(error); }
    finally { pending = false; }
  };
  const timer = setInterval(() => void tick(), milliseconds);
  return () => { active = false; clearInterval(timer); };
}
