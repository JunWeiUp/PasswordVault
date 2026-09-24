// Injected only after a user clicks Fill or Read from page. No observers or idle work.
(() => {
  const context = window as typeof window & { __passwordVaultV2?: boolean };
  if (context.__passwordVaultV2 || window.top !== window) return;
  context.__passwordVaultV2 = true;
  const visible = (input: HTMLInputElement) =>
    !input.disabled &&
    !input.readOnly &&
    input.getClientRects().length > 0 &&
    getComputedStyle(input).visibility !== "hidden";
  chrome.runtime.onMessage.addListener((request, sender, respond) => {
    if (
      sender.id !== chrome.runtime.id ||
      request.origin !== location.origin ||
      !["http:", "https:"].includes(location.protocol)
    )
      return;
    const passwords = Array.from(
      document.querySelectorAll<HTMLInputElement>('input[type="password"]'),
    ).filter(visible);
    const password =
      passwords.find((v) => v.autocomplete === "current-password") ??
      passwords[0];
    if (!password) {
      respond({ ok: false });
      return;
    }
    const scope = password.form ?? document;
    const username =
      Array.from(scope.querySelectorAll<HTMLInputElement>("input"))
        .filter(visible)
        .find((v) => v.autocomplete === "username") ??
      Array.from(
        scope.querySelectorAll<HTMLInputElement>(
          'input[type="email"],input[type="text"]',
        ),
      ).filter(visible)[0];
    if (request.action === "vault-capture") {
      respond({
        ok: true,
        username: username?.value ?? "",
        password: password.value,
      });
      return;
    }
    if (request.action !== "vault-fill") return;
    function set(input: HTMLInputElement | undefined, value: string) {
      if (!input) return;
      Object.getOwnPropertyDescriptor(
        HTMLInputElement.prototype,
        "value",
      )!.set!.call(input, value);
      input.dispatchEvent(new Event("input", { bubbles: true }));
      input.dispatchEvent(new Event("change", { bubbles: true }));
    }
    set(username, request.username);
    set(password, request.password);
    respond({ ok: true });
  });
})();
