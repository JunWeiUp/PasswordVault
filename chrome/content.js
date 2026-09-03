// Escape both text and attributes before adding dynamic values to markup.
const escapeHtml = (value) => String(value).replace(/[&<>"']/g, (character) => ({
  '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
})[character]);
const messageText = (key, substitutions) => chrome.i18n.getMessage(key, substitutions);
const messageHtml = (key, substitutions) => escapeHtml(messageText(key, substitutions));

// Content script for SecurePass Extension
console.log('🛡️ SecurePass Content Script loaded');

// Global state to track inputs
let currentCreds = {
  username: '',
  password: '',
  url: window.location.origin,
  origin: window.location.origin
};

let lastFocusedField = null;
let activeDropdownHost = null;
let autoFillTriggered = false;
let passwordChangeFields = null;
let suppressAutofillDropdownUntil = 0;
let dropdownRenderToken = 0;
const passwordFieldSelector = 'input[type="password"], input[data-securepass-password-field="true"], input[autocomplete="current-password"], input[autocomplete="new-password"]';

// Add a small toast feedback
const showToast = (message) => {
  const toast = document.createElement('div');
  toast.textContent = message;
  toast.style.cssText = `
    position: fixed !important;
    top: 20px !important;
    left: 50% !important;
    transform: translateX(-50%) !important;
    background: rgba(0,0,0,0.8) !important;
    color: white !important;
    padding: 8px 16px !important;
    border-radius: 20px !important;
    z-index: 2147483647 !important;
    font-size: 14px !important;
    pointer-events: none !important;
    transition: opacity 0.3s !important;
  `;
  document.body.appendChild(toast);
  setTimeout(() => {
    toast.style.opacity = '0';
    setTimeout(() => toast.remove(), 300);
  }, 2000);
};

function isVisibleInput(field) {
  return field &&
    field.tagName === 'INPUT' &&
    field.type !== 'hidden' &&
    field.offsetWidth > 0 &&
    field.offsetHeight > 0;
}

function isSecurePassPasswordField(field) {
  return isVisibleInput(field) &&
    (field.type === 'password' ||
      field.dataset.securepassPasswordField === 'true' ||
      field.getAttribute('autocomplete') === 'current-password' ||
      field.getAttribute('autocomplete') === 'new-password');
}

function findPasswordField(scope = document) {
  const fields = Array.from(scope.querySelectorAll(passwordFieldSelector));
  return fields.find(isSecurePassPasswordField) || null;
}

function findPasswordFields(scope = document) {
  return Array.from(scope.querySelectorAll(passwordFieldSelector))
    .filter(isSecurePassPasswordField);
}

// --- Inline Autofill Dropdown (Shadow DOM) ---

function hideAutofillDropdown({ invalidatePending = true } = {}) {
  if (invalidatePending) dropdownRenderToken += 1;
  document.querySelectorAll('.securepass-dropdown-host').forEach(host => host.remove());
  activeDropdownHost = null;
}

