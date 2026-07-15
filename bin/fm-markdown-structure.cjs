function listContainerCandidate(line) {
  let offset = 0;
  let found = false;
  const initial = line.match(/^ {0,3}/)[0].length;
  offset += initial;
  while (offset < line.length) {
    const rest = line.slice(offset);
    const blockquote = rest.match(/^>[ \t]?/);
    if (blockquote) {
      offset += blockquote[0].length;
      offset += (line.slice(offset).match(/^ {0,3}/) || [""])[0].length;
      continue;
    }
    const list = rest.match(/^(?:[*+-]|\d{1,9}[.)])([ \t]{1,4})/);
    if (!list) break;
    found = true;
    offset += list[0].length;
    offset += (line.slice(offset).match(/^ {0,3}/) || [""])[0].length;
  }
  return found ? { text: line.slice(offset), indent: offset } : undefined;
}

function fenceMarker(line) {
  const match = line.match(/^ {0,3}(`{3,}|~{3,})(.*)$/);
  if (!match || (match[1][0] === "`" && match[2].includes("`"))) return undefined;
  return { character: match[1][0], length: match[1].length, suffix: match[2] };
}

function heading(line) {
  const match = line.match(/^ {0,3}(#{1,6})(?:[ \t]+(.*)|[ \t]*)$/);
  if (!match) return undefined;
  return {
    level: match[1].length,
    content: (match[2] || "").replace(/[ \t]+#+[ \t]*$/, "").trim(),
  };
}

function markdownStructure(markdown) {
  const visible = [];
  let fence;
  for (const line of String(markdown).split(/\r?\n/)) {
    const container = listContainerCandidate(line);
    const candidates = [{ text: line, indent: 0 }];
    if (container) candidates.push(container);
    if (fence && fence.indent > 0 && /^ +/.test(line)) {
      const spaces = line.match(/^ +/)[0].length;
      if (spaces >= fence.indent) candidates.push({ text: line.slice(fence.indent), indent: fence.indent });
    }

    if (fence) {
      const closing = candidates.map(({ text }) => fenceMarker(text)).find((marker) => marker
        && marker.character === fence.character
        && marker.length >= fence.length
        && marker.suffix.trim() === "");
      if (closing) fence = undefined;
      continue;
    }

    const opening = candidates.map(({ text, indent }) => ({ marker: fenceMarker(text), indent }))
      .find(({ marker }) => marker);
    if (opening) {
      fence = {
        character: opening.marker.character,
        length: opening.marker.length,
        indent: opening.indent,
      };
      continue;
    }
    visible.push({ line, heading: heading(line) });
  }
  return visible;
}

module.exports = { markdownStructure };
