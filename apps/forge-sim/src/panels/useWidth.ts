import { useLayoutEffect, useState, type RefObject } from 'react';

/** The element's width in CSS pixels, so a chart draws at 1:1 and its text stays legible at any width. */
export function useWidth(ref: RefObject<HTMLElement | null>, fallback: number): number {
  const [w, setW] = useState(fallback);
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const measure = () => setW(Math.max(280, Math.round(el.getBoundingClientRect().width)));
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, [ref]);
  return w;
}

/** Estimated width of `text` in the 11px chart mono font. */
export const textWidth = (text: string) => text.length * 6.7;

/**
 * Greedy label placement: each label takes the first of `rows` lanes where its [left, right]
 * span clears every label already in that lane by `gap`, or is dropped. Earlier items win.
 */
export function placeLabels<T>(items: T[], span: (t: T) => [number, number], rows: number, gap = 6) {
  const lanes: [number, number][][] = Array.from({ length: rows }, () => []);
  const out: { item: T; row: number }[] = [];
  for (const t of items) {
    const [l, r] = span(t);
    const row = lanes.findIndex((lane) => lane.every(([a, b]) => r + gap <= a || l >= b + gap));
    if (row < 0) continue;
    lanes[row].push([l, r]);
    out.push({ item: t, row });
  }
  return out;
}
