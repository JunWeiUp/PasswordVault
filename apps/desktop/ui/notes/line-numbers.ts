// Pure ProseMirror document line-anchor extraction and gutter geometry helpers
// for displaying editor-style logical line numbers inside RichEditor's contentLayer.
import type { Node } from "./model";

export type BoxRect = { x: number; y: number; width: number; height: number };

export type LineAnchor = {
  /** 1-based logical line number. */
  line: number;
  /** Primary document position to query geometry for. */
  pos: number;
  /** Document range [from, to] covered by this logical line (used for active-line highlighting). */
  from: number;
  to: number;
  /** Geometry query method for `pos`: caret line box or block node box. */
  measure: "caret" | "node";
  /** Optional fallback block position if `coordsAtPos(pos)` is unavailable. */
  fallbackNodePos?: number;
};

export type MeasuredLine = {
  line: number;
  top: number;
  height: number;
  from: number;
  to: number;
};

export type GutterMetrics = {
  digits: number;
  numberWidth: number;
  hairlineX: number;
  contentPaddingLeft: number;
};

const LEAF_NODES = new Set(["hardBreak", "horizontalRule", "vaultImage", "vaultAttachment", "image"]);
const TEXTBLOCK_NODES = new Set(["paragraph", "heading", "codeBlock"]);
const CONTAINER_NODES = new Set(["doc", "blockquote", "bulletList", "orderedList", "taskList", "listItem", "taskItem"]);

/** ProseMirror node size in UTF-16 code units (matching nsh-base's model::Node::node_size). */
export function nodeSize(node: Node): number {
  if (node.type === "text") return (node.text ?? "").length;
  if (LEAF_NODES.has(node.type)) return 1;
  let inner = 0;
  for (const child of node.content ?? []) inner += nodeSize(child);
  return inner + 2;
}

/** Finds the first textblock's opening content position inside a subtree (used to align table rows). */
function firstTextPosIn(node: Node, nodePos: number): number | null {
  if (TEXTBLOCK_NODES.has(node.type)) return nodePos + 1;
  if (LEAF_NODES.has(node.type) || node.type === "text") return null;
  let cursor = nodePos + 1;
  for (const child of node.content ?? []) {
    const found = firstTextPosIn(child, cursor);
    if (found !== null) return found;
    cursor += nodeSize(child);
  }
  return null;
}

/** Extracts logical line anchors in document order with exact ProseMirror positions. */
export function extractLineAnchors(doc: Node): LineAnchor[] {
  const out: LineAnchor[] = [];
  const push = (anchor: Omit<LineAnchor, "line">) => {
    out.push({ line: out.length + 1, ...anchor });
  };

  function collectTextblock(node: Node, blockPos: number) {
    const contentStart = blockPos + 1;
    let cursor = contentStart;
    let lineStart = contentStart;

    for (const child of node.content ?? []) {
      if (child.type === "hardBreak") {
        push({ pos: lineStart, from: lineStart, to: cursor, measure: "caret", fallbackNodePos: blockPos });
        cursor += 1;
        lineStart = cursor;
        continue;
      }
      if (child.type === "text") {
        const text = child.text ?? "";
        let idx = text.indexOf("\n");
        let segStart = 0;
        while (idx >= 0) {
          const breakPos = cursor + idx;
          push({ pos: lineStart, from: lineStart, to: breakPos, measure: "caret", fallbackNodePos: blockPos });
          segStart = idx + 1;
          lineStart = cursor + segStart;
          idx = text.indexOf("\n", segStart);
        }
        cursor += text.length;
        continue;
      }
      cursor += nodeSize(child);
    }

    push({ pos: lineStart, from: lineStart, to: cursor, measure: "caret", fallbackNodePos: blockPos });
  }

  function collectTable(table: Node, tablePos: number) {
    let rowPos = tablePos + 1;
    for (const row of table.content ?? []) {
      const size = nodeSize(row);
      if (row.type === "tableRow") {
        const textPos = firstTextPosIn(row, rowPos);
        if (textPos !== null) {
          push({ pos: textPos, from: rowPos, to: rowPos + size, measure: "caret", fallbackNodePos: rowPos });
        } else {
          push({ pos: rowPos, from: rowPos, to: rowPos + size, measure: "node" });
        }
      }
      rowPos += size;
    }
  }

  function visit(node: Node, pos: number, isRoot = false) {
    if (isRoot) {
      let cursor = 0;
      for (const child of node.content ?? []) {
        visit(child, cursor, false);
        cursor += nodeSize(child);
      }
      return;
    }
    if (TEXTBLOCK_NODES.has(node.type)) {
      collectTextblock(node, pos);
      return;
    }
    if (node.type === "table") {
      collectTable(node, pos);
      return;
    }
    if (CONTAINER_NODES.has(node.type)) {
      let cursor = pos + 1;
      for (const child of node.content ?? []) {
        visit(child, cursor, false);
        cursor += nodeSize(child);
      }
      return;
    }
    const size = nodeSize(node);
    push({ pos, from: pos, to: pos + size, measure: "node" });
  }

  visit(doc, 0, true);
  return out;
}

