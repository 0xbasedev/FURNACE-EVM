import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from 'react';
import gsap from 'gsap';

export const reducedMotion = (): boolean =>
  typeof window !== 'undefined' && window.matchMedia?.('(prefers-reduced-motion: reduce)').matches === true;

/** A number that tweens to each new value (writes the DOM directly: no re-render per frame). */
export function Num({ value, format, duration = 0.6, className }: {
  value: number; format: (n: number) => string; duration?: number; className?: string;
}) {
  const ref = useRef<HTMLSpanElement>(null);
  const state = useRef({ n: value });
  const fmtRef = useRef(format);
  fmtRef.current = format;
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    if (reducedMotion() || !Number.isFinite(value)) {
      state.current.n = value;
      el.textContent = format(value);
      return;
    }
    const tween = gsap.to(state.current, {
      n: value,
      duration,
      ease: 'power3.out',
      onUpdate: () => { el.textContent = fmtRef.current(state.current.n); },
    });
    return () => { tween.kill(); };
  }, [value, duration]); // eslint-disable-line react-hooks/exhaustive-deps
  return <span ref={ref} className={className}>{format(state.current.n)}</span>;
}

/**
 * Press and hold to confirm: friction for an irreversible, costly action. Releasing
 * early drains the bar; completing calls `onConfirm`. Keyboard: hold Space or Enter.
 */
export function HoldButton({ seconds = 1.6, onConfirm, children, label }: {
  seconds?: number; onConfirm: () => void; children: ReactNode; label: string;
}) {
  const fill = useRef<HTMLSpanElement>(null);
  const tween = useRef<gsap.core.Tween | undefined>(undefined);
  const [armed, setArmed] = useState(false);
  const start = () => {
    tween.current?.kill();
    tween.current = gsap.to(fill.current, {
      scaleX: 1,
      duration: reducedMotion() ? 0.01 : seconds,
      ease: 'none',
      onStart: () => setArmed(true),
      onComplete: () => {
        onConfirm();
        gsap.to(fill.current, { scaleX: 0, duration: 0.4, delay: 0.3, onComplete: () => setArmed(false) });
      },
    });
  };
  const stop = () => {
    if (!tween.current || tween.current.progress() >= 1) return;
    tween.current.kill();
    gsap.to(fill.current, { scaleX: 0, duration: 0.25, ease: 'power2.out', onComplete: () => setArmed(false) });
  };
  return (
    <button
      type="button"
      className={`hold${armed ? ' armed' : ''}`}
      aria-label={label}
      onPointerDown={start}
      onPointerUp={stop}
      onPointerLeave={stop}
      onPointerCancel={stop}
      onKeyDown={(e) => { if ((e.key === ' ' || e.key === 'Enter') && !e.repeat) { e.preventDefault(); start(); } }}
      onKeyUp={(e) => { if (e.key === ' ' || e.key === 'Enter') stop(); }}
    >
      <span className="fill" ref={fill} aria-hidden="true" />
      <span className="lbl">{children}</span>
    </button>
  );
}

/** One orchestrated entrance: panels rise from a visible resting state, staggered. */
export function useEntrance(selector: string) {
  useEffect(() => {
    if (reducedMotion()) return;
    const ctx = gsap.context(() => {
      gsap.from(selector, { y: 14, opacity: 0.35, duration: 0.7, ease: 'power3.out', stagger: 0.07, clearProps: 'transform,opacity' });
    });
    return () => ctx.revert();
  }, [selector]);
}
