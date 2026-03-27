// Background service worker for SecurePass Extension
console.log('🛡️ SecurePass Service Worker starting...');

// Handle installation and updates
chrome.runtime.onInstalled.addListener((details) => {
  console.log('🛡️ SecurePass Extension installed/updated:', details.reason);
  
  chrome.contextMenus.create({
    id: 'fill_password',
    title: 'SecurePass: Fill Password',
    contexts: ['editable']
  });
});

// State
let lastDetectedCredentials = null;
let lastNotificationTime = 0;
let cachedMasterKey = null; // Memory cache for derived key (base64 string)
let lastActiveContext = null; // Store context of where the icon was clicked

async function hashPassword(password) {
  if (!password) return "";
  const encoder = new TextEncoder();
  const data = encoder.encode(password);
  const hashBuffer = await crypto.subtle.digest('SHA-256', data);
  const hashArray = Array.from(new Uint8Array(hashBuffer));
  return btoa(String.fromCharCode.apply(null, hashArray));
}

async function checkCredentialsMismatch(creds) {
  const domain = getDomain(creds.url);
  const result = await chrome.storage.local.get(['known_accounts']);
  const knownAccountsMap = result.known_accounts || {};
  
  const domainKey = Object.keys(knownAccountsMap).find(d => domain === d || domain.endsWith('.' + d));
  if (!domainKey) return { mismatch: true, reason: 'new_domain' };

  const accounts = knownAccountsMap[domainKey];
  const matchingAccount = accounts.find(a => a.username === creds.username);
  
  if (!matchingAccount) return { mismatch: true, reason: 'new_account' };

  const hashedInput = await hashPassword(creds.password);
  if (hashedInput !== matchingAccount.passwordHash) {
    return { mismatch: true, reason: 'wrong_password' };
  }

  return { mismatch: false };
}

