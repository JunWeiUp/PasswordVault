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
  function showBanner(message: string, dismiss = true, notice?: Notice) {
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
    title.textContent = "PasswordVault · 登录提醒";
    const description = document.createElement("p");
    description.textContent = message;
    const close = document.createElement("button");
    close.textContent = dismiss ? "暂不保存" : "知道了";
    close.onclick = () => {
      removeBanner();
      if (dismiss) void send({ action: "login-dismiss" });
    };
    card.append(title, description);
    if (dismiss) {
      const review = document.createElement("button");
      review.textContent = "查看并保存";
      review.style.marginRight = "8px";
      review.onclick = async () => {
        const result = await send({ action: "login-open" });
        if (!result?.ok)
          description.textContent =
            "请点击浏览器工具栏的 PasswordVault 图标，核对后保存账号。";
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
      "检测到登录提交。是否保存这次填写的账号？请确认登录成功后再保存。",
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
    'input[type="password"], input[autocomplete~="current-password"]',
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
    if (
      !hasPassword &&
      event.target instanceof HTMLInputElement &&
      passwordField(event.target)
    ) {
      hasPassword = true;
      void refreshStatus();
    }
  });
  // Keep revealed-password identity, without treating arbitrary text inputs as secrets.
  const knownPasswords = new WeakMap<HTMLInputElement, string>();
  const signature = (input: HTMLInputElement) =>
    [input.id, input.name, input.autocomplete].join("\u0000");
  const passwordField = (input: HTMLInputElement) => {
    const tokens = input.autocomplete.toLowerCase().split(/\s+/);
    if (
      tokens.some((token) =>
        ["new-password", "one-time-code", "username"].includes(token),
      )
    )
      return false;
    if (input.type === "password") {
      knownPasswords.set(input, signature(input));
      return true;
    }
    return (
      input.type === "text" &&
      (tokens.includes("current-password") ||
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
  const remember = (root: ParentNode) =>
    root
      .querySelectorAll<HTMLInputElement>('input[type="password"]')
      .forEach(passwordField);
  remember(document);
  new MutationObserver((records) => {
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
  }).observe(document.documentElement, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ["type"],
    attributeOldValue: true,
  });
  type Fields = { username: HTMLInputElement; password: HTMLInputElement };
  function fieldsIn(scope: Element, strict: boolean): Fields | undefined {
    const inputs = Array.from(
      scope.querySelectorAll<HTMLInputElement>("input"),
    ).filter(visible);
    const passwords = inputs.filter(passwordField);
    if (passwords.length !== 1) return;
    const password = passwords[0];
    const preceding = inputs.filter(
      (input) =>
        input !== password &&
        !passwordField(input) &&
        ["text", "email", "tel"].includes(input.type) &&
        !input.autocomplete.split(/\s+/).includes("one-time-code") &&
        !!(
          input.compareDocumentPosition(password) &
          Node.DOCUMENT_POSITION_FOLLOWING
        ),
    );
    if (strict && preceding.length !== 1) return;
    const username =
      preceding.find((input) =>
        input.autocomplete.split(/\s+/).includes("username"),
      ) ?? preceding.at(-1);
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
    return { username, password };
  }
  function nearby(target: Element): Fields | undefined {
    if (target.closest("form")) return fieldsIn(target.closest("form")!, false);
    let scope: Element | null = target.parentElement;
    for (
      let depth = 0;
      scope && scope !== document.body && depth < 6;
      depth++, scope = scope.parentElement
    ) {
      const fields = fieldsIn(scope, true);
      if (fields) return fields;
      // Never climb past a group with multiple possible password destinations.
      if (
        Array.from(scope.querySelectorAll<HTMLInputElement>("input")).filter(
          (input) => visible(input) && passwordField(input),
        ).length > 1
      )
        return;
    }
  }
  async function capture(fields: Fields | undefined) {
    if (
      !enabled ||
      busy ||
      !fields?.password.value ||
      !fields.username.value.trim()
    )
      return;
    busy = true;
    // Snapshot synchronously, before page handlers can remove/navigate the iframe.
    const request = {
      action: "login-submitted",
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
    return /^(?:登\s*[录入陆]|立即登录|登录并继续|登录\s*[/／]\s*注册|log\s*in|sign\s*in|continue|继续)$/i.test(
      label,
    );
  }
  function hasLoginControl(fields: Fields) {
    let scope = fields.password.parentElement;
    for (
      let depth = 0;
      scope && scope !== document.body && depth < 6;
      depth++, scope = scope.parentElement
    ) {
      if (
        scope.contains(fields.username) &&
        Array.from(
          scope.querySelectorAll(
            'button,[role="button"],input[type="button"],input[type="submit"],div,span',
          ),
        ).some(loginControl)
      )
        return true;
    }
    return false;
  }
  document.addEventListener(
    "submit",
    (event) => {
      if (event.isTrusted && event.target instanceof HTMLFormElement)
        void capture(fieldsIn(event.target, false));
    },
    true,
  );
  document.addEventListener(
    "click",
    (event) => {
      if (!event.isTrusted || !(event.target instanceof Element)) return;
      if (
        event.target.closest(
          'a,[role="link"],[role="tab"],[disabled],[aria-disabled="true"]',
        )
      )
        return;
      const submit = event.target.closest('button,input[type="submit"]');
      if (
        (submit instanceof HTMLButtonElement ||
          submit instanceof HTMLInputElement) &&
        submit.form &&
        submit.type === "submit"
      )
        return;
      let target: Element | null = event.target;
      for (
        let depth = 0;
        target && target !== document.body && depth < 5;
        depth++, target = target.parentElement
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
      if (
        !event.isTrusted ||
        event.isComposing ||
        event.key !== "Enter" ||
        !(event.target instanceof HTMLInputElement)
      )
        return;
      // Native forms generate a submit event; this path is for form-less SPA panels.
      if (event.target.form) return;
      const fields = nearby(event.target);
      if (
        fields &&
        hasLoginControl(fields) &&
        (event.target === fields.username || event.target === fields.password)
      )
        void capture(fields);
    },
    true,
  );
})();
