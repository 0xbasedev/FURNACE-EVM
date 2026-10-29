import { useEffect, useRef, useState } from 'react';
import type { SealRequest, SealWire, WorkerRequest } from './worker';
import type { TimelineInput, TimelineResult } from './engine/timeline';

type Reply =
  | { id: number; type: 'seal'; result: SealWire[] }
  | { id: number; type: 'timeline'; result: TimelineResult }
  | { id: number; type: 'error'; error: string };

let worker: Worker | undefined;
let nextId = 1;
const listeners = new Map<number, (r: Reply) => void>();

function getWorker(): Worker {
  if (!worker) {
    worker = new Worker(new URL('./worker.ts', import.meta.url), { type: 'module' });
    worker.onmessage = (ev: MessageEvent<Reply>) => {
      listeners.get(ev.data.id)?.(ev.data);
      listeners.delete(ev.data.id);
    };
  }
  return worker;
}

/**
 * Latest-wins request hook: each new `input` supersedes the last; a stale reply is
 * dropped. While a request runs, the previous result stays on screen (`busy` dims it).
 */
function useWorkerResult<I, R>(type: 'seal' | 'timeline', input: I | undefined, delayMs = 120) {
  const [result, setResult] = useState<R>();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string>();
  const latest = useRef(0);
  const key = JSON.stringify(input);
  useEffect(() => {
    if (input === undefined) return;
    const timer = setTimeout(() => {
      const id = nextId++;
      latest.current = id;
      setBusy(true);
      listeners.set(id, (r) => {
        if (latest.current !== id) return;
        setBusy(false);
        if (r.type === 'error') setError(r.error);
        else {
          setError(undefined);
          setResult(r.result as R);
        }
      });
      getWorker().postMessage({ id, type, input } as WorkerRequest);
    }, delayMs);
    return () => clearTimeout(timer);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key]);
  return { result, busy, error };
}

export const useSealProjection = (input: SealRequest | undefined) => useWorkerResult<SealRequest, SealWire[]>('seal', input);
export const useTimeline = (input: TimelineInput | undefined) => useWorkerResult<TimelineInput, TimelineResult>('timeline', input, 250);