// Handle messages
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  console.log('📩 Background received message:', message.type);
  
  if (message.type === 'DETECTED_LOGIN') {
    (async () => {
      // Throttling to prevent duplicate notifications (e.g., both click and submit)
      const now = Date.now();
      if (lastDetectedCredentials && 
          lastDetectedCredentials.username === message.data.username && 
          lastDetectedCredentials.password === message.data.password && 
          (now - lastNotificationTime) < 5000) {
        console.log('⏭️ Duplicate login detection ignored');
        return;
      }

      console.log('📝 Credentials detected:', message.data.username);
      
      const checkResult = await checkCredentialsMismatch(message.data);
      
      lastDetectedCredentials = {
        ...message.data,
        tabId: sender.tab?.id,
        timestamp: now,
        mismatch: checkResult.mismatch,
        reason: checkResult.reason
      };
      lastNotificationTime = now;
      
      if (checkResult.mismatch) {
        updateBadgeForTab(sender.tab?.id);
      }

      // Create notification to save
      const notificationId = 'save_password_' + now;
      chrome.notifications.create(notificationId, {
        type: 'basic',
        iconUrl: chrome.runtime.getURL('icons/icon192.png'),
        title: checkResult.mismatch ? 'SecurePass: 检测到账号变动' : 'SecurePass: 是否保存此账号?',
        message: checkResult.reason === 'wrong_password' 
          ? `检测到 ${message.data.username} 的密码与保险箱中不一致，是否更新？`
          : `检测到 ${message.data.username} 的登录，是否保存到保险箱？`,
        buttons: [{ title: '立即保存/更新' }, { title: '暂不处理' }],
        priority: 2,
        requireInteraction: true
      });
    })();
    return true;
  } 
  else if (message.type === 'CONFIRM_SAVE') {
    console.log('📥 Confirm save message received:', message.data.username);
    savePendingCredentials(message.data);
    
    // Clear last detected after saving
    lastDetectedCredentials = null;

    // Also open the popup window so they can see the pending save
    chrome.windows.create({
      url: chrome.runtime.getURL('index.html'),
      type: 'popup',
      width: 400,
      height: 600,
      focused: true
    });

    if (sendResponse) sendResponse({ success: true });
    return true;
  }
  else if (message.type === 'CLEAR_LAST_DETECTED') {
    console.log('🗑️ Clearing last detected credentials');
    lastDetectedCredentials = null;
    if (sendResponse) sendResponse({ success: true });
  }
  else if (message.type === 'SET_MASTER_KEY') {
    console.log('🔑 Master key cached in background');
    cachedMasterKey = message.data.key;
    sendResponse({ success: true });
  }
  else if (message.type === 'GET_MASTER_KEY') {
    console.log('🔑 Retrieving master key from background:', cachedMasterKey ? 'found' : 'not found');
    sendResponse({ key: cachedMasterKey });
  }
  else if (message.type === 'CLEAR_MASTER_KEY') {
    console.log('🔒 Master key cleared from background');
    cachedMasterKey = null;
    sendResponse({ success: true });
  }
  else if (message.type === 'OPEN_POPUP_FOR_FILL') {
    console.log('🔔 Opening popup window with context:', message.data);
    lastActiveContext = message.data;
    
    // Open a small standalone window that acts as a popup
    chrome.windows.create({
      url: chrome.runtime.getURL('index.html'),
      type: 'popup',
      width: 400,
      height: 600,
      focused: true
    }, (window) => {
      console.log('✅ Popup window created:', window.id);
    });
  }
  else if (message.type === 'GET_ACTIVE_CONTEXT') {
    (async () => {
      console.log('🔍 GET_ACTIVE_CONTEXT requested');
      
      // If we already have a forced context (e.g. from context menu or icon click), use it
      if (lastActiveContext) {
        console.log('🎯 Returning existing active context:', lastActiveContext);
        sendResponse(lastActiveContext);
        return;
      }

      // Otherwise, check if the current active tab has a mismatch
      const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
      if (tab && lastDetectedCredentials && lastDetectedCredentials.tabId === tab.id && lastDetectedCredentials.mismatch) {
        console.log('⚠️ Current tab has mismatch, returning mismatch context');
        sendResponse({
          type: 'mismatch_detected',
          data: lastDetectedCredentials
        });
        return;
      }

      // If no context but we have a tab, create context from current tab
      if (tab && tab.url) {
        try {
          const url = new URL(tab.url);
          const context = {
            url: tab.url,
            origin: url.origin,
            username: '',
          };
          console.log('🌐 Creating context from current tab:', url.origin);
          // Don't set lastActiveContext here, just return it so popup can check current tab
          sendResponse(context);
          return;
        } catch (e) {
          console.error('❌ Failed to parse tab URL:', e);
        }
      }

      console.log('ℹ️ No active context to return');
      sendResponse(null);
    })();
    return true; // Keep message channel open for async sendResponse
  }
  else if (message.type === 'CLEAR_ACTIVE_CONTEXT') {
    console.log('🧹 Clearing active context');
    lastActiveContext = null;
    sendResponse({ success: true });
  }
  else if (message.type === 'UPDATE_BADGE') {
    updateBadgeForTab(sender.tab?.id);
    sendResponse({ success: true });
  }
  else if (message.type === 'GET_CURRENT_TAB_URL') {
    chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
      if (tabs[0]) {
        sendResponse({ url: tabs[0].url });
      } else {
        sendResponse({ url: null });
      }
    });
    return true;
  }
  // ... rest of handlers ...
  else if (message.type === 'GET_LAST_DETECTED') {
    sendResponse(lastDetectedCredentials);
  }
  else if (message.type === 'DO_FILL') {
    chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
      if (tabs[0]) {
        chrome.tabs.sendMessage(tabs[0].id, {
          type: 'FILL_CREDENTIALS',
          data: message.data
        }, (response) => {
          sendResponse(response);
        });
      }
    });
    return true;
  }
  return true;
});

// Helper to save pending credentials
function savePendingCredentials(creds) {
  chrome.storage.local.get(['pending_saves'], (result) => {
    const pending = result.pending_saves || [];
    // Avoid duplicates
    if (!pending.some(p => p.username === creds.username && p.password === creds.password && p.url === creds.url)) {
      pending.push(creds);
      chrome.storage.local.set({ pending_saves: pending }, () => {
        console.log('✅ Credentials saved to pending_saves');
      });
    }
  });
}

// Handle notification button clicks
chrome.notifications.onButtonClicked.addListener((notificationId, buttonIndex) => {
  if (notificationId.startsWith('save_password_') && lastDetectedCredentials) {
    if (buttonIndex === 0) {
      // "立即保存/更新" - Open popup with context
      console.log('🔔 Opening popup for save/update from notification button click');
      
      lastActiveContext = {
        type: 'mismatch_detected',
        data: lastDetectedCredentials
      };

      chrome.windows.create({
        url: chrome.runtime.getURL('index.html'),
        type: 'popup',
        width: 400,
        height: 600,
        focused: true
      });
    }
    chrome.notifications.clear(notificationId);
  } else {
    chrome.notifications.clear(notificationId);
  }
});