function showAutofillDropdown(field) {
  if (Date.now() < suppressAutofillDropdownUntil) return;
  hideAutofillDropdown({ invalidatePending: false });
  const renderToken = ++dropdownRenderToken;

  const domain = window.location.hostname;
  chrome.runtime.sendMessage({ type: 'GET_MATCHING_ACCOUNTS', data: { domain } }, (result) => {
    if (renderToken !== dropdownRenderToken) return;
    if (Date.now() < suppressAutofillDropdownUntil) return;
    if (chrome.runtime.lastError || !result || !result.accounts || result.accounts.length === 0) return;
    if (document.activeElement !== field) return;

    const host = document.createElement('div');
    host.className = 'securepass-dropdown-host';
    host.style.cssText = 'position:absolute;z-index:2147483647;';
    const shadow = host.attachShadow({ mode: 'closed' });

    const rect = field.getBoundingClientRect();
    host.style.left = (window.scrollX + rect.left) + 'px';
    host.style.top = (window.scrollY + rect.bottom + 4) + 'px';
    host.style.width = Math.max(rect.width, 260) + 'px';

    const iconUrl = chrome.runtime.getURL('icons/icon16.png');

    let itemsHtml = '';
    result.accounts.forEach((acc, idx) => {
      const badge = acc.lastUsed ? `<span class="badge">${messageHtml('recentlyUsed')}</span>` : '';
      itemsHtml += `
        <div class="item" data-index="${idx}" data-username="${escapeHtml(acc.username)}">
          <img src="${iconUrl}" class="icon" />
          <span class="username">${escapeHtml(acc.username)}</span>
          ${badge}
        </div>`;
    });

    shadow.innerHTML = `
      <style>
        :host { all: initial; }
        .dropdown {
          background: #fff; border: 1px solid #ddd; border-radius: 8px;
          box-shadow: 0 4px 16px rgba(0,0,0,0.12); overflow: hidden;
          font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
          font-size: 14px; color: #333; animation: fadeIn 0.15s ease-out;
        }
        @keyframes fadeIn { from { opacity: 0; transform: translateY(-4px); } to { opacity: 1; transform: translateY(0); } }
        .header { padding: 8px 8px 8px 12px; font-size: 11px; color: #888; border-bottom: 1px solid #f0f0f0; display: flex; align-items: center; gap: 6px; }
        .header img { width: 14px; height: 14px; }
        .header-title { flex: 1; }
        .close-btn {
          width: 22px; height: 22px; border: none; border-radius: 50%;
          background: transparent; color: #888; cursor: pointer; font-size: 18px;
          line-height: 20px; display: flex; align-items: center; justify-content: center;
        }
        .close-btn:hover { background: #f1f3f4; color: #333; }
        .item { display: flex; align-items: center; gap: 10px; padding: 10px 12px; cursor: pointer; transition: background 0.1s; }
        .item:hover { background: #f0f5ff; }
        .item .icon { width: 18px; height: 18px; flex-shrink: 0; }
        .item .username { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .badge { font-size: 10px; color: #1a73e8; background: #e8f0fe; padding: 2px 6px; border-radius: 4px; white-space: nowrap; }
        .footer { border-top: 1px solid #f0f0f0; padding: 8px 12px; display: flex; align-items: center; gap: 6px; cursor: pointer; color: #666; font-size: 12px; transition: background 0.1s; }
        .footer:hover { background: #f5f5f5; }
        .footer img { width: 14px; height: 14px; }
      </style>
      <div class="dropdown">
        <div class="header">
          <img src="${iconUrl}" />
          <span class="header-title">PasswordVault</span>
          <button class="close-btn" id="close-dropdown" title="${messageHtml('close')}" aria-label="${messageHtml('close')}">&times;</button>
        </div>
        ${itemsHtml}
        <div class="footer" id="open-sp"><img src="${iconUrl}" />${messageHtml('openVault')}</div>
      </div>
    `;

    document.body.appendChild(host);
    activeDropdownHost = host;

    const closeDropdown = (e, suppressMs = 1000) => {
      e.preventDefault();
      e.stopPropagation();
      suppressAutofillDropdownUntil = Date.now() + suppressMs;
      hideAutofillDropdown();
    };

    const closeButton = shadow.getElementById('close-dropdown');
    closeButton?.addEventListener('pointerdown', closeDropdown, true);
    closeButton?.addEventListener('mousedown', closeDropdown, true);
    closeButton?.addEventListener('click', closeDropdown, true);

    shadow.querySelectorAll('.item').forEach(el => {
      let selected = false;
      const selectAccount = (e) => {
        e.preventDefault();
        e.stopPropagation();
        if (selected) return;
        selected = true;
        const username = el.dataset.username;
        suppressAutofillDropdownUntil = Date.now() + 1000;
        hideAutofillDropdown();
        chrome.runtime.sendMessage({
          type: 'FILL_MATCHING_ACCOUNT',
          data: {
            domain: window.location.hostname,
            username: username,
          }
        }, (response) => {
          if (chrome.runtime.lastError || !response?.success) {
            showToast(messageText('unlockFirst'));
          } else {
            showToast(messageText('filled'));
          }
        });
      };
      el.addEventListener('pointerdown', selectAccount, true);
      el.addEventListener('mousedown', selectAccount, true);
      el.addEventListener('click', selectAccount, true);
    });

    let openingSecurePass = false;
    const openSecurePass = (e) => {
      e.preventDefault();
      e.stopPropagation();
      if (openingSecurePass) return;
      openingSecurePass = true;
      suppressAutofillDropdownUntil = Date.now() + 1000;
      hideAutofillDropdown();
      chrome.runtime.sendMessage({
        type: 'OPEN_POPUP_FOR_FILL',
        data: { url: window.location.href, origin: window.location.origin, username: '' }
      });
    };
    shadow.getElementById('open-sp')?.addEventListener('pointerdown', openSecurePass, true);
    shadow.getElementById('open-sp')?.addEventListener('mousedown', openSecurePass, true);
    shadow.getElementById('open-sp')?.addEventListener('click', openSecurePass, true);
  });
}

