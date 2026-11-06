export type DAVConfig = {
  url: string;
  username: string;
  password: string;
  folder: string;
};
export type RemoteBackup = {
  url: string;
  name: string;
  size?: number;
  modified?: string;
};
export function davBase(config: DAVConfig): URL {
  const url = new URL(config.url);
  if (
    url.username ||
    url.password ||
    url.search ||
    url.hash ||
    !(
      url.protocol === "https:" ||
      (url.protocol === "http:" &&
        ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname))
    )
  )
    throw Error("Invalid service URL");
  if (
    config.username.includes(":") ||
    config.folder.startsWith("/") ||
    config.folder
      .split("/")
      .some((v) => v === ".." || v === "." || /[\\%?#]/.test(v))
  )
    throw Error("Invalid folder");
  if (!url.pathname.endsWith("/")) url.pathname += "/";
  url.pathname += config.folder
    .split("/")
    .filter(Boolean)
    .map(encodeURIComponent)
    .join("/");
  if (!url.pathname.endsWith("/")) url.pathname += "/";
  return url;
}
export function davChild(base: URL, path: string): URL {
  const url = new URL(path, base);
  const decoded = decodeURIComponent(url.pathname);
  if (
    url.origin !== base.origin ||
    url.username ||
    url.password ||
    url.search ||
    url.hash ||
    !url.pathname.startsWith(base.pathname) ||
    decoded.includes("\\") ||
    decoded.split("/").includes("..") ||
    /%(?:2e|2f|5c)/i.test(decoded)
  )
    throw Error("Untrusted file URL");
  return url;
}
export class WebDAVClient {
  readonly base: URL;
  private authorization: string;
  constructor(
    config: DAVConfig,
    private signal: AbortSignal,
    private transport: typeof fetch = globalThis.fetch.bind(globalThis),
  ) {
    this.base = davBase(config);
    const bytes = new TextEncoder().encode(
      `${config.username}:${config.password}`,
    );
    let binary = "";
    for (const byte of bytes) binary += String.fromCharCode(byte);
    this.authorization = "Basic " + btoa(binary);
    bytes.fill(0);
  }
  async request(
    method: string,
    url = this.base.href,
    body?: string,
  ): Promise<string> {
    const target = davChild(this.base, url);
    const response = await this.transport(target, {
      method,
      body,
      signal: this.signal,
      redirect: "error",
      credentials: "omit",
      cache: "no-store",
      referrerPolicy: "no-referrer",
      headers: {
        Authorization: this.authorization,
        ...(method === "PROPFIND"
          ? { Depth: "1", "Content-Type": "application/xml" }
          : {}),
        ...(method === "PUT"
          ? { "Content-Type": "application/octet-stream", "If-None-Match": "*" }
          : {}),
      },
    });
    if (!response.ok && !(method === "MKCOL" && response.status === 405))
      throw Error(`WebDAV ${response.status}`);
    if (Number(response.headers.get("content-length")) > 64 * 1024 * 1024)
      throw Error("Response too large");
    const reader = response.body?.getReader();
    if (!reader) return "";
    const chunks: Uint8Array[] = [];
    let length = 0;
    try {
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        length += value.length;
        if (length > 64 * 1024 * 1024) throw Error("Response too large");
        chunks.push(value);
      }
    } finally {
      await reader.cancel();
    }
    const bytes = new Uint8Array(length);
    let at = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, at);
      at += chunk.length;
    }
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  }
  async list(): Promise<RemoteBackup[]> {
    const content = await this.request(
      "PROPFIND",
      this.base.href,
      '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>',
    );
    if (content.length > 4 * 1024 * 1024 || /<!DOCTYPE|<!ENTITY/i.test(content))
      throw Error("Invalid listing");
    const doc = new DOMParser().parseFromString(content, "application/xml");
    if (doc.querySelector("parsererror")) throw Error("Invalid listing");
    const files: RemoteBackup[] = [];
    for (const row of Array.from(
      doc.getElementsByTagNameNS("DAV:", "response"),
    )) {
      if (row.getElementsByTagNameNS("DAV:", "collection").length) continue;
      const href = row.getElementsByTagNameNS("DAV:", "href")[0]?.textContent;
      if (!href) continue;
      let url: URL;
      try {
        url = davChild(this.base, href);
      } catch {
        continue;
      }
      if (url.href === this.base.href) continue;
      const size = Number(
        row.getElementsByTagNameNS("DAV:", "getcontentlength")[0]
          ?.textContent ?? NaN,
      );
      const modified =
        row.getElementsByTagNameNS("DAV:", "getlastmodified")[0]?.textContent ??
        undefined;
      files.push({
        url: url.href,
        name: decodeURIComponent(url.pathname.split("/").pop() ?? ""),
        size: Number.isFinite(size) && size >= 0 ? size : undefined,
        modified,
      });
    }
    return files.sort((a, b) => a.name.localeCompare(b.name));
  }
}
