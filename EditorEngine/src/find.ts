// Counts literal (non-regex) occurrences of query in text. Shared by the
// native find bar (mossmarkCountMatches) and kept pure so it is testable
// without a DOM.
export function countOccurrences(
  text: string,
  query: string,
  caseSensitive = false,
): number {
  if (query === "") return 0;
  const haystack = caseSensitive ? text : text.toLowerCase();
  const needle = caseSensitive ? query : query.toLowerCase();
  let count = 0;
  let index = haystack.indexOf(needle);
  while (index !== -1) {
    count += 1;
    index = haystack.indexOf(needle, index + needle.length);
  }
  return count;
}
