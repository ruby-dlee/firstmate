function initialIndent(line, offset = 0) {
  return (line.slice(offset).match(/^ {0,3}/) || [""])[0].length;
}

function containerCandidate(line) {
  let prefixIndent = initialIndent(line);
  let offset = prefixIndent;
  const containers = [];
  while (offset < line.length) {
    const rest = line.slice(offset);
    const blockquote = rest.match(/^>[ \t]?/);
    if (blockquote) {
      containers.push({ type: "blockquote" });
      offset += blockquote[0].length;
      prefixIndent = initialIndent(line, offset);
      offset += prefixIndent;
      continue;
    }
    const list = rest.match(/^((?:[*+-]|\d{1,9}[.)]))([ \t]{1,4})/);
    if (!list) break;
    containers.push({ type: "list", indent: prefixIndent + list[0].length });
    offset += list[0].length;
    prefixIndent = initialIndent(line, offset);
    offset += prefixIndent;
  }
  return { text: line.slice(offset), containers };
}

function scopedLine(line, containers) {
  if (containers.length === 0) return { text: line };
  if (/^[ \t]*$/.test(line)) {
    return containers.every(({ type }) => type === "list") ? { text: "" } : undefined;
  }
  let offset = 0;
  for (const container of containers) {
    if (container.type === "blockquote") {
      offset += initialIndent(line, offset);
      const match = line.slice(offset).match(/^>[ \t]?/);
      if (!match) return undefined;
      offset += match[0].length;
      offset += initialIndent(line, offset);
      continue;
    }
    let columns = 0;
    while (offset < line.length && columns < container.indent) {
      if (line[offset] === " ") {
        offset += 1;
        columns += 1;
      } else if (line[offset] === "\t") {
        offset += 1;
        columns += 4 - (columns % 4);
      } else {
        break;
      }
    }
    if (columns < container.indent) return undefined;
  }
  return { text: line.slice(offset) };
}

function activeListScope(line, containers) {
  for (let length = containers.length; length > 0; length -= 1) {
    const active = containers.slice(0, length);
    const scoped = scopedLine(line, active);
    if (scoped) return { containers: active, text: scoped.text };
  }
  return undefined;
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
  let lazyList;
  for (const line of String(markdown).split(/\r?\n/)) {
    let consumed = false;
    while (!consumed) {
      if (htmlBlock) {
        const scoped = scopedLine(line, htmlBlock.containers);
        if (!scoped) {
          htmlBlock = undefined;
          continue;
        }
        if (htmlBlock.blank) {
          if (/^[ \t]*$/.test(scoped.text)) htmlBlock = undefined;
        } else if (htmlBlock.end.test(scoped.text)) {
          htmlBlock = undefined;
        }
        paragraphOpen = false;
        consumed = true;
        continue;
      }
      if (fence) {
        const scoped = scopedLine(line, fence.containers);
        if (!scoped) {
          fence = undefined;
          continue;
        }
        const closing = fenceMarker(scoped.text);
        if (closing && closing.character === fence.character
          && closing.length >= fence.length && closing.suffix.trim() === "") {
          fence = undefined;
        }
        paragraphOpen = false;
        consumed = true;
        continue;
      }

      const candidate = containerCandidate(line);
      const activeList = lazyList && !/^[ \t]*$/.test(line) ? activeListScope(line, lazyList) : undefined;
      const nestedCandidate = activeList ? containerCandidate(activeList.text) : undefined;
      const lazyListContinuation = Boolean(activeList);
      const activeCandidate = activeList
        ? { text: nestedCandidate.text, containers: [...activeList.containers, ...nestedCandidate.containers] }
        : candidate;
      if (!activeList && candidate.containers.length === 0 && /^(?: {4}|\t)/.test(line)) {
        visible.push({ line, heading: undefined });
        paragraphOpen = false;
        consumed = true;
        continue;
      }
      const marker = fenceMarker(activeCandidate.text);
      if (marker) {
        fence = {
          character: marker.character,
          length: marker.length,
          containers: activeCandidate.containers,
        };
        paragraphOpen = false;
        consumed = true;
        continue;
      }
      const htmlOpening = htmlBlockStart(activeCandidate.text, paragraphOpen && activeCandidate.containers.length === 0);
      if (htmlOpening) {
        const htmlStart = { ...htmlOpening, containers: activeCandidate.containers };
        if (htmlStart.blank || !htmlStart.end.test(activeCandidate.text.slice(activeCandidate.text.indexOf("<") + 1))) {
          htmlBlock = htmlStart;
        }
        paragraphOpen = false;
        consumed = true;
        continue;
      }
      const parsedHeading = activeCandidate.containers.length === 0 ? heading(activeCandidate.text) : undefined;
      visible.push({ line, heading: lazyListContinuation ? undefined : parsedHeading });
      if (activeCandidate.containers.some(({ type }) => type === "list")) {
        lazyList = activeCandidate.containers;
      } else if (!lazyListContinuation && !/^[ \t]*$/.test(line)) {
        lazyList = undefined;
      }
      paragraphOpen = !(/^[ \t]*$/.test(candidate.text) || heading(candidate.text));
      consumed = true;
    }
  }
  return visible;
}

module.exports = { markdownStructure };
