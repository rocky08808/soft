const TOKEN_KEY = "remoteScreenToken";
const MOUSE_TRACK_KEY = "remoteScreenMouseTrack";
const AUTO_SCREENSHOT_KEY_PREFIX = "autoScreenshot:";
const SCREEN_RECORDING_KEY_PREFIX = "screenRecording:";
const DEFAULT_AUTO_SCREENSHOT_INTERVAL = 60;
const DEFAULT_RECORDING_SEGMENT = 30;

const tokenInput = document.getElementById("accessToken");
const deviceInput = document.getElementById("deviceId");
const serverInput = document.getElementById("serverUrl");
const connectBtn = document.getElementById("connectBtn");
const disconnectBtn = document.getElementById("disconnectBtn");
const refreshBtn = document.getElementById("refreshBtn");
const statusEl = document.getElementById("status");
const canvas = document.getElementById("screen");
const placeholder = document.getElementById("placeholder");
const metaEl = document.getElementById("meta");
const fpsEl = document.getElementById("fps");
const deviceListEl = document.getElementById("deviceList");
const auditListEl = document.getElementById("auditList");
const clipboardListEl = document.getElementById("clipboardList");
const clipboardHintEl = document.getElementById("clipboardHint");
const clearClipboardBtn = document.getElementById("clearClipboardBtn");
const keyboardListEl = document.getElementById("keyboardList");
const clearKeyboardBtn = document.getElementById("clearKeyboardBtn");
const screenshotBtn = document.getElementById("screenshotBtn");
const clearScreenshotsBtn = document.getElementById("clearScreenshotsBtn");
const screenshotListEl = document.getElementById("screenshotList");
const screenshotHintEl = document.getElementById("screenshotHint");
const screenshotModalEl = document.getElementById("screenshotModal");
const screenshotModalImgEl = document.getElementById("screenshotModalImg");
const screenshotModalTitleEl = document.getElementById("screenshotModalTitle");
const screenshotModalCloseBtn = document.getElementById("screenshotModalClose");
const screenshotModalDownloadBtn = document.getElementById("screenshotModalDownload");
const autoScreenshotToggle = document.getElementById("autoScreenshotToggle");
const autoScreenshotIntervalInput = document.getElementById("autoScreenshotInterval");
const clearRecordingsBtn = document.getElementById("clearRecordingsBtn");
const screenRecordingToggle = document.getElementById("screenRecordingToggle");
const screenRecordingSegmentInput = document.getElementById("screenRecordingSegment");
const recordingListEl = document.getElementById("recordingList");
const recordingHintEl = document.getElementById("recordingHint");
const recordingModalEl = document.getElementById("recordingModal");
const recordingModalVideoEl = document.getElementById("recordingModalVideo");
const recordingModalTitleEl = document.getElementById("recordingModalTitle");
const recordingModalCloseBtn = document.getElementById("recordingModalClose");
const recordingModalDownloadBtn = document.getElementById("recordingModalDownload");
const mouseTrackToggle = document.getElementById("mouseTrackToggle");
const terminalHintEl = document.getElementById("terminalHint");
const openTerminalBtn = document.getElementById("openTerminalBtn");
const terminalModalEl = document.getElementById("terminalModal");
const terminalModalTitleEl = document.getElementById("terminalModalTitle");
const terminalModalCloseBtn = document.getElementById("terminalModalClose");
const terminalClearBtn = document.getElementById("terminalClearBtn");
const terminalShellEl = document.getElementById("terminalShell");
const terminalRunBtn = document.getElementById("terminalRunBtn");
const terminalOutputEl = document.getElementById("terminalOutput");
const terminalInputEl = document.getElementById("terminalInput");
const terminalCwdEl = document.getElementById("terminalCwd");
const ctx = canvas.getContext("2d");

const MAX_CLIPBOARD_UI = 300;
const MAX_KEYBOARD_UI = 300;
const MAX_SCREENSHOT_UI = 80;
const MAX_RECORDING_UI = 20;
let clipboardEntries = [];
let keyboardEntries = [];
let screenshotEntries = [];
let recordingEntries = [];
let recordingModalEntry = null;
let screenshotModalEntry = null;
let screenshotPendingTimer = null;
let screenshotPendingId = "";

const params = new URLSearchParams(window.location.search);
if (params.get("device")) deviceInput.value = params.get("device");
tokenInput.value = localStorage.getItem(TOKEN_KEY) || tokenInput.value;
mouseTrackToggle.checked = localStorage.getItem(MOUSE_TRACK_KEY) === "1";

let ws = null;
let dashWs = null;
let remoteWidth = 0;
let remoteHeight = 0;
let frameCount = 0;
let lastFpsAt = performance.now();
let lastMoveAt = 0;
let termOnline = false;
let terminalReqSeq = 0;
let terminalSessionCwd = "";
const MAX_TERMINAL_HISTORY = 100;
let terminalHistory = [];
let terminalTabCycle = { basePrefix: "", list: [], index: -1 };

function getToken() {
  return tokenInput.value.trim();
}

function saveToken() {
  localStorage.setItem(TOKEN_KEY, getToken());
}

function httpBase() {
  const custom = serverInput.value.trim();
  if (custom) {
    let base = custom.replace(/\/$/, "");
    if (base.startsWith("ws://")) base = "http://" + base.slice(5);
    else if (base.startsWith("wss://")) base = "https://" + base.slice(6);
    else if (!base.startsWith("http")) base = "http://" + base;
    return base;
  }
  return `${location.protocol}//${location.host}`;
}

function wsBase() {
  const custom = serverInput.value.trim();
  if (custom) {
    let base = custom.replace(/\/$/, "");
    if (base.startsWith("http://")) base = "ws://" + base.slice(7);
    else if (base.startsWith("https://")) base = "wss://" + base.slice(8);
    else if (!base.startsWith("ws")) base = "ws://" + base;
    return base;
  }
  const proto = location.protocol === "https:" ? "wss:" : "ws:";
  return `${proto}//${location.host}`;
}