function asRect(raw: unknown): BoxRect | null {
  if (!raw || typeof raw !== "object") return null;
  const r = raw as Record<string, unknown>;
  if (typeof r.y !== "number" || typeof r.height !== "number" || !Number.isFinite(r.y) || !Number.isFinite(r.height)) {
    return null;
  }
  return {
    x: typeof r.x === "number" && Number.isFinite(r.x) ? r.x : 0,
    y: r.y,
    width: typeof r.width === "number" && Number.isFinite(r.width) ? r.width : 0,
    height: r.height,
  };
}

export type GeometryReader = {
  coordsAtPos(pos: number): unknown | null;
  nodeRect(pos: number): unknown | null;
};

/** Resolves exact y/height coordinates for each logical line anchor inside the content box. */
export function measureLineAnchors(
  anchors: LineAnchor[],
  reader: GeometryReader,
  defaultLineHeight: number,
): MeasuredLine[] {
  const out: MeasuredLine[] = [];
  const safeCaret = (pos: number): BoxRect | null => {
    try {
      return asRect(reader.coordsAtPos(pos));
    } catch {
      return null;
    }
  };
  const safeNode = (pos: number): BoxRect | null => {
    try {
      return asRect(reader.nodeRect(pos));
    } catch {
      return null;
    }
  };

  for (const anchor of anchors) {
    let rect: BoxRect | null = null;
    let isNodeBox = false;
    if (anchor.measure === "caret") {
      rect = safeCaret(anchor.pos);
      if (!rect && anchor.fallbackNodePos !== undefined) {
        rect = safeNode(anchor.fallbackNodePos);
        isNodeBox = true;
      }
    } else {
      rect = safeNode(anchor.pos);
      isNodeBox = true;
    }
    if (!rect) continue;

    let top = rect.y;
    let height = rect.height;
    if (isNodeBox) {
      // Align tall block atoms (e.g. images) to their top line, and give thin rules a readable box.
      if (height > defaultLineHeight * 1.35) {
        height = defaultLineHeight;
      } else if (height < defaultLineHeight * 0.7) {
        top = Math.max(0, rect.y + (rect.height - defaultLineHeight) / 2);
        height = defaultLineHeight;
      }
    } else if (height < 10) {
      height = defaultLineHeight;
    }

    // Prevent visual stacking when a trailing hardBreak shares the same y as the preceding line.
    const prev = out[out.length - 1];
    if (prev && Math.abs(top - prev.top) < 2) {
      prev.to = Math.max(prev.to, anchor.to);
      continue;
    }

    out.push({
      line: out.length + 1,
      top: Math.round(top * 2) / 2,
      height: Math.round(height * 2) / 2,
      from: anchor.from,
      to: anchor.to,
    });
  }
  return out;
}

/** Checks whether two measured line lists are visually indistinguishable (avoids redundant renders). */
export function sameMeasuredLines(a: MeasuredLine[], b: MeasuredLine[]): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) {
    if (
      a[i].line !== b[i].line ||
      Math.abs(a[i].top - b[i].top) >= 0.5 ||
      Math.abs(a[i].height - b[i].height) >= 0.5 ||
      a[i].from !== b[i].from ||
      a[i].to !== b[i].to
    ) {
      return false;
    }
  }
  return true;
}

/** Computes scaled gutter geometry that widens automatically for 3+ digit documents. */
export function gutterMetrics(lineCount: number, scale: (n: number) => number): GutterMetrics {
  const digits = Math.max(2, String(Math.max(1, lineCount)).length);
  const numberWidth = Math.ceil(digits * scale(7.5)) + 10;
  const hairlineX = numberWidth + 8;
  const contentPaddingLeft = hairlineX + 12;
  return { digits, numberWidth, hairlineX, contentPaddingLeft };
}

/** Returns the 1-based line number containing document position `pos`, or null if none. */
export function activeLineAt(lines: MeasuredLine[], pos: number | null): number | null {
  if (pos === null || lines.length === 0) return null;
  for (const row of lines) {
    if (pos >= row.from && pos <= row.to) return row.line;
  }
  let best = lines[0];
  for (const row of lines) {
    if (row.from <= pos) best = row;
    else break;
  }
  return best.line;
}
