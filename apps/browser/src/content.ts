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
  // Some sites render passwords in plain `type="text"` inputs (for example
  // name="password" placeholder="设置登录密码"). Recognize only explicit password
  // names/labels and never captcha, OTP, hint or search fields.
  function textHints(el: HTMLInputElement) {
    return [
      el.name,
      el.id,
      el.placeholder,
      el.getAttribute("aria-label"),
      el.labels?.[0]?.textContent,
    ]
      .filter(Boolean)
      .join(" ");
  }
  function namedPassword(el: HTMLInputElement) {
    if (el.type !== "text") return false;
    const tokens = el.autocomplete.toLowerCase().split(/\s+/);
    if (
      tokens.some((t) =>
        ["username", "email", "tel", "one-time-code"].includes(t),
      )
    )
      return false;
    const hints = textHints(el);
    if (
      /验证码|校验码|动态码|captcha|otp|code|hint|提示|question|问题|search|搜索/i.test(
        hints,
      )
    )
      return false;
    return (
      /^(?:(?:user|login|new|confirm|re)[_-]?)?(?:pass(?:word)?|passwd|pwd)(?:[_-]?(?:confirm(?:ation)?|again|repeat|2))?$/i.test(
        el.name,
      ) ||
      /^(?:(?:user|login|new|confirm|re)[_-]?)?(?:pass(?:word)?|passwd|pwd)(?:[_-]?(?:confirm(?:ation)?|again|repeat|2))?$/i.test(
        el.id,
      ) ||
      /密码|口令|password|passwort|contraseña|mot de passe|пароль/i.test(hints)
    );
  }
  chrome.runtime.onMessage.addListener((request, sender, respond) => {
    if (
      sender.id !== chrome.runtime.id ||
      request.origin !== location.origin ||
      !["http:", "https:"].includes(location.protocol)
    )
      return;
    const passwords = Array.from(
      document.querySelectorAll<HTMLInputElement>("input"),
    ).filter((v) => (v.type === "password" || namedPassword(v)) && visible(v));
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
      ).filter(
        (v) =>
          visible(v) &&
          !passwords.includes(v) &&
          !!(
            v.compareDocumentPosition(password) &
            Node.DOCUMENT_POSITION_FOLLOWING
          ),
      )[0] ??
      Array.from(
        scope.querySelectorAll<HTMLInputElement>(
          'input[type="email"],input[type="text"]',
        ),
      ).filter((v) => visible(v) && !passwords.includes(v))[0];
    if (request.action === "vault-capture") {
      const group = passwords.filter((p) => p.form === password.form);
      if (
        !password.value ||
        group.length > 2 ||
        (group.length === 2 &&
          (password.autocomplete.includes("current-password") ||
            !(
              /confirm|repeat|确认|重复/i.test(
                [group[1].name, group[1].id, group[1].placeholder].join(" "),
              ) || group.every((p) => p.autocomplete.includes("new-password"))
            ) ||
            group[1].value !== password.value))
      ) {
        respond({ ok: false });
        return;
      }
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