function bindDropdownEvents(field) {
  if (field.dataset.securepassDropdown) return;
  field.dataset.securepassDropdown = 'true';

  field.addEventListener('focus', () => showAutofillDropdown(field));
  field.addEventListener('click', () => {
    if (!activeDropdownHost) showAutofillDropdown(field);
  });
  field.addEventListener('blur', () => {
    setTimeout(hideAutofillDropdown, 150);
  });
}

function bindDropdownToAllFields() {
  const fields = document.querySelectorAll(
    'input[type="password"], input[type="email"], input[type="text"], input:not([type])'
  );
  fields.forEach(f => {
    if (f.offsetWidth > 0 && f.type !== 'hidden') {
      const form = f.closest('form') || document.body;
      if (findPasswordField(form)) {
        bindDropdownEvents(f);
      }
    }
  });
}

document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && activeDropdownHost) {
    hideAutofillDropdown();
  }
}, true);

// --- Password Change Form Detection ---

function detectPasswordChangeForm() {
  const allPwdFields = findPasswordFields(document);
  
  if (allPwdFields.length < 2 || allPwdFields.length > 4) return null;

  const getFieldHint = (field) => {
    const attrs = [
      field.name, field.id, field.placeholder,
      field.getAttribute('aria-label'), field.getAttribute('autocomplete'),
    ].filter(Boolean).join(' ').toLowerCase();

    const label = field.labels?.[0]?.textContent?.toLowerCase() || '';
    return attrs + ' ' + label;
  };

  const currentPatterns = /current|old|旧|原|当前|existing|prev/;
  const newPatterns = /new|新|create/;
  const confirmPatterns = /confirm|repeat|retype|再次|重复|确认|verify/;

  let currentField = null, newField = null, confirmField = null;

  for (const f of allPwdFields) {
    const hint = getFieldHint(f);
    const ac = f.getAttribute('autocomplete') || '';
    if (ac === 'current-password' || currentPatterns.test(hint)) {
      if (!currentField) currentField = f;
    } else if (confirmPatterns.test(hint)) {
      confirmField = f;
    } else if (ac === 'new-password' || newPatterns.test(hint)) {
      if (!newField) newField = f;
    }
  }

  if (!currentField && !newField && allPwdFields.length >= 2) {
    if (allPwdFields.length === 2) {
      currentField = allPwdFields[0];
      newField = allPwdFields[1];
    } else if (allPwdFields.length >= 3) {
      currentField = allPwdFields[0];
      newField = allPwdFields[1];
      confirmField = allPwdFields[2];
    }
  }

  if (currentField && newField) {
    return { type: 'change_password', currentField, newField, confirmField };
  }
  return null;
}

