import http from 'node:http';
import { pathToFileURL } from 'node:url';
import WebSocket, { WebSocketServer } from 'ws';

/** Header bridge for browsers. It has no vault keys and never parses vault data. */
export function createGateway({ upstream, origins, allowLocalTest = false, handshakeMs = 10_000, maxConnections = 128 }) {
  const target = new URL(upstream);
  if (!(target.protocol === 'wss:' || (allowLocalTest && target.protocol === 'ws:' && target.hostname === '127.0.0.1')) || target.username || target.password || target.hash || target.search) throw new Error('Invalid fixed upstream');
  const validOrigin = origin => {
    try { const url = new URL(origin);
      if (url.protocol === 'chrome-extension:') return /^[a-p]{32}$/u.test(url.hostname) && origin === `chrome-extension://${url.hostname}`;
      return url.origin === origin && (url.protocol === 'https:' || (allowLocalTest && url.protocol === 'http:' && ['127.0.0.1', 'localhost'].includes(url.hostname)));
    } catch { return false; }
  };
  if (!Array.isArray(origins) || origins.length === 0 || origins.some(origin => !validOrigin(origin))) throw new Error('Exact HTTPS or extension origins required');
  const allowed = new Set(origins);
  const server = http.createServer((_req, res) => { res.writeHead(404, { 'Cache-Control': 'no-store' }); res.end(); });
  const wss = new WebSocketServer({ noServer: true, maxPayload: 270336, perMessageDeflate: false, handleProtocols: protocols => protocols.has('passwordvault.gateway.v1') ? 'passwordvault.gateway.v1' : false });
  const rates = new Map();
  server.on('upgrade', (request, socket, head) => {
    const ip = request.socket.remoteAddress ?? ''; // Never trust forwarded IP headers.
    const now = Date.now();
    for (const [key, value] of rates) if (now - value.started > 60_000) rates.delete(key);
    let rate = rates.get(ip); if (!rate) { if (rates.size >= 4096) { socket.end('HTTP/1.1 429 Too Many Requests\r\nConnection: close\r\n\r\n'); return; } rate = { started: now, count: 0 }; rates.set(ip, rate); }
    if (request.url !== '/connect' || !allowed.has(request.headers.origin) || request.headers['sec-websocket-protocol'] !== 'passwordvault.gateway.v1' || ++rate.count > 30 || wss.clients.size >= maxConnections || rates.size > 4096) {
      socket.end('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n'); return;
    }
    wss.handleUpgrade(request, socket, head, client => wss.emit('connection', client));
  });
  wss.on('connection', client => {
    let remote, authenticated = false, received = 0, receivedBytes = 0, window = Date.now();
    const stop = () => { clearTimeout(timer); client.close(1008, 'Connection ended'); remote?.close(); };
    const timer = setTimeout(stop, handshakeMs);
    client.on('error', stop); client.on('close', () => { clearTimeout(timer); remote?.close(); });
    client.on('message', (data, binary) => {
      if (Date.now() - window >= 1000) { window = Date.now(); received = 0; receivedBytes = 0; }
      receivedBytes += data.length;
      if (++received > 256 || receivedBytes > 8 * 1024 * 1024) { stop(); return; }
      if (!authenticated) {
        if (remote || binary || data.length > 12_288) { stop(); return; }
        let frame; try { frame = JSON.parse(data.toString()); } catch { stop(); return; }
        if (frame.type !== 'authenticate' || typeof frame.token !== 'string' || frame.token.length < 1 || frame.token.length > 8192 || /[\r\n]/u.test(frame.token) || Object.keys(frame).some(k => k !== 'type' && k !== 'token')) { stop(); return; }
        // Fixed administrator-configured destination, no URL supplied by a client and no redirects.
        remote = new WebSocket(target, ['common-relay.v1'], { headers: { Authorization: `Bearer ${frame.token}` }, followRedirects: false, handshakeTimeout: handshakeMs, maxPayload: 270336, perMessageDeflate: false });
        frame.token = ''; // Never retain tokens in application state or logs.
        remote.on('open', () => { if (remote.protocol !== 'common-relay.v1') { stop(); return; } authenticated = true; clearTimeout(timer); });
        remote.on('message', (payload, isBinary) => { if (client.readyState !== WebSocket.OPEN || client.bufferedAmount > 1_048_576) { stop(); return; } client.send(payload, { binary: isBinary }); });
        remote.on('error', stop); remote.on('close', () => client.close(1011, 'Relay disconnected'));
      } else {
        if (remote.readyState !== WebSocket.OPEN || remote.bufferedAmount > 1_048_576) { stop(); return; }
        remote.send(data, { binary });
      }
    });
  });
  return { server, close: async () => { for (const client of wss.clients) client.terminate(); await new Promise(resolve => wss.close(resolve)); if (server.listening) await new Promise(resolve => server.close(resolve)); } };
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const gateway = createGateway({ upstream: process.env.RELAY_UPSTREAM, origins: (process.env.WEB_ORIGINS ?? '').split(',').filter(Boolean) });
  gateway.server.listen(Number(process.env.PORT ?? '8788'), process.env.BIND_HOST ?? '127.0.0.1');
}
