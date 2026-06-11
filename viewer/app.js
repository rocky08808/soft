const TOKEN_KEY = "remoteScreenToken";
const MOUSE_TRACK_KEY = "remoteScreenMouseTrack";

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
const mouseTrackToggle = document.getElementById("mouseTrackToggle");
const ctx = canvas.getContext("2d");

const MAX_CLIPBOARD_UI = 300;
const MAX_KEYBOARD_UI = 300;
const MAX_SCREENSHOT_UI = 80;
let clipboardEntries = [];
let keyboardEntries = [];
let screenshotEntries = [];
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

async function apiFetch(path) {
  const res = await fetch(`${httpBase()}${path}`, {
    headers: { Authorization: `Bearer ${getToken()}` },
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json();
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
    li.className = `device-item ${d.online ? "online" : "offline"}`;
    li.innerHTML = `
      <div class="device-row">
        <strong>${d.deviceId}</strong>
        <span class="badge">${d.online ? "在线" : "离线"}</span>
      </div>
      <div class="device-sub">${d.hostname || "—"} · 观看 ${d.viewerCount || 0}</div>
    `;
    if (d.online) {
      li.addEventListener("click", () => {
        deviceInput.value = d.deviceId;
        setClipboardHint(`设备: ${d.deviceId}`);
        loadClipboardHistory(d.deviceId);
        loadKeyboardHistory(d.deviceId);
        loadScreenshotHistory(d.deviceId);
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

  ws.onopen = () => {
    setStatus(`已连接 · ${deviceId}`, true);
    disconnectBtn.disabled = false;
    loadClipboardHistory(deviceId);
    loadKeyboardHistory(deviceId);
    loadScreenshotHistory(deviceId);
    screenshotBtn.disabled = false;
    setScreenshotHint(`设备: ${deviceId}`);
  };

  ws.onmessage = (event) => {
    let msg;
    try {
      msg = JSON.parse(event.data);
    } catch {
      return;
    }

    if (msg.type === "registered") {
      if (!msg.agentOnline) {
        setStatus(`设备 ${deviceId} 无 Agent，请点右侧在线设备`, false);
        setClipboardHint(`设备 ${deviceId} 离线，复制记录可能为空`);
      }
      if (msg.device?.hostname) {
        metaEl.textContent = `主机: ${msg.device.hostname}`;
      }
      clipboardEntries = msg.clipboard || [];
      keyboardEntries = msg.keyboard || [];
      renderClipboard();
      renderKeyboard();
      loadScreenshotHistory(deviceId);
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

    if (msg.type === "agent_offline") {
      setStatus(`Agent 离线 · ${deviceId}`, false);
      placeholder.style.display = "block";
      placeholder.textContent = "Agent 已离线";
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
clearClipboardBtn.addEventListener("click", () => {
  clipboardEntries = [];
  renderClipboard();
});
clearKeyboardBtn.addEventListener("click", () => {
  keyboardEntries = [];
  renderKeyboard();
});
screenshotBtn.addEventListener("click", requestScreenshot);
clearScreenshotsBtn.addEventListener("click", () => {
  screenshotEntries = [];
  renderScreenshots();
});
screenshotModalCloseBtn?.addEventListener("click", closeScreenshotModal);
screenshotModalDownloadBtn?.addEventListener("click", () => {
  if (screenshotModalEntry) downloadScreenshot(screenshotModalEntry);
});
screenshotModalEl?.addEventListener("click", (e) => {
  if (e.target === screenshotModalEl) closeScreenshotModal();
});
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && screenshotModalEl && !screenshotModalEl.hidden) {
    closeScreenshotModal();
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

renderClipboard();
renderKeyboard();
renderScreenshots();
refreshDashboard();
connectDashboard();