function showPasswordChangeBanner(pwChangeInfo) {
  if (document.getElementById('securepass-pwchange-banner')) return;

  passwordChangeFields = pwChangeInfo;

  const iconUrl = chrome.runtime.getURL('icons/icon192.png');
  const banner = document.createElement('div');
  banner.id = 'securepass-pwchange-banner';

  if (!document.getElementById('securepass-styles')) {
    const style = document.createElement('style');
    style.id = 'securepass-styles';
    style.textContent = `
      @keyframes securepass-slide-in { from { transform: translateX(100%); opacity: 0; } to { transform: translateX(0); opacity: 1; } }
      .securepass-btn:active { transform: scale(0.98); }
    `;
    document.head.appendChild(style);
  }

  banner.style.cssText = `
    position: fixed !important; top: 20px !important; right: 20px !important;
    width: 350px !important; background: #fff !important;
    box-shadow: 0 4px 20px rgba(0,0,0,0.15) !important; z-index: 2147483647 !important;
    display: flex !important; flex-direction: column !important; padding: 16px !important;
    border-radius: 12px !important;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif !important;
    font-size: 14px !important; color: #333 !important; border: 1px solid #e0e0e0 !important;
    animation: securepass-slide-in 0.3s ease-out !important;
  `;

  banner.innerHTML = `
    <div style="display:flex;align-items:center;margin-bottom:12px;">
      <img src="${iconUrl}" style="width:24px;height:24px;margin-right:10px;">
      <span style="font-weight:600;font-size:16px;">PasswordVault</span>
      <button id="securepass-pwchange-close" style="margin-left:auto;background:none;border:none;font-size:20px;cursor:pointer;color:#999;">&times;</button>
    </div>
    <div style="margin-bottom:16px;line-height:1.4;">
      ${messageHtml('passwordChangeDetected')}
    </div>
    <div style="display:flex;gap:8px;">
      <button id="securepass-fill-current" class="securepass-btn" style="flex:1;background:#1a73e8;color:#fff;border:none;padding:10px;border-radius:6px;cursor:pointer;font-weight:500;font-size:13px;">${messageHtml('fillCurrentPassword')}</button>
      <button id="securepass-gen-new" class="securepass-btn" style="flex:1;background:#e8f0fe;color:#1a73e8;border:none;padding:10px;border-radius:6px;cursor:pointer;font-weight:500;font-size:13px;">${messageHtml('generateNewPassword')}</button>
    </div>
  `;

  document.body.appendChild(banner);

  document.getElementById('securepass-pwchange-close').onclick = () => banner.remove();

  document.getElementById('securepass-fill-current').onclick = () => {
    chrome.runtime.sendMessage({
      type: 'FILL_CURRENT_PASSWORD',
      data: {
        url: window.location.href,
        origin: window.location.origin,
        username: '',
      }
    });
    showToast(messageText('fillingCurrentPassword'));
  };

  document.getElementById('securepass-gen-new').onclick = () => {
    chrome.runtime.sendMessage({
      type: 'OPEN_POPUP_FOR_FILL',
      data: {
        url: window.location.href,
        origin: window.location.origin,
        username: '',
        fillTarget: 'new_password',
      }
    });
    showToast(messageText('openingGenerator'));
    banner.remove();
  };

  setTimeout(() => { if (banner.parentElement) banner.remove(); }, 60000);
}

const detector = {
  getCredentials: (field) => {
    if (!field) return currentCreds;
    const form = field.closest('form') || document.body;
    
    // Find password field
    const passwordField = isSecurePassPasswordField(field) ? field : findPasswordField(form);
    
    // Find username field - look for common patterns
    let usernameField = null;
    
    // 1. Look for fields with name/id containing 'user', 'email', 'login'
    const usernameSelectors = [
      'input[type="email"]',
      'input[name*="user" i]',
      'input[id*="user" i]',
      'input[name*="email" i]',
      'input[id*="email" i]',
      'input[name*="login" i]',
      'input[id*="login" i]',
      'input[type="text"]'
    ];
    
    for (const selector of usernameSelectors) {
      const found = form.querySelector(selector);
      if (found && found !== passwordField && found.type !== 'hidden' && found.offsetWidth > 0) {
        usernameField = found;
        break;
      }
    }
    
    // 2. Fallback: first visible text input that isn't the password field
    if (!usernameField) {
      usernameField = Array.from(form.querySelectorAll('input')).find(i => 
        i !== passwordField && 
        (i.type === 'text' || i.type === 'email' || !i.type) && 
        i.offsetWidth > 0 &&
        i.type !== 'hidden'
      );
    }
    
    return {
      username: usernameField ? usernameField.value : currentCreds.username,
      password: passwordField ? passwordField.value : currentCreds.password,
      url: window.location.href,
      origin: window.location.origin
    };
  }
};

