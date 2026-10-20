const SECTION = /^\s*(?:#+\s*|\*\*)?(Needs you|Done|Running)\b/i

/**
 * True when a reply's "Needs you" section lists anything other than "Nothing"/"None".
 * The Orchestrator's Summary is three sections; only that one asks the human to act.
 */
export const needsHuman = (text: string): boolean => {
  let inNeedsYou = false
  for (const line of text.split('\n')) {
    const section = SECTION.exec(line)
    if (section) {
      inNeedsYou = section[1]?.toLowerCase() === 'needs you'
      const rest = line.slice(section[0].length).replace(/^[*:\s-]+/, '').trim()
      if (inNeedsYou && rest && !/^(nothing|none)\b/i.test(rest)) return true
      continue
    }
    const item = /^\s*(?:[-*]|\d+\.)\s+(.*)$/.exec(line)
    if (inNeedsYou && item && !/^(nothing|none)\b/i.test(item[1]?.trim() ?? '')) return true
  }
  return false
}
