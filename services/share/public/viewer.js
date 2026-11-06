const id = location.pathname.split("/").pop();
const encodedKey = location.hash.slice(1);
const status = document.querySelector("#status");
const emailForm = document.querySelector("#email-form");
const codeForm = document.querySelector("#code-form");
const content = document.querySelector("#content");
const files = [];
const decode = value => Uint8Array.from(atob(value.replaceAll("-", "+").replaceAll("_", "/")), c => c.charCodeAt(0));
async function api(suffix = "", body) {
  const response = await fetch(`/api/shares/${id}${suffix}`, { method: body ? "POST" : "GET", credentials: "same-origin", cache: "no-store", headers: body ? { "Content-Type": "application/json" } : {}, body: body ? JSON.stringify(body) : undefined });
  if (response.status === 401) { emailForm.hidden = false; throw new Error("此分享仅限指定邮箱，请先验证。 Verify the recipient email first."); }
  if (!response.ok) throw new Error("链接不可用、已过期、验证码错误或请求过于频繁。请检查后重试。 Share unavailable, expired, incorrect code, or rate limited.");
  return response.json();
}
async function load() {
  try {
    if (!/^[a-f0-9]{32}$/.test(id) || !/^[A-Za-z0-9_-]{43}$/.test(encodedKey)) throw new Error("分享链接不完整，请使用包含密钥的完整链接。 Use the complete share link including its key.");
    const envelope = await api();
    if (envelope.id !== id || envelope.version !== 1) throw new Error("Invalid share format");
    const key = await crypto.subtle.importKey("raw", decode(encodedKey), "AES-GCM", false, ["decrypt"]);
    const clear = await crypto.subtle.decrypt({ name: "AES-GCM", iv: decode(envelope.nonce), additionalData: new TextEncoder().encode(`PasswordVaultShare/v1/${id}`) }, key, decode(envelope.ciphertext));
    const item = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(clear));
    document.querySelector("#title").textContent = typeof item.title === "string" ? item.title : "Shared item";
    const fields = document.querySelector("#fields"); fields.replaceChildren();
    for (const [name, value] of Object.entries(item.fields ?? {})) {
      const label = document.createElement("dt"); label.textContent = name;
      const field = document.createElement("dd"); field.textContent = typeof value === "string" ? value : JSON.stringify(value);
      fields.append(label, field);
    }
    const attachments = document.querySelector("#files"); attachments.replaceChildren();
    for (const file of item.attachments ?? []) {
      if (typeof file.name !== "string" || typeof file.data !== "string") continue;
      const url = URL.createObjectURL(new Blob([decode(file.data)], { type: "application/octet-stream" })); files.push(url);
      const link = document.createElement("a"); link.href = url; link.download = file.name.replaceAll(/[\\/\x00-\x1F]/g, "_"); link.textContent = `下载附件 / Download: ${file.name}`; attachments.append(link);
    }
    emailForm.hidden = true; codeForm.hidden = true; content.hidden = false;
    status.textContent = "已在此设备解密 / Decrypted on this device";
  } catch (error) { status.textContent = error instanceof DOMException ? "无法解密，密钥错误或内容已损坏。 Incorrect key or damaged content." : error.message; }
}
emailForm.addEventListener("submit", async event => {
  event.preventDefault(); const button = emailForm.querySelector("button"); button.disabled = true;
  try { await api("/challenge", { email: document.querySelector("#email").value }); codeForm.hidden = false; status.textContent = "若邮箱匹配，验证码已发送。 If the email matches, a code has been sent."; }
  catch (error) { status.textContent = error.message; } finally { button.disabled = false; }
});
codeForm.addEventListener("submit", async event => {
  event.preventDefault(); const button = codeForm.querySelector("button"); button.disabled = true;
  try { await api("/verify", { code: document.querySelector("#code").value }); document.querySelector("#code").value = ""; await load(); }
  catch (error) { status.textContent = error.message; } finally { button.disabled = false; }
});
addEventListener("pagehide", () => { for (const url of files) URL.revokeObjectURL(url); content.replaceChildren(); });
void load();
