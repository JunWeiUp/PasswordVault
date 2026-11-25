import { Events } from "passwordvault/native";

export type DesktopEventTopic = "hotkey" | "browser" | "ai" | "relay" | "status";

type Listener = {
  topic: DesktopEventTopic;
  active: boolean;
  running: boolean;
  dirty: boolean;
  handler: (isActive: () => boolean) => Promise<void> | void;
};

const listeners = new Set<Listener>();
let loopGeneration = 0;
let loopsRunning = false;

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function trigger(listener: Listener) {
  if (!listener.active) return;
  if (listener.running) {
    listener.dirty = true;
    return;
  }
  listener.running = true;
  void (async () => {
    try {
      do {
        listener.dirty = false;
        await listener.handler(() => listener.active);
      } while (listener.active && listener.dirty);
    } catch {
      // Individual subscribers surface their own errors; never break the event bus.
    } finally {
      listener.running = false;
    }
  })();
}

function dispatchTopics(topics: unknown) {
  if (!Array.isArray(topics) || topics.length === 0) return;
  const all = topics.includes("all");
  for (const listener of [...listeners]) {
    if (all || topics.includes(listener.topic)) {
      trigger(listener);
    }
  }
}

function runWaitLoop(
  gen: number,
  waitFn: (since: number, timeoutMs: number) => Promise<string>,
) {
  void (async () => {
    let rev = 0;
    while (gen === loopGeneration && listeners.size > 0) {
      let parsed: { rev?: number; topics?: string[]; disabled?: boolean; error?: boolean } = {};
      try {
        const raw = await waitFn(rev, 15_000);
        parsed = JSON.parse(raw || "{}");
      } catch {
        parsed = { error: true };
      }
      if (gen !== loopGeneration || listeners.size === 0) break;
      if (parsed.disabled) break;
      if (parsed.error) {
        await sleep(1000);
        continue;
      }
      if (typeof parsed.rev === "number" && parsed.rev !== rev) {
        rev = parsed.rev;
        dispatchTopics(parsed.topics);
      }
    }
  })();
}

function ensureLoops() {
  if (loopsRunning) return;
  loopsRunning = true;
  const gen = ++loopGeneration;
  if (typeof Events?.waitLocal === "function") {
    runWaitLoop(gen, (since, ms) => Events.waitLocal(since, ms));
  }
  if (typeof Events?.waitService === "function") {
    runWaitLoop(gen, (since, ms) => Events.waitService(since, ms));
  }
}

/**
 * Subscribe to a native desktop event topic (`hotkey`, `browser`, `ai`, `relay`, `status`).
 * Replaces high-frequency 200ms–1000ms polling with a single Condvar-backed long-poll.
 */
export function onDesktopEvent(
  topic: DesktopEventTopic,
  handler: (isActive: () => boolean) => Promise<void> | void,
  options?: { immediate?: boolean },
): () => void {
  const entry: Listener = { topic, active: true, running: false, dirty: false, handler };
  listeners.add(entry);
  ensureLoops();
  if (options?.immediate) {
    trigger(entry);
  }
  return () => {
    entry.active = false;
    listeners.delete(entry);
    if (listeners.size === 0) {
      loopsRunning = false;
      loopGeneration++;
    }
  };
}
