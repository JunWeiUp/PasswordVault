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
  // Check if there are multiple password fields on the page (common in "change password" forms)
  const passwordFields = document.querySelectorAll('input[type="password"]');
  if (passwordFields.length >= 3) {
    console.log('ℹ️ Multiple password fields detected, likely a change password form. Skipping auto-save.');
    return;
  }

  if (creds.username && creds.password && creds.password.length >= 4) {
    console.log('🚀 Detected login attempt for:', creds.username);
    
    // 1. Send to background for system notification
    chrome.runtime.sendMessage({ type: 'DETECTED_LOGIN', data: creds });
    
    // 2. Show internal banner (more reliable than system notifications)
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
    <div style="display: flex; gap: 10px;">
      <button id="securepass-save-btn" class="securepass-btn" style="flex: 1; background: #1a73e8; color: white; border: none; padding: 10px; border-radius: 6px; cursor: pointer; font-weight: 500; font-size: 14px;">立即保存</button>
      <button id="securepass-ignore-btn" class="securepass-btn" style="flex: 1; background: #f1f3f4; color: #3c4043; border: none; padding: 10px; border-radius: 6px; cursor: pointer; font-weight: 500; font-size: 14px;">以后再说</button>
    </div>
  `;

  document.body.appendChild(banner);

  document.getElementById('securepass-save-btn').onclick = () => {
    showToast('🚀 正在保存并打开 SecurePass...');
    chrome.runtime.sendMessage({ type: 'CONFIRM_SAVE', data: creds }, (response) => {
      banner.innerHTML = `
        <div style="display: flex; flex-direction: column; align-items: center; padding: 10px;">
          <div style="font-size: 24px; margin-bottom: 10px;">✅</div>
          <div style="font-weight: 600; color: #1e8e3e; margin-bottom: 4px;">已保存成功</div>
          <div style="font-size: 12px; color: #666; text-align: center;">请点击插件图标查看或完善信息</div>
        </div>
      `;
      setTimeout(() => banner.remove(), 3000);
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
const observer = new MutationObserver(() => injectIcons());
observer.observe(document.body, { childList: true, subtree: true });
injectIcons();

// Check for pending save banner on load (handles page redirects after login)
chrome.runtime.sendMessage({ type: 'GET_LAST_DETECTED' }, (lastCreds) => {
  if (lastCreds && lastCreds.username && lastCreds.password) {
    const now = Date.now();
    // If detected within last 15 seconds for this origin, show the banner
    if (now - lastCreds.timestamp < 15000 && lastCreds.origin === window.location.origin) {
      console.log('🔄 Restoring save banner after navigation');
      showSaveBanner(lastCreds);
    }
  }
});
