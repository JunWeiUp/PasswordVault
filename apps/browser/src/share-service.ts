export type ShareEnvelope = {
  version: number;
  id: string;
  nonce: string;
  ciphertext: string;
  key: string;
};
export class ShareService {
  private base: URL;
  constructor(
    endpoint: string,
    private token: string,
    private fetcher: typeof fetch = globalThis.fetch.bind(globalThis),
  ) {
    this.base = new URL(endpoint);
    if (
      !(
        this.base.protocol === "https:" ||
        (this.base.protocol === "http:" &&
          ["localhost", "127.0.0.1", "[::1]"].includes(this.base.hostname))
      ) ||
      this.base.username ||
      this.base.password ||
      this.base.search ||
      this.base.hash ||
      this.base.pathname !== "/" ||
      token.length < 32
    )
      throw new Error("Invalid share service configuration");
  }
  private async request(
    path: string,
    method: string,
    body?: unknown,
    signal?: AbortSignal,
  ) {
    const response = await this.fetcher(new URL(path, this.base), {
      method,
      signal,
      redirect: "error",
      credentials: "omit",
      cache: "no-store",
      headers: {
        Authorization: `Bearer ${this.token}`,
        ...(body ? { "Content-Type": "application/json" } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    });
    if (!response.ok)
      throw new Error(`Share request failed (${response.status})`);
    const text = await response.text();
    if (text.length > 1024 * 1024) throw new Error("Share response too large");
    return JSON.parse(text);
  }
  capabilities(signal?: AbortSignal) {
    return this.request("api/capabilities", "GET", undefined, signal);
  }
  list(signal?: AbortSignal) {
    return this.request("api/shares", "GET", undefined, signal);
  }
  async revoke(id: string, signal?: AbortSignal) {
    if (!/^[a-f0-9]{32}$/.test(id)) throw new Error("Invalid share ID");
    await this.request(`api/shares/${id}`, "DELETE", undefined, signal);
  }
  async create(
    envelope: ShareEnvelope,
    expiresIn: number,
    email?: string,
    signal?: AbortSignal,
  ) {
    if (
      !/^[a-f0-9]{32}$/.test(envelope.id) ||
      !/^[A-Za-z0-9_-]{43}$/.test(envelope.key) ||
      ![3600, 86400, 604800, 2592000].includes(expiresIn)
    )
      throw new Error("Invalid share snapshot");
    const { key, ...ciphertext } = envelope;
    const response = await this.request(
      "api/shares",
      "POST",
      { ...ciphertext, expiresIn, ...(email ? { recipientEmail: email } : {}) },
      signal,
    );
    if (response.id !== envelope.id) throw new Error("Share ID mismatch");
    const url = new URL(`s/${envelope.id}`, this.base);
    url.hash = key;
    return url.href;
  }
}