// Handle notification body clicks
chrome.notifications.onClicked.addListener((notificationId) => {
  console.log('🖱️ Notification clicked:', notificationId);
  
  if (notificationId.startsWith('save_password_') && lastDetectedCredentials) {
    // Treat notification click same as "立即保存/更新" button
    console.log('🔔 Opening popup for save/update from notification click');
    
    lastActiveContext = {
      type: 'mismatch_detected',
      data: lastDetectedCredentials
    };

    chrome.windows.create({
      url: chrome.runtime.getURL('index.html'),
      type: 'popup',
      width: 400,
      height: 600,
      focused: true
    });
    
    chrome.notifications.clear(notificationId);
  } else if (notificationId.startsWith('fill_hint_')) {
    // Just clearing it is fine, the user now knows to click the extension icon
    chrome.notifications.clear(notificationId);
  }
});

// --- Badge and URL Monitoring ---

// Helper to extract domain from URL
function getDomain(url) {
  if (!url) return '';
  try {
    const hostname = new URL(url).hostname;
    return hostname.toLowerCase();
  } catch (e) {
    return '';
  }
}

// Update badge for a specific tab
async function updateBadgeForTab(tabId) {
  if (!tabId) return;

  try {
    const tab = await chrome.tabs.get(tabId);
    if (!tab || !tab.url) return;

    const domain = getDomain(tab.url);
    if (!domain) {
      chrome.action.setBadgeText({ text: '', tabId: tabId });
      return;
    }

    // Check for detected mismatch first
    if (lastDetectedCredentials && 
        lastDetectedCredentials.tabId === tabId && 
        lastDetectedCredentials.mismatch) {
      chrome.action.setBadgeText({ text: '!', tabId: tabId });
      chrome.action.setBadgeBackgroundColor({ color: '#F44336', tabId: tabId }); // Red for warning
      return;
    }

    chrome.storage.local.get(['known_domains'], (result) => {
      const knownDomains = result.known_domains || [];
      const hasMatch = knownDomains.some(d => domain === d || domain.endsWith('.' + d));

      if (hasMatch) {
        chrome.action.setBadgeText({ text: '1', tabId: tabId });
        chrome.action.setBadgeBackgroundColor({ color: '#4CAF50', tabId: tabId });
      } else {
        chrome.action.setBadgeText({ text: '', tabId: tabId });
      }
    });
  } catch (e) {
    console.error('❌ Error updating badge:', e);
  }
}

// Handle action icon clicks
chrome.action.onClicked.addListener(async (tab) => {
  // If we have a mismatch, open the popup to add/update the account
  if (lastDetectedCredentials && lastDetectedCredentials.tabId === tab.id && lastDetectedCredentials.mismatch) {
    console.log('⚠️ Mismatch detected, opening popup for add/update');
    
    // Set the active context so the popup knows what to show
    lastActiveContext = {
      type: 'mismatch_detected',
      data: lastDetectedCredentials
    };

    chrome.windows.create({
      url: chrome.runtime.getURL('index.html'),
      type: 'popup',
      width: 400,
      height: 600,
      focused: true
    });
    return;
  }

  // Default behavior: set context for current tab to trigger auto-search
  if (tab && tab.url) {
    try {
      const url = new URL(tab.url);
      lastActiveContext = {
        url: tab.url,
        origin: url.origin,
        username: '',
      };
      console.log('🔍 Setting active context for tab:', url.origin);
    } catch (e) {
      console.error('❌ Failed to parse tab URL:', e);
    }
  }

  // Open the popup
  chrome.windows.create({
    url: chrome.runtime.getURL('index.html'),
    type: 'popup',
    width: 400,
    height: 600,
    focused: true
  });
});

// Listen for tab updates (URL changes)
chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (changeInfo.status === 'complete' && tab.url) {
    updateBadgeForTab(tabId);
  }
});

// Listen for tab activation (switching tabs)
chrome.tabs.onActivated.addListener((activeInfo) => {
  updateBadgeForTab(activeInfo.tabId);
});

// Listen for storage changes (when Flutter app updates known_domains)
chrome.storage.onChanged.addListener((changes, areaName) => {
  if (areaName === 'local' && changes.known_domains) {
    chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
      if (tabs[0]) {
        updateBadgeForTab(tabs[0].id);
      }
    });
  }
});
