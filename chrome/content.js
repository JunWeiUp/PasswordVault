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

// --- Inline Autofill Dropdown (Shadow DOM) ---

function hideAutofillDropdown() {
  if (activeDropdownHost) {
    activeDropdownHost.remove();
    activeDropdownHost = null;
  }
}

function showAutofillDropdown(field) {
  hideAutofillDropdown();

  const domain = window.location.hostname;
  chrome.runtime.sendMessage({ type: 'GET_MATCHING_ACCOUNTS', data: { domain } }, (result) => {
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
      const badge = acc.lastUsed ? '<span class="badge">最近使用</span>' : '';
      itemsHtml += `
        <div class="item" data-index="${idx}" data-username="${acc.username.replace(/"/g, '&quot;')}">
          <img src="${iconUrl}" class="icon" />
          <span class="username">${acc.username}</span>
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
        .header { padding: 8px 12px; font-size: 11px; color: #888; border-bottom: 1px solid #f0f0f0; display: flex; align-items: center; gap: 6px; }
        .header img { width: 14px; height: 14px; }
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
        <div class="header"><img src="${iconUrl}" />SecurePass</div>
        ${itemsHtml}
        <div class="footer" id="open-sp"><img src="${iconUrl}" />打开 SecurePass...</div>
      </div>
    `;

    document.body.appendChild(host);
    activeDropdownHost = host;

    shadow.querySelectorAll('.item').forEach(el => {
      el.addEventListener('mousedown', (e) => {
        e.preventDefault();
        e.stopPropagation();
        const username = el.dataset.username;
        hideAutofillDropdown();
        chrome.runtime.sendMessage({
          type: 'OPEN_POPUP_FOR_FILL',
          data: {
            url: window.location.href,
            origin: window.location.origin,
            username: username,
            fillRequested: true,
            autoClose: true,
          }
        });
        showToast('正在自动填充...');
      });
    });

    shadow.getElementById('open-sp')?.addEventListener('mousedown', (e) => {
      e.preventDefault();
      hideAutofillDropdown();
      chrome.runtime.sendMessage({
        type: 'OPEN_POPUP_FOR_FILL',
        data: { url: window.location.href, origin: window.location.origin, username: '' }
      });
    });
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
      if (form.querySelector('input[type="password"]')) {
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
  const allPwdFields = Array.from(document.querySelectorAll('input[type="password"]'))
    .filter(f => f.offsetWidth > 0 && f.offsetHeight > 0);
  
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
      <span style="font-weight:600;font-size:16px;">SecurePass</span>
      <button id="securepass-pwchange-close" style="margin-left:auto;background:none;border:none;font-size:20px;cursor:pointer;color:#999;">&times;</button>
    </div>
    <div style="margin-bottom:16px;line-height:1.4;">
      检测到修改密码表单，是否需要帮助？
    </div>
    <div style="display:flex;gap:8px;">
      <button id="securepass-fill-current" class="securepass-btn" style="flex:1;background:#1a73e8;color:#fff;border:none;padding:10px;border-radius:6px;cursor:pointer;font-weight:500;font-size:13px;">填充当前密码</button>
      <button id="securepass-gen-new" class="securepass-btn" style="flex:1;background:#e8f0fe;color:#1a73e8;border:none;padding:10px;border-radius:6px;cursor:pointer;font-weight:500;font-size:13px;">生成新密码</button>
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
    showToast('正在从保险箱填充当前密码...');
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
    showToast('正在打开密码生成器...');
    banner.remove();
  };

  setTimeout(() => { if (banner.parentElement) banner.remove(); }, 60000);
}

const detector = {
  getCredentials: (field) => {
    if (!field) return currentCreds;
    const form = field.closest('form') || document.body;
    
    // Find password field
    const passwordField = field.type === 'password' ? field : form.querySelector('input[type="password"]');
    
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
    const passwordField = document.querySelector('input[type="password"]');
    if (passwordField) {
      const form = passwordField.closest('form') || document.body;
      const usernameField = form.querySelector('input[type="email"], input[type="text"], input:not([type])');
      
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
    const pwdField = document.querySelector('input[type="password"]');
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
          type: 'OPEN_POPUP_FOR_FILL',
          data: {
            url: window.location.href,
            origin: window.location.origin,
            username: creds.username
          }
        }, (response) => {
          if (chrome.runtime.lastError) {
            console.error('❌ SendMessage error:', chrome.runtime.lastError);
            showToast('⚠️ 插件通信失败，请刷新页面重试');
          } else {
            showToast('🚀 正在为您打开 SecurePass...');
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
  const passwordFields = document.querySelectorAll('input[type="password"]');

  if (passwordFields.length >= 2) {
    const pwChangeInfo = detectPasswordChangeForm();
    if (pwChangeInfo) {
      console.log('🔑 Password change form detected');
      chrome.runtime.sendMessage({
        type: 'DETECTED_PASSWORD_CHANGE',
        data: { url: window.location.href, origin: window.location.origin }
      });
      showPasswordChangeBanner(pwChangeInfo);
      return;
    }
  }

  if (creds.username && creds.password && creds.password.length >= 4) {
    console.log('🚀 Detected login attempt for:', creds.username);
    chrome.runtime.sendMessage({ type: 'DETECTED_LOGIN', data: creds });
    showSaveBanner(creds);
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
      <span style="font-weight: 600; font-size: 16px;">SecurePass</span>
      <button id="securepass-close-x" style="margin-left: auto; background: none; border: none; font-size: 20px; cursor: pointer; color: #999;">&times;</button>
    </div>
    <div style="margin-bottom: 16px; line-height: 1.4;">
      是否将 <strong>${creds.username}</strong> 的密码保存到保险箱？
    </div>
    <div style="display: flex; gap: 8px;">
      <button id="securepass-quick-save-btn" class="securepass-btn" style="flex: 1; background: #1a73e8; color: white; border: none; padding: 10px; border-radius: 6px; cursor: pointer; font-weight: 500; font-size: 14px;">一键保存</button>
      <button id="securepass-detail-save-btn" class="securepass-btn" style="flex: 0; background: #e8f0fe; color: #1a73e8; border: none; padding: 10px 14px; border-radius: 6px; cursor: pointer; font-weight: 500; font-size: 13px; white-space: nowrap;">详细编辑</button>
      <button id="securepass-ignore-btn" class="securepass-btn" style="flex: 0; background: #f1f3f4; color: #3c4043; border: none; padding: 10px 14px; border-radius: 6px; cursor: pointer; font-weight: 500; font-size: 13px;">忽略</button>
    </div>
  `;

  document.body.appendChild(banner);

  document.getElementById('securepass-quick-save-btn').onclick = () => {
    chrome.runtime.sendMessage({ type: 'QUICK_SAVE', data: creds }, (response) => {
      banner.innerHTML = `
        <div style="display: flex; flex-direction: column; align-items: center; padding: 10px;">
          <div style="font-size: 24px; margin-bottom: 10px;">✅</div>
          <div style="font-weight: 600; color: #1e8e3e; margin-bottom: 4px;">已保存到待处理</div>
          <div style="font-size: 12px; color: #666; text-align: center;">下次打开 SecurePass 时可完善信息</div>
        </div>
      `;
      setTimeout(() => banner.remove(), 2500);
    });
  };

  document.getElementById('securepass-detail-save-btn').onclick = () => {
    showToast('正在打开 SecurePass...');
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
  const pwd = e.target.querySelector('input[type="password"]');
  if (pwd && pwd.value && pwd.value.length >= 4) {
    console.log('📝 Form submitted with password field');
    notifyLogin(detector.getCredentials(pwd));
  }
}, true);

// Real-time tracking to ensure we capture the latest values before page navigation
document.addEventListener('input', (e) => {
  if (e.target.tagName === 'INPUT' && (e.target.type === 'password' || e.target.type === 'text' || e.target.type === 'email')) {
    const form = e.target.closest('form') || document.body;
    const pwdField = form.querySelector('input[type="password"]');
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
      pwd = form.querySelector('input[type="password"]');
    }
    
    // Fallback: look for ANY password field on the page if the button looks very much like a login button
    if (!pwd) {
      pwd = document.querySelector('input[type="password"]');
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
    showSaveBanner(message.data);
  }
  return false;
});

// 3. Enter key in password field
document.addEventListener('keydown', (e) => {
  if (e.key === 'Enter') {
    const target = e.target;
    if (target.tagName === 'INPUT' && target.type === 'password') {
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
      showSaveBanner(lastCreds);
    }
  }
});

// --- Auto-fill on page load ---
function tryAutoFillOnLoad() {
  if (autoFillTriggered) return;
  const pwdField = document.querySelector('input[type="password"]');
  if (!pwdField || pwdField.offsetWidth === 0) return;

  autoFillTriggered = true;
  const domain = window.location.hostname;

  chrome.runtime.sendMessage({ type: 'AUTO_FILL_CHECK', data: { domain } }, (result) => {
    if (chrome.runtime.lastError || !result || !result.autoFillEnabled) return;

    if (result.singleMatch && result.accounts.length === 1) {
      console.log('🚀 Auto-filling single matching account:', result.accounts[0].username);
      chrome.runtime.sendMessage({
        type: 'OPEN_POPUP_FOR_FILL',
        data: {
          url: window.location.href,
          origin: window.location.origin,
          username: result.accounts[0].username,
          fillRequested: true,
          autoClose: true,
        }
      });
    } else if (result.accounts.length > 1 && result.lastUsed) {
      console.log('🚀 Auto-filling last-used account:', result.lastUsed);
      chrome.runtime.sendMessage({
        type: 'OPEN_POPUP_FOR_FILL',
        data: {
          url: window.location.href,
          origin: window.location.origin,
          username: result.lastUsed,
          fillRequested: true,
          autoClose: true,
        }
      });
    } else if (result.accounts.length > 1) {
      showAutofillDropdown(pwdField);
    }
  });
}

setTimeout(tryAutoFillOnLoad, 800);
