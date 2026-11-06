import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { createHmac, randomBytes, randomInt, timingSafeEqual } from "node:crypto";
import { DatabaseSync } from "node:sqlite";
import { mkdirSync, chmodSync, writeFileSync, readFileSync, unlinkSync, readdirSync } from "node:fs";
import { join } from "node:path";

export interface Options {
  directory: string;
  origin: string;
  ownerTokens: string[];
  secret: string;
  sendCode?: (email: string, code: string) => Promise<void>;
  now?: () => number;
  maxBytes?: number;
  allowedOrigins?: string[];
}
type Share = { id: string; owner: string; expiry: number; recipient: string | null };
class Failure extends Error { status: number; constructor(status: number) { super("Request rejected"); this.status = status; } }
const idPattern = /^[a-f0-9]{32}$/;
const expiries = new Set([3600, 86400, 604800, 2592000]);
const normalizedEmail = (input: unknown): string => {
  if (typeof input !== "string" || input.length > 254 || !/^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$/.test(input)) throw new Failure(400);
  return input.trim().toLowerCase();
};

export function createShareService(options: Options) {
  const origin = new URL(options.origin);
  if ((origin.protocol !== "https:" && !["localhost", "127.0.0.1", "[::1]"].includes(origin.hostname)) || origin.pathname !== "/" || origin.search || origin.hash || origin.username || origin.password) throw new Error("Invalid public origin");
  if (options.secret.length < 32 || !options.ownerTokens.length || options.ownerTokens.some(t => t.length < 32)) throw new Error("Configure independent strong service and owner secrets");
  const now = options.now ?? Date.now;
  const maximum = options.maxBytes ?? 40 * 1024 * 1024;
  mkdirSync(options.directory, { recursive: true, mode: 0o700 });
  chmodSync(options.directory, 0o700);
  const db = new DatabaseSync(join(options.directory, "share.sqlite"));
  chmodSync(join(options.directory, "share.sqlite"), 0o600);
  db.exec(`PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;
    CREATE TABLE IF NOT EXISTS shares(id TEXT PRIMARY KEY,owner TEXT NOT NULL,expiry INTEGER NOT NULL,recipient TEXT);
    CREATE TABLE IF NOT EXISTS challenges(share TEXT PRIMARY KEY REFERENCES shares(id) ON DELETE CASCADE,digest TEXT NOT NULL,expiry INTEGER NOT NULL,attempts INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS sessions(digest TEXT PRIMARY KEY,share TEXT NOT NULL REFERENCES shares(id) ON DELETE CASCADE,expiry INTEGER NOT NULL);
    CREATE INDEX IF NOT EXISTS sessions_share ON sessions(share);
    CREATE TABLE IF NOT EXISTS rates(bucket TEXT PRIMARY KEY,start INTEGER NOT NULL,count INTEGER NOT NULL);`);
  const hash = (domain: string, value: string) => createHmac("sha256", options.secret).update(domain).update("\0").update(value).digest("hex");
  const json = (res: ServerResponse, status: number, body: unknown) => {
    res.writeHead(status, { "Content-Type": "application/json; charset=utf-8" }); res.end(JSON.stringify(body));
  };
  const authenticate = (req: IncomingMessage) => {
    const authorization = req.headers.authorization ?? "";
    const candidate = authorization.startsWith("Bearer ") ? authorization.slice(7) : "";
    const digest = hash("owner", candidate);
    if (!options.ownerTokens.some(token => timingSafeEqual(Buffer.from(digest), Buffer.from(hash("owner", token))))) throw new Failure(401);
    return digest;
  };
  const rate = (bucket: string, limit: number, duration: number) => {
    const key = hash("rate", bucket);
    const row = db.prepare("SELECT start,count FROM rates WHERE bucket=?").get(key) as {start:number;count:number}|undefined;
    if (!row || row.start + duration <= now()) db.prepare("INSERT OR REPLACE INTO rates VALUES(?,?,1)").run(key, now());
    else {
      if (row.count >= limit) throw new Failure(429);
      db.prepare("UPDATE rates SET count=count+1 WHERE bucket=?").run(key);
    }
  };
  const body = async (req: IncomingMessage, limit = 8192) => {
    if (!(req.headers["content-type"] ?? "").startsWith("application/json")) throw new Failure(415);
    if (Number(req.headers["content-length"] ?? 0) > limit) throw new Failure(413);
    let length = 0; const chunks: Buffer[] = [];
    for await (const chunk of req) { length += chunk.length; if (length > limit) throw new Failure(413); chunks.push(Buffer.from(chunk)); }
    try { const value = JSON.parse(Buffer.concat(chunks).toString("utf8")); if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(); return value as Record<string, unknown>; }
    catch { throw new Failure(400); }
  };
  const share = (id: string) => {
    const row = db.prepare("SELECT * FROM shares WHERE id=? AND expiry>?").get(id, now()) as Share|undefined;
    if (!row) throw new Failure(404);
    return row;
  };
  const discard = (id: string) => {
    db.prepare("DELETE FROM shares WHERE id=?").run(id);
    try { unlinkSync(join(options.directory, id + ".json")); } catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; }
  };
  const purge = () => {
    for (const row of db.prepare("SELECT id FROM shares WHERE expiry<=?").all(now())) discard(String(row.id));
    db.prepare("DELETE FROM sessions WHERE expiry<=?").run(now());
    db.prepare("DELETE FROM challenges WHERE expiry<=?").run(now());
    db.prepare("DELETE FROM rates WHERE start<?").run(now() - 86400000);
    for (const name of readdirSync(options.directory)) {
      if (/^[a-f0-9]{32}\.json$/.test(name) && !db.prepare("SELECT id FROM shares WHERE id=?").get(name.slice(0,32))) unlinkSync(join(options.directory, name));
    }
  };
  const server = createServer(async (req, res) => {
    res.setHeader("Cache-Control", "no-store");
    res.setHeader("Referrer-Policy", "no-referrer");
    res.setHeader("X-Content-Type-Options", "nosniff");
    res.setHeader("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' blob:; base-uri 'none'; frame-ancestors 'none'; form-action 'self'");
    try {
      const url = new URL(req.url ?? "/", options.origin);
      if (url.origin !== origin.origin || url.search) throw new Failure(400);
      if (req.headers.origin && req.headers.origin !== origin.origin && !(options.allowedOrigins ?? []).includes(req.headers.origin)) throw new Failure(403);
      if (req.headers.origin) {
        res.setHeader("Access-Control-Allow-Origin", req.headers.origin);
        res.setHeader("Vary", "Origin");
      }
      if (req.method === "OPTIONS") {
        if (!req.headers.origin) throw new Failure(403);
        res.setHeader("Access-Control-Allow-Methods", "GET, POST, DELETE");
        res.setHeader("Access-Control-Allow-Headers", "Authorization, Content-Type");
        res.writeHead(204); res.end(); return;
      }
      rate("request:" + req.socket.remoteAddress, 300, 60000);
      if (req.method === "GET" && ["/viewer.js", "/style.css"].includes(url.pathname)) {
        res.setHeader("Content-Type", url.pathname.endsWith(".js") ? "text/javascript; charset=utf-8" : "text/css; charset=utf-8");
        res.end(readFileSync(new URL("../public" + url.pathname, import.meta.url))); return;
      }
      if (req.method === "GET" && /^\/s\/[a-f0-9]{32}$/.test(url.pathname)) {
        res.setHeader("Content-Type", "text/html; charset=utf-8"); res.end(readFileSync(new URL("../public/index.html", import.meta.url))); return;
      }
      if (req.method === "GET" && url.pathname === "/api/capabilities") { json(res, 200, { version: 1, emailVerification: Boolean(options.sendCode), expiries: [...expiries], maxBytes: maximum }); return; }
      if (req.method === "GET" && url.pathname === "/api/shares") {
        const owner = authenticate(req);
        const shares = db.prepare("SELECT id,expiry,recipient IS NOT NULL AS restricted FROM shares WHERE owner=? AND expiry>? ORDER BY expiry").all(owner, now());
        json(res, 200, { shares }); return;
      }
      if (req.method === "POST" && url.pathname === "/api/shares") {
        const owner = authenticate(req);
        rate("create:" + owner, 30, 60000);
        const input = await body(req, maximum);
        if (Object.keys(input).some(key => !["id","version","nonce","ciphertext","expiresIn","recipientEmail"].includes(key))) throw new Failure(400);
        if (typeof input.id !== "string" || !idPattern.test(input.id) || input.version !== 1 || !expiries.has(Number(input.expiresIn))) throw new Failure(400);
        if (typeof input.nonce !== "string" || typeof input.ciphertext !== "string" || !/^[A-Za-z0-9+/]+={0,2}$/.test(input.nonce) || !/^[A-Za-z0-9+/]+={0,2}$/.test(input.ciphertext)) throw new Failure(400);
        if (Buffer.from(input.nonce, "base64").length !== 12 || Buffer.from(input.ciphertext, "base64").length < 16) throw new Failure(400);
        const recipient = input.recipientEmail == null ? null : hash("email", normalizedEmail(input.recipientEmail));
        if (recipient && !options.sendCode) throw new Failure(503);
        if (db.prepare("SELECT id FROM shares WHERE id=?").get(input.id)) throw new Failure(409);
        const count = db.prepare("SELECT COUNT(*) AS count FROM shares WHERE owner=? AND expiry>?").get(owner, now());
        if (Number(count?.count) >= 1000) throw new Failure(429);
        const expiry = now() + Number(input.expiresIn) * 1000;
        const file = join(options.directory, input.id + ".json");
        const envelope = { version: 1, id: input.id, nonce: input.nonce, ciphertext: input.ciphertext };
        writeFileSync(file, JSON.stringify(envelope), { mode: 0o600, flag: "wx" });
        try { db.prepare("INSERT INTO shares VALUES(?,?,?,?)").run(input.id, owner, expiry, recipient); }
        catch (error) { unlinkSync(file); throw error; }
        json(res, 201, { id: input.id, expiresAt: expiry, url: origin.origin + "/s/" + input.id }); return;
      }
      const match = /^\/api\/shares\/([a-f0-9]{32})(?:\/(challenge|verify))?$/.exec(url.pathname);
      if (!match) throw new Failure(404);
      const id = match[1]; const row = share(id);
      if (req.method === "DELETE" && !match[2]) {
        if (row.owner !== authenticate(req)) throw new Failure(404);
        discard(id); json(res, 200, { ok: true }); return;
      }
      if (req.method === "GET" && !match[2]) {
        if (row.recipient) {
          const session = /(?:^|;\s*)pvshare=([a-f0-9]{64})(?:;|$)/.exec(req.headers.cookie ?? "")?.[1] ?? "";
          if (!db.prepare("SELECT digest FROM sessions WHERE digest=? AND share=? AND expiry>?").get(hash("session", session), id, now())) { json(res, 401, { emailRequired: true }); return; }
        }
        json(res, 200, JSON.parse(readFileSync(join(options.directory, id + ".json"), "utf8"))); return;
      }
      if (req.method === "POST" && match[2] === "challenge") {
        if (!row.recipient || !options.sendCode) throw new Failure(400);
        rate("challenge:" + id, 3, 900000);
        const input = await body(req);
        const email = normalizedEmail(input.email);
        // Always give the same response for a different valid email address.
        if (hash("email", email) === row.recipient) {
          const code = randomInt(0, 1000000).toString().padStart(6, "0");
          db.prepare("INSERT OR REPLACE INTO challenges VALUES(?,?,?,0)").run(id, hash("code:" + id, code), Math.min(row.expiry, now() + 600000));
          try { await options.sendCode(email, code); } catch { db.prepare("DELETE FROM challenges WHERE share=?").run(id); throw new Failure(503); }
        }
        json(res, 202, { ok: true }); return;
      }
      if (req.method === "POST" && match[2] === "verify") {
        rate("verify:" + id, 10, 900000);
        const input = await body(req);
        const challenge = db.prepare("SELECT * FROM challenges WHERE share=? AND expiry>?").get(id, now()) as {digest:string;attempts:number}|undefined;
        if (!challenge || challenge.attempts >= 5 || typeof input.code !== "string" || !/^\d{6}$/.test(input.code)) throw new Failure(403);
        db.prepare("UPDATE challenges SET attempts=attempts+1 WHERE share=?").run(id);
        if (!timingSafeEqual(Buffer.from(challenge.digest), Buffer.from(hash("code:" + id, input.code)))) throw new Failure(403);
        const session = randomBytes(32).toString("hex");
        db.prepare("INSERT INTO sessions VALUES(?,?,?)").run(hash("session", session), id, Math.min(row.expiry, now() + 900000));
        db.prepare("DELETE FROM challenges WHERE share=?").run(id);
        res.setHeader("Set-Cookie", `pvshare=${session}; HttpOnly; SameSite=Strict; Path=/api/shares/${id}; Max-Age=900${origin.protocol === "https:" ? "; Secure" : ""}`);
        json(res, 200, { ok: true }); return;
      }
      throw new Failure(405);
    } catch (error) {
      if (!res.headersSent) json(res, error instanceof Failure ? error.status : 500, { error: "Request unavailable" });
      else res.end();
    }
  });
  server.requestTimeout = 30000; server.headersTimeout = 10000;
  purge();
  const timer = setInterval(() => { try { purge(); } catch { console.error("Share cleanup failed; expired links remain inaccessible"); } }, 60000); timer.unref();
  server.on("close", () => { clearInterval(timer); db.close(); });
  return { server, purge };
}