async function apiFetch(path, options = {}) {
  const res = await fetch(`${httpBase()}${path}`, {
    ...options,
    headers: {
      Authorization: `Bearer ${getToken()}`,
      ...(options.headers || {}),
    },
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const text = await res.text();
  return text ? JSON.parse(text) : {};
}

function setStatus(text, online) {
  statusEl.textContent = text;
  statusEl.classList.toggle("online", online);
  statusEl.classList.toggle("offline", !online);
}

function sendControl(payload) {
  if (!ws || ws.readyState !== WebSocket.OPEN) return;
  ws.send(JSON.stringify({ type: "control", ...payload }));
}

function setTerminalHint(text) {
  if (terminalHintEl) terminalHintEl.textContent = text;
}

function updateTerminalUi() {
  const connected = !!(ws && ws.readyState === WebSocket.OPEN);
  const enabled = connected && termOnline;
  if (openTerminalBtn) openTerminalBtn.disabled = !connected;
  if (terminalRunBtn) terminalRunBtn.disabled = !enabled;
  if (terminalInputEl) terminalInputEl.disabled = !enabled;
}

function setTerminalCwd(path) {
  terminalSessionCwd = path ? String(path) : "";
  if (terminalCwdEl) {
    terminalCwdEl.textContent = terminalSessionCwd
      ? `工作目录: ${terminalSessionCwd}`
      : "工作目录: —";
  }
  updateTerminalModalTitle();
}

function updateTerminalModalTitle() {
  if (!terminalModalTitleEl) return;
  const deviceId = currentDeviceId();
  const status = termOnline ? "已连接" : "离线";
  terminalModalTitleEl.textContent = deviceId
    ? `远程终端 · ${deviceId} · ${status}`
    : `远程终端 · ${status}`;
}

function openTerminalModal() {
  if (!terminalModalEl) return;
  if (!ws || ws.readyState !== WebSocket.OPEN) {
    setTerminalHint("请先连接设备");
    return;
  }
  terminalModalEl.hidden = false;
  updateTerminalModalTitle();
  if (terminalInputEl && termOnline) {
    setTimeout(() => terminalInputEl.focus(), 0);
  }
}

function closeTerminalModal() {
  if (terminalModalEl) terminalModalEl.hidden = true;
}

function resetTerminalTabCycle() {
  terminalTabCycle = { basePrefix: "", list: [], index: -1 };
}

function pushTerminalHistory(command) {
  const cmd = String(command || "").trim();
  if (!cmd) return;
  terminalHistory = terminalHistory.filter((item) => item !== cmd);
  terminalHistory.unshift(cmd);
  if (terminalHistory.length > MAX_TERMINAL_HISTORY) {
    terminalHistory.length = MAX_TERMINAL_HISTORY;
  }
}

function longestCommonPrefix(items) {
  if (!items.length) return "";
  let prefix = items[0];
  for (let i = 1; i < items.length; i += 1) {
    const item = items[i];
    while (prefix && !item.toLowerCase().startsWith(prefix.toLowerCase())) {
      prefix = prefix.slice(0, -1);
    }
    if (!prefix) return "";
  }
  return prefix;
}

function getTerminalHistoryMatches(prefix) {
  const needle = String(prefix || "").toLowerCase();
  const seen = new Set();
  const matches = [];
  for (const cmd of terminalHistory) {
    if (!cmd.toLowerCase().startsWith(needle)) continue;
    if (seen.has(cmd)) continue;
    seen.add(cmd);
    matches.push(cmd);
  }
  return matches;
}

function handleTerminalTabCompletion() {
  if (!terminalInputEl || terminalInputEl.disabled) return false;

  const prefix = terminalInputEl.value;
  const matches = getTerminalHistoryMatches(prefix);
  if (!matches.length) return true;

  const sameCycle =
    terminalTabCycle.basePrefix === prefix &&
    terminalTabCycle.list.length === matches.length &&
    terminalTabCycle.list.every((item, index) => item === matches[index]);

  if (sameCycle) {
    terminalTabCycle.index = (terminalTabCycle.index + 1) % matches.length;
    terminalInputEl.value = matches[terminalTabCycle.index];
  } else {
    terminalTabCycle.basePrefix = prefix;
    terminalTabCycle.list = matches;
    const shared = longestCommonPrefix(matches);
    if (shared.length > prefix.length) {
      terminalInputEl.value = shared;
      terminalTabCycle.index = -1;
    } else if (matches.length === 1) {
      terminalInputEl.value = matches[0];
      terminalTabCycle.index = 0;
    } else {
      terminalTabCycle.index = 0;
      terminalInputEl.value = matches[0];
      appendTerminalBlock("", `[Tab 补全] ${matches.join("  ")}\n`);
    }
  }

  const end = terminalInputEl.value.length;
  terminalInputEl.setSelectionRange(end, end);
  return true;
}

function clearTerminalOutput() {
  if (!terminalOutputEl) return;
  terminalOutputEl.textContent = "连接设备后可执行命令";
  setTerminalCwd("");
  terminalHistory = [];
  resetTerminalTabCycle();
}

function appendTerminalBlock(title, text) {
  if (!terminalOutputEl) return;
  const chunk = text ? String(text) : "";
  if (terminalOutputEl.textContent === "连接设备后可执行命令") {
    terminalOutputEl.textContent = "";
  }
  terminalOutputEl.textContent += `${title}${chunk}${chunk && !chunk.endsWith("\n") ? "\n" : ""}`;
  terminalOutputEl.scrollTop = terminalOutputEl.scrollHeight;
  if (terminalModalEl && !terminalModalEl.hidden) {
    updateTerminalModalTitle();
  }
}

function sendTerminalCommand(command) {
  const cmd = String(command || "").trim();
  if (!cmd) return;
  if (!ws || ws.readyState !== WebSocket.OPEN) {
    setTerminalHint("请先连接设备");
    return;
  }
  if (!termOnline) {
    setTerminalHint("终端 Agent 离线，请在被控端运行 ReST.exe");
    return;
  }
  const shell = terminalShellEl?.value || "cmd";
  const id = `t-${Date.now()}-${++terminalReqSeq}`;
  appendTerminalBlock(`> [${shell}] ${cmd}\n`, "");
  pushTerminalHistory(cmd);
  resetTerminalTabCycle();
  ws.send(JSON.stringify({ type: "terminal", id, command: cmd, shell }));
  setTerminalHint(`设备: ${currentDeviceId()} · 命令已发送`);
}

function autoScreenshotStorageKey(deviceId) {
  return `${AUTO_SCREENSHOT_KEY_PREFIX}${deviceId}`;
}

function loadAutoScreenshotPrefs(deviceId) {
  try {
    const raw = localStorage.getItem(autoScreenshotStorageKey(deviceId));
    if (!raw) return { enabled: false, interval: DEFAULT_AUTO_SCREENSHOT_INTERVAL };
    const data = JSON.parse(raw);
    const interval = Math.max(
      10,
      Math.min(3600, Number(data.interval) || DEFAULT_AUTO_SCREENSHOT_INTERVAL)
    );
    return { enabled: !!data.enabled, interval };
  } catch {
    return { enabled: false, interval: DEFAULT_AUTO_SCREENSHOT_INTERVAL };
  }
}

function saveAutoScreenshotPrefs(deviceId, enabled, interval) {
  localStorage.setItem(
    autoScreenshotStorageKey(deviceId),
    JSON.stringify({ enabled: !!enabled, interval })
  );
}

function applyAutoScreenshotUi(prefs) {
  if (!autoScreenshotToggle || !autoScreenshotIntervalInput) return;
  autoScreenshotToggle.checked = !!prefs.enabled;
  autoScreenshotIntervalInput.value = String(prefs.interval);
  autoScreenshotIntervalInput.disabled = !prefs.enabled;
}

function syncAutoScreenshotUi(deviceId) {
  applyAutoScreenshotUi(loadAutoScreenshotPrefs(deviceId));
}

function sendAutoScreenshotSetting(deviceId, enabled, interval) {
  const seconds = enabled
    ? Math.max(10, Math.min(3600, Number(interval) || DEFAULT_AUTO_SCREENSHOT_INTERVAL))
    : 0;
  saveAutoScreenshotPrefs(deviceId, enabled, seconds);
  sendControl({ action: "set_auto_screenshot", interval: seconds });
  if (enabled) {
    setScreenshotHint(`设备: ${deviceId} · 自动截屏已开启（每 ${seconds} 秒）`);
  } else {
    setScreenshotHint(`设备: ${deviceId} · 自动截屏已关闭`);
  }
}

function pushAutoScreenshotToAgent(deviceId) {
  const prefs = loadAutoScreenshotPrefs(deviceId);
  applyAutoScreenshotUi(prefs);
  if (!ws || ws.readyState !== WebSocket.OPEN) return;
  const seconds = prefs.enabled ? prefs.interval : 0;
  sendControl({ action: "set_auto_screenshot", interval: seconds });
}

function screenRecordingStorageKey(deviceId) {
  return `${SCREEN_RECORDING_KEY_PREFIX}${deviceId}`;
}

function loadScreenRecordingPrefs(deviceId) {
  try {
    const raw = localStorage.getItem(screenRecordingStorageKey(deviceId));
    if (!raw) return { enabled: false, segmentSeconds: DEFAULT_RECORDING_SEGMENT };
    const data = JSON.parse(raw);
    const segmentSeconds = Math.max(
      30,
      Math.min(600, Number(data.segmentSeconds) || DEFAULT_RECORDING_SEGMENT)
    );
    return { enabled: !!data.enabled, segmentSeconds };
  } catch {
    return { enabled: false, segmentSeconds: DEFAULT_RECORDING_SEGMENT };
  }
}

function saveScreenRecordingPrefs(deviceId, enabled, segmentSeconds) {
  localStorage.setItem(
    screenRecordingStorageKey(deviceId),
    JSON.stringify({ enabled: !!enabled, segmentSeconds })
  );
}

function applyScreenRecordingUi(prefs) {
  if (!screenRecordingToggle || !screenRecordingSegmentInput) return;
  screenRecordingToggle.checked = !!prefs.enabled;
  screenRecordingSegmentInput.value = String(prefs.segmentSeconds);
  screenRecordingSegmentInput.disabled = !prefs.enabled;
}

function syncScreenRecordingUi(deviceId) {
  applyScreenRecordingUi(loadScreenRecordingPrefs(deviceId));
}

function setRecordingHint(text) {
  if (recordingHintEl) recordingHintEl.textContent = text;
}

function sendScreenRecordingSetting(deviceId, enabled, segmentSeconds) {
  const seconds = Math.max(30, Math.min(600, Number(segmentSeconds) || DEFAULT_RECORDING_SEGMENT));
  saveScreenRecordingPrefs(deviceId, enabled, seconds);
  sendControl({
    action: "set_screen_recording",
    enabled: !!enabled,
    segmentSeconds: seconds,
  });
  if (enabled) {
    setRecordingHint(`设备: ${deviceId} · 录屏中（每 ${seconds} 秒上传一段）`);
  } else {
    setRecordingHint(`设备: ${deviceId} · 录屏已关闭`);
  }
}

function pushScreenRecordingToAgent(deviceId) {
  const prefs = loadScreenRecordingPrefs(deviceId);
  applyScreenRecordingUi(prefs);
  if (!ws || ws.readyState !== WebSocket.OPEN) return;
  sendControl({
    action: "set_screen_recording",
    enabled: prefs.enabled,
    segmentSeconds: prefs.segmentSeconds,
  });
}

function isMouseTrackEnabled() {
  return mouseTrackToggle.checked;
}

function sendMouseMove(clientX, clientY) {
  if (!remoteWidth) return;
  const { x, y } = mapCoords(clientX, clientY);
  sendControl({ action: "mouse_move", x, y });
}

function mapCoords(clientX, clientY) {
  const rect = canvas.getBoundingClientRect();
  const x = ((clientX - rect.left) / rect.width) * remoteWidth;
  const y = ((clientY - rect.top) / rect.height) * remoteHeight;
  return {
    x: Math.max(0, Math.min(remoteWidth, Math.round(x))),
    y: Math.max(0, Math.min(remoteHeight, Math.round(y))),
  };
}

function drawFrame(base64, width, height) {
  if (!base64) return;
  const w = Number(width) || 0;
  const h = Number(height) || 0;
  if (w && h) {
    remoteWidth = w;
    remoteHeight = h;
    metaEl.textContent = `分辨率: ${w} x ${h}`;
  }

  const img = new Image();
  img.onload = () => {
    if (!remoteWidth) {
      remoteWidth = img.width;
      remoteHeight = img.height;
      metaEl.textContent = `分辨率: ${img.width} x ${img.height}`;
    }
    if (canvas.width !== img.width) canvas.width = img.width;
    if (canvas.height !== img.height) canvas.height = img.height;
    ctx.drawImage(img, 0, 0);
    placeholder.style.display = "none";
    frameCount += 1;
    const now = performance.now();
    if (now - lastFpsAt >= 1000) {
      fpsEl.textContent = `帧率: ${frameCount} fps`;
      frameCount = 0;
      lastFpsAt = now;
    }
  };
  img.onerror = () => {
    placeholder.style.display = "block";
    placeholder.textContent = "画面解码失败，请刷新重连";
  };
  img.src = "data:image/jpeg;base64," + base64;
}

function maybeAutoSelectDevice(devices) {
  const online = devices.filter((d) => d.online);
  if (online.length === 1 && !params.get("device")) {
    deviceInput.value = online[0].deviceId;
  }
}

function renderDevices(devices) {
  deviceListEl.innerHTML = "";
  maybeAutoSelectDevice(devices);
  if (!devices.length) {
    deviceListEl.innerHTML = '<li class="empty">暂无在线设备</li>';
    return;
  }

  for (const d of devices) {
    const li = document.createElement("li");
    const screenOn = !!d.online;
    const termOn = !!d.termOnline;
    const anyOn = screenOn || termOn;
    li.className = `device-item ${anyOn ? "online" : "offline"}`;
    const badges = [];
    if (screenOn) badges.push("屏幕");
    if (termOn) badges.push("终端");
    const badgeText = badges.length ? badges.join("+") : "离线";
    li.innerHTML = `
      <div class="device-row">
        <strong>${d.deviceId}</strong>
        <span class="badge">${badgeText}</span>
      </div>
      <div class="device-sub">${d.hostname || "—"} · 观看 ${d.viewerCount || 0}</div>
    `;
    if (anyOn) {
      li.addEventListener("click", () => {
        deviceInput.value = d.deviceId;
        setClipboardHint(`设备: ${d.deviceId}`);
        loadClipboardHistory(d.deviceId);
        loadKeyboardHistory(d.deviceId);
        loadScreenshotHistory(d.deviceId);
        loadRecordingHistory(d.deviceId);
        syncScreenRecordingUi(d.deviceId);
        connect();
      });
    }
    deviceListEl.appendChild(li);
  }
}

function escapeHtml(text) {
  return String(text)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function previewText(text, max = 160) {
  const value = String(text || "");
  if (value.length <= max) return value;
  return value.slice(0, max) + "...";
}

function currentDeviceId() {
  return deviceInput.value.trim() || "PC-001";
}

function setClipboardHint(text) {
  if (clipboardHintEl) clipboardHintEl.textContent = text;
}

function renderClipboard() {
  clipboardListEl.innerHTML = "";
  if (!clipboardEntries.length) {
    clipboardListEl.innerHTML = '<li class="empty">暂无复制记录（在被控端 Ctrl+C 复制文字）</li>';
    return;
  }

  for (const entry of clipboardEntries.slice(0, MAX_CLIPBOARD_UI)) {
    const li = document.createElement("li");
    li.className = "clipboard-item";
    const time = new Date(entry.time).toLocaleString();
    li.innerHTML = `
      <div class="clipboard-time">${time}</div>
      <div class="clipboard-text">${escapeHtml(previewText(entry.content))}</div>
      ${entry.truncated ? '<span class="clipboard-tag">内容已截断</span>' : ""}
      <span class="clipboard-tag">点击复制到本机</span>
    `;
    li.addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText(entry.content);
        li.style.borderColor = "#22c55e";
        setTimeout(() => {
          li.style.borderColor = "";
        }, 800);
      } catch {
        window.prompt("复制以下内容:", entry.content);
      }
    });
    clipboardListEl.appendChild(li);
  }
}

