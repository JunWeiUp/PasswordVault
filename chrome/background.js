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

// Handle messages
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  console.log('📩 Background received message:', message.type);
  
  if (message.type === 'DETECTED_LOGIN') {
    // Throttling to prevent duplicate notifications (e.g., both click and submit)
    const now = Date.now();
    if (lastDetectedCredentials && 
        lastDetectedCredentials.username === message.data.username && 
        lastDetectedCredentials.password === message.data.password && 
        (now - lastNotificationTime) < 5000) {
      console.log('⏭️ Duplicate login detection ignored');
      return true;
    }

    console.log('📝 Credentials detected:', message.data.username);
    lastDetectedCredentials = {
      ...message.data,
      tabId: sender.tab?.id,
      timestamp: now
    };
    lastNotificationTime = now;
    
    // Create notification to save
    const notificationId = 'save_password_' + now;
    chrome.notifications.create(notificationId, {
      type: 'basic',
      iconUrl: chrome.runtime.getURL('icons/icon192.png'),
      title: 'SecurePass: 是否保存此账号?',
      message: `检测到 ${message.data.username} 的登录，是否保存到保险箱？`,
      buttons: [{ title: '立即保存' }, { title: '暂不保存' }],
      priority: 2,
      requireInteraction: true
    }, (id) => {
      if (chrome.runtime.lastError) {
        console.error('❌ Notification Error:', chrome.runtime.lastError.message);
      } else {
        console.log('✅ Notification created successfully:', id);
      }
    });
  } 
  else if (message.type === 'CONFIRM_SAVE') {
    console.log('📥 Confirm save message received:', message.data.username);
    savePendingCredentials(message.data);
    
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
    console.log('🔍 Returning active context:', lastActiveContext);
    sendResponse(lastActiveContext);
    // lastActiveContext = null; // Clear after retrieval to avoid stale data
  }
  else if (message.type === 'CLEAR_ACTIVE_CONTEXT') {
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
  if (notificationId.startsWith('save_password_') && buttonIndex === 0 && lastDetectedCredentials) {
    savePendingCredentials(lastDetectedCredentials);
    chrome.notifications.clear(notificationId);
    chrome.notifications.create('save_confirm_' + Date.now(), {
      type: 'basic',
      iconUrl: chrome.runtime.getURL('icons/icon192.png'),
      title: 'SecurePass',
      message: '已存入待保存列表，请在插件主界面完成添加。'
    });
  } else {
    chrome.notifications.clear(notificationId);
  }
});

// Handle notification body clicks
chrome.notifications.onClicked.addListener((notificationId) => {
  console.log('🖱️ Notification clicked:', notificationId);
  chrome.notifications.clear(notificationId);
  
  // In Chrome, we can't easily open the popup from background, 
  // but we can focus the window or provide a hint.
  if (notificationId.startsWith('fill_hint_')) {
    // Just clearing it is fine, the user now knows to click the extension icon
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