// Handle fill messages
chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
  if (request.type === 'FILL_CREDENTIALS') {
    const { username, password } = request.data;
    const passwordField = findPasswordField(document);
    if (passwordField) {
      const form = passwordField.closest('form') || document.body;
      const usernameField = Array.from(form.querySelectorAll('input[type="email"], input[type="text"], input:not([type])'))
        .find(field => field !== passwordField && !isSecurePassPasswordField(field));
      
      if (usernameField) {
        usernameField.value = username;
        usernameField.dispatchEvent(new Event('input', { bubbles: true }));
      }
      passwordField.value = password;
      passwordField.dispatchEvent(new Event('input', { bubbles: true }));
      sendResponse({ success: true });
    } else {
      sendResponse({ success: false, error: 'No password field found' });
    }
  }
  else if (request.type === 'SHOW_AUTOFILL_DROPDOWN') {
    const pwdField = findPasswordField(document);
    if (pwdField) {
      pwdField.focus();
      showAutofillDropdown(pwdField);
    }
    sendResponse({ success: true });
  }
  else if (request.type === 'FILL_PASSWORD_CHANGE_FIELDS') {
    const { currentPassword, newPassword } = request.data || {};
    if (passwordChangeFields) {
      if (currentPassword && passwordChangeFields.currentField) {
        passwordChangeFields.currentField.value = currentPassword;
        passwordChangeFields.currentField.dispatchEvent(new Event('input', { bubbles: true }));
      }
      if (newPassword) {
        if (passwordChangeFields.newField) {
          passwordChangeFields.newField.value = newPassword;
          passwordChangeFields.newField.dispatchEvent(new Event('input', { bubbles: true }));
        }
        if (passwordChangeFields.confirmField) {
          passwordChangeFields.confirmField.value = newPassword;
          passwordChangeFields.confirmField.dispatchEvent(new Event('input', { bubbles: true }));
        }
      }
      sendResponse({ success: true });
    } else {
      sendResponse({ success: false, error: 'No password change fields tracked' });
    }
  }
  else if (request.type === 'SHOW_TOAST') {
    showToast(request.data?.message || '');
    sendResponse({ success: true });
  }
});