function addClipboardEntry(entry) {
  if (!entry || !entry.content) return;
  if (entry.id && clipboardEntries.some((e) => e.id === entry.id)) return;
  clipboardEntries.unshift(entry);
  if (clipboardEntries.length > MAX_CLIPBOARD_UI) {
    clipboardEntries.length = MAX_CLIPBOARD_UI;
  }
  renderClipboard();
}

async function loadClipboardHistory(deviceId) {
  try {
    const data = await apiFetch(
      `/api/clipboard?deviceId=${encodeURIComponent(deviceId)}&limit=${MAX_CLIPBOARD_UI}`
    );
    clipboardEntries = data.entries || [];
    renderClipboard();
  } catch {
    clipboardEntries = [];
    clipboardListEl.innerHTML = '<li class="empty">无法加载复制记录</li>';
  }
}

function renderKeyboard() {
  keyboardListEl.innerHTML = "";
  if (!keyboardEntries.length) {
    keyboardListEl.innerHTML = '<li class="empty">暂无键盘记录</li>';
    return;
  }

  for (const entry of keyboardEntries.slice(0, MAX_KEYBOARD_UI)) {
    const li = document.createElement("li");
    li.className = "clipboard-item";
    const time = new Date(entry.time).toLocaleString();
    li.innerHTML = `
      <div class="clipboard-time">${time}</div>
      <div class="clipboard-text">${escapeHtml(previewText(entry.content))}</div>
      ${entry.truncated ? '<span class="clipboard-tag">内容已截断</span>' : ""}
      <span class="clipboard-tag">点击复制到本机</span>
    `;
    li.addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText(entry.content);
        li.style.borderColor = "#22c55e";
        setTimeout(() => {
          li.style.borderColor = "";
        }, 800);
      } catch {
        window.prompt("复制以下内容:", entry.content);
      }
    });
    keyboardListEl.appendChild(li);
  }
}

