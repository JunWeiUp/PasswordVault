import { Editor, Node, mergeAttributes } from "@tiptap/core";
import StarterKit from "@tiptap/starter-kit";
import { TextStyle, Color } from "@tiptap/extension-text-style";
import Highlight from "@tiptap/extension-highlight";
import TextAlign from "@tiptap/extension-text-align";
import { TableKit } from "@tiptap/extension-table";
import TaskList from "@tiptap/extension-task-list";
import TaskItem from "@tiptap/extension-task-item";
import { Markdown } from "@tiptap/markdown";
import { EditorState, Plugin } from "@tiptap/pm/state";
import { Decoration, DecorationSet } from "@tiptap/pm/view";
import DOMPurify from "dompurify";

let editor,
  token = "",
  source = "",
  revision = 0,
  sequence = -1,
  editable = false,
  editing = false;
let initialized = false,
  suppress = false,
  sealed = false,
  chinese = true,
  layoutID = 0,
  frame = 0;
let search = "",
  matchIndex = -1,
  uploadID = 0,
  pendingUploads = new Map(),
  retryFiles = [];
const post = (body) =>
  window.webkit?.messageHandlers?.noteEditor?.postMessage({ ...body, token });
const t = (zh, en) => (chinese ? zh : en);
const stable = (value) =>
  JSON.stringify(value, (_key, v) =>
    v && typeof v === "object" && !Array.isArray(v)
      ? Object.keys(v)
          .sort()
          .reduce((out, k) => ((out[k] = v[k]), out), {})
      : v,
  );
const summaryText = () =>
  editor.state.doc.textBetween(
    0,
    editor.state.doc.content.size,
    "\n",
    (node) => node.attrs.caption || node.attrs.name || "",
  );
const snapshotSource = () =>
  stable({
    format: "rich-v1",
    document: editor.getJSON(),
    text: summaryText(),
  });