// Inject icons with a more robust method
function injectIcons() {
  const passwordFields = document.querySelectorAll('input[type="password"]:not([data-securepass-injected])');
  
  passwordFields.forEach(field => {
    // Basic visibility check
    if (field.offsetWidth === 0 || field.offsetHeight === 0) return;
    
    console.log('🎯 Found password field, injecting icon:', field);
    
    const icon = document.createElement('div');
    icon.className = 'securepass-icon-overlay';
    
    // Initial position
    const updatePosition = () => {
      const rect = field.getBoundingClientRect();
      if (rect.width === 0) return;
      
      icon.style.left = (window.scrollX + rect.right - 28) + 'px';
      icon.style.top = (window.scrollY + rect.top + (rect.height / 2) - 12) + 'px';
      icon.style.display = 'block';
    };

    const iconUrl = chrome.runtime.getURL('icons/icon16.png');
    icon.style.cssText = `
      position: absolute !important;
      width: 24px !important;
      height: 24px !important;
      cursor: pointer !important;
      z-index: 2147483647 !important;
      background-image: url("${iconUrl}") !important;
      background-size: contain !important;
      background-repeat: no-repeat !important;
      background-position: center !important;
      background-color: white !important;
      border: 1px solid #eee !important;
      border-radius: 4px !important;
      box-shadow: 0 2px 4px rgba(0,0,0,0.1) !important;
      display: none;
      transition: transform 0.1s, box-shadow 0.1s !important;
    `;
    
    icon.onmouseover = () => {
      icon.style.transform = 'scale(1.1)';
      icon.style.boxShadow = '0 2px 8px rgba(0,0,0,0.2) !important';
    };
    icon.onmouseout = () => {
      icon.style.transform = 'scale(1)';
      icon.style.boxShadow = '0 2px 4px rgba(0,0,0,0.1) !important';
    };
    
    document.body.appendChild(icon);
    updatePosition();

    icon.addEventListener('click', (e) => {
      try {
        e.preventDefault();
        e.stopPropagation();
        console.log('🔑 SecurePass icon clicked');
        
        // Visual feedback on icon
        icon.style.transform = 'scale(0.9)';
        setTimeout(() => icon.style.transform = 'scale(1)', 100);

        const creds = detector.getCredentials(field);
        console.log('📦 Context captured:', creds.username, window.location.origin);

        chrome.runtime.sendMessage({ 
          type: 'FILL_MATCHING_ACCOUNT',
          data: {
            domain: window.location.hostname,
            username: creds.username
          }
        }, (response) => {
          if (chrome.runtime.lastError || !response?.success) {
            showToast(messageText('unlockFirst'));
          } else {
            showToast(messageText('filled'));
          }
        });
      } catch (err) {
        console.error('❌ Icon click error:', err);
      }
    });

    // Events to keep icon aligned
    window.addEventListener('resize', updatePosition);
    window.addEventListener('scroll', updatePosition);
    
    // Also update on input focus to ensure it's there
    field.addEventListener('focus', updatePosition);

    field.dataset.securepassInjected = "true";
    field.dataset.securepassPasswordField = "true";
    
    // Clean up if field is removed
    const removeObserver = new MutationObserver(() => {
      if (!document.body.contains(field)) {
        icon.remove();
        removeObserver.disconnect();
      }
    });
    removeObserver.observe(document.body, { childList: true, subtree: true });

    // Track input changes
    field.addEventListener('input', () => {
      const creds = detector.getCredentials(field);
      currentCreds = creds;
    });
  });
}

// Detection logic for login
function notifyLogin(creds) {
  const passwordFields = findPasswordFields(document);

  if (passwordFields.length >= 2) {
    const pwChangeInfo = detectPasswordChangeForm();
    if (pwChangeInfo) {
      console.log('🔑 Password change form detected');
      chrome.runtime.sendMessage({
        type: 'DETECTED_PASSWORD_CHANGE',
        data: { url: window.location.href, origin: window.location.origin }
      });
      passwordChangeFields = pwChangeInfo;
      return;
    }
  }

  if (creds.username && creds.password && creds.password.length >= 4) {
    console.log('🚀 Detected login attempt for:', creds.username);
    chrome.runtime.sendMessage({ type: 'DETECTED_LOGIN', data: creds });
  }
}