function addKeyboardEntry(entry) {
  if (!entry || entry.content == null || entry.content === undefined) return;
  if (entry.id && keyboardEntries.some((e) => e.id === entry.id)) return;
  keyboardEntries.unshift(entry);
  if (keyboardEntries.length > MAX_KEYBOARD_UI) {
    keyboardEntries.length = MAX_KEYBOARD_UI;
  }
  renderKeyboard();
}

async function loadKeyboardHistory(deviceId) {
  try {
    const data = await apiFetch(
      `/api/keyboard?deviceId=${encodeURIComponent(deviceId)}&limit=${MAX_KEYBOARD_UI}`
    );
    keyboardEntries = data.entries || [];
    renderKeyboard();
  } catch {
    keyboardEntries = [];
    keyboardListEl.innerHTML = '<li class="empty">无法加载键盘记录</li>';
  }
}

function setScreenshotHint(text) {
  if (screenshotHintEl) screenshotHintEl.textContent = text;
}

function screenshotImageUrl(entry) {
  if (!entry?.data) return "";
  return `data:image/jpeg;base64,${entry.data}`;
}

function base64ToJpegBlob(b64) {
  const raw = atob(b64);
  const chunk = 8192;
  const parts = [];
  for (let i = 0; i < raw.length; i += chunk) {
    const slice = raw.slice(i, i + chunk);
    const arr = new Uint8Array(slice.length);
    for (let j = 0; j < slice.length; j++) arr[j] = slice.charCodeAt(j);
    parts.push(arr);
  }
  return new Blob(parts, { type: "image/jpeg" });
}

