import { Editor, rootCtx, defaultValueCtx, editorViewCtx, editorViewOptionsCtx, serializerCtx } from '@milkdown/kit/core';
import { commonmark } from '@milkdown/kit/preset/commonmark';
import { gfm } from '@milkdown/kit/preset/gfm';
import { history } from '@milkdown/kit/plugin/history';
import { undo, redo, undoDepth, redoDepth } from '@milkdown/kit/prose/history';
import { Plugin } from '@milkdown/kit/prose/state';
import { $prose, replaceAll } from '@milkdown/kit/utils';

let editor, token = '', source = '', revision = 0, editable = false, editing = false;
let initialized = false, suppress = false, dirty = false, sealed = false;
const post = body => window.webkit?.messageHandlers?.noteEditor?.postMessage({ ...body, token });
const view = () => editor?.ctx.get(editorViewCtx);
let caretFrame = 0;
function revealCaret() {
  cancelAnimationFrame(caretFrame);
  caretFrame = requestAnimationFrame(() => {
    const current = view();
    if (!current || !editing || sealed || !current.hasFocus()) return;
    const rect = current.coordsAtPos(current.state.selection.head);
    post({kind:'caret', x:rect.left, y:rect.top, height:Math.max(20,rect.bottom-rect.top)});
  });
}
const serialize = () => dirty ? editor.ctx.get(serializerCtx)(view().state.doc) : source;
function status() {
  const v = view();
  if (!v || !initialized || sealed) return;
  post({ kind: 'state', revision, undo: undoDepth(v.state) > 0, redo: redoDepth(v.state) > 0 });
}
function publish() {
  if (suppress || !initialized || sealed || !editable) return;
  dirty = true; revision++;
  source = editor.ctx.get(serializerCtx)(view().state.doc);
  post({ kind: 'change', source, revision });
  status();
}
const bridge = $prose(() => new Plugin({
  view() {
    return { update(current, previous) {
      if (!current.state.doc.eq(previous.doc)) publish();
      else status();
      revealCaret();
    }};
  },
  props: {
    handleScrollToSelection() { revealCaret(); return true; },
    handleDOMEvents: {
      pointerdown(current, event) {
        if (editable && !sealed && !editing) {
          editing = true; current.setProps({editable: () => editable && editing && !sealed});
          post({kind:'editing'});
        }
        const item = event.target.closest?.('li[data-item-type="task"]');
        if (item && editable && !sealed && event.clientX < item.getBoundingClientRect().left + 2) {
          const pos = current.posAtDOM(item, 0), resolved = current.state.doc.resolve(pos);
          for (let depth = resolved.depth; depth > 0; depth--) {
            const node = resolved.node(depth);
            if (node.type.name === 'list_item') {
              current.dispatch(current.state.tr.setNodeMarkup(resolved.before(depth), undefined, {...node.attrs, checked: !node.attrs.checked}));
              event.preventDefault(); return true;
            }
          }
        }
        return false;
      },
      click(_current, event) { if (event.target.closest?.('a')) { event.preventDefault(); return true; } return false; },
      contextmenu(_current, event) {
        const link = event.target.closest?.('a[href]');
        if (link && /^(https?:|mailto:)/i.test(link.getAttribute('href') || '')) {
          event.preventDefault(); post({kind:'link', url:link.href, x:event.clientX, y:event.clientY}); return true;
        }
        return false;
      },
      dragover(_current,event) { event.preventDefault(); return true; },
      drop(_current,event) { event.preventDefault(); return true; },
    },
  },
}));
async function start() {
  editor = await Editor.make().config(ctx => {
    ctx.set(rootCtx, document.querySelector('#editor'));
    ctx.set(defaultValueCtx, '');
    ctx.update(editorViewOptionsCtx, options => ({...options, editable: () => false,
      attributes: {'aria-label':'笔记正文', 'role':'textbox', 'aria-multiline':'true', spellcheck:'false'}}));
  }).use(commonmark).use(gfm).use(history).use(bridge).create();
  window.pvEditor = {
    configure(options) {
      if (sealed) return {accepted:false};
      if (initialized && token !== options.token) return {accepted:false};
      token = options.token;
      editable = !!options.editable; editing = !!options.editing;
      const current = view();
      current.setProps({editable: () => editable && editing && !sealed});
      current.dom.setAttribute('aria-label', options.chinese ? '笔记正文' : 'Note body');
      if (!initialized || source !== options.source) {
        if (initialized && (current.composing || options.expectedRevision !== revision)) {
          post({kind:'change', source:serialize(), revision});
          return {accepted:false};
        }
        suppress = true;
        try { editor.action(replaceAll(options.source, true)); source = options.source; dirty = false; }
        finally { suppress = false; }
      }
      initialized = true; status(); measure();
      return {accepted:true};
    },
    async snapshot(close = false) {
      if (!initialized) return null;
      if (close) { view().dom.blur(); }
      // Allow composition/input DOM mutations to reach ProseMirror first.
      await new Promise(resolve => setTimeout(resolve, 0));
      const result = {source:serialize(), revision};
      if (close) {
        sealed = true; editable = false;
        await editor.destroy(); editor = undefined; source = ''; token = '';
        document.querySelector('#editor').replaceChildren();
      }
      return result;
    },
    refocus() { if (editable && editing && !sealed) view().focus(); },
    command(action) {
      if (!editable || sealed) return;
      editing = true; view().setProps({editable:()=>true});
      post({kind:'editing'});
      if (action === 'undo') undo(view().state, view().dispatch);
      if (action === 'redo') redo(view().state, view().dispatch);
      view().focus(); status();
    },
  };
  document.addEventListener('selectionchange', revealCaret);
  const observer = new ResizeObserver(measure);
  observer.observe(document.querySelector('#editor'));
  post({kind:'ready'});
}
function measure() {
  if (initialized && !sealed) post({kind:'height', height:Math.max(360, document.querySelector('#editor').scrollHeight + 24)});
}
start().catch(() => post({kind:'failure'}));