function showSaveBanner(creds) {
  // Prevent duplicate banners
  if (document.getElementById('securepass-save-banner')) return;

  console.log('✨ Showing save banner for:', creds.username);

  const banner = document.createElement('div');
  banner.id = 'securepass-save-banner';
  const iconUrl = chrome.runtime.getURL('icons/icon192.png');
  
  banner.style.cssText = `
    position: fixed !important;
    top: 20px !important;
    right: 20px !important;
    width: 350px !important;
    background: #ffffff !important;
    box-shadow: 0 4px 20px rgba(0,0,0,0.15) !important;
    z-index: 2147483647 !important;
    display: flex !important;
    flex-direction: column !important;
    padding: 16px !important;
    border-radius: 12px !important;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif !important;
    font-size: 14px !important;
    color: #333 !important;
    box-sizing: border-box !important;
    border: 1px solid #e0e0e0 !important;
    animation: securepass-slide-in 0.3s ease-out !important;
  `;

  // Add animation keyframes
  if (!document.getElementById('securepass-styles')) {
    const style = document.createElement('style');
    style.id = 'securepass-styles';
    style.textContent = `
      @keyframes securepass-slide-in {
        from { transform: translateX(100%); opacity: 0; }
        to { transform: translateX(0); opacity: 1; }
      }
      .securepass-btn:active { transform: scale(0.98); }
    `;
    document.head.appendChild(style);
  }

  banner.innerHTML = `
    <div style="display: flex; align-items: center; margin-bottom: 12px;">
      <img src="${iconUrl}" style="width: 24px; height: 24px; margin-right: 10px;">
      <span style="font-weight: 600; font-size: 16px;">PasswordVault</span>
      <button id="securepass-close-x" style="margin-left: auto; background: none; border: none; font-size: 20px; cursor: pointer; color: #999;">&times;</button>
    </div>
    <div style="margin-bottom: 16px; line-height: 1.4;">
      ${messageHtml('savePasswordFor', [creds.username])}
    </div>
    <div style="display: flex; gap: 8px;">
      <button id="securepass-quick-save-btn" class="securepass-btn" style="flex: 1; background: #1a73e8; color: white; border: none; padding: 10px; border-radius: 6px; cursor: pointer; font-weight: 500; font-size: 14px;">${messageHtml('quickSave')}</button>
      <button id="securepass-detail-save-btn" class="securepass-btn" style="flex: 0; background: #e8f0fe; color: #1a73e8; border: none; padding: 10px 14px; border-radius: 6px; cursor: pointer; font-weight: 500; font-size: 13px; white-space: nowrap;">${messageHtml('editDetails')}</button>
      <button id="securepass-ignore-btn" class="securepass-btn" style="flex: 0; background: #f1f3f4; color: #3c4043; border: none; padding: 10px 14px; border-radius: 6px; cursor: pointer; font-weight: 500; font-size: 13px;">${messageHtml('ignore')}</button>
    </div>
  `;

  document.body.appendChild(banner);

  document.getElementById('securepass-quick-save-btn').onclick = () => {
    chrome.runtime.sendMessage({ type: 'QUICK_SAVE', data: creds }, (response) => {
      banner.innerHTML = `
        <div style="display: flex; flex-direction: column; align-items: center; padding: 10px;">
          <div style="font-size: 24px; margin-bottom: 10px;">✅</div>
          <div style="font-weight: 600; color: #1e8e3e; margin-bottom: 4px;">${messageHtml('savedForReview')}</div>
          <div style="font-size: 12px; color: #666; text-align: center;">${messageHtml('reviewNextOpen')}</div>
        </div>
      `;
      setTimeout(() => banner.remove(), 2500);
    });
  };

  document.getElementById('securepass-detail-save-btn').onclick = () => {
    showToast(messageText('openingVault'));
    chrome.runtime.sendMessage({ type: 'CONFIRM_SAVE', data: creds }, () => {
      banner.remove();
    });
  };

  document.getElementById('securepass-ignore-btn').onclick = () => {
    banner.remove();
    chrome.runtime.sendMessage({ type: 'CLEAR_LAST_DETECTED' });
  };
  
  document.getElementById('securepass-close-x').onclick = () => {
    banner.remove();
    chrome.runtime.sendMessage({ type: 'CLEAR_LAST_DETECTED' });
  };

  // Auto-hide after 30 seconds
  setTimeout(() => {
    if (banner.parentElement) banner.remove();
  }, 30000);
}

// Standard form submission - track more scenarios
document.addEventListener('submit', (e) => {
  const pwd = findPasswordField(e.target);
  if (pwd && pwd.value && pwd.value.length >= 4) {
    console.log('📝 Form submitted with password field');
    notifyLogin(detector.getCredentials(pwd));
  }
}, true);

// Real-time tracking to ensure we capture the latest values before page navigation
document.addEventListener('input', (e) => {
  if (e.target.tagName === 'INPUT' && (e.target.type === 'password' || e.target.type === 'text' || e.target.type === 'email')) {
    const form = e.target.closest('form') || document.body;
    const pwdField = findPasswordField(form);
    if (pwdField) {
      currentCreds = detector.getCredentials(pwdField);
    }
  }
}, true);

