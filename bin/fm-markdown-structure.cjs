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

const htmlBlockTags = "address|article|aside|base|basefont|blockquote|body|caption|center|col|colgroup|dd|details|dialog|dir|div|dl|dt|fieldset|figcaption|figure|footer|form|frame|frameset|h1|h2|h3|h4|h5|h6|head|header|hr|html|iframe|legend|li|link|main|menu|menuitem|nav|noframes|ol|optgroup|option|p|param|search|section|summary|table|tbody|td|tfoot|th|thead|title|tr|track|ul";
const htmlBlockTagPattern = new RegExp(`^ {0,3}</?(?:${htmlBlockTags})(?:[ \\t]+|/?>|$)`, "i");
const completeOpenTagPattern = /^ {0,3}<[A-Za-z][A-Za-z0-9-]*(?:[ \t]+[A-Za-z_:][A-Za-z0-9_.:-]*(?:[ \t]*=[ \t]*(?:[^ "'=<>`]+|'[^']*'|"[^"]*"))?)*[ \t]*\/?>(?:[ \t]*)$/;
const completeClosingTagPattern = /^ {0,3}<\/[A-Za-z][A-Za-z0-9-]*[ \t]*>(?:[ \t]*)$/;

function htmlBlockStart(line, paragraphOpen) {
  const script = line.match(/^ {0,3}<(script|pre|style|textarea)(?:[ \t]|>|$)/i);
  if (script) return { end: new RegExp(`</${script[1]}[ \\t]*>`, "i") };
  if (/^ {0,3}<!--/.test(line)) return { end: /-->/ };
  if (/^ {0,3}<\?/.test(line)) return { end: /\?>/ };
  if (/^ {0,3}<![A-Z]/.test(line)) return { end: />/ };
  if (/^ {0,3}<!\[CDATA\[/.test(line)) return { end: /\]\]>/ };
  if (htmlBlockTagPattern.test(line)) return { blank: true };
  if (!paragraphOpen && (completeOpenTagPattern.test(line) || completeClosingTagPattern.test(line))) return { blank: true };
  return undefined;
}

function markdownStructure(markdown) {
  const visible = [];
  let fence;
  let htmlBlock;
  let paragraphOpen = false;
  for (const line of String(markdown).split(/\r?\n/)) {
    if (htmlBlock) {
      if (htmlBlock.blank) {
        if (/^[ \t]*$/.test(line)) htmlBlock = undefined;
      } else if (htmlBlock.end.test(line)) {
        htmlBlock = undefined;
      }
      paragraphOpen = false;
      continue;
    }
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
      paragraphOpen = false;
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
      paragraphOpen = false;
      continue;
    }
    const htmlStart = htmlBlockStart(line, paragraphOpen);
    if (htmlStart) {
      if (htmlStart.blank || !htmlStart.end.test(line.slice(line.indexOf("<") + 1))) htmlBlock = htmlStart;
      paragraphOpen = false;
      continue;
    }
    const parsedHeading = heading(line);
    visible.push({ line, heading: parsedHeading });
    if (/^[ \t]*$/.test(line) || parsedHeading) {
      paragraphOpen = false;
    } else {
      paragraphOpen = true;
    }
  }
  return visible;
}

module.exports = { markdownStructure };
