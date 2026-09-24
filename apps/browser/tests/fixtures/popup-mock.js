// Fictional in-memory bridge. Never sends a request to the installed extension.
window.qa = {
  reads: 0, saved: [], dismissed: [], edited: [], filled: [], failSave: false,
  state: { mode: 'native', available: true, unlocked: true, paired: true },
  origin: 'https://accounts.example.test',
  pending: { id: 'fixture-1', tabId: 123, origin: 'https://accounts.example.test', username: 'fixture@example.test', password: 'Fictional-only-208!', expires: Date.now() + 120000 },
};
window.chrome = {
  runtime: {
    id: 'synthetic-popup-test', getURL: path => path,
    async sendMessage(request) {
      const qa = window.qa;
      if (request.action === 'status') return { ok: true, data: qa.state };
      if (request.action === 'matches') {
        qa.reads++;
        return { ok: true, data: { id: 123, origin: qa.origin, reminders: true, pending: qa.pending,
          accounts: Array.from({length: 30}, (_, i) => ({id: i === 1 ? '0' : String(i), ...(i === 1 ? {accountId:'extra'} : {}), title: '虚构账号 ' + i, username: 'fixture' + i + '@example.test'})) } };
      }
      if (request.action === 'edit-native-entry') { if (qa.failEdit) return {ok:false,error:qa.failEdit}; qa.edited.push(request); }
      if (request.action === 'fill') qa.filled.push(request);
      if (request.action === 'save-captured') {
        if (qa.failSave) return { ok: false, error: 'unavailable' };
        qa.saved.push(request); qa.pending = undefined;
      }
      if (request.action === 'dismiss-pending') { qa.dismissed.push(request); qa.pending = undefined; }
      if (request.action === 'capture') return { ok: true, data: { tabId: 123, origin: qa.origin, username: 'manual@example.test', password: 'Fictional-manual-208!' } };
      if (request.action === 'lock') qa.state.unlocked = false;
      return { ok: true, data: {} };
    },
  },
  tabs: { async create() {}, async update() {} },
};