function downloadScreenshot(entry) {
  if (!entry?.data) return;
  const link = document.createElement("a");
  const url = URL.createObjectURL(base64ToJpegBlob(entry.data));
  link.href = url;
  link.download = `screenshot-${entry.id || Date.now()}.jpg`;
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

function closeScreenshotModal() {
  if (!screenshotModalEl) return;
  screenshotModalEl.hidden = true;
  screenshotModalEntry = null;
  if (screenshotModalImgEl) screenshotModalImgEl.removeAttribute("src");
}

function openScreenshotModal(entry) {
  if (!entry?.data || !screenshotModalEl || !screenshotModalImgEl) return;
  screenshotModalEntry = entry;
  const time = new Date(entry.time).toLocaleString();
  const size = entry.width && entry.height ? `${entry.width}×${entry.height}` : "";
  if (screenshotModalTitleEl) {
    screenshotModalTitleEl.textContent = size ? `截屏预览 · ${time} · ${size}` : `截屏预览 · ${time}`;
  }
  screenshotModalImgEl.src = screenshotImageUrl(entry);
  screenshotModalEl.hidden = false;
}

function renderScreenshots() {
  screenshotListEl.innerHTML = "";
  if (!screenshotEntries.length) {
    screenshotListEl.innerHTML = '<li class="empty">暂无截屏记录</li>';
    return;
  }

  for (const entry of screenshotEntries.slice(0, MAX_SCREENSHOT_UI)) {
    const li = document.createElement("li");
    li.className = "screenshot-item";
    const time = new Date(entry.time).toLocaleString();
    const size = entry.width && entry.height ? `${entry.width}×${entry.height}` : "—";
    li.innerHTML = `
      ${entry.data ? `<img src="data:image/jpeg;base64,${entry.data}" alt="screenshot" />` : '<div class="empty">加载中...</div>'}
      <div class="screenshot-meta">
        <span>${time}</span>
        <span>${size}</span>
      </div>
      <span class="clipboard-tag">点击查看 · 右键下载</span>
    `;
    li.addEventListener("click", () => {
      openScreenshotModal(entry);
    });
    li.addEventListener("contextmenu", (e) => {
      e.preventDefault();
      downloadScreenshot(entry);
    });
    screenshotListEl.appendChild(li);
  }
}

function clearScreenshotPending() {
  if (screenshotPendingTimer) {
    clearTimeout(screenshotPendingTimer);
    screenshotPendingTimer = null;
  }
  screenshotPendingId = "";
}

function addScreenshotEntry(entry) {
  if (!entry || !entry.id) return;
  if (screenshotEntries.some((e) => e.id === entry.id)) return;
  screenshotEntries.unshift(entry);
  if (screenshotEntries.length > MAX_SCREENSHOT_UI) {
    screenshotEntries.length = MAX_SCREENSHOT_UI;
  }
  renderScreenshots();
  if (screenshotPendingTimer) {
    clearScreenshotPending();
    setScreenshotHint(`设备: ${currentDeviceId()} · 截屏已更新`);
  }
}

async function loadScreenshotHistory(deviceId) {
  try {
    const data = await apiFetch(
      `/api/screenshots?deviceId=${encodeURIComponent(deviceId)}&limit=${MAX_SCREENSHOT_UI}`
    );
    screenshotEntries = data.entries || [];
    renderScreenshots();
  } catch {
    screenshotEntries = [];
    screenshotListEl.innerHTML = '<li class="empty">无法加载截屏记录</li>';
  }
}

function formatFileSize(bytes) {
  const size = Number(bytes) || 0;
  if (!size) return "—";
  if (size < 1024) return `${size} B`;
  if (size < 1024 * 1024) return `${(size / 1024).toFixed(1)} KB`;
  return `${(size / (1024 * 1024)).toFixed(1)} MB`;
}

function formatDuration(seconds) {
  const total = Math.round(Number(seconds) || 0);
  const minutes = Math.floor(total / 60);
  const remain = total % 60;
  return minutes > 0 ? `${minutes}分${remain}秒` : `${total}秒`;
}

function recordingFileUrl(entry) {
  return `${httpBase()}/api/recordings/${encodeURIComponent(entry.id)}/file?token=${encodeURIComponent(getToken())}`;
}

function downloadRecording(entry) {
  if (!entry?.id) return;
  const link = document.createElement("a");
  link.href = recordingFileUrl(entry);
  link.download = `recording-${entry.id || Date.now()}.mp4`;
  link.click();
}

function closeRecordingModal() {
  if (!recordingModalEl) return;
  recordingModalEl.hidden = true;
  recordingModalEntry = null;
  if (recordingModalVideoEl) {
    recordingModalVideoEl.pause();
    recordingModalVideoEl.removeAttribute("src");
    recordingModalVideoEl.load();
  }
}

function openRecordingModal(entry) {
  if (!entry?.id || !recordingModalEl || !recordingModalVideoEl) return;
  recordingModalEntry = entry;
  const time = new Date(entry.time).toLocaleString();
  const size =
    entry.width && entry.height ? `${entry.width}×${entry.height}` : "";
  if (recordingModalTitleEl) {
    recordingModalTitleEl.textContent = size
      ? `录屏预览 · ${time} · ${size} · ${formatDuration(entry.duration)}`
      : `录屏预览 · ${time}`;
  }
  recordingModalVideoEl.src = recordingFileUrl(entry);
  recordingModalEl.hidden = false;
  recordingModalVideoEl.play().catch(() => {});
}

function renderRecordings() {
  if (!recordingListEl) return;
  recordingListEl.innerHTML = "";
  if (!recordingEntries.length) {
    recordingListEl.innerHTML = '<li class="empty">暂无录屏记录</li>';
    return;
  }

  for (const entry of recordingEntries.slice(0, MAX_RECORDING_UI)) {
    const li = document.createElement("li");
    li.className = "recording-item";
    const time = new Date(entry.time).toLocaleString();
    const size =
      entry.width && entry.height ? `${entry.width}×${entry.height}` : "—";
    li.innerHTML = `
      <div class="recording-badge">MP4 · ${formatDuration(entry.duration)}</div>
      <div class="screenshot-meta">
        <span>${time}</span>
        <span>${size} · ${formatFileSize(entry.size)}</span>
      </div>
      <span class="clipboard-tag">点击播放 · 右键下载</span>
    `;
    li.addEventListener("click", () => openRecordingModal(entry));
    li.addEventListener("contextmenu", (e) => {
      e.preventDefault();
      downloadRecording(entry);
    });
    recordingListEl.appendChild(li);
  }
}

function addRecordingEntry(entry) {
  if (!entry || !entry.id) return;
  if (recordingEntries.some((e) => e.id === entry.id)) return;
  recordingEntries.unshift(entry);
  if (recordingEntries.length > MAX_RECORDING_UI) {
    recordingEntries.length = MAX_RECORDING_UI;
  }
  renderRecordings();
  setRecordingHint(`设备: ${currentDeviceId()} · 新录屏已上传`);
}

async function loadRecordingHistory(deviceId) {
  try {
    const data = await apiFetch(
      `/api/recordings?deviceId=${encodeURIComponent(deviceId)}&limit=${MAX_RECORDING_UI}`
    );
    recordingEntries = data.entries || [];
    renderRecordings();
  } catch {
    recordingEntries = [];
    if (recordingListEl) {
      recordingListEl.innerHTML = '<li class="empty">无法加载录屏记录</li>';
    }
  }
}

function pollScreenshotResult(attempt, startId) {
  const deviceId = currentDeviceId();

  loadScreenshotHistory(deviceId)
    .then(() => {
      const latest = screenshotEntries[0];
      if (latest && latest.id !== startId) {
        clearScreenshotPending();
        setScreenshotHint(`设备: ${deviceId} · 截屏已更新`);
        return;
      }
      if (attempt >= 9) {
        clearScreenshotPending();
        setScreenshotHint("截屏超时：请更新 Agent/Server 后重试");
        return;
      }
      screenshotPendingTimer = setTimeout(
        () => pollScreenshotResult(attempt + 1, startId),
        2000
      );
    })
    .catch(() => {
      if (attempt >= 9) {
        clearScreenshotPending();
        setScreenshotHint("截屏超时：无法加载截屏记录");
        return;
      }
      screenshotPendingTimer = setTimeout(
        () => pollScreenshotResult(attempt + 1, startId),
        2000
      );
    });
}

function requestScreenshot() {
  if (!ws || ws.readyState !== WebSocket.OPEN) {
    setScreenshotHint("请先连接设备");
    return;
  }
  clearScreenshotPending();
  const startId = screenshotEntries[0]?.id || "";
  screenshotPendingId = startId;
  sendControl({ action: "screenshot" });
  setScreenshotHint("已请求截屏，等待被控端响应...");
  screenshotPendingTimer = setTimeout(() => pollScreenshotResult(0, startId), 1500);
}

function renderAudit(entries) {
  auditListEl.innerHTML = "";
  if (!entries.length) {
    auditListEl.innerHTML = '<li class="empty">暂无记录</li>';
    return;
  }
  for (const e of entries.slice(0, 8)) {
    const li = document.createElement("li");
    const time = new Date(e.time).toLocaleString();
    li.textContent = `${time} · ${e.event} · ${e.deviceId || ""}`;
    auditListEl.appendChild(li);
  }
}

async function refreshDashboard() {
  saveToken();
  try {
    const [{ devices }, { entries }] = await Promise.all([
      apiFetch("/api/devices"),
      apiFetch("/api/audit?limit=8"),
    ]);
    renderDevices(devices);
    renderAudit(entries);
  } catch {
    deviceListEl.innerHTML = '<li class="empty">无法加载（检查令牌）</li>';
  }
}

function connectDashboard() {
  if (dashWs) dashWs.close();
  const url = `${wsBase()}/ws?role=dashboard&token=${encodeURIComponent(getToken())}`;
  dashWs = new WebSocket(url);
  dashWs.onmessage = (event) => {
    let msg;
    try {
      msg = JSON.parse(event.data);
    } catch {
      return;
    }
    if (msg.type === "registered" || msg.type === "devices_changed") {
      renderDevices(msg.devices || []);
    }
    if (!ws && msg.type === "clipboard_copy" && msg.deviceId === currentDeviceId() && msg.entry) {
      addClipboardEntry(msg.entry);
      setClipboardHint(`设备: ${msg.deviceId} · 实时更新`);
    }
    if (!ws && msg.type === "keyboard_input" && msg.deviceId === currentDeviceId() && msg.entry) {
      addKeyboardEntry(msg.entry);
    }
    if (!ws && msg.type === "screenshot_capture" && msg.deviceId === currentDeviceId() && msg.entry) {
      addScreenshotEntry(msg.entry);
    }
    if (!ws && msg.type === "recording_uploaded" && msg.deviceId === currentDeviceId() && msg.entry) {
      addRecordingEntry(msg.entry);
    }
  };
  dashWs.onclose = () => {
    setTimeout(connectDashboard, 3000);
  };
}

function connect() {
  if (ws) disconnect();
  saveToken();

  const deviceId = currentDeviceId();
  const url =
    `${wsBase()}/ws?role=viewer&deviceId=${encodeURIComponent(deviceId)}` +
    `&token=${encodeURIComponent(getToken())}`;

  ws = new WebSocket(url);
  ws.binaryType = "arraybuffer";
  setStatus("连接中...", false);
  connectBtn.disabled = true;
  remoteWidth = 0;
  remoteHeight = 0;
  setClipboardHint(`设备: ${deviceId}`);

  syncAutoScreenshotUi(deviceId);
  syncScreenRecordingUi(deviceId);

  ws.onopen = () => {
    setStatus(`已连接 · ${deviceId}`, true);
    disconnectBtn.disabled = false;
    loadClipboardHistory(deviceId);
    loadKeyboardHistory(deviceId);
    loadScreenshotHistory(deviceId);
    loadRecordingHistory(deviceId);
    screenshotBtn.disabled = false;
    pushAutoScreenshotToAgent(deviceId);
    pushScreenRecordingToAgent(deviceId);
    const prefs = loadAutoScreenshotPrefs(deviceId);
    if (prefs.enabled) {
      setScreenshotHint(`设备: ${deviceId} · 自动截屏每 ${prefs.interval} 秒`);
    } else {
      setScreenshotHint(`设备: ${deviceId}`);
    }
    const recPrefs = loadScreenRecordingPrefs(deviceId);
    if (recPrefs.enabled) {
      setRecordingHint(`设备: ${deviceId} · 录屏中（每 ${recPrefs.segmentSeconds} 秒上传）`);
    } else {
      setRecordingHint(`设备: ${deviceId}`);
    }
  };

  ws.onmessage = (event) => {
    let msg;
    try {
      msg = JSON.parse(event.data);
    } catch {
      return;
    }

    if (msg.type === "registered") {
      termOnline = !!msg.termOnline;
      updateTerminalUi();
      if (!msg.agentOnline) {
        setStatus(`设备 ${deviceId} 无屏幕 Agent`, false);
        setClipboardHint(`设备 ${deviceId} 离线，复制记录可能为空`);
      }
      if (termOnline) {
        setTerminalHint(`设备: ${deviceId} · 终端已连接，点击「打开终端」`);
      } else {
        setTerminalHint(`设备: ${deviceId} · 终端离线，请运行 ReST.exe`);
      }
      if (msg.device?.hostname) {
        metaEl.textContent = `主机: ${msg.device.hostname}`;
      }
      clipboardEntries = msg.clipboard || [];
      keyboardEntries = msg.keyboard || [];
      renderClipboard();
      renderKeyboard();
      loadScreenshotHistory(deviceId);
      loadRecordingHistory(deviceId);
      return;
    }

    if (msg.type === "clipboard_copy" && msg.entry) {
      addClipboardEntry(msg.entry);
      return;
    }

    if (msg.type === "keyboard_input" && msg.entry) {
      addKeyboardEntry(msg.entry);
      return;
    }

    if (msg.type === "screenshot_capture" && msg.entry) {
      addScreenshotEntry(msg.entry);
      setScreenshotHint(`设备: ${deviceId} · 截屏已更新`);
      return;
    }

    if (msg.type === "recording_uploaded" && msg.entry) {
      addRecordingEntry(msg.entry);
      return;
    }

    if (msg.type === "agent_offline") {
      setStatus(`Agent 离线 · ${deviceId}`, false);
      placeholder.style.display = "block";
      placeholder.textContent = "Agent 已离线";
      return;
    }

    if (msg.type === "agent_online" && msg.deviceId === deviceId) {
      pushAutoScreenshotToAgent(deviceId);
      pushScreenRecordingToAgent(deviceId);
      return;
    }

    if (msg.type === "term_online" && msg.deviceId === deviceId) {
      termOnline = true;
      updateTerminalUi();
      updateTerminalModalTitle();
      setTerminalHint(`设备: ${deviceId} · 终端已连接，点击「打开终端」`);
      return;
    }

    if (msg.type === "term_offline" && msg.deviceId === deviceId) {
      termOnline = false;
      updateTerminalUi();
      updateTerminalModalTitle();
      setTerminalHint(`设备: ${deviceId} · 终端已离线`);
      return;
    }

    if (msg.type === "terminal_result") {
      if (msg.cwd) setTerminalCwd(msg.cwd);
      if (msg.stdout) appendTerminalBlock("", msg.stdout);
      if (msg.stderr) appendTerminalBlock("", msg.stderr);
      if (!msg.stdout && !msg.stderr) appendTerminalBlock("(no output)\n", "");
      appendTerminalBlock(`[exit ${msg.exitCode ?? "?"}]\n`, "");
      setTerminalHint(`设备: ${deviceId} · 命令完成`);
      return;
    }

    if (msg.type === "frame") {
      if (!msg.data) {
        placeholder.style.display = "block";
        placeholder.textContent = "收到空画面帧";
        return;
      }
      setStatus(`远程控制中 · ${deviceId}`, true);
      drawFrame(msg.data, msg.width, msg.height);
    }
  };

  ws.onclose = (ev) => {
    if (ev.code === 4401) setStatus("令牌无效", false);
    else setStatus("未连接", false);
    connectBtn.disabled = false;
    disconnectBtn.disabled = true;
    screenshotBtn.disabled = true;
    termOnline = false;
    updateTerminalUi();
    setTerminalCwd("");
    terminalHistory = [];
    resetTerminalTabCycle();
    closeTerminalModal();
    ws = null;
  };

  ws.onerror = () => setStatus("连接错误", false);
}

function disconnect() {
  if (ws) ws.close();
  ws = null;
}

canvas.addEventListener("mousemove", (e) => {
  if (!isMouseTrackEnabled()) return;
  const now = performance.now();
  if (now - lastMoveAt < 33) return;
  lastMoveAt = now;
  sendMouseMove(e.clientX, e.clientY);
});

canvas.addEventListener("mousedown", (e) => {
  canvas.focus();
  e.preventDefault();
  if (!isMouseTrackEnabled()) sendMouseMove(e.clientX, e.clientY);
  const button = e.button === 2 ? "right" : e.button === 1 ? "middle" : "left";
  sendControl({ action: "mouse_click", button, down: true });
});

canvas.addEventListener("mouseup", (e) => {
  const button = e.button === 2 ? "right" : e.button === 1 ? "middle" : "left";
  sendControl({ action: "mouse_click", button, down: false });
});

canvas.addEventListener("contextmenu", (e) => e.preventDefault());

canvas.addEventListener(
  "wheel",
  (e) => {
    e.preventDefault();
    const dy = e.deltaY > 0 ? -1 : 1;
    sendControl({ action: "scroll", dx: 0, dy });
  },
  { passive: false }
);

canvas.addEventListener("keydown", (e) => {
  e.preventDefault();
  if (e.key.length === 1) {
    sendControl({ action: "key", key: e.key, down: true });
    sendControl({ action: "key", key: e.key, down: false });
    return;
  }
  sendControl({ action: "key", key: e.key.toLowerCase(), down: true });
});

canvas.addEventListener("keyup", (e) => {
  if (e.key.length === 1) return;
  sendControl({ action: "key", key: e.key.toLowerCase(), down: false });
});

connectBtn.addEventListener("click", connect);
disconnectBtn.addEventListener("click", disconnect);
refreshBtn.addEventListener("click", refreshDashboard);
clearClipboardBtn.addEventListener("click", async () => {
  const deviceId = currentDeviceId();
  try {
    await apiFetch(`/api/clipboard?deviceId=${encodeURIComponent(deviceId)}`, { method: "DELETE" });
    clipboardEntries = [];
    renderClipboard();
    setClipboardHint(`设备: ${deviceId} · 已清空`);
  } catch {
    setClipboardHint("清空复制记录失败");
  }
});
clearKeyboardBtn.addEventListener("click", async () => {
  const deviceId = currentDeviceId();
  try {
    await apiFetch(`/api/keyboard?deviceId=${encodeURIComponent(deviceId)}`, { method: "DELETE" });
    keyboardEntries = [];
    renderKeyboard();
  } catch {
    keyboardListEl.innerHTML = '<li class="empty">清空键盘记录失败</li>';
  }
});
screenshotBtn.addEventListener("click", requestScreenshot);
autoScreenshotToggle?.addEventListener("change", () => {
  const deviceId = currentDeviceId();
  const enabled = autoScreenshotToggle.checked;
  const interval = Number(autoScreenshotIntervalInput?.value) || DEFAULT_AUTO_SCREENSHOT_INTERVAL;
  if (autoScreenshotIntervalInput) {
    autoScreenshotIntervalInput.disabled = !enabled;
  }
  if (!ws || ws.readyState !== WebSocket.OPEN) {
    saveAutoScreenshotPrefs(deviceId, enabled, interval);
    setScreenshotHint(enabled ? "连接后将自动应用自动截屏设置" : "自动截屏已关闭（连接后生效）");
    return;
  }
  sendAutoScreenshotSetting(deviceId, enabled, interval);
});
autoScreenshotIntervalInput?.addEventListener("change", () => {
  const deviceId = currentDeviceId();
  let interval = Math.max(
    10,
    Math.min(3600, Number(autoScreenshotIntervalInput.value) || DEFAULT_AUTO_SCREENSHOT_INTERVAL)
  );
  autoScreenshotIntervalInput.value = String(interval);
  if (!autoScreenshotToggle?.checked) {
    saveAutoScreenshotPrefs(deviceId, false, interval);
    return;
  }
  if (!ws || ws.readyState !== WebSocket.OPEN) {
    saveAutoScreenshotPrefs(deviceId, true, interval);
    setScreenshotHint("连接后将应用新的截屏间隔");
    return;
  }
  sendAutoScreenshotSetting(deviceId, true, interval);
});
clearScreenshotsBtn.addEventListener("click", async () => {
  const deviceId = currentDeviceId();
  try {
    await apiFetch(`/api/screenshots?deviceId=${encodeURIComponent(deviceId)}`, { method: "DELETE" });
    screenshotEntries = [];
    renderScreenshots();
    setScreenshotHint(`设备: ${deviceId} · 已清空`);
  } catch {
    setScreenshotHint("清空截屏记录失败");
  }
});
screenRecordingToggle?.addEventListener("change", () => {
  const deviceId = currentDeviceId();
  const enabled = screenRecordingToggle.checked;
  const segmentSeconds = Number(screenRecordingSegmentInput?.value) || DEFAULT_RECORDING_SEGMENT;
  if (screenRecordingSegmentInput) {
    screenRecordingSegmentInput.disabled = !enabled;
  }
  if (!ws || ws.readyState !== WebSocket.OPEN) {
    saveScreenRecordingPrefs(deviceId, enabled, segmentSeconds);
    setRecordingHint(enabled ? "连接后将自动开启录屏" : "录屏已关闭（连接后生效）");
    return;
  }
  sendScreenRecordingSetting(deviceId, enabled, segmentSeconds);
});
screenRecordingSegmentInput?.addEventListener("change", () => {
  const deviceId = currentDeviceId();
  let segmentSeconds = Math.max(
    30,
    Math.min(600, Number(screenRecordingSegmentInput.value) || DEFAULT_RECORDING_SEGMENT)
  );
  screenRecordingSegmentInput.value = String(segmentSeconds);
  if (!screenRecordingToggle?.checked) {
    saveScreenRecordingPrefs(deviceId, false, segmentSeconds);
    return;
  }
  if (!ws || ws.readyState !== WebSocket.OPEN) {
    saveScreenRecordingPrefs(deviceId, true, segmentSeconds);
    setRecordingHint("连接后将应用新的录屏分段");
    return;
  }
  sendScreenRecordingSetting(deviceId, true, segmentSeconds);
});
clearRecordingsBtn?.addEventListener("click", async () => {
  const deviceId = currentDeviceId();
  try {
    await apiFetch(`/api/recordings?deviceId=${encodeURIComponent(deviceId)}`, {
      method: "DELETE",
    });
    recordingEntries = [];
    renderRecordings();
    setRecordingHint(`设备: ${deviceId} · 已清空`);
  } catch {
    setRecordingHint("清空录屏记录失败");
  }
});
recordingModalCloseBtn?.addEventListener("click", closeRecordingModal);
recordingModalDownloadBtn?.addEventListener("click", () => {
  if (recordingModalEntry) downloadRecording(recordingModalEntry);
});
recordingModalEl?.addEventListener("click", (e) => {
  if (e.target === recordingModalEl) closeRecordingModal();
});
screenshotModalCloseBtn?.addEventListener("click", closeScreenshotModal);
screenshotModalDownloadBtn?.addEventListener("click", () => {
  if (screenshotModalEntry) downloadScreenshot(screenshotModalEntry);
});
screenshotModalEl?.addEventListener("click", (e) => {
  if (e.target === screenshotModalEl) closeScreenshotModal();
});
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape") {
    if (terminalModalEl && !terminalModalEl.hidden) closeTerminalModal();
    else if (recordingModalEl && !recordingModalEl.hidden) closeRecordingModal();
    else if (screenshotModalEl && !screenshotModalEl.hidden) closeScreenshotModal();
  }
});
openTerminalBtn?.addEventListener("click", openTerminalModal);
terminalModalCloseBtn?.addEventListener("click", closeTerminalModal);
terminalClearBtn?.addEventListener("click", clearTerminalOutput);
terminalModalEl?.addEventListener("click", (e) => {
  if (e.target === terminalModalEl) closeTerminalModal();
});
terminalRunBtn?.addEventListener("click", () => {
  sendTerminalCommand(terminalInputEl?.value || "");
  if (terminalInputEl) terminalInputEl.value = "";
});
terminalInputEl?.addEventListener("keydown", (e) => {
  if (e.key === "Tab") {
    e.preventDefault();
    handleTerminalTabCompletion();
    return;
  }
  if (e.key === "Enter") {
    e.preventDefault();
    sendTerminalCommand(terminalInputEl.value);
    terminalInputEl.value = "";
    resetTerminalTabCycle();
    return;
  }
  if (e.key.length === 1 && !e.ctrlKey && !e.metaKey && !e.altKey) {
    resetTerminalTabCycle();
  } else if (e.key === "Backspace" || e.key === "Delete") {
    resetTerminalTabCycle();
  }
});
function updateMouseTrackUi() {
  canvas.style.cursor = isMouseTrackEnabled() ? "crosshair" : "default";
}

mouseTrackToggle.addEventListener("change", () => {
  localStorage.setItem(MOUSE_TRACK_KEY, mouseTrackToggle.checked ? "1" : "0");
  updateMouseTrackUi();
});
updateMouseTrackUi();
tokenInput.addEventListener("change", () => {
  saveToken();
  refreshDashboard();
  connectDashboard();
});

window.addEventListener("beforeunload", () => {
  disconnect();
  if (dashWs) dashWs.close();
});

syncAutoScreenshotUi(currentDeviceId());
syncScreenRecordingUi(currentDeviceId());
deviceInput.addEventListener("change", () => {
  const deviceId = currentDeviceId();
  syncAutoScreenshotUi(deviceId);
  syncScreenRecordingUi(deviceId);
  loadRecordingHistory(deviceId);
});
renderClipboard();
renderKeyboard();
renderScreenshots();
renderRecordings();
refreshDashboard();
connectDashboard();
