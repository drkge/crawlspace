/** The fix descriptions' Markdown, shown as it would be in ClickUp. */
export function Markdown({ text, className = '' }: { text: string; className?: string }) {
  return <div className={`markdown ${className}`} dangerouslySetInnerHTML={{ __html: markdown(text) }} />
}

const escapeHTML = (text: string) => text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')

/** Enough Markdown for the descriptions: paragraphs, bullets, tables, headings, bold, italics, code and links. */
export function markdown(source: string): string {
  const inline = (text: string) =>
    escapeHTML(text)
      .replace(/\\\|/g, '|')
      .replace(/`([^`]+)`/g, '<code>$1</code>')
      .replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>')
      .replace(/(^|[^*])\*([^*\s][^*]*?)\*/g, '$1<em>$2</em>')
      .replace(/\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/g, '<a href="$2" target="_blank" rel="noopener noreferrer">$1</a>')
  const cells = (line: string) =>
    line
      .trim()
      .replace(/^\||\|$/g, '')
      .split(/(?<!\\)\|/)
      .map((cell) => cell.trim())
  const html: string[] = []
  const blocks = source.split(/\n{2,}/)
  for (const block of blocks) {
    const lines = block.split('\n')
    const tableStart = lines.findIndex((line) => line.trim().startsWith('|'))
    if (tableStart >= 0 && lines[tableStart + 1]?.match(/^\|?\s*-{3}/)) {
      if (tableStart > 0) html.push(`<p>${lines.slice(0, tableStart).map(inline).join('<br>')}</p>`)
      const head = cells(lines[tableStart])
      const rows = lines.slice(tableStart + 2).filter((line) => line.trim().startsWith('|')).map(cells)
      html.push(
        `<table class="simple"><thead><tr>${head.map((cell) => `<th>${inline(cell)}</th>`).join('')}</tr></thead><tbody>${rows
          .map((row) => `<tr>${row.map((cell) => `<td>${inline(cell)}</td>`).join('')}</tr>`)
          .join('')}</tbody></table>`,
      )
      continue
    }
    if (lines.some((line) => line.startsWith('- '))) {
      const lead = lines.filter((line) => !line.startsWith('- '))
      if (lead.length) html.push(`<p>${lead.map(inline).join('<br>')}</p>`)
      html.push(`<ul>${lines.filter((line) => line.startsWith('- ')).map((line) => `<li>${inline(line.slice(2))}</li>`).join('')}</ul>`)
      continue
    }
    if (block.startsWith('### ')) {
      html.push(`<h4>${inline(block.slice(4))}</h4>`)
      continue
    }
    html.push(`<p>${lines.map(inline).join('<br>')}</p>`)
  }
  return html.join('')
}
