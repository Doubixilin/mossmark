export interface PaginationInterval {
  top: number;
  bottom: number;
}

export function calculatePageBreaks(
  contentHeight: number,
  pageHeight: number,
  intervals: PaginationInterval[],
  safetyPadding = 2,
): number[] {
  if (
    !Number.isFinite(contentHeight) ||
    !Number.isFinite(pageHeight) ||
    contentHeight <= 0 ||
    pageHeight <= 0
  ) {
    return [0];
  }

  const breaks = [0];
  let pageStart = 0;
  while (pageStart + pageHeight < contentHeight) {
    const idealBreak = pageStart + pageHeight;
    const crossing = intervals.filter(
      (interval) =>
        interval.top - safetyPadding < idealBreak &&
        interval.bottom + safetyPadding > idealBreak,
    );
    let pageEnd = crossing.length
      ? Math.max(...crossing.map((interval) => interval.top)) - safetyPadding
      : idealBreak;

    // An indivisible item can be taller than a page. In that case a hard cut
    // is unavoidable; keep making progress rather than producing a blank page.
    if (pageEnd - pageStart < pageHeight * 0.5) {
      pageEnd = idealBreak;
    }
    pageEnd = Math.min(contentHeight, Math.max(pageStart + 1, pageEnd));
    breaks.push(pageEnd);
    pageStart = pageEnd;
  }

  if ((breaks[breaks.length - 1] ?? 0) < contentHeight) {
    breaks.push(contentHeight);
  }
  return breaks;
}