// 2. Click on potential login buttons
document.addEventListener('click', (e) => {
  const target = e.target.closest('button, input[type="submit"], input[type="button"], a');
  if (!target) return;
  
  const isSubmitInput = target.tagName === 'INPUT' && (target.type === 'submit' || target.type === 'button');
  const isButton = target.tagName === 'BUTTON';
  const btnText = (target.innerText || target.value || target.title || '').toLowerCase().trim();
  
  // Refined login terms - avoid very common short words like "ok" unless it's a submit type
  const loginTerms = ['login', 'log in', 'signin', 'sign in', '登录', '进入', '确定', 'submit', 'next', '下一步', 'auth', 'verify', 'connect', '注册', 'register', 'signup', 'sign up'];
  
  // Check if it's a potential submission button
  const isPotentialSubmit = 
    target.type === 'submit' || 
    loginTerms.some(term => btnText === term || (btnText.length < 10 && btnText.includes(term)));

  if (isPotentialSubmit) {
    // Look for password field in the same form or container
    const form = target.closest('form');
    let pwd = null;
    
    if (form) {
      pwd = findPasswordField(form);
    }
    
    // Fallback: look for ANY password field on the page if the button looks very much like a login button
    if (!pwd) {
      pwd = findPasswordField(document);
    }

    if (pwd && pwd.value && pwd.value.length >= 4) {
      console.log('📝 Clicked login button with password field');
      notifyLogin(detector.getCredentials(pwd));
    }
  }
}, true);

// 4. Listen for messages from background (e.g., if background detected something)
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type === 'SHOW_SAVE_BANNER') {
    console.log('ℹ️ Save banner suppressed by direct-fill mode');
  }
  return false;
});

// 3. Enter key in password field
document.addEventListener('keydown', (e) => {
  if (e.key === 'Enter') {
    const target = e.target;
    if (target.tagName === 'INPUT' && isSecurePassPasswordField(target)) {
      if (target.value) {
        notifyLogin(detector.getCredentials(target));
      }
    }
  }
}, true);

// Watch for DOM changes
const observer = new MutationObserver(() => {
  injectIcons();
  bindDropdownToAllFields();
});
observer.observe(document.body, { childList: true, subtree: true });
injectIcons();
bindDropdownToAllFields();

// Check for pending save banner on load (handles page redirects after login)
chrome.runtime.sendMessage({ type: 'GET_LAST_DETECTED' }, (lastCreds) => {
  if (lastCreds && lastCreds.username && lastCreds.password) {
    const now = Date.now();
    if (now - lastCreds.timestamp < 15000 && lastCreds.origin === window.location.origin) {
      console.log('🔄 Restoring save banner after navigation');
    }
  }
});

// --- Auto-fill on page load ---
function tryAutoFillOnLoad() {
  if (autoFillTriggered) return;
  const pwdField = findPasswordField(document);
  if (!pwdField || pwdField.offsetWidth === 0) return;

  autoFillTriggered = true;
  const domain = window.location.hostname;

  chrome.runtime.sendMessage({ type: 'AUTO_FILL_CHECK', data: { domain } }, (result) => {
    if (chrome.runtime.lastError || !result || !result.autoFillEnabled) return;

    if (result.singleMatch && result.accounts.length === 1) {
      console.log('🚀 Auto-filling single matching account:', result.accounts[0].username);
      chrome.runtime.sendMessage({
        type: 'FILL_MATCHING_ACCOUNT',
        data: {
          domain: window.location.hostname,
          username: result.accounts[0].username,
        }
      });
    } else if (result.accounts.length > 1 && result.lastUsed) {
      console.log('🚀 Auto-filling last-used account:', result.lastUsed);
      chrome.runtime.sendMessage({
        type: 'FILL_MATCHING_ACCOUNT',
        data: {
          domain: window.location.hostname,
          username: result.lastUsed,
        }
      });
    } else if (result.accounts.length > 1) {
      showAutofillDropdown(pwdField);
    }
  });
}

setTimeout(tryAutoFillOnLoad, 800);
