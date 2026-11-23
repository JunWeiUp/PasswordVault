// Isolated-world UI: only explicit trusted clicks can request a fill. Passwords are
// delivered once to the selected live field, not returned as account-list metadata.
(() => {
  // In-page UI language. Content scripts cannot read the extension pages' localStorage, so
  // the pages mirror the language to chrome.storage.local ("uiLanguage"); in-page UI stays light.
  const INLINE_EN: Record<string, string> = {
    "PasswordVault · 生成密码": "PasswordVault · Generate password",
    "PasswordVault · 选择账号": "PasswordVault · Choose login",
    "PasswordVault 匹配账号": "PasswordVault matching logins",
    "PasswordVault：选择本站账号": "PasswordVault: choose a login for this site",
    "仅填入当前表单，不自动登录": "Fills this form only; never signs in automatically",
    "关闭": "Close",
    "大写字母 A–Z": "Uppercase A–Z",
    "密码长度（8–128）": "Password length (8–128)",
    "小写字母 a–z": "Lowercase a–z",
    "数字 0–9": "Digits 0–9",
    "无法填入：请解锁资料库或关闭后重新选择": "Couldn't fill: unlock the vault, or close and choose again",
    "未填写用户名": "No username",
    "本站暂无可用账号": "No logins for this site",
    "使用通行密钥登录": "Sign in with a passkey",
    "在 PasswordVault 中确认并选择通行密钥": "Confirm and choose a passkey in PasswordVault",
    "正在等待确认…": "Waiting for confirmation…",
    "未完成通行密钥登录，可重新选择": "Passkey sign-in not completed; you can choose again",
    "正在查找账号…": "Finding logins…",
    "特殊字符 !@#$%&*+-": "Symbols !@#$%&*+-",
    "生成并填入 {length} 位密码": "Generate and fill a {length}-character password",
    "生成随机密码，仅填入当前字段；提交成功后请确认保存。": "Generates a random password into this field only; confirm saving after you submit successfully.",
    "请先在 PasswordVault 中解锁，再重试": "Unlock PasswordVault, then try again",
    "请输入有效长度并至少选择一种字符": "Enter a valid length and choose at least one character type",
    "账号": "Login"
  };
  let inlineLanguage: "zh" | "en" = "zh";
  const inlineText = (text: string): string => (inlineLanguage === "en" ? INLINE_EN[text] ?? text : text);
  try {
    void chrome.storage.local.get("uiLanguage").then((value) => { inlineLanguage = value.uiLanguage === "en" ? "en" : "zh"; }, () => {});
    chrome.storage.onChanged.addListener((changes, area) => {
      if (area === "local" && changes.uiLanguage) inlineLanguage = changes.uiLanguage.newValue === "en" ? "en" : "zh";
    });
  } catch {
    // Without storage access the in-page UI stays Chinese.
  }
  const context = window as typeof window & { __pvInline?: boolean };
  if (context.__pvInline || !/^https?:$/.test(location.protocol)) return;
  // Only same-origin embedded login pages may use the top page's vault matches.
  try {
    if (window.top?.location.origin !== location.origin) return;
  } catch {
    return;
  }
  context.__pvInline = true;
  const origin = location.origin;
  type Account = {
    id: string;
    accountId?: string;
    title: string;
    username: string;
  };
  type Control = {
    input: HTMLInputElement;
    host: HTMLElement;
    button: HTMLButtonElement;
  };
  const controls = new Map<HTMLInputElement, Control>();
  const passwordFields = new WeakMap<
    HTMLInputElement,
    { form: HTMLFormElement | null; identity: string }
  >();
  const identity = (el: HTMLInputElement) =>
    [el.id, el.name, el.autocomplete].join("\u0000");
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
    if (tokens.some((t) => ["username", "email", "tel", "one-time-code"].includes(t)))
      return false;
    const hints = textHints(el);
    if (/验证码|校验码|动态码|captcha|otp|code|hint|提示|question|问题|search|搜索/i.test(hints))
      return false;
    return (
      /^(?:(?:user|login|new|confirm|re)[_-]?)?(?:pass(?:word)?|passwd|pwd)(?:[_-]?(?:confirm(?:ation)?|again|repeat|2))?$/i.test(el.name) ||
      /^(?:(?:user|login|new|confirm|re)[_-]?)?(?:pass(?:word)?|passwd|pwd)(?:[_-]?(?:confirm(?:ation)?|again|repeat|2))?$/i.test(el.id) ||
      /密码|口令|password|passwort|contraseña|mot de passe|пароль/i.test(hints)
    );
  }
  function newPassword(el: HTMLInputElement) {
    if (el.autocomplete.toLowerCase().split(/\s+/).includes("new-password")) return true;
    return (
      namedPassword(el) &&
      /new|set|create|confirm|repeat|again|register|sign.?up|设置|新|创建|确认|重复|再次|注册/i.test(
        textHints(el),
      )
    );
  }
  function credentialField(el: HTMLInputElement) {
    const tokens = el.autocomplete.toLowerCase().split(/\s+/);
    if (tokens.includes("username") && ["text", "email", "tel"].includes(el.type)) return true;
    if (tokens.includes("new-password") && ["text", "password"].includes(el.type)) return true;
    if (tokens.includes("one-time-code") && ["text", "tel", "number"].includes(el.type)) return true;
    if (el.type === "password") {
      passwordFields.set(el, { form: el.form, identity: identity(el) });
      return true;
    }
    if (el.type !== "text") return false;
    const prior = passwordFields.get(el);
    return (
      tokens.includes("current-password") ||
      namedPassword(el) ||
      (prior?.form === el.form && prior?.identity === identity(el))
    );
  }
  let count = 0,
    checked = 0,
    checking = false,
    timer: ReturnType<typeof setTimeout> | undefined;
  let panel: HTMLElement | undefined,
    menuControl: Control | undefined,
    revision = 0;
  let delivery:
    | {
        token: string;
        input: HTMLInputElement;
        form: HTMLFormElement | null;
        username?: HTMLInputElement;
        expires: number;
        href: string;
      }
    | undefined;
  const visible = (input: HTMLInputElement) => {
    if (
      !input.isConnected ||
      input.matches(":disabled") ||
      input.readOnly ||
      input.closest("[inert]")
    )
      return false;
    const rect = input.getBoundingClientRect();
    if (!rect.width || !rect.height || !input.getClientRects().length)
      return false;
    for (
      let element: Element | null = input;
      element;
      element = element.parentElement
    ) {
      const style = getComputedStyle(element);
      if (
        ["hidden", "collapse"].includes(style.visibility) ||
        style.display === "none" ||
        Number(style.opacity) === 0
      )
        return false;
    }
    return true;
  };
  const eligible = (el: HTMLInputElement) => credentialField(el) && visible(el);
  const send = async (action: string, args = {}) => {
    try {
      return await chrome.runtime.sendMessage({ action, ...args });
    } catch {
      return undefined;
    }
  };
  function close() {
    revision++;
    panel?.remove();
    panel = undefined;
    menuControl?.button.setAttribute("aria-expanded", "false");
    menuControl = undefined;
    delivery = undefined;
  }
  function mount(host: HTMLElement) {
    host.style.cssText =
      "position:fixed;inset:auto;margin:0;padding:0;border:0;background:transparent;overflow:visible;z-index:2147483647;color-scheme:light";
    if ("showPopover" in host) host.setAttribute("popover", "manual");
    document.documentElement.append(host);
    try {
      if ("showPopover" in host) host.showPopover();
    } catch {
      /* fixed overlay fallback */
    }
  }
  function position(c: Control) {
    const r = c.input.getBoundingClientRect();
    let left = r.right - 32;
    // Reveal controls are often an SVG/span rather than a semantic button.
    for (const sibling of Array.from(
      c.input.parentElement?.querySelectorAll(
        'button,[role="button"],svg,img,i,span,div',
      ) ?? [],
    )) {
      const eye = sibling.getBoundingClientRect();
      if (
        eye.width > 0 &&
        eye.width <= 44 &&
        eye.height > 0 &&
        eye.height <= 44 &&
        eye.left >= r.right - 72 &&
        eye.right <= r.right + 2 &&
        eye.top < r.bottom &&
        eye.bottom > r.top
      ) {
        left = Math.min(left, eye.left - 30);
      }
    }
    c.host.style.left = `${Math.max(r.left + 4, left)}px`;
    c.host.style.top = `${r.top + (r.height - 26) / 2}px`;
    c.host.style.display =
      r.top < 0 ||
      r.bottom > innerHeight ||
      r.right > innerWidth ||
      r.width < 70 ||
      !eligible(c.input)
        ? "none"
        : "block";
  }
  async function open(c: Control) {
    close();
    if (!eligible(c.input)) return;
    menuControl = c;
    c.button.setAttribute("aria-expanded", "true");
    const ownRevision = revision;
    const href = location.href;
    const form = c.input.form;
    const username = usernameFor(c.input);
    panel = document.createElement("div");
    mount(panel);
    const host = panel,
      root = host.attachShadow({ mode: "closed" });
    const style = document.createElement("style");
    style.textContent =
      ":host{all:initial}.card{box-sizing:border-box;width:300px;max-width:calc(100vw - 16px);font:13px/1.5 system-ui;background:#fff;color:#1d2739;border:1px solid #d9dfeb;border-radius:12px;max-height:calc(100vh - 16px);display:flex;flex-direction:column;box-shadow:0 8px 32px #15254430;padding:8px}.head{font-weight:600;padding:8px}button{font:inherit;display:block;text-align:left;width:100%;border:0;border-radius:8px;background:white;color:inherit;padding:10px;cursor:pointer}button:hover,button:focus-visible{background:#eaf0ff;outline:2px solid #b8ceff}small{display:block;color:#65718a;overflow:hidden;text-overflow:ellipsis}strong{display:block;overflow:hidden;text-overflow:ellipsis}.list{max-height:240px;min-height:0;overflow:auto}.generator{display:grid;gap:8px;padding:8px}.generator label{display:flex;align-items:center;gap:8px}.generator input[type=number]{width:72px;font:inherit}.generator input[type=checkbox]{accent-color:#2761d8}button:disabled{opacity:.5;cursor:default}.status{padding:10px;color:#65718a}";
    const card = document.createElement("section");
    card.className = "card";
    card.setAttribute("aria-label", inlineText("PasswordVault 匹配账号"));
    const head = document.createElement("div");
    head.className = "head";
    head.textContent = inlineText("PasswordVault · 选择账号");
    const status = document.createElement("div");
    status.className = "status";
    status.setAttribute("role", "status");
    status.textContent = inlineText("正在查找账号…");
    const list = document.createElement("div");
    list.className = "list";
    const dismiss = document.createElement("button");
    dismiss.textContent = inlineText("关闭");
    dismiss.onclick = (e) => {
      if (e.isTrusted) {
        close();
        c.input.focus();
      }
    };
    card.append(head, status, list, dismiss);
    root.append(style, card);
    const r = c.input.getBoundingClientRect();
    host.style.left = `${Math.max(8, Math.min(r.right - 300, innerWidth - 308))}px`;
    host.style.top = `${Math.max(8, Math.min(r.bottom + 6, innerHeight - 330))}px`;
    if (newPassword(c.input)) {
      status.textContent = inlineText("生成随机密码，仅填入当前字段；提交成功后请确认保存。");
      head.textContent = inlineText("PasswordVault · 生成密码");
      const options = document.createElement("div");
      options.className = "generator";
      const lengthLabel = document.createElement("label");
      lengthLabel.textContent = inlineText("密码长度（8–128）");
      const lengthInput = document.createElement("input");
      lengthInput.type = "number";
      lengthInput.min = "8";
      lengthInput.max = "128";
      lengthInput.step = "1";
      lengthInput.value = "24";
      lengthLabel.append(lengthInput);
      options.append(lengthLabel);
      const groups = [
        [inlineText("大写字母 A–Z"), "ABCDEFGHIJKLMNOPQRSTUVWXYZ"],
        [inlineText("小写字母 a–z"), "abcdefghijklmnopqrstuvwxyz"],
        [inlineText("数字 0–9"), "0123456789"],
        [inlineText("特殊字符 !@#$%&*+-"), "!@#$%&*+-"],
      ].map(([title, alphabet]) => {
        const label = document.createElement("label");
        const checkbox = document.createElement("input");
        checkbox.type = "checkbox";
        checkbox.checked = true;
        label.append(checkbox, document.createTextNode(title));
        options.append(label);
        return { checkbox, alphabet };
      });
      const generate = document.createElement("button");
      const validate = () => {
        const length = lengthInput.valueAsNumber;
        const valid = Number.isInteger(length) && length >= 8 && length <= 128 &&
          groups.some(group => group.checkbox.checked);
        generate.disabled = !valid;
        generate.textContent = valid ? inlineText("生成并填入 {length} 位密码").replace("{length}", String(length)) : inlineText("请输入有效长度并至少选择一种字符");
        return valid;
      };
      options.addEventListener("input", validate);
      validate();
      generate.onclick = (event) => {
        if (!event.isTrusted || ownRevision !== revision || !eligible(c.input) || c.input.form !== form || href !== location.href) return;
        if (!validate()) return;
        const length = lengthInput.valueAsNumber;
        const selected = groups.filter(group => group.checkbox.checked).map(group => group.alphabet);
        const alphabet = selected.join("");
        let value = "";
        while (value.length < length || !selected.every(group => [...value].some(char => group.includes(char)))) {
          if (value.length === length) value = "";
          const bytes = crypto.getRandomValues(new Uint8Array(128));
          for (const byte of bytes) {
            const ceiling = Math.floor(256 / alphabet.length) * alphabet.length;
            if (byte < ceiling && value.length < length) value += alphabet[byte % alphabet.length];
          }
        }
        const targets = c.input.form ? Array.from(c.input.form.querySelectorAll<HTMLInputElement>("input")).filter(input=>newPassword(input) && eligible(input)) : [c.input];
        if (!targets.includes(c.input) || targets.length > 2) { value=""; return; }
        for(const input of targets) {
          if(!eligible(input) || input.form!==form || href!==location.href) break;
          Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input, value);
          input.dispatchEvent(new Event("input", { bubbles: true }));
          input.dispatchEvent(new Event("change", { bubbles: true }));
        }
        value = "";
        close();
        c.input.focus();
      };
      list.append(options, generate);
      const panelHeight = host.getBoundingClientRect().height;
      host.style.top = `${Math.max(8, Math.min(r.bottom + 6, innerHeight - panelHeight - 8))}px`;
      root.addEventListener("keydown", (event) => {
        if (event instanceof KeyboardEvent && event.key === "Escape") {
          event.preventDefault();
          close();
          c.input.focus();
        }
      });
      lengthInput.focus();
      return;
    }
    // Conditional mediation: the page asked for passkey autofill; offer it first.
    const conditional = (globalThis as any).pvConditionalPasskey;
    if (window === top && conditional?.available() && !c.input.autocomplete.split(/\s+/).includes("one-time-code")) {
      const button = document.createElement("button");
      button.type = "button";
      const title = document.createElement("strong");
      title.textContent = inlineText("使用通行密钥登录");
      const note = document.createElement("small");
      note.textContent = inlineText("在 PasswordVault 中确认并选择通行密钥");
      button.append(title, note);
      button.onclick = async (e) => {
        if (!e.isTrusted || ownRevision !== revision || href !== location.href || !conditional.available()) return;
        button.disabled = true;
        status.textContent = inlineText("正在等待确认…");
        const outcome = await conditional.start();
        if (panel !== host) return;
        if (outcome?.ok) { close(); return; }
        button.disabled = false;
        status.textContent = inlineText("未完成通行密钥登录，可重新选择");
      };
      list.append(button);
    }
    const result = await send("inline-accounts", {field: c.input.autocomplete.split(/\s+/).includes("one-time-code") ? "otp" : "login"});
    if (ownRevision !== revision || panel !== host) return;
    if (!eligible(c.input)) {
      close();
      return;
    }
    if (
      c.input.form !== form ||
      href !== location.href ||
      usernameFor(c.input) !== username
    ) {
      close();
      return;
    }
    if (!result?.ok || !result.data?.accounts?.length) {
      status.textContent = result?.ok
        ? inlineText("本站暂无可用账号")
        : inlineText("请先在 PasswordVault 中解锁，再重试");
      dismiss.focus();
      return;
    }
    status.textContent = inlineText("仅填入当前表单，不自动登录");
    for (const account of result.data.accounts as Account[]) {
      const button = document.createElement("button");
      button.type = "button";
      const title = document.createElement("strong");
      title.textContent = account.title || inlineText("账号");
      const user = document.createElement("small");
      user.textContent = account.username || inlineText("未填写用户名");
      button.append(title, user);
      button.onclick = async (e) => {
        if (!e.isTrusted || ownRevision !== revision || !eligible(c.input))
          return;
        if (
          href !== location.href ||
          c.input.form !== form ||
          usernameFor(c.input) !== username
        ) {
          close();
          return;
        }
        for (const control of Array.from(list.querySelectorAll("button")))
          control.disabled = true;
        const token = crypto.randomUUID();
        delivery = {
          token,
          input: c.input,
          form,
          username,
          expires: Date.now() + 15000,
          href: location.href,
        };
        const filled = await send("inline-fill", {
          token: result.data.token,
          id: account.id,
          accountId: account.accountId,
          deliveryToken: token,
          field: c.input.autocomplete.split(/\s+/).includes("one-time-code") ? "otp" : c.input.autocomplete.split(/\s+/).includes("username") ? "username" : "password",
        });
        if (ownRevision !== revision) return;
        delivery = undefined;
        if (filled?.ok) {
          close();
          c.input.focus();
        } else {
          status.textContent = inlineText("无法填入：请解锁资料库或关闭后重新选择");
          dismiss.focus();
        }
      };
      list.append(button);
    }
    const panelHeight = host.getBoundingClientRect().height;
    host.style.top = `${Math.max(8, Math.min(r.bottom + 6, innerHeight - panelHeight - 8))}px`;
    list.querySelector("button")?.focus();
    root.addEventListener("keydown", (e) => {
      if (!(e instanceof KeyboardEvent)) return;
      if (e.key === "Escape") {
        e.preventDefault();
        close();
        c.button.focus();
      }
      if (["ArrowDown", "ArrowUp"].includes(e.key)) {
        const buttons = Array.from(list.querySelectorAll("button"));
        const index = buttons.indexOf(root.activeElement as HTMLButtonElement);
        e.preventDefault();
        buttons[
          (index + (e.key === "ArrowDown" ? 1 : -1) + buttons.length) %
            buttons.length
        ]?.focus();
      }
    });
  }
  function add(input: HTMLInputElement) {
    const host = document.createElement("div");
    mount(host);
    const root = host.attachShadow({ mode: "closed" });
    const style = document.createElement("style");
    style.textContent =
      ":host{all:initial}button{display:block;box-sizing:border-box;width:26px;height:26px;border:1px solid #c3d1ed;border-radius:7px;background:#eef3ff;color:#255ad7;font:700 17px system-ui;cursor:pointer;padding:0}button:hover{background:#dce7ff}button:focus-visible{outline:2px solid #255ad7;outline-offset:2px}";
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = "P";
    button.title = inlineText("PasswordVault：选择本站账号");
    button.setAttribute("aria-label", inlineText("PasswordVault：选择本站账号"));
    button.setAttribute("aria-expanded", "false");
    root.append(style, button);
    const c = { input, host, button };
    controls.set(input, c);
    button.onclick = (e) => {
      if (e.isTrusted) {
        if (menuControl === c) close();
        else void open(c);
      }
    };
    position(c);
  }
  async function scan(refresh = false) {
    const inputs = Array.from(
      document.querySelectorAll<HTMLInputElement>("input"),
    ).filter(eligible);
    if (
      inputs.length &&
      (refresh || Date.now() - checked > 10000) &&
      !checking &&
      !document.hidden
    ) {
      checking = true;
      try {
        const result = await send("inline-availability");
        count = result?.ok ? result.data.count : 0;
        checked = Date.now();
      } finally {
        checking = false;
      }
    }
    for (const [input, c] of controls)
      if ((!count && !newPassword(input)) || !eligible(input) || !c.host.isConnected) {
        if (menuControl === c) close();
        c.host.remove();
        controls.delete(input);
      }
    for (const input of inputs.slice(0, 50))
      if ((count || newPassword(input)) && !controls.has(input)) add(input);
    for (const c of controls.values()) position(c);
  }
  function schedule() {
    if (timer) return;
    timer = setTimeout(() => {
      timer = undefined;
      void scan();
    }, 150);
  }
  function usernameFor(
    password: HTMLInputElement,
  ): HTMLInputElement | undefined {
    if (password.autocomplete.split(/\s+/).some(token => ["username", "one-time-code"].includes(token))) return undefined;
    const preceding = (scope: Element) =>
      Array.from(scope.querySelectorAll<HTMLInputElement>("input")).filter(
        (input) =>
          visible(input) &&
          (!credentialField(input) || input.autocomplete.split(/\s+/).includes("username")) &&
          ["text", "email", "tel"].includes(input.type) &&
          !input.autocomplete.split(/\s+/).includes("one-time-code") &&
          !!(
            input.compareDocumentPosition(password) &
            Node.DOCUMENT_POSITION_FOLLOWING
          ),
      );
    if (password.form) {
      const fields = preceding(password.form);
      return (
        fields.find((input) =>
          input.autocomplete.split(/\s+/).includes("username"),
        ) ?? fields.at(-1)
      );
    }
    // Framework login panels often omit <form>. Use the nearest bounded group
    // with exactly one password and one explicitly labelled account field.
    let scope = password.parentElement;
    for (
      let depth = 0;
      scope && scope !== document.body && depth < 6;
      depth++, scope = scope.parentElement
    ) {
      const passwords = Array.from(
        scope.querySelectorAll<HTMLInputElement>("input"),
      ).filter(eligible);
      if (passwords.length !== 1 || passwords[0] !== password) return undefined;
      const fields = preceding(scope);
      if (fields.length > 1) return undefined;
      if (fields.length === 1) {
        const field = fields[0];
        const hints = [
          field.autocomplete,
          field.name,
          field.id,
          field.placeholder,
          field.getAttribute("aria-label"),
        ].join(" ");
        return ["email", "tel"].includes(field.type) ||
          /username|email|e-mail|account|手机号|手机号码|邮箱|用户名|账号/i.test(
            hints,
          )
          ? field
          : undefined;
      }
    }
    return undefined;
  }
  const observer = new MutationObserver((records) => {
    for (const record of records) {
      if (
        record.attributeName === "type" &&
        record.oldValue === "password" &&
        record.target instanceof HTMLInputElement
      ) {
        const input = record.target;
        passwordFields.set(input, {
          form: input.form,
          identity: identity(input),
        });
      }
    }
    if (
      records.some(
        (r) =>
          !(r.target instanceof Element) ||
          ![...controls.values()].some(
            (c) => c.host === r.target || c.host.contains(r.target),
          ),
      )
    )
      schedule();
  });
  observer.observe(document.documentElement, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeOldValue: true,
    attributeFilter: [
      "type",
      "disabled",
      "readonly",
      "autocomplete",
      "name",
      "id",
      "class",
      "hidden",
      "inert",
      "style",
    ],
  });
  document.addEventListener("focusin", (e) => {
    if (e.target instanceof HTMLInputElement) void scan(true);
  });
  document.addEventListener(
    "pointerdown",
    (e) => {
      if (panel && e.target !== panel && e.target !== menuControl?.host)
        close();
    },
    true,
  );
  window.addEventListener(
    "scroll",
    () => {
      close();
      schedule();
    },
    true,
  );
  window.addEventListener("resize", () => {
    close();
    schedule();
  });
  window.addEventListener("focus", () => {
    if (Date.now() - checked > 1000) void scan(true);
  });
  window.addEventListener("pagehide", close);
  window.addEventListener("popstate", close);
  window.addEventListener("hashchange", close);
  document.addEventListener("visibilitychange", () => {
    close();
    if (!document.hidden) void scan(true);
  });
  chrome.runtime.onMessage.addListener((request, sender, respond) => {
    if (sender.id !== chrome.runtime.id) return;
    if (request.action === "inline-cancel") {
      close();
      count = 0;
      void scan();
      return;
    }
    if (request.action !== "inline-deliver") return;
    const target = delivery;
    delivery = undefined;
    if (
      !target ||
      target.token !== request.deliveryToken ||
      target.expires < Date.now() ||
      target.href !== location.href ||
      request.origin !== origin ||
      !eligible(target.input) ||
      target.input.form !== target.form ||
      usernameFor(target.input) !== target.username ||
      document.hidden
    ) {
      respond({ ok: false });
      return;
    }
    const set = (input: HTMLInputElement | undefined, value: string) => {
      if (!input) return;
      Object.getOwnPropertyDescriptor(
        HTMLInputElement.prototype,
        "value",
      )!.set!.call(input, value);
      input.dispatchEvent(new Event("input", { bubbles: true }));
      input.dispatchEvent(new Event("change", { bubbles: true }));
    };
    set(target.username, request.username);
    if (
      !eligible(target.input) ||
      target.input.form !== target.form ||
      usernameFor(target.input) !== target.username ||
      target.href !== location.href ||
      document.hidden
    ) {
      respond({ ok: false });
      return;
    }
    set(target.input, target.input.autocomplete.split(/\s+/).includes("one-time-code") ? request.code : target.input.autocomplete.split(/\s+/).includes("username") ? request.username : request.password);
    respond({ ok: true });
  });
  let refresh: ReturnType<typeof setInterval> | undefined;
  function startRefresh() {
    if (refresh) clearInterval(refresh);
    refresh = setInterval(() => {
      if (!document.hidden) void scan(true);
    }, 30000);
  }
  startRefresh();
  window.addEventListener("pagehide", () => {
    clearInterval(refresh);
    close();
  });
  window.addEventListener("pageshow", () => {
    startRefresh();
    void scan(true);
  });
  void scan(true);
})();