const textNode = (text) => (text ? [{ type: "text", text }] : []);
const plainDoc = (text) => ({
  type: "doc",
  content: text
    .split("\n")
    .map((line) => ({ type: "paragraph", content: textNode(line) })),
});
function importMarkdown(text) {
  // Preserve unsupported HTML/remote images as visible literal blocks, not executable DOM.
  let fenced = false;
  return text
    .split("\n")
    .map((line) => {
      if (/^\s*(```|~~~)/.test(line)) {
        fenced = !fenced;
        return line;
      }
      if (
        !fenced &&
        (/<\/?[a-z!][^>]*>/i.test(line) ||
          /^\s*\[\^[^\]]+\]:/.test(line) ||
          /!\[[^\]]*\]\([^)]+\)/.test(line))
      )
        return "\n````text\n" + line + "\n````\n";
      return line;
    })
    .join("\n");
}

const safeURL = (value) => /^(https?:\/\/|mailto:)/i.test(value);
const resourceURL = (id) => `pvnote://${token}/${encodeURIComponent(id)}`;

const VaultImage = Node.create({
  name: "vaultImage",
  group: "block",
  atom: true,
  draggable: true,
  addAttributes: () => ({
    attachmentId: { default: "" },
    name: { default: "" },
    mime: { default: "image/png" },
    width: { default: 600 },
    caption: { default: "" },
  }),
  parseHTML: () => [],
  renderHTML({ node, HTMLAttributes }) {
    return [
      "figure",
      mergeAttributes(HTMLAttributes, { "data-vault-image": "" }),
      [
        "img",
        {
          src: resourceURL(node.attrs.attachmentId),
          alt: node.attrs.caption || node.attrs.name,
          width: node.attrs.width,
          draggable: "false",
        },
      ],
      ["figcaption", {}, node.attrs.caption || node.attrs.name],
    ];
  },
  renderMarkdown: (node) =>
    `![${node.attrs.caption || node.attrs.name}](attachments/${node.attrs.attachmentId})`,
});
const VaultAttachment = Node.create({
  name: "vaultAttachment",
  group: "block",
  atom: true,
  draggable: true,
  addAttributes: () => ({
    attachmentId: { default: "" },
    name: { default: "" },
    mime: { default: "application/octet-stream" },
    size: { default: 0 },
  }),
  parseHTML: () => [],
  renderHTML({ node }) {
    return [
      "div",
      {
        "data-vault-attachment": node.attrs.attachmentId,
        class: "attachment",
        contenteditable: "false",
      },
      ["strong", {}, node.attrs.name],
      [
        "span",
        {},
        node.attrs.size < 1024
          ? `${node.attrs.size} B`
          : `${(node.attrs.size / 1024).toFixed(1)} KB`,
      ],
    ];
  },
  renderMarkdown: (node) =>
    `[${node.attrs.name}](attachments/${node.attrs.attachmentId})`,
});
const toolbar = document.createElement("div");
toolbar.className = "toolbar";
toolbar.setAttribute("role", "toolbar");
const bubble = document.createElement("div");
bubble.className = "bubble";
bubble.setAttribute("role", "toolbar");
bubble.hidden = true;
const context = document.createElement("div");
context.className = "context";
context.hidden = true;
const findBar = document.createElement("div");
findBar.className = "findbar";
findBar.hidden = true;
const notice = document.createElement("div");
notice.className = "notice";
notice.setAttribute("role", "status");
notice.hidden = true;
const stats = document.createElement("div");
stats.className = "stats";
document.querySelector("#editor").before(toolbar, findBar, notice, context);
document.body.append(bubble, stats);
const controls = [];
function button(
  parent,
  zh,
  en,
  action,
  run,
  enabled = () => editable && editing,
  active = () => false,
) {
  const b = document.createElement("button");
  b.type = "button";
  b.dataset.action = action;
  b.textContent = t(zh, en);
  b.title = b.textContent;
  b.setAttribute("aria-label", b.textContent);
  b.addEventListener("mousedown", (e) => e.preventDefault());
  b.addEventListener("click", () => {
    if (!b.disabled) {
      run();
      for (const menu of toolbar.querySelectorAll("details[open]"))
        menu.open = false;
      status();
    }
  });
  parent.append(b);
  controls.push({ b, zh, en, enabled, active });
  return b;
}
function error(message) {
  notice.textContent = message;
  notice.hidden = false;
  measure();
}
function clearNotice() {
  notice.hidden = true;
  notice.replaceChildren();
}
const chain = () => editor.chain().focus();
const commandButton = (parent, zh, en, name, args = [], active = name) =>
  button(
    parent,
    zh,
    en,
    name,
    () =>
      chain()
        [name](...args)
        .run(),
    () => editable && editing && editor.can()[name](...args),
    () => editor.isActive(active),
  );
function group(label) {
  const el = document.createElement("span");
  el.className = "toolgroup";
  el.setAttribute("aria-label", label);
  toolbar.append(el);
  return el;
}
function menu(zh, en) {
  const details = document.createElement("details");
  const summary = document.createElement("summary");
  summary.textContent = t(zh, en);
  details.append(summary);
  const panel = document.createElement("div");
  panel.className = "toolmenu";
  details.append(panel);
  toolbar.append(details);
  details.addEventListener("toggle", () => {
    if (details.open) {
      const left = details.getBoundingClientRect().left;
      panel.style.left = `${Math.min(0, innerWidth - left - 300)}px`;
      panel.style.right = "auto";
    }
    layout();
  });
  controls.push({
    b: summary,
    zh,
    en,
    enabled: () => true,
    active: () => false,
  });
  return panel;
}
const historyGroup = group("History");
commandButton(historyGroup, "撤销", "Undo", "undo");
commandButton(historyGroup, "重做", "Redo", "redo");
const blocks = document.createElement("select");
blocks.setAttribute("aria-label", "段落 / Paragraph");
for (const [value, label] of [
  ["0", "段落 / Paragraph"],
  ["1", "标题 1"],
  ["2", "标题 2"],
  ["3", "标题 3"],
]) {
  const o = new Option(label, value);
  blocks.add(o);
}
blocks.onchange = () => {
  const level = Number(blocks.value);
  level ? chain().toggleHeading({ level }).run() : chain().setParagraph().run();
};
toolbar.append(blocks);
for (const parent of [group("Format"), bubble]) {
  commandButton(parent, "粗体", "Bold", "toggleBold", [], "bold");
  commandButton(parent, "斜体", "Italic", "toggleItalic", [], "italic");
  commandButton(
    parent,
    "下划线",
    "Underline",
    "toggleUnderline",
    [],
    "underline",
  );
}
const formatMenu = menu("对齐与格式", "Alignment & format");
commandButton(formatMenu, "删除线", "Strike", "toggleStrike", [], "strike");
const colorPickers = [];
function closeColors() {
  for (const picker of colorPickers) {
    picker.panel.hidden = true;
    picker.trigger.setAttribute("aria-expanded", "false");
  }
}
for (const [zh, en, name, defaultColor] of [
  ["文字颜色", "Text color", "setColor", "#315ce7"],
  ["高亮", "Highlight", "setHighlight", "#fff0a0"],
]) {
  const wrapper = document.createElement("span");
  wrapper.className = "color-picker";
  const panel = document.createElement("div");
  panel.className = "color-panel";
  panel.hidden = true;
  panel.setAttribute("role", "group");
  panel.id = `palette-${name}`;
  const trigger = button(wrapper, zh, en, name + "Picker", () => {
    const opening = panel.hidden;
    closeColors();
    panel.hidden = !opening;
    trigger.setAttribute("aria-expanded", String(opening));
    if (opening) {
      const left = wrapper.getBoundingClientRect().left;
      panel.style.left = `${Math.min(0, innerWidth - left - 244)}px`;
      input.value =
        editor.getAttributes(name === "setColor" ? "textStyle" : "highlight")
          .color || defaultColor;
      input.removeAttribute("aria-invalid");
    }
    measure();
  });
  trigger.setAttribute("aria-controls", panel.id);
  trigger.setAttribute("aria-expanded", "false");
  const apply = (color) => {
    if (!editable || !editing) return;
    if (color === null)
      chain()[name === "setColor" ? "unsetColor" : "unsetHighlight"]().run();
    else
      chain()
        [name](name === "setColor" ? color : { color })
        .run();
    closeColors();
    status();
    measure();
  };
  const swatches = document.createElement("div");
  swatches.className = "color-swatches";
  for (const color of [
    "#222222",
    "#ffffff",
    "#697386",
    "#c62828",
    "#ef6c00",
    "#f9a825",
    "#2e7d32",
    "#00838f",
    "#1565c0",
    "#6a1b9a",
    "#ad1457",
    "#795548",
    "#ffcdd2",
    "#ffe0b2",
    "#fff0a0",
    "#c8e6c9",
    "#b2ebf2",
    "#bbdefb",
    "#e1bee7",
    "#f8bbd0",
  ]) {
    const swatch = button(swatches, color, color, name + color, () =>
      apply(color),
    );
    swatch.className = "color-swatch";
    swatch.style.backgroundColor = color;
  }
  panel.append(swatches);
  const custom = document.createElement("div");
  custom.className = "color-custom";
  const input = document.createElement("input");
  input.type = "text";
  input.placeholder = "#RRGGBB";
  input.maxLength = 7;
  input.setAttribute("aria-label", "HEX");
  const submit = () => {
    const color = input.value.trim();
    if (/^#[0-9a-f]{6}$/i.test(color)) apply(color);
    else {
      input.setAttribute("aria-invalid", "true");
      input.focus();
    }
  };
  input.addEventListener("keydown", (event) => {
    if (event.key === "Enter") {
      event.preventDefault();
      submit();
    }
  });
  custom.append(input);
  button(custom, "应用", "Apply", name + "Apply", submit);
  panel.append(custom);
  button(panel, "恢复默认", "Reset color", name + "Reset", () => apply(null));
  wrapper.append(panel);
  formatMenu.append(wrapper);
  colorPickers.push({ wrapper, panel, trigger, name, defaultColor });
}
for (const [zh, value] of [
  ["左对齐", "left"],
  ["居中", "center"],
  ["右对齐", "right"],
  ["两端对齐", "justify"],
])
  commandButton(formatMenu, zh, value, "setTextAlign", [value], {
    textAlign: value,
  });
button(formatMenu, "清除格式", "Clear formatting", "clear", () =>
  chain().unsetAllMarks().clearNodes().run(),
);
const insertMenu = menu("更多工具", "More tools");
commandButton(
  insertMenu,
  "无序列表",
  "Bullet list",
  "toggleBulletList",
  [],
  "bulletList",
);
commandButton(
  insertMenu,
  "有序列表",
  "Ordered list",
  "toggleOrderedList",
  [],
  "orderedList",
);
commandButton(
  insertMenu,
  "任务列表",
  "Task list",
  "toggleTaskList",
  [],
  "taskList",
);
for (const [zh, en, name] of [
  ["增加缩进", "Indent", "sinkListItem"],
  ["减少缩进", "Outdent", "liftListItem"],
]) {
  const type = () => (editor.isActive("taskItem") ? "taskItem" : "listItem");
  button(
    insertMenu,
    zh,
    en,
    name,
    () => chain()[name](type()).run(),
    () => editable && editing && editor.can()[name](type()),
  );
}
commandButton(
  insertMenu,
  "引用",
  "Quote",
  "toggleBlockquote",
  [],
  "blockquote",
);
commandButton(insertMenu, "行内代码", "Inline code", "toggleCode", [], "code");
commandButton(
  insertMenu,
  "代码块",
  "Code block",
  "toggleCodeBlock",
  [],
  "codeBlock",
);
commandButton(insertMenu, "分隔线", "Divider", "setHorizontalRule");
commandButton(insertMenu, "表格", "Table", "insertTable", [
  { rows: 3, cols: 3, withHeaderRow: true },
]);
function form(zh, en, initial, onSubmit) {
  clearNotice();
  notice.hidden = false;
  const label = document.createElement("label");
  label.textContent = t(zh, en);
  const input = document.createElement("input");
  input.value = initial;
  label.append(input);
  notice.append(label);
  const b = document.createElement("button");
  b.textContent = t("确定", "Apply");
  b.onclick = () => {
    onSubmit(input.value);
    clearNotice();
  };
  notice.append(b);
  const cancel = document.createElement("button");
  cancel.textContent = t("取消", "Cancel");
  cancel.onclick = () => {
    clearNotice();
    editor.commands.focus();
  };
  notice.append(cancel);
  input.focus();
  measure();
}
button(insertMenu, "链接", "Link", "link", () =>
  form(
    "链接地址",
    "Link URL",
    editor.getAttributes("link").href || "",
    (url) => {
      if (!url) chain().unsetLink().run();
      else if (safeURL(url))
        chain().extendMarkRange("link").setLink({ href: url }).run();
      else
        error(
          t(
            "仅支持 https、http 或 mailto 链接",
            "Use an https, http or mailto link",
          ),
        );
    },
  ),
);
for (const [zh, en, images] of [
  ["图片", "Image", true],
  ["附件", "Attachment", false],
])
  button(insertMenu, zh, en, images ? "image" : "attachment", () => {
    const request = String(++uploadID);
    pendingUploads.set(request, {
      bookmark: editor.state.selection.getBookmark(),
      images,
    });
    post({ kind: "chooseFile", request, images });
  });
button(
  toolbar,
  "查找",
  "Find",
  "find",
  () => {
    findBar.hidden = !findBar.hidden;
    if (!findBar.hidden) findInput.focus();
    measure();
  },
  () => initialized,
);
const findInput = document.createElement("input");
findInput.placeholder = "查找 / Find";
findInput.setAttribute("aria-label", findInput.placeholder);
const replaceInput = document.createElement("input");
replaceInput.placeholder = "替换为 / Replace with";
replaceInput.setAttribute("aria-label", replaceInput.placeholder);
findBar.append(findInput, replaceInput);
function matches() {
  const out = [];
  if (!search) return out;
  const escaped = [...search]
    .map((c) => "\\u{" + c.codePointAt(0).toString(16) + "}")
    .join("");
  editor.state.doc.descendants((block, pos) => {
    if (!block.isTextblock) return;
    let text = "";
    const positions = [];
    block.descendants((node, relative) => {
      if (node.isText) {
        for (let index = 0; index < node.text.length; index++)
          positions.push(pos + 1 + relative + index);
        text += node.text;
      } else if (node.isLeaf) {
        positions.push(pos + 1 + relative);
        text += "\uFFFC";
      }
    });
    for (const match of text.matchAll(new RegExp(escaped, "giu"))) {
      out.push({
        from: positions[match.index],
        to: positions[match.index + match[0].length - 1] + 1,
      });
    }
    return false;
  });
  return out;
}
findInput.oninput = () => {
  search = findInput.value;
  matchIndex = -1;
  editor.view.dispatch(editor.state.tr.setMeta("find", true));
  nextMatch();
};
function nextMatch() {
  const all = matches();
  if (!all.length) return;
  matchIndex = (matchIndex + 1) % all.length;
  const m = all[matchIndex];
  editor.commands.setTextSelection(m);
  layout(true);
}
button(findBar, "下一处", "Next", "findNext", nextMatch, () => !!search);
button(findBar, "替换", "Replace", "replace", () => {
  const m = matches().find(
    (m) =>
      m.from === editor.state.selection.from &&
      m.to === editor.state.selection.to,
  );
  if (m)
    chain()
      .insertContentAt(
        m,
        replaceInput.value ? { type: "text", text: replaceInput.value } : "",
      )
      .run();
  nextMatch();
});
button(findBar, "全部替换", "Replace all", "replaceAll", () => {
  const all = matches();
  let tr = editor.state.tr;
  for (const m of all.reverse())
    tr = tr.insertText(replaceInput.value, m.from, m.to);
  editor.view.dispatch(tr);
});
button(
  findBar,
  "关闭",
  "Close",
  "closeFind",
  () => {
    findBar.hidden = true;
    search = "";
    editor.view.dispatch(editor.state.tr.setMeta("find", true));
    editor.commands.focus();
    measure();
  },
  () => true,
);

const tableTools = document.createElement("span");
context.append(tableTools);
for (const [zh, en, name] of [
  ["前插行", "Row above", "addRowBefore"],
  ["后插行", "Row below", "addRowAfter"],
  ["删除行", "Delete row", "deleteRow"],
  ["前插列", "Column before", "addColumnBefore"],
  ["后插列", "Column after", "addColumnAfter"],
  ["删除列", "Delete column", "deleteColumn"],
  ["表头", "Header", "toggleHeaderRow"],
  ["合并", "Merge", "mergeCells"],
  ["拆分", "Split", "splitCell"],
  ["删除表格", "Delete table", "deleteTable"],
])
  commandButton(tableTools, zh, en, name);
const imageTools = document.createElement("span");
context.append(imageTools);
button(imageTools, "说明", "Caption", "caption", () =>
  form(
    "图片说明",
    "Image caption",
    editor.getAttributes("vaultImage").caption || "",
    (caption) => chain().updateAttributes("vaultImage", { caption }).run(),
  ),
);
for (const width of [240, 400, 600, 800])
  button(imageTools, `${width}px`, `${width}px`, "width" + width, () =>
    chain().updateAttributes("vaultImage", { width }).run(),
  );
button(imageTools, "替换图片", "Replace image", "replaceImage", () => {
  const request = String(++uploadID);
  pendingUploads.set(request, {
    bookmark: editor.state.selection.getBookmark(),
    replace: true,
    images: true,
  });
  post({ kind: "chooseFile", request, images: true });
});
const fileTools = document.createElement("span");
context.append(fileTools);
button(
  fileTools,
  "另存为…",
  "Save as…",
  "saveAttachment",
  () => {
    const node = editor.state.selection.node;
    if (node)
      post({
        kind: "saveAttachment",
        id: node.attrs.attachmentId,
        name: node.attrs.name,
      });
  },
  () => initialized && !!editor.state.selection.node,
);
button(fileTools, "删除", "Delete", "deleteAttachment", () =>
  chain().deleteSelection().run(),
);
button(
  insertMenu,
  "导出 Markdown…",
  "Export Markdown…",
  "exportMarkdown",
  () => post({ kind: "exportMarkdown", markdown: editor.getMarkdown() }),
  () => initialized,
);

// Keep the everyday tools visible instead of hiding discovery behind two menus.
// Move the existing controls so their selection preservation and enabled state
// remain shared with the context toolbar and keyboard commands.
const textRow = document.createElement("div");
const insertRow = document.createElement("div");
textRow.className = insertRow.className = "toolbar-row";
const textLabel = document.createElement("span");
const insertLabel = document.createElement("span");
textLabel.className = insertLabel.className = "toolbar-label";
const primaryFormat = toolbar.querySelector('.toolgroup[aria-label="Format"]');
primaryFormat.append(formatMenu.querySelector('[data-action="toggleStrike"]'));
textRow.append(textLabel, historyGroup, blocks, primaryFormat);
const colorGroup = document.createElement("span");
colorGroup.className = "toolgroup color-tools";
colorGroup.append(...formatMenu.querySelectorAll(".color-picker"));
textRow.append(colorGroup, formatMenu.parentElement);
insertRow.append(insertLabel);
for (const actions of [
  ["toggleBulletList", "toggleOrderedList", "toggleTaskList"],
  ["link", "insertTable", "image", "attachment"],
]) {
  const tools = document.createElement("span");
  tools.className = "toolgroup";
  for (const action of actions)
    tools.append(insertMenu.querySelector(`[data-action="${action}"]`));
  insertRow.append(tools);
}
insertRow.append(
  insertMenu.parentElement,
  toolbar.querySelector('[data-action="find"]'),
);
toolbar.replaceChildren(textRow, insertRow);

function status() {
  if (!editor || !initialized || sealed) return;
  toolbar.setAttribute("aria-label", t("编辑工具栏", "Editing tools"));
  textLabel.textContent = t("文字", "Text");
  insertLabel.textContent = t("插入", "Insert");
  for (const c of controls) {
    c.b.textContent = t(c.zh, c.en);
    c.b.title = t(c.zh, c.en);
    c.b.setAttribute("aria-label", t(c.zh, c.en));
    if (c.b.tagName === "BUTTON") {
      c.b.disabled = !c.enabled();
      c.b.setAttribute("aria-pressed", String(!!c.active()));
    }
  }
  for (const input of toolbar.querySelectorAll("input"))
    input.disabled = !(editable && editing);
  for (const picker of colorPickers) {
    const color = editor.getAttributes(
      picker.name === "setColor" ? "textStyle" : "highlight",
    ).color;
    picker.trigger.style.setProperty("--swatch", color || picker.defaultColor);
    picker.panel.setAttribute("aria-label", picker.trigger.textContent);
    if (!editable || !editing) closeColors();
  }
  findInput.placeholder = t("查找", "Find");
  replaceInput.placeholder = t("替换为", "Replace with");
  findInput.setAttribute("aria-label", findInput.placeholder);
  replaceInput.setAttribute("aria-label", replaceInput.placeholder);
  blocks.options[0].textContent = t("段落", "Paragraph");
  for (let level = 1; level <= 3; level++)
    blocks.options[level].textContent = t("标题 ", "Heading ") + level;
  blocks.setAttribute("aria-label", t("段落样式", "Paragraph style"));
  blocks.disabled = !(editable && editing);
  blocks.value = String(editor.getAttributes("heading").level || 0);
  toolbar.hidden = !editable;
  tableTools.hidden = !editor.isActive("table");
  imageTools.hidden = !editor.isActive("vaultImage");
  fileTools.hidden = !(
    editor.isActive("vaultImage") || editor.isActive("vaultAttachment")
  );
  context.hidden = tableTools.hidden && imageTools.hidden && fileTools.hidden;
  stats.textContent = `${editor.getText().length} ${t("字", "characters")} · ${t("本地加密笔记", "Encrypted local note")}`;
  post({
    kind: "state",
    revision,
    undo: editor.can().undo(),
    redo: editor.can().redo(),
  });
}
function measure() {
  if (initialized && !sealed)
    post({
      kind: "height",
      height: Math.max(360, document.body.scrollHeight),
      layoutID: ++layoutID,
    });
}
function layout(force = false) {
  cancelAnimationFrame(frame);
  frame = requestAnimationFrame(() => {
    if (!editor || !initialized || sealed) return;
    measure();
    const v = editor.view;
    if ((force || v.hasFocus()) && editing) {
      const r = v.coordsAtPos(v.state.selection.head);
      post({
        kind: "caret",
        x: r.left,
        y: r.top,
        height: Math.max(20, r.bottom - r.top),
        layoutID,
      });
    }
    const selection = window.getSelection();
    const show =
      v.hasFocus() &&
      !v.state.selection.empty &&
      !v.state.selection.node &&
      editable &&
      editing;
    bubble.hidden = !show;
    if (show && selection?.rangeCount) {
      const r = selection.getRangeAt(0).getBoundingClientRect();
      bubble.style.left = `${Math.max(0, Math.min(innerWidth - 240, r.left))}px`;
      bubble.style.top = `${Math.max(0, r.top + scrollY - 38)}px`;
    }
  });
}
async function upload(files) {
  for (const file of files) {
    if (file.size > 25 * 1024 * 1024) {
      error(t("单个文件不能超过 25 MiB", "Each file must be at most 25 MiB"));
      continue;
    }
    const request = String(++uploadID);
    pendingUploads.set(request, {
      bookmark: editor.state.selection.getBookmark(),
    });
    retryFiles = [file];
    error(t("正在导入附件…", "Importing attachment…"));
    const cancel = document.createElement("button");
    cancel.textContent = t("取消", "Cancel");
    cancel.onclick = () => {
      pendingUploads.delete(request);
      post({ kind: "cancelUpload", request });
      clearNotice();
    };
    notice.append(cancel);
    post({
      kind: "uploadStart",
      request,
      name: file.name,
      mime: file.type,
      size: file.size,
    });
    const bytes = new Uint8Array(await file.arrayBuffer());
    for (let at = 0; at < bytes.length; at += 192 * 1024) {
      if (!pendingUploads.has(request) || sealed) break;
      let binary = "";
      for (const byte of bytes.subarray(at, at + 192 * 1024))
        binary += String.fromCharCode(byte);
      post({ kind: "uploadChunk", request, data: btoa(binary) });
      window.pvEditor.uploadProgress(
        request,
        Math.round(
          (Math.min(bytes.length, at + 192 * 1024) / bytes.length) * 90,
        ),
      );
      await new Promise((r) => setTimeout(r, 0));
    }
    if (pendingUploads.has(request) && !sealed)
      post({ kind: "uploadFinish", request });
  }
}
editor = new Editor({
  element: document.querySelector("#editor"),
  editable: false,
  content: "",
  extensions: [
    StarterKit.configure({
      link: {
        openOnClick: false,
        autolink: false,
        protocols: ["http", "https", "mailto"],
      },
      heading: { levels: [1, 2, 3] },
    }),
    TextStyle,
    Color,
    Highlight.configure({ multicolor: true }),
    TextAlign.configure({ types: ["heading", "paragraph"] }),
    TableKit.configure({ table: { resizable: true } }),
    TaskList,
    TaskItem.configure({
      nested: true,
      HTMLAttributes: { "data-type": "taskItem" },
      a11y: {
        checkboxLabel: (node) => t("待办：", "Task: ") + node.textContent,
      },
    }),
    VaultImage,
    VaultAttachment,
    Markdown,
  ],
  editorProps: {
    attributes: {
      "aria-label": "笔记正文",
      role: "textbox",
      "aria-multiline": "true",
      spellcheck: "false",
    },
    handleScrollToSelection() {
      layout();
      return true;
    },
    transformPastedHTML(html) {
      return DOMPurify.sanitize(html, {
        FORBID_TAGS: [
          "img",
          "iframe",
          "video",
          "audio",
          "script",
          "style",
          "object",
          "embed",
        ],
        FORBID_ATTR: ["src", "srcset", "onerror", "onclick"],
      });
    },
    handlePaste(_view, event) {
      const files = [...(event.clipboardData?.files || [])];
      if (files.length) {
        if (editable && editing) void upload(files);
        return true;
      }
      return false;
    },
    handleDrop(_view, event, _slice, moved) {
      if (moved) return false;
      const files = [...(event.dataTransfer?.files || [])];
      if (files.length) {
        if (editable && editing) void upload(files);
        return true;
      }
      return false;
    },
    handleDOMEvents: {
      click(_v, event) {
        const link = event.target.closest("a");
        if (link) {
          event.preventDefault();
          return true;
        }
        return false;
      },
      contextmenu(_v, event) {
        const link = event.target.closest("a[href]");
        if (link && safeURL(link.href)) {
          event.preventDefault();
          post({
            kind: "link",
            url: link.href,
            x: event.clientX,
            y: event.clientY,
          });
          return true;
        }
        return false;
      },
    },
  },
  onTransaction({ transaction }) {
    for (const pending of pendingUploads.values())
      pending.bookmark = pending.bookmark.map(transaction.mapping);
  },
  onUpdate() {
    if (!initialized || suppress || sealed || !editable) return;
    revision++;
    source = snapshotSource();
    post({ kind: "change", source, revision });
    status();
    layout();
  },
  onSelectionUpdate() {
    status();
    layout();
  },
  onFocus() {
    layout();
  },
  onBlur() {
    bubble.hidden = true;
  },
});
editor.registerPlugin(
  new Plugin({
    props: {
      decorations(state) {
        return DecorationSet.create(
          state.doc,
          matches().map((m) =>
            Decoration.inline(m.from, m.to, { class: "search-match" }),
          ),
        );
      },
    },
  }),
);

window.pvEditor = {
  configure(options) {
    if (sealed || (initialized && token !== options.token))
      return { accepted: false };
    // Reject stale state BEFORE changing editability, selection, or language.
    if (
      initialized &&
      (options.sequence < sequence || options.expectedRevision !== revision)
    )
      return { accepted: false };
    if (initialized && options.source !== source && editor.view.composing)
      return { accepted: false };
    token = options.token;
    sequence = options.sequence ?? sequence + 1;
    chinese = !!options.chinese;
    if (!initialized) {
      suppress = true;
      try {
        if (options.format === "rich-v1")
          editor.commands.setContent(JSON.parse(options.source).document, {
            emitUpdate: false,
            errorOnInvalidContent: true,
          });
        else if (options.format === "plain")
          editor.commands.setContent(plainDoc(options.source), {
            emitUpdate: false,
          });
        else
          editor.commands.setContent(importMarkdown(options.source), {
            contentType: "markdown",
            emitUpdate: false,
          });
        editor.view.updateState(
          EditorState.create({
            schema: editor.schema,
            doc: editor.state.doc,
            plugins: editor.state.plugins,
          }),
        );
        source = options.source;
      } catch {
        post({ kind: "failure" });
        return { accepted: false };
      } finally {
        suppress = false;
      }
    } else if (options.source !== source) {
      return { accepted: false };
    }
    editable = !!options.editable;
    editing = !!options.editing;
    if (editor.isEditable !== (editable && editing))
      editor.setEditable(editable && editing, false);
    initialized = true;
    editor.view.dom.setAttribute("aria-label", t("笔记正文", "Note body"));
    status();
    layout();
    return { accepted: true };
  },
  async snapshot(close = false) {
    if (!initialized) return null;
    if (close) editor.view.dom.blur();
    await new Promise((r) => setTimeout(r, 0));
    const result = { source, revision };
    if (close) {
      sealed = true;
      pendingUploads.clear();
      retryFiles = [];
      editor.destroy();
      source = "";
      token = "";
      document.body.replaceChildren();
    }
    return result;
  },
  command(action) {
    if (editable && editing && !sealed) {
      editor.chain().focus()[action]().run();
      status();
    }
  },
  refocus() {
    if (editable && editing && !sealed)
      editor.commands.focus(undefined, { scrollIntoView: false });
  },
  attachment(request, meta) {
    const pending = pendingUploads.get(request);
    pendingUploads.delete(request);
    if (!pending || sealed || !editable) {
      post({ kind: "discardAttachment", id: meta.id });
      return false;
    }
    const selection = pending.bookmark.resolve(editor.state.doc);
    editor.view.dispatch(editor.state.tr.setSelection(selection));
    const image = [
      "image/png",
      "image/jpeg",
      "image/gif",
      "image/webp",
    ].includes(meta.mime);
    editor
      .chain()
      .focus()
      .insertContent({
        type: image ? "vaultImage" : "vaultAttachment",
        attrs: {
          attachmentId: meta.id,
          name: meta.name,
          mime: meta.mime,
          size: meta.size,
          width: 600,
        },
      })
      .run();
    clearNotice();
    retryFiles = [];
    layout();
    return true;
  },
  uploadError(request, message) {
    const pending = pendingUploads.get(request);
    pendingUploads.delete(request);
    error(message);
    const b = document.createElement("button");
    b.textContent = t("重试", "Retry");
    b.onclick = () => {
      if (retryFiles.length) void upload(retryFiles);
      else if (pending) {
        const next = String(++uploadID);
        pendingUploads.set(next, {
          bookmark: editor.state.selection.getBookmark(),
          images: pending.images,
        });
        post({ kind: "chooseFile", request: next, images: !!pending.images });
      }
    };
    notice.append(b);
  },
  uploadProgress(request, percent) {
    if (!pendingUploads.has(request) || sealed) return;
    notice.replaceChildren();
    notice.hidden = false;
    const label = document.createElement("span");
    label.textContent =
      t("正在导入附件", "Importing attachment") + ` ${percent}%`;
    notice.append(label);
    const cancel = document.createElement("button");
    cancel.textContent = t("取消", "Cancel");
    cancel.onclick = () => {
      pendingUploads.delete(request);
      post({ kind: "cancelUpload", request });
      clearNotice();
    };
    notice.append(cancel);
    measure();
  },
  cancelUpload(request) {
    pendingUploads.delete(request);
    clearNotice();
  },
  // Read-only diagnostics contain no document text and are used by native window regression tests.
  diagnostics() {
    const r = editor.view.coordsAtPos(editor.state.selection.head);
    return {
      focused: editor.view.hasFocus(),
      editable: editor.isEditable,
      revision,
      selection: {
        from: editor.state.selection.from,
        to: editor.state.selection.to,
      },
      composing: editor.view.composing,
      caret: { top: r.top, bottom: r.bottom, left: r.left, right: r.right },
    };
  },
};
new ResizeObserver(() => layout()).observe(document.querySelector("#editor"));
// The web page grows to its content height: the native parent scrolls both title
// and body. WebKit consumes wheel events even with overflow:hidden, so explicitly
// hand vertical scrolling to that parent. Keep nested menus and horizontal tables
// in WebKit, and never focus the editor or move its selection while scrolling.
document.addEventListener(
  "wheel",
  (event) => {
    if (
      sealed ||
      !initialized ||
      event.defaultPrevented ||
      event.ctrlKey ||
      !event.cancelable ||
      !Number.isFinite(event.deltaY) ||
      event.deltaY === 0 ||
      Math.abs(event.deltaX) > Math.abs(event.deltaY)
    )
      return;
    for (
      let node = event.target instanceof Element ? event.target : null;
      node && node !== document.body;
      node = node.parentElement
    ) {
      const overflow = getComputedStyle(node).overflowY;
      if (
        (overflow === "auto" || overflow === "scroll") &&
        node.scrollHeight > node.clientHeight + 1 &&
        (event.deltaY < 0
          ? node.scrollTop > 0
          : node.scrollTop + node.clientHeight < node.scrollHeight - 1)
      )
        return;
    }
    event.preventDefault();
    post({ kind: "wheel", deltaY: event.deltaY, deltaMode: event.deltaMode });
  },
  { passive: false },
);
document.addEventListener("selectionchange", () => layout());
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") {
    closeColors();
    measure();
  }
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "f") {
    event.preventDefault();
    findBar.hidden = false;
    findInput.focus();
    measure();
  }
});
post({ kind: "ready" });

document.addEventListener("pointerdown", (event) => {
  if (!event.target.closest(".color-picker")) closeColors();
  if (!event.target.closest(".toolbar details"))
    for (const menu of toolbar.querySelectorAll("details[open]"))
      menu.open = false;
});
