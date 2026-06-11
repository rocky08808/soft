const TOKEN_KEY = "remoteScreenToken";

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
const ctx = canvas.getContext("2d");

const params = new URLSearchParams(window.location.search);
if (params.get("device")) deviceInput.value = params.get("device");
tokenInput.value = localStorage.getItem(TOKEN_KEY) || tokenInput.value;

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
  remoteWidth = width;
  remoteHeight = height;
  metaEl.textContent = `分辨率: ${width} x ${height}`;

  const img = new Image();
  img.onload = () => {
    canvas.width = img.width;
    canvas.height = img.height;
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
  img.src = "data:image/jpeg;base64," + base64;
}

function renderDevices(devices) {
  deviceListEl.innerHTML = "";
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
        connect();
      });
    }
    deviceListEl.appendChild(li);
  }
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
  };
  dashWs.onclose = () => {
    setTimeout(connectDashboard, 3000);
  };
}

function connect() {
  if (ws) disconnect();
  saveToken();

  const deviceId = deviceInput.value.trim() || "PC-001";
  const url =
    `${wsBase()}/ws?role=viewer&deviceId=${encodeURIComponent(deviceId)}` +
    `&token=${encodeURIComponent(getToken())}`;

  ws = new WebSocket(url);
  setStatus("连接中...", false);
  connectBtn.disabled = true;
  remoteWidth = 0;
  remoteHeight = 0;

  ws.onopen = () => {
    setStatus(`已连接 · ${deviceId}`, true);
    disconnectBtn.disabled = false;
  };

  ws.onmessage = (event) => {
    let msg;
    try {
      msg = JSON.parse(event.data);
    } catch {
      return;
    }

    if (msg.type === "registered") {
      if (!msg.agentOnline) setStatus(`已连接，等待 Agent (${deviceId})`, false);
      if (msg.device?.hostname) {
        metaEl.textContent = `主机: ${msg.device.hostname}`;
      }
      return;
    }

    if (msg.type === "agent_offline") {
      setStatus(`Agent 离线 · ${deviceId}`, false);
      placeholder.style.display = "block";
      placeholder.textContent = "Agent 已离线";
      return;
    }

    if (msg.type === "frame") {
      setStatus(`远程控制中 · ${deviceId}`, true);
      drawFrame(msg.data, msg.width, msg.height);
    }
  };

  ws.onclose = (ev) => {
    if (ev.code === 4401) setStatus("令牌无效", false);
    else setStatus("未连接", false);
    connectBtn.disabled = false;
    disconnectBtn.disabled = true;
    ws = null;
  };

  ws.onerror = () => setStatus("连接错误", false);
}

function disconnect() {
  if (ws) ws.close();
  ws = null;
}

canvas.addEventListener("mousemove", (e) => {
  if (!remoteWidth) return;
  const now = performance.now();
  if (now - lastMoveAt < 33) return;
  lastMoveAt = now;
  const { x, y } = mapCoords(e.clientX, e.clientY);
  sendControl({ action: "mouse_move", x, y });
});

canvas.addEventListener("mousedown", (e) => {
  canvas.focus();
  e.preventDefault();
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
tokenInput.addEventListener("change", () => {
  saveToken();
  refreshDashboard();
  connectDashboard();
});

window.addEventListener("beforeunload", () => {
  disconnect();
  if (dashWs) dashWs.close();
});

refreshDashboard();
connectDashboard();
