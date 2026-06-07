// Bound how long an upstream call (Qwen story gen, ElevenLabs TTS) may take, so a hung or
// pathologically slow dependency can never hold a request open indefinitely. A timed-out call
// rejects with TimeoutError, which the callers treat as a (retryable / gracefully-degraded)
// failure rather than hanging. Pure and unit-testable.

export class TimeoutError extends Error {
  constructor(ms: number) {
    super(`timed out after ${ms}ms`);
    this.name = "TimeoutError";
  }
}

// Runs `work()` but rejects with TimeoutError if it hasn't settled within `ms`. A non-positive
// `ms` disables the timeout (returns the work unchanged).
export function withTimeout<T>(work: () => Promise<T>, ms: number): Promise<T> {
  if (!ms || ms <= 0) return work();
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new TimeoutError(ms)), ms);
    work().then(
      (v) => {
        clearTimeout(timer);
        resolve(v);
      },
      (e) => {
        clearTimeout(timer);
        reject(e);
      },
    );
  });
}
