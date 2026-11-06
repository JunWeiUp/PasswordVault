// Capture top-level and same-origin embedded login attempts. Only the top frame
// owns banners, so removing a login iframe cannot remove the save reminder.
(() => {
  const context = window as typeof window & {
    __passwordVaultLoginObserver?: boolean;
  };
  if (
    context.__passwordVaultLoginObserver ||
    !["http:", "https:"].includes(location.protocol)
  )
    return;
  try {
    if (window.top?.location.origin !== location.origin) return;
  } catch {
    return;
  }
  const mainDocument = window === top;
  context.__passwordVaultLoginObserver = true;
  let banner: HTMLElement | undefined;
  let enabled = false;
  let busy = false;
  type Notice = { id: string; origin: string; expires: number };
  let activeNotice: Notice | undefined;
  let savingNotice: string | undefined;
  let repairTimer: ReturnType<typeof setTimeout> | undefined;
  const repair = new MutationObserver(() => {
    if (!activeNotice || banner?.isConnected || repairTimer) return;
    repairTimer = setTimeout(() => {
      repairTimer = undefined;
      if (
        activeNotice &&
        activeNotice.expires > Date.now() &&
        banner &&
        !banner.isConnected
      )
        mountBanner();
    }, 100);
  });
  let bannerTimer: ReturnType<typeof setTimeout> | undefined;
  const removeBanner = () => {
    clearTimeout(bannerTimer);
    clearTimeout(repairTimer);
    repairTimer = undefined;
    repair.disconnect();
    activeNotice = undefined;
    banner?.remove();
    banner = undefined;
  };
  const send = async (request: Record<string, unknown>) => {
    try {
      return await chrome.runtime.sendMessage(request);
    } catch {
      return undefined;
    }
  };
  function mountBanner() {
    if (!banner || !document.documentElement) return;
    document.documentElement.append(banner);
    if ("showPopover" in banner) {
      try {
        banner.showPopover();
      } catch {
        /* Older shells retain the fixed-position fallback. */
      }
    }
    if (activeNotice) {
      repair.disconnect();
      repair.observe(document, { childList: true });
      repair.observe(document.documentElement, { childList: true });
    }
  }
  function showBanner(message: string, dismiss = true, notice?: Notice, saved = false) {
    if (!mainDocument) return;
    removeBanner();
    activeNotice = notice;
    banner = document.createElement("div");
    banner.style.cssText =
      "position:fixed;inset:20px 20px auto auto;z-index:2147483647;max-width:360px;width:calc(100vw - 40px);margin:0;border:0;padding:0;background:transparent;overflow:visible";
    if ("showPopover" in banner) banner.setAttribute("popover", "manual");
    const shadow = banner.attachShadow({ mode: "closed" });
    const style = document.createElement("style");
    style.textContent =
      ":host{all:initial}.card{font:14px/1.6 system-ui;color:#243049;background:white;border:1px solid #bdcbe4;border-radius:14px;padding:18px;box-shadow:0 8px 32px #172a5026}strong{font-size:15px}p{margin:8px 0}button{font:inherit;border:1px solid #cbd5e5;background:#f2f5fc;color:#244879;border-radius:7px;padding:6px 12px;cursor:pointer}button:hover{background:#dfe9fc}button:focus-visible{outline:3px solid #84a9f9}";
    const card = document.createElement("section");
    card.className = "card";
    card.setAttribute("role", "status");
    const title = document.createElement("strong");
    title.textContent = saved ? "PasswordVault · 已保存" : "PasswordVault · 登录提醒";
    const description = document.createElement("p");
    description.textContent = message;
    const close = document.createElement("button");
    close.textContent = dismiss ? "暂不保存" : "知道了";
    close.onclick = (event) => {
      if (!event.isTrusted) return;
      removeBanner();
      if (dismiss) void send({ action: "login-dismiss" });
    };
    card.append(title, description);
    if (dismiss || saved) {
      const review = document.createElement("button");
      review.textContent = saved ? "修改账号密码" : "保存";
      review.style.marginRight = "8px";
      const currentBanner = banner;
      review.onclick = async (event) => {
        if (!event.isTrusted || review.disabled || !notice) return;
        review.disabled = true;
        close.disabled = true;
        if (!saved) {
          savingNotice = notice.id;
          review.textContent = "保存中…";
        }
        const result = await send({ action: saved ? "login-open" : "login-save", id: notice.id, saved });
        if (savingNotice === notice.id) savingNotice = undefined;
        if (banner !== currentBanner) return;
        if (result?.ok && !saved) {
          showBanner(result.data?.queued ? "已加密保存在此浏览器，稍后自动同步到 Mac。" : "账号密码已保存。", false,
            { ...notice, expires: Date.now() + 120_000 }, true);
          return;
        }
        review.disabled = false;
        close.disabled = false;
        review.textContent = saved ? "修改账号密码" : "重试保存";
        if (!result?.ok) description.textContent = saved
          ? "请点击浏览器工具栏的 PasswordVault 图标修改账号密码。"
          : result?.error === "expired" || result?.error === "cancelled"
            ? "这次填写已过期或取消，请重新填写后保存。"
            : "保存未完成，请重试，或打开插件检查解锁及连接状态。";
      };
      card.append(review);
    }
    card.append(close);
    shadow.append(style, card);
    mountBanner();
    bannerTimer = setTimeout(
      removeBanner,
      Math.max(0, (notice?.expires ?? Date.now() + 120_000) - Date.now()),
    );
  }
  function prompt(notice: Notice) {
    if (
      !notice ||
      notice.origin !== location.origin ||
      notice.expires <= Date.now()
    )
      return;
    if (activeNotice?.id === notice.id && banner?.isConnected) return;
    showBanner(
      "检测到填写的账号和密码。是否保存？请核对凭据，确认可用后再保存。",
      true,
      notice,
    );
  }
  chrome.runtime.onMessage.addListener((request, sender) => {
    if (sender.id !== chrome.runtime.id) return;
    if (request.action === "reminder-disabled") {
      enabled = false;
      removeBanner();
    }
    if (request.action === "reminder-enabled") enabled = true;
    if (
      request.action === "reminder-cleared" &&
      (!savingNotice || (request.id && request.id !== savingNotice)) &&
      (!request.id || activeNotice?.id === request.id)
    )
      removeBanner();
    if (request.action === "reminder-pending") prompt(request.notice);
    if (
      request.action === "reminder-unavailable" &&
      request.origin === location.origin
    )
      showBanner("请先打开并解锁 PasswordVault，再提交登录以保存账号。", false);
  });
  let hasPassword = !!document.querySelector(
    'input[type="password"], input[autocomplete~="current-password"], input[autocomplete~="new-password"]',
  );
  const refreshStatus = () =>
    send({ action: "login-pending", hasPassword }).then((result) => {
      enabled = result?.data?.enabled === true;
      if (enabled && result?.data?.pending) prompt(result.data.notice);
      else if (result?.ok) removeBanner();
    });
  window.addEventListener("pageshow", () => {
    void refreshStatus();
  });
  window.addEventListener("popstate", () => {
    void refreshStatus();
  });
  void refreshStatus();
  document.addEventListener("focusin", (event) => {
    const target = event.composedPath()[0];
    for (const node of event.composedPath()) {
      if (node instanceof ShadowRoot) observeRoot(node);
    }
    if (
      !hasPassword &&
      target instanceof HTMLInputElement &&
      passwordField(target)
    ) {
      hasPassword = true;
      void refreshStatus();
    }
  });
  // Keep revealed-password identity, without treating arbitrary text inputs as secrets.
  const knownPasswords = new WeakMap<HTMLInputElement, string>();
  const signature = (input: HTMLInputElement) =>
    [input.id, input.name, input.autocomplete].join("\u0000");
  const parent = (element: Element): Element | null =>
    element.parentElement ??
    (element.getRootNode() instanceof ShadowRoot
      ? (element.getRootNode() as ShadowRoot).host
      : null);
  function queryDeep<T extends Element>(
    root: ParentNode,
    selector: string,
  ): T[] {
    const matches: T[] = [];
    for (const element of Array.from(root.children)) {
      if (element.matches(selector)) matches.push(element as T);
      if (element.shadowRoot)
        matches.push(...queryDeep<T>(element.shadowRoot, selector));
      matches.push(...queryDeep<T>(element, selector));
    }
    return matches;
  }
  const passwordField = (input: HTMLInputElement) => {
    const tokens = input.autocomplete.toLowerCase().split(/\s+/);
    if (tokens.some((token) => ["one-time-code", "username"].includes(token)))
      return false;
    if (input.type === "password") {
      knownPasswords.set(input, signature(input));
      return true;
    }
    return (
      input.type === "text" &&
      (tokens.includes("current-password") ||
        tokens.includes("new-password") ||
        knownPasswords.get(input) === signature(input))
    );
  };
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
      element = parent(element)
    ) {
      const style = getComputedStyle(element);
      if (
        ["hidden", "collapse"].includes(style.visibility) ||
        style.display === "none" ||
        Number(style.opacity) === 0 ||
        element.matches('[inert],[disabled],[aria-disabled="true"]')
      )
        return false;
    }
    return true;
  };
  const observedRoots = new WeakSet<ParentNode>();
  function remember(root: ParentNode) {
    if (root instanceof Element && root.shadowRoot)
      observeRoot(root.shadowRoot);
    queryDeep<HTMLInputElement>(root, 'input[type="password"]').forEach(
      passwordField,
    );
    for (const element of queryDeep<Element>(root, "*")) {
      if (element.shadowRoot) observeRoot(element.shadowRoot);
    }
  }
  const observeMutations = (records: MutationRecord[]) => {
    for (const record of records) {
      if (
        record.target instanceof HTMLInputElement &&
        record.attributeName === "type" &&
        record.oldValue === "password"
      )
        knownPasswords.set(record.target, signature(record.target));
      for (const node of Array.from(record.addedNodes)) {
        if (node instanceof HTMLInputElement) passwordField(node);
        else if (node instanceof Element) remember(node);
      }
    }
  };
  function observeRoot(root: Document | ShadowRoot) {
    if (observedRoots.has(root)) return;
    observedRoots.add(root);
    new MutationObserver(observeMutations).observe(root, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ["type"],
      attributeOldValue: true,
    });
    root.addEventListener("submit", onSubmit, true);
    remember(root);
  }
  type Fields = {
    username: HTMLInputElement;
    password: HTMLInputElement;
    changePassword?: boolean;
    multiStep?: boolean;
  };
  function fieldsIn(scope: Element, strict: boolean): Fields | undefined {
    const inputs = Array.from(
      queryDeep<HTMLInputElement>(scope, "input"),
    ).filter(visible);
    const allPasswords = inputs.filter(passwordField);
    const newPasswords = allPasswords.filter((input) =>
      input.autocomplete.split(/\s+/).includes("new-password"),
    );
    const changePassword =
      newPasswords.length > 0 &&
      allPasswords.some((input) =>
        input.autocomplete.split(/\s+/).includes("current-password"),
      );
    const passwords = changePassword ? newPasswords : allPasswords;
    if (!passwords.length || passwords.length > 2 || allPasswords.length > 3)
      return;
    const password = passwords[0];
    if (passwords.length === 2) {
      const confirmation = passwords[1];
      const hints = [
        confirmation.name,
        confirmation.id,
        confirmation.placeholder,
        confirmation.getAttribute("aria-label"),
      ].join(" ");
      // Registration only: never mistake old/new-password change forms for signup.
      if (
        password.autocomplete.includes("current-password") ||
        !(
          /confirm|repeat|确认|重复/i.test(hints) ||
          passwords.every((p) => p.autocomplete.includes("new-password"))
        ) ||
        !password.value ||
        confirmation.value !== password.value
      )
        return;
    }
    const preceding = inputs.filter(
      (input, index) =>
        input !== password &&
        !passwordField(input) &&
        ["text", "email", "tel"].includes(input.type) &&
        !input.autocomplete.split(/\s+/).includes("one-time-code") &&
        index < inputs.indexOf(password),
    );
    if (strict && preceding.length !== 1) return;
    let username =
      preceding.find((input) =>
        input.autocomplete.split(/\s+/).includes("username"),
      ) ?? preceding.at(-1);
    const multiStep = !username && passwords.length === 1 && !changePassword;
    if (!username && (changePassword || multiStep))
      username = document.createElement("input");
    if (!username) return;
    const hints = [
      username.autocomplete,
      username.name,
      username.id,
      username.placeholder,
      username.getAttribute("aria-label"),
    ].join(" ");
    if (
      strict &&
      !["email", "tel"].includes(username.type) &&
      !/username|email|e-mail|account|手机号|手机号码|邮箱|用户名|账号/i.test(
        hints,
      )
    )
      return;
    return { username, password, changePassword, multiStep };
  }
  function nearby(target: Element): Fields | undefined {
    if (target.closest("form")) return fieldsIn(target.closest("form")!, false);
    let scope: Element | null = parent(target);
    for (
      let depth = 0;
      scope && scope !== document.body && depth < 12;
      depth++, scope = parent(scope)
    ) {
      if (scope instanceof HTMLFormElement) return fieldsIn(scope, false);
      const fields = fieldsIn(scope, true);
      if (fields) return fields;
      // Never climb past a group larger than a signup password/confirmation pair.
      if (
        queryDeep<HTMLInputElement>(scope, "input").filter(
          (input) => visible(input) && passwordField(input),
        ).length > 2
      )
        return;
      if (scope.matches('dialog,[role="dialog"]')) return;
    }
  }
  async function capture(fields: Fields | undefined) {
    if (
      !enabled ||
      busy ||
      !fields?.password.value ||
      (!fields.username.value.trim() &&
        !fields.changePassword &&
        !fields.multiStep)
    )
      return;
    busy = true;
    // Snapshot synchronously, before page handlers can remove/navigate the iframe.
    const request = {
      action: "login-submitted",
      changePassword: fields.changePassword === true,
      multiStep: fields.multiStep === true,
      username: fields.username.value,
      password: fields.password.value,
    };
    try {
      const result = await send(request);
      if (result?.data?.pending) prompt(result.data.notice);
      else if (result?.data?.duplicate) removeBanner();
      else if (
        result &&
        !result.ok &&
        ["locked", "unpaired", "native-unavailable", "not-running"].includes(
          result.error,
        )
      )
        showBanner(
          "请先打开并解锁 PasswordVault，再提交登录以保存账号。",
          false,
        );
    } finally {
      request.password = "";
      request.username = "";
      busy = false;
    }
  }
  function loginControl(target: Element) {
    if (
      target.matches(
        'a,input:not([type="button"]):not([type="submit"]),textarea,select',
      ) ||
      target.querySelector("input,textarea,select") ||
      target.closest(
        '[disabled],[aria-disabled="true"],a,[role="link"],[role="tab"]',
      ) ||
      target.querySelector('a,[role="link"],[role="tab"]')
    )
      return false;
    const label = (
      target.getAttribute("aria-label") ??
      (target instanceof HTMLInputElement
        ? target.value
        : target.textContent) ??
      ""
    ).trim();
    return /^(?:登\s*[录入陆]|立即登录|登录并继续|登录\s*[/／]\s*注册|log\s*in|sign\s*in|sign\s*up|register|create\s+(?:an?\s+)?account|注\s*册|立即注册|创建(?:一个)?(?:账户|账号)|continue|继续|submit|提\s*交|change\s+password|update\s+password|save\s+password|修改密码|更新密码|保存密码)$/i.test(
      label,
    );
  }
  function hasLoginControl(fields: Fields) {
    let scope = parent(fields.password);
    for (
      let depth = 0;
      scope && scope !== document.body && depth < 12;
      depth++, scope = parent(scope)
    ) {
      if (
        queryDeep<HTMLInputElement>(scope, "input").includes(fields.username) &&
        Array.from(
          queryDeep(
            scope,
            'button,[role="button"],input[type="button"],input[type="submit"],div,span',
          ),
        ).some(loginControl)
      )
        return true;
    }
    return false;
  }
  function onSubmit(event: Event) {
    if (event.isTrusted && event.target instanceof HTMLFormElement) {
      const form = event.target;
      const inputs = queryDeep<HTMLInputElement>(form, "input").filter(visible);
      if (!inputs.some(passwordField)) {
        const username = inputs.find((input) =>
          input.autocomplete.split(/\s+/).includes("username"),
        );
        if (username?.value.trim())
          void send({
            action: "inline-remember-username",
            username: username.value,
          });
      }
      void capture(fieldsIn(form, false));
    }
  }
  observeRoot(document);
  const edited = new WeakSet<HTMLInputElement>();
  document.addEventListener(
    "input",
    (event) => {
      const target = event.composedPath()[0];
      if (event.isTrusted && target instanceof HTMLInputElement)
        edited.add(target);
    },
    true,
  );
  document.addEventListener(
    "focusout",
    (event) => {
      const target = event.composedPath()[0];
      if (
        !event.isTrusted ||
        !(target instanceof HTMLInputElement) ||
        !edited.has(target)
      )
        return;
      edited.delete(target);
      const fields = nearby(target);
      if (
        !fields ||
        fields.changePassword ||
        fields.multiStep ||
        (target !== fields.username && target !== fields.password) ||
        fields.password.autocomplete.split(/\s+/).includes("new-password") ||
        !fields.username.checkValidity() ||
        !fields.password.checkValidity()
      )
        return;
      void capture(fields);
    },
    true,
  );
  document.addEventListener(
    "click",
    (event) => {
      const source = event.composedPath()[0];
      if (!event.isTrusted || !(source instanceof Element)) return;
      if (
        event
          .composedPath()
          .some(
            (node) =>
              node instanceof Element &&
              node.matches(
                'a,[role="link"],[role="tab"],[disabled],[aria-disabled="true"]',
              ),
          )
      )
        return;
      const submit = source.closest('button,input[type="submit"]');
      if (
        (submit instanceof HTMLButtonElement ||
          submit instanceof HTMLInputElement) &&
        submit.form &&
        submit.type === "submit"
      )
        return;
      let target: Element | null = source;
      for (
        let depth = 0;
        target && target !== document.body && depth < 5;
        depth++, target = parent(target)
      ) {
        if (target.matches('[disabled],[aria-disabled="true"]')) return;
        // Native submit buttons are handled after the browser's form validation.
        if (
          (target instanceof HTMLButtonElement ||
            target instanceof HTMLInputElement) &&
          target.form &&
          target.type === "submit"
        )
          return;
        if (loginControl(target)) {
          void capture(nearby(target));
          return;
        }
      }
    },
    true,
  );
  document.addEventListener(
    "keydown",
    (event) => {
      const target = event.composedPath()[0];
      if (
        !event.isTrusted ||
        event.isComposing ||
        event.key !== "Enter" ||
        !(target instanceof HTMLInputElement)
      )
        return;
      // Native forms generate a submit event; this path is for form-less SPA panels.
      if (target.form) return;
      const fields = nearby(target);
      if (
        fields &&
        hasLoginControl(fields) &&
        (target === fields.username || target === fields.password)
      )
        void capture(fields);
    },
    true,
  );
})();
