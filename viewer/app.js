const TOKEN_KEY = "remoteScreenToken";
const MOUSE_TRACK_KEY = "remoteScreenMouseTrack";
const AUTO_SCREENSHOT_KEY_PREFIX = "autoScreenshot:";
const DEVICE_GROUP_COLLAPSE_PREFIX = "deviceGroupCollapse:";
const DEFAULT_AUTO_SCREENSHOT_INTERVAL = 60;

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
const openFilesBtn = document.getElementById("openFilesBtn");
const filesHintEl = document.getElementById("filesHint");
const filesModalEl = document.getElementById("filesModal");
const filesModalTitleEl = document.getElementById("filesModalTitle");
const filesModalCloseBtn = document.getElementById("filesModalClose");
const filesDrivesBtn = document.getElementById("filesDrivesBtn");
const filesUpBtn = document.getElementById("filesUpBtn");
const filesRefreshBtn = document.getElementById("filesRefreshBtn");
const filesPathInputEl = document.getElementById("filesPathInput");
const filesGoBtn = document.getElementById("filesGoBtn");
const filesListEl = document.getElementById("filesList");
const filesStatusEl = document.getElementById("filesStatus");
const updateNowBtn = document.getElementById("updateNowBtn");
const updateVersionMetaEl = document.getElementById("updateVersionMeta");
const updateHintEl = document.getElementById("updateHint");
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
let termOnline = false;
let agentOnline = false;
let terminalReqSeq = 0;
const pendingTerminal = new Map();
const streamingTerminalIds = new Set();
const TERMINAL_CMD_TIMEOUT_MS = 130000;
let fileReqSeq = 0;
let fileCurrentPath = "";
const pendingFiles = new Map();
const FILE_REQUEST_TIMEOUT_MS = 30000;
let updateReqSeq = 0;
let latestResaVersion = "";
let latestRestVersion = "";
let deviceAgentVersion = "";
let deviceTermVersion = "";
let lastKnownDevices = [];
let screenFrameReady = false;
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
  const isMouse =
    payload.action === "mouse_move" ||
    payload.action === "mouse_click" ||
    payload.action === "scroll";
  if (isMouse) {
    const frameW = remoteWidth || canvas.width;
    const frameH = remoteHeight || canvas.height;
    if (!frameW || !frameH) {
      if (metaEl) metaEl.textContent = "等待首帧画面…";
      return;
    }
  }
  ws.send(JSON.stringify({ type: "control", ...payload }));
}

function isScreenAgentReady() {
  return !!(agentOnline || remoteWidth > 0 || screenFrameReady);
}

function isTerminalAvailable() {
  return termOnline;
}

function setTerminalHint(text) {
  if (terminalHintEl) terminalHintEl.textContent = text;
}

function setFilesHint(text) {
  if (filesHintEl) filesHintEl.textContent = text;
}

function setUpdateHint(text) {
  if (updateHintEl) updateHintEl.textContent = text;
}

function formatVersionPair(local, latest) {
  const left = local || "—";
  const right = latest || "—";
  if (left === "—" && right === "—") return "— / —";
  return `${left} / ${right}`;
}

function renderUpdateVersionMeta() {
  if (!updateVersionMetaEl) return;
  updateVersionMetaEl.textContent =
    `ReSA ${formatVersionPair(deviceAgentVersion, latestResaVersion)} · ` +
    `ReST ${formatVersionPair(deviceTermVersion, latestRestVersion)}`;
}

async function refreshDeviceVersions() {
  const deviceId = currentDeviceId();
  if (!deviceId) return;
  try {
    const data = await apiFetch("/api/devices");
    const device = (data.devices || []).find((d) => d.deviceId === deviceId);
    syncDeviceVersions(device);
  } catch {
    // ignore
  }
}

async function loadLatestVersions() {
  try {
    const res = await fetch(`${httpBase()}/download/versions.json`, {
      cache: "no-store",
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const data = await res.json();
    latestResaVersion = data.resa?.version || "";
    latestRestVersion = data.rest?.version || "";
  } catch {
    latestResaVersion = "";
    latestRestVersion = "";
  }
  renderUpdateVersionMeta();
}

function syncDeviceVersions(device) {
  if (!device) return;
  if (device.agentVersion) deviceAgentVersion = device.agentVersion;
  if (device.termVersion) deviceTermVersion = device.termVersion;
  renderUpdateVersionMeta();
}

function updateVersionUi() {
  const connected = !!(ws && ws.readyState === WebSocket.OPEN);
  const canUpdate = connected && (agentOnline || termOnline);
  if (updateNowBtn) updateNowBtn.disabled = !canUpdate;
  renderUpdateVersionMeta();
}

function sendUpdateRequest(product) {
  if (!ws || ws.readyState !== WebSocket.OPEN) return;
  const id = `u${++updateReqSeq}`;
  ws.send(JSON.stringify({ type: "update", id, product }));
}

function triggerUpdateNow() {
  if (!ws || ws.readyState !== WebSocket.OPEN) {
    setUpdateHint("请先连接设备");
    return;
  }
  if (!agentOnline && !termOnline) {
    setUpdateHint("ReSA 与 ReST 均离线，无法更新");
    return;
  }
  const parts = [];
  if (agentOnline) {
    sendUpdateRequest("resa");
    parts.push("ReSA");
  }
  if (termOnline) {
    sendUpdateRequest("rest");
    parts.push("ReST");
  }
  setUpdateHint(`正在检查 ${parts.join("、")} 更新...`);
  if (updateNowBtn) updateNowBtn.disabled = true;
}

function handleUpdateResult(msg) {
  const name = msg.product === "rest" ? "ReST" : "ReSA";
  if (msg.status === "up_to_date") {
    setUpdateHint(`${name} 已是最新版本 (${msg.localVersion || "?"})`);
    if (msg.product === "resa") deviceAgentVersion = msg.localVersion || deviceAgentVersion;
    if (msg.product === "rest") deviceTermVersion = msg.localVersion || deviceTermVersion;
  } else if (msg.status === "updating") {
    setUpdateHint(
      `${name} 正在更新 ${msg.localVersion || "?"} → ${msg.remoteVersion || "?"}，即将重连...`
    );
    if (msg.product === "resa") agentOnline = false;
    if (msg.product === "rest") termOnline = false;
    updateTerminalUi();
    updateFilesUi();
  } else {
    setUpdateHint(`${name} 更新失败: ${msg.error || "未知错误"}`);
  }
  renderUpdateVersionMeta();
  updateVersionUi();
}

function updateTerminalUi() {
  const connected = !!(ws && ws.readyState === WebSocket.OPEN);
  const enabled = connected && isTerminalAvailable();
  if (openTerminalBtn) openTerminalBtn.disabled = !connected;
  if (terminalRunBtn) terminalRunBtn.disabled = !enabled;
  if (terminalInputEl) terminalInputEl.disabled = !enabled;
  updateFilesUi();
  updateVersionUi();
}

function updateFilesUi() {
  const connected = !!(ws && ws.readyState === WebSocket.OPEN);
  const enabled = connected && isScreenAgentReady();
  if (openFilesBtn) openFilesBtn.disabled = !enabled;
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
  const status = isTerminalAvailable() ? "已连接" : "离线";
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
  if (terminalInputEl && isTerminalAvailable()) {
    setTimeout(() => terminalInputEl.focus(), 0);
  }
}

function closeTerminalModal() {
  if (terminalModalEl) terminalModalEl.hidden = true;
}

function updateFilesModalTitle() {
  if (!filesModalTitleEl) return;
  const deviceId = currentDeviceId();
  const status = agentOnline ? "已连接" : "离线";
  const pathPart = fileCurrentPath ? ` · ${fileCurrentPath}` : "";
  filesModalTitleEl.textContent = deviceId
    ? `文件管理器 · ${deviceId} · ${status}${pathPart}`
    : `文件管理器 · ${status}${pathPart}`;
}

function openFilesModal() {
  if (!filesModalEl) return;
  if (!ws || ws.readyState !== WebSocket.OPEN) {
    setFilesHint("请先连接设备");
    return;
  }
  if (!isScreenAgentReady()) {
    setFilesHint("屏幕 Agent 未就绪，请从左侧选择带「屏幕」的在线设备");
    return;
  }
  filesModalEl.hidden = false;
  updateFilesModalTitle();
  sendFileRequest("drives");
}

function closeFilesModal() {
  if (filesModalEl) filesModalEl.hidden = true;
}

function formatFileSize(bytes) {
  const value = Number(bytes) || 0;
  if (value < 1024) return `${value} B`;
  if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KB`;
  if (value < 1024 * 1024 * 1024) return `${(value / 1024 / 1024).toFixed(1)} MB`;
  return `${(value / 1024 / 1024 / 1024).toFixed(2)} GB`;
}

function formatFileMtime(ts) {
  if (!ts) return "—";
  return new Date(Number(ts) * 1000).toLocaleString();
}

function joinFilePath(base, name) {
  if (!base) return name;
  const sep = base.includes("/") && !base.includes("\\") ? "/" : "\\";
  const trimmed = base.replace(/[\\/]+$/, "");
  return `${trimmed}${sep}${name}`;
}

function sendFileRequest(action, path = "") {
  if (!ws || ws.readyState !== WebSocket.OPEN) return;
  const id = `f${++fileReqSeq}`;
  const timer = setTimeout(() => {
    if (!pendingFiles.has(id)) return;
    pendingFiles.delete(id);
    if (filesStatusEl) {
      filesStatusEl.textContent =
        "请求超时：请更新被控端 ReSA 到最新版后重试";
    }
  }, FILE_REQUEST_TIMEOUT_MS);
  pendingFiles.set(id, timer);
  ws.send(JSON.stringify({ type: "file", id, action, path }));
  if (filesStatusEl) filesStatusEl.textContent = "加载中...";
}

function fileNavigate(path) {
  if (!path) {
    fileCurrentPath = "";
    sendFileRequest("drives");
    return;
  }
  sendFileRequest("list", path);
}

function fileGoUp() {
  if (!fileCurrentPath) return;
  let current = fileCurrentPath.replace(/[\\/]+$/, "");
  if (/^[A-Za-z]:\\?$/.test(current) || /^[A-Za-z]:$/.test(current)) {
    fileCurrentPath = "";
    sendFileRequest("drives");
    return;
  }
  const slash = Math.max(current.lastIndexOf("\\"), current.lastIndexOf("/"));
  if (slash <= 0) {
    fileCurrentPath = "";
    sendFileRequest("drives");
    return;
  }
  let parent = current.slice(0, slash);
  if (parent.length === 2 && parent[1] === ":") parent += "\\";
  fileNavigate(parent);
}

function renderFileList(entries) {
  if (!filesListEl) return;
  filesListEl.innerHTML = "";
  if (!entries?.length) {
    const row = document.createElement("tr");
    row.innerHTML = '<td colspan="4" class="files-empty">空目录</td>';
    filesListEl.appendChild(row);
    return;
  }
  for (const entry of entries) {
    const row = document.createElement("tr");
    row.className = entry.dir ? "files-row-dir" : "files-row-file";
    row.innerHTML = `
      <td class="files-col-name">${escapeHtml(entry.name)}</td>
      <td class="files-col-type">${entry.dir ? "文件夹" : "文件"}</td>
      <td class="files-col-size">${entry.dir ? "—" : formatFileSize(entry.size)}</td>
      <td class="files-col-time">${formatFileMtime(entry.mtime)}</td>
    `;
    row.addEventListener("dblclick", () => {
      if (entry.dir) {
        const nextPath = fileCurrentPath
          ? joinFilePath(fileCurrentPath, entry.name)
          : entry.name;
        fileNavigate(nextPath);
        return;
      }
      const fullPath = joinFilePath(fileCurrentPath, entry.name);
      sendFileRequest("download", fullPath);
    });
    filesListEl.appendChild(row);
  }
}

function downloadFileBlob(name, base64Data) {
  const binary = atob(base64Data);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) {
    bytes[i] = binary.charCodeAt(i);
  }
  const blob = new Blob([bytes]);
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = name || "download";
  link.click();
  URL.revokeObjectURL(url);
}

function handleFileResult(msg) {
  if (msg.id && pendingFiles.has(msg.id)) {
    clearTimeout(pendingFiles.get(msg.id));
    pendingFiles.delete(msg.id);
  }
  if (msg.ok === false || (!msg.ok && msg.error)) {
    if (filesStatusEl) filesStatusEl.textContent = msg.error || "操作失败";
    return;
  }
  if (msg.action === "drives") {
    fileCurrentPath = "";
    if (filesPathInputEl) filesPathInputEl.value = "";
    renderFileList(msg.entries);
    updateFilesModalTitle();
    if (filesStatusEl) filesStatusEl.textContent = "双击磁盘进入目录";
    return;
  }
  if (msg.action === "list") {
    fileCurrentPath = msg.path || "";
    if (filesPathInputEl) filesPathInputEl.value = fileCurrentPath;
    renderFileList(msg.entries);
    updateFilesModalTitle();
    if (filesStatusEl) {
      filesStatusEl.textContent = "双击文件夹进入，双击文件下载";
    }
    return;
  }
  if (msg.action === "download" && msg.data) {
    downloadFileBlob(msg.name, msg.data);
    if (filesStatusEl) {
      filesStatusEl.textContent = `已下载 ${msg.name} (${formatFileSize(msg.size)})`;
    }
  }
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

function getTerminalHistoryMatches(linePrefix) {
  const needle = String(linePrefix || "").toLowerCase();
  const seen = new Set();
  const matches = [];
  for (const cmd of terminalHistory) {
    const firstLine = cmd.split("\n")[0];
    if (!firstLine.toLowerCase().startsWith(needle)) continue;
    if (seen.has(cmd)) continue;
    seen.add(cmd);
    matches.push(cmd);
  }
  return matches;
}

function getTerminalLineContext() {
  const value = terminalInputEl.value;
  const cursor = terminalInputEl.selectionStart;
  const lineStart = value.lastIndexOf("\n", Math.max(0, cursor - 1)) + 1;
  const lineEnd = value.indexOf("\n", cursor);
  const lineEndPos = lineEnd === -1 ? value.length : lineEnd;
  return {
    value,
    lineStart,
    lineEnd: lineEndPos,
    linePrefix: value.slice(lineStart, cursor),
  };
}

function setTerminalInputCompletion(text, ctx) {
  const next = String(text || "");
  const onlyLine = ctx.lineStart === 0 && ctx.lineEnd === ctx.value.length;
  if (next.includes("\n") || onlyLine) {
    terminalInputEl.value = next;
  } else {
    terminalInputEl.value = ctx.value.slice(0, ctx.lineStart) + next + ctx.value.slice(ctx.lineEnd);
  }
  const pos = onlyLine || next.includes("\n") ? terminalInputEl.value.length : ctx.lineStart + next.length;
  terminalInputEl.setSelectionRange(pos, pos);
}

function handleTerminalTabCompletion() {
  if (!terminalInputEl || terminalInputEl.disabled) return false;

  const ctx = getTerminalLineContext();
  const prefix = ctx.linePrefix;
  const matches = getTerminalHistoryMatches(prefix);
  if (!matches.length) return true;

  const sameCycle =
    terminalTabCycle.basePrefix === prefix &&
    terminalTabCycle.list.length === matches.length &&
    terminalTabCycle.list.every((item, index) => item === matches[index]);

  if (sameCycle) {
    terminalTabCycle.index = (terminalTabCycle.index + 1) % matches.length;
    setTerminalInputCompletion(matches[terminalTabCycle.index], ctx);
  } else {
    terminalTabCycle.basePrefix = prefix;
    terminalTabCycle.list = matches;
    const firstLines = matches.map((cmd) => cmd.split("\n")[0]);
    const shared = longestCommonPrefix(firstLines);
    if (shared.length > prefix.length) {
      setTerminalInputCompletion(shared, ctx);
      terminalTabCycle.index = -1;
    } else if (matches.length === 1) {
      setTerminalInputCompletion(matches[0], ctx);
      terminalTabCycle.index = 0;
    } else {
      terminalTabCycle.index = 0;
      setTerminalInputCompletion(matches[0], ctx);
      appendTerminalBlock("", `[Tab 补全] ${firstLines.join("  ")}\n`);
    }
  }

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

function appendTerminalStream(text) {
  if (!terminalOutputEl || text == null || text === "") return;
  if (terminalOutputEl.textContent === "连接设备后可执行命令") {
    terminalOutputEl.textContent = "";
  }
  terminalOutputEl.textContent += String(text);
  terminalOutputEl.scrollTop = terminalOutputEl.scrollHeight;
}

function clearPendingTerminal(reason) {
  for (const timer of pendingTerminal.values()) clearTimeout(timer);
  pendingTerminal.clear();
  streamingTerminalIds.clear();
  if (reason) setTerminalHint(reason);
}

function sendTerminalCommand(command) {
  const cmd = String(command || "").trim();
  if (!cmd) return;
  if (!ws || ws.readyState !== WebSocket.OPEN) {
    setTerminalHint("请先连接设备");
    return;
  }
  if (!isTerminalAvailable()) {
    setTerminalHint("终端离线，请确认 ReST 已运行");
    return;
  }
  const shell = terminalShellEl?.value || "powershell";
  const id = `t-${Date.now()}-${++terminalReqSeq}`;
  appendTerminalBlock(`> [${shell}]\n${cmd}\n`, "");
  pushTerminalHistory(cmd);
  resetTerminalTabCycle();
  const payload = { type: "terminal", id, command: cmd, shell };
  if (terminalSessionCwd) payload.cwd = terminalSessionCwd;
  ws.send(JSON.stringify(payload));
  setTerminalHint(`设备: ${currentDeviceId()} · 命令已发送`);
  const timer = setTimeout(() => {
    if (!pendingTerminal.has(id)) return;
    pendingTerminal.delete(id);
    appendTerminalBlock("", "命令超时 (130s)，ReST 可能已退出或卡住\n");
    appendTerminalBlock("[exit timeout]\n", "");
    setTerminalHint(`设备: ${currentDeviceId()} · 命令超时`);
  }, TERMINAL_CMD_TIMEOUT_MS);
  pendingTerminal.set(id, timer);
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

function isMouseTrackEnabled() {
  return mouseTrackToggle.checked;
}

function sendMouseMove(clientX, clientY) {
  const coords = mapCoords(clientX, clientY);
  if (!coords) return;
  sendControl({ action: "mouse_move", x: coords.x, y: coords.y });
}

function mapCoords(clientX, clientY) {
  const rect = canvas.getBoundingClientRect();
  const frameW = remoteWidth || canvas.width;
  const frameH = remoteHeight || canvas.height;
  if (!rect.width || !rect.height || !frameW || !frameH) {
    return null;
  }
  const x = ((clientX - rect.left) / rect.width) * frameW;
  const y = ((clientY - rect.top) / rect.height) * frameH;
  const maxX = Math.max(0, frameW - 1);
  const maxY = Math.max(0, frameH - 1);
  return {
    x: Math.max(0, Math.min(maxX, Math.round(x))),
    y: Math.max(0, Math.min(maxY, Math.round(y))),
  };
}

function isAgentBinaryFrame(buf) {
  if (!buf || buf.byteLength < 5) return false;
  const type = new DataView(buf).getUint8(0);
  return type === 0x01 || type === 0x02;
}

function markFrameRendered(width, height) {
  const w = Number(width) || 0;
  const h = Number(height) || 0;
  if (w && h) {
    remoteWidth = w;
    remoteHeight = h;
    screenFrameReady = true;
    metaEl.textContent = `分辨率: ${w} x ${h}`;
    if (canvas.width !== w) canvas.width = w;
    if (canvas.height !== h) canvas.height = h;
  }
  updateFilesUi();
  placeholder.style.display = "none";
  frameCount += 1;
  const now = performance.now();
  if (now - lastFpsAt >= 1000) {
    fpsEl.textContent = `帧率: ${frameCount} fps`;
    frameCount = 0;
    lastFpsAt = now;
  }
}

function blobToImage(blob) {
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(blob);
    const img = new Image();
    img.onload = () => {
      URL.revokeObjectURL(url);
      resolve(img);
    };
    img.onerror = () => {
      URL.revokeObjectURL(url);
      reject(new Error("jpeg decode failed"));
    };
    img.src = url;
  });
}

async function drawBinaryFullFrame(buf) {
  const view = new DataView(buf);
  const width = view.getUint16(1);
  const height = view.getUint16(3);
  const jpeg = buf.slice(5);
  markFrameRendered(width, height);
  const img = await blobToImage(new Blob([jpeg], { type: "image/jpeg" }));
  ctx.drawImage(img, 0, 0);
}

async function drawBinaryDeltaFrame(buf) {
  const view = new DataView(buf);
  const width = view.getUint16(1);
  const height = view.getUint16(3);
  const patchCount = view.getUint16(5);
  markFrameRendered(width, height);
  let offset = 7;
  for (let i = 0; i < patchCount; i += 1) {
    const x = view.getUint16(offset);
    offset += 2;
    const y = view.getUint16(offset);
    offset += 2;
    const pw = view.getUint16(offset);
    offset += 2;
    const ph = view.getUint16(offset);
    offset += 2;
    const jlen = view.getUint16(offset);
    offset += 2;
    const jpeg = buf.slice(offset, offset + jlen);
    offset += jlen;
    const img = await blobToImage(new Blob([jpeg], { type: "image/jpeg" }));
    ctx.drawImage(img, x, y, pw, ph);
  }
}

async function handleAgentBinaryFrame(buf) {
  if (!isAgentBinaryFrame(buf)) return false;
  const type = new DataView(buf).getUint8(0);
  try {
    if (type === 0x01) await drawBinaryFullFrame(buf);
    else await drawBinaryDeltaFrame(buf);
    return true;
  } catch {
    placeholder.style.display = "block";
    placeholder.textContent = "画面解码失败，请刷新重连";
    return true;
  }
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
    markFrameRendered(width || img.width, height || img.height);
    ctx.drawImage(img, 0, 0);
  };
  img.onerror = () => {
    placeholder.style.display = "block";
    placeholder.textContent = "画面解码失败，请刷新重连";
  };
  img.src = "data:image/jpeg;base64," + base64;
}

function isDeviceOnline(d) {
  return !!(d.online || d.termOnline || d.proxyOnline);
}

function patchDeviceStatus(deviceId, patch) {
  if (!deviceId) return;
  const idx = lastKnownDevices.findIndex((d) => d.deviceId === deviceId);
  if (idx >= 0) {
    lastKnownDevices[idx] = { ...lastKnownDevices[idx], ...patch };
  } else if (isDeviceOnline({ ...patch })) {
    lastKnownDevices.push({
      deviceId,
      hostname: "",
      viewerCount: 0,
      online: false,
      termOnline: false,
      proxyOnline: false,
      ...patch,
    });
  } else {
    return;
  }
  renderDevices(lastKnownDevices);
}

function maybeAutoSelectDevice(devices) {
  if (params.get("device")) return;
  const screenOnline = devices.filter((d) => d.online);
  if (screenOnline.length === 1) {
    deviceInput.value = screenOnline[0].deviceId;
    return;
  }
  const online = devices.filter(isDeviceOnline);
  if (online.length === 1) {
    deviceInput.value = online[0].deviceId;
  }
}

function getDeviceGroupKey(device) {
  const host = String(device.hostname || "").trim();
  if (host) return host;
  const id = String(device.deviceId || "");
  const dash = id.indexOf("-");
  if (dash > 0) return id.slice(0, dash);
  return id || "未知设备";
}

function isDeviceGroupCollapsed(groupKey) {
  try {
    return localStorage.getItem(DEVICE_GROUP_COLLAPSE_PREFIX + groupKey) === "1";
  } catch {
    return false;
  }
}

function setDeviceGroupCollapsed(groupKey, collapsed) {
  try {
    localStorage.setItem(DEVICE_GROUP_COLLAPSE_PREFIX + groupKey, collapsed ? "1" : "0");
  } catch {
    // ignore
  }
}

function groupDevices(devices) {
  const map = new Map();
  for (const device of devices) {
    const key = getDeviceGroupKey(device);
    if (!map.has(key)) map.set(key, []);
    map.get(key).push(device);
  }

  return [...map.entries()]
    .map(([key, items]) => ({
      key,
      items: items.sort((a, b) => {
        const aOnline = isDeviceOnline(a) ? 0 : 1;
        const bOnline = isDeviceOnline(b) ? 0 : 1;
        if (aOnline !== bOnline) return aOnline - bOnline;
        return a.deviceId.localeCompare(b.deviceId);
      }),
    }))
    .sort((a, b) => {
      const aOnline = a.items.some(isDeviceOnline) ? 0 : 1;
      const bOnline = b.items.some(isDeviceOnline) ? 0 : 1;
      if (aOnline !== bOnline) return aOnline - bOnline;
      return a.key.localeCompare(b.key, "zh-CN");
    });
}

function connectToDevice(deviceId) {
  deviceInput.value = deviceId;
  setClipboardHint(`设备: ${deviceId}`);
  loadClipboardHistory(deviceId);
  loadKeyboardHistory(deviceId);
  loadScreenshotHistory(deviceId);
  connect();
}

async function copyDeviceId(deviceId, buttonEl) {
  const text = String(deviceId || "").trim();
  if (!text) return;
  try {
    await navigator.clipboard.writeText(text);
  } catch {
    const ta = document.createElement("textarea");
    ta.value = text;
    ta.style.position = "fixed";
    ta.style.left = "-9999px";
    document.body.appendChild(ta);
    ta.select();
    document.execCommand("copy");
    document.body.removeChild(ta);
  }
  if (buttonEl) {
    const prev = buttonEl.textContent;
    buttonEl.textContent = "已复制";
    setTimeout(() => {
      buttonEl.textContent = prev;
    }, 1200);
  }
}

async function removeDeviceFromList(deviceId) {
  const id = String(deviceId || "").trim();
  if (!id) return;
  if (!window.confirm(`从列表移除设备「${id}」？\n离线记录与复制/截屏历史将被清除；被控端再次上线会重新出现。`)) {
    return;
  }
  try {
    await apiFetch(`/api/devices?deviceId=${encodeURIComponent(id)}`, { method: "DELETE" });
    if (currentDeviceId() === id) {
      deviceInput.value = "";
      if (ws) ws.close();
    }
    lastKnownDevices = lastKnownDevices.filter((d) => d.deviceId !== id);
    renderDevices(lastKnownDevices);
    setStatus(`已移除设备 ${id}`, false);
  } catch (err) {
    const msg = String(err?.message || err);
    if (msg.includes("409")) {
      alert("设备仍在线，无法移除。请等待离线后再试。");
    } else {
      alert("移除失败，请稍后重试");
    }
  }
}

function createDeviceItem(device) {
  const li = document.createElement("li");
  const screenOn = !!device.online;
  const termOn = !!device.termOnline;
  const proxyOn = !!device.proxyOnline;
  const anyOn = isDeviceOnline(device);
  li.className = `device-item ${anyOn ? "online" : "offline"}`;
  const badges = [];
  if (screenOn) badges.push("屏幕");
  if (termOn) badges.push("终端");
  if (proxyOn) badges.push("代理");
  const badgeText = badges.length ? badges.join("+") : "离线";
  const ipPart = proxyOn && device.proxyIp ? ` · 出口 ${device.proxyIp}` : "";
  const lastSeenPart =
    !anyOn && device.lastSeen
      ? ` · 最后在线 ${new Date(device.lastSeen).toLocaleString()}`
      : "";

  const row = document.createElement("div");
  row.className = "device-row";

  const idEl = document.createElement("strong");
  idEl.textContent = device.deviceId;

  const rowRight = document.createElement("div");
  rowRight.className = "device-row-right";

  const badge = document.createElement("span");
  badge.className = "badge";
  badge.textContent = badgeText;

  const actions = document.createElement("div");
  actions.className = "device-actions";

  const copyBtn = document.createElement("button");
  copyBtn.type = "button";
  copyBtn.className = "device-action-btn";
  copyBtn.textContent = "复制ID";
  copyBtn.addEventListener("click", (event) => {
    event.stopPropagation();
    copyDeviceId(device.deviceId, copyBtn);
  });

  const removeBtn = document.createElement("button");
  removeBtn.type = "button";
  removeBtn.className = "device-action-btn danger";
  removeBtn.textContent = "移除";
  removeBtn.disabled = anyOn;
  removeBtn.title = anyOn ? "设备在线时无法移除" : "从列表移除此设备";
  removeBtn.addEventListener("click", (event) => {
    event.stopPropagation();
    removeDeviceFromList(device.deviceId);
  });

  actions.appendChild(copyBtn);
  actions.appendChild(removeBtn);
  rowRight.appendChild(badge);
  rowRight.appendChild(actions);
  row.appendChild(idEl);
  row.appendChild(rowRight);

  const sub = document.createElement("div");
  sub.className = "device-sub";
  sub.textContent = `${device.hostname || "—"}${ipPart} · 观看 ${device.viewerCount || 0}${lastSeenPart}`;

  li.appendChild(row);
  li.appendChild(sub);

  if (anyOn) {
    li.addEventListener("click", () => connectToDevice(device.deviceId));
  }
  return li;
}

function renderDevices(devices) {
  lastKnownDevices = devices || [];
  deviceListEl.innerHTML = "";
  maybeAutoSelectDevice(devices);
  if (!devices.length) {
    deviceListEl.innerHTML =
      '<li class="empty">暂无设备。请在被控机安装 ReSA / ReST / ReProxy，并确认 Agent 已连上服务器（可点「刷新」）</li>';
    return;
  }

  const anyOnline = devices.some(isDeviceOnline);
  if (!anyOnline) {
    const tip = document.createElement("li");
    tip.className = "empty";
    tip.textContent = "有历史设备记录，但当前全部离线";
    deviceListEl.appendChild(tip);
  }

  for (const group of groupDevices(devices)) {
    const groupLi = document.createElement("li");
    groupLi.className = "device-group";

    const collapsed = isDeviceGroupCollapsed(group.key);
    const onlineCount = group.items.filter(isDeviceOnline).length;
    const head = document.createElement("button");
    head.type = "button";
    head.className = "device-group-head";
    head.setAttribute("aria-expanded", collapsed ? "false" : "true");
    head.innerHTML = `
      <span class="device-group-chevron">${collapsed ? "▸" : "▾"}</span>
      <span class="device-group-title">${escapeHtml(group.key)}</span>
      <span class="device-group-meta">${group.items.length} 项 · ${onlineCount > 0 ? onlineCount + " 在线" : "离线"}</span>
    `;

    const body = document.createElement("ul");
    body.className = "device-group-items";
    body.hidden = collapsed;

    for (const device of group.items) {
      body.appendChild(createDeviceItem(device));
    }

    head.addEventListener("click", () => {
      const nextCollapsed = !body.hidden;
      body.hidden = nextCollapsed;
      head.querySelector(".device-group-chevron").textContent = nextCollapsed ? "▸" : "▾";
      head.setAttribute("aria-expanded", nextCollapsed ? "false" : "true");
      setDeviceGroupCollapsed(group.key, nextCollapsed);
    });

    groupLi.appendChild(head);
    groupLi.appendChild(body);
    deviceListEl.appendChild(groupLi);
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

let clipboardRefreshTimer = null;

function startClipboardRefresh(deviceId) {
  stopClipboardRefresh();
  clipboardRefreshTimer = setInterval(() => {
    if (ws && ws.readyState === WebSocket.OPEN) {
      loadClipboardHistory(deviceId);
    }
  }, 15000);
}

function stopClipboardRefresh() {
  if (clipboardRefreshTimer) {
    clearInterval(clipboardRefreshTimer);
    clipboardRefreshTimer = null;
  }
}

function setClipboardHint(text) {
  if (clipboardHintEl) clipboardHintEl.textContent = text;
}

function renderClipboard() {
  clipboardListEl.innerHTML = "";
  if (!clipboardEntries.length) {
    clipboardListEl.innerHTML = '<li class="empty">暂无复制记录（在被控端按 Ctrl+C 复制文字后显示）</li>';
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
    deviceListEl.innerHTML = '<li class="empty">无法加载设备列表（检查网络或重新登录）</li>';
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
  const known = lastKnownDevices.find((d) => d.deviceId === deviceId);
  if (known && !known.online && known.termOnline) {
    setStatus(`设备 ${deviceId} 仅有终端在线，请安装 ReSA 或从左侧选择`, false);
    setFilesHint("该设备 ID 无屏幕 Agent");
  } else if (known && !isDeviceOnline(known)) {
    setStatus(`设备 ${deviceId} 离线`, false);
  }

  const url =
    `${wsBase()}/ws?role=viewer&deviceId=${encodeURIComponent(deviceId)}` +
    `&token=${encodeURIComponent(getToken())}`;

  ws = new WebSocket(url);
  ws.binaryType = "arraybuffer";
  setStatus("连接中...", false);
  connectBtn.disabled = true;
  remoteWidth = 0;
  remoteHeight = 0;
  screenFrameReady = false;
  agentOnline = false;
  setClipboardHint(`设备: ${deviceId}`);

  syncAutoScreenshotUi(deviceId);

  ws.onopen = () => {
    setStatus(`已连接 · ${deviceId}`, true);
    disconnectBtn.disabled = false;
    loadClipboardHistory(deviceId);
    loadKeyboardHistory(deviceId);
    loadScreenshotHistory(deviceId);
    startClipboardRefresh(deviceId);
    screenshotBtn.disabled = false;
    pushAutoScreenshotToAgent(deviceId);
    const prefs = loadAutoScreenshotPrefs(deviceId);
    if (prefs.enabled) {
      setScreenshotHint(`设备: ${deviceId} · 自动截屏每 ${prefs.interval} 秒`);
    } else {
      setScreenshotHint(`设备: ${deviceId}`);
    }
  };

  ws.onmessage = async (event) => {
    const binary =
      event.data instanceof ArrayBuffer
        ? event.data
        : event.data instanceof Blob
          ? await event.data.arrayBuffer()
          : null;
    if (binary && isAgentBinaryFrame(binary)) {
      agentOnline = true;
      setStatus(`远程控制中 · ${deviceId}`, true);
      await handleAgentBinaryFrame(binary);
      updateFilesUi();
      updateFilesModalTitle();
      return;
    }

    let msg;
    try {
      msg = JSON.parse(typeof event.data === "string" ? event.data : "");
    } catch {
      return;
    }

    if (msg.type === "registered") {
      termOnline = !!msg.termOnline;
      agentOnline = !!msg.agentOnline;
      screenFrameReady = false;
      syncDeviceVersions(msg.device);
      loadLatestVersions();
      updateTerminalUi();
      updateFilesUi();
      if (!msg.agentOnline) {
        setStatus(`设备 ${deviceId} 无屏幕 Agent`, false);
        setClipboardHint(`设备 ${deviceId} 离线，复制记录可能为空`);
        setFilesHint(`请从左侧列表点击带「屏幕」的在线设备`);
      } else {
        setStatus(`Agent 在线 · 等待画面…`, true);
        setFilesHint(`设备: ${deviceId} · 等待首帧后可操作`);
      }
      if (termOnline) {
        setTerminalHint(`设备: ${deviceId} · 终端已连接，点击「打开终端」`);
      } else {
        setTerminalHint(`设备: ${deviceId} · 终端离线，请运行 ReST`);
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
      setClipboardHint(`设备: ${deviceId} · 实时更新`);
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
      agentOnline = false;
      patchDeviceStatus(deviceId, { online: false });
      updateTerminalUi();
      updateTerminalModalTitle();
      updateFilesUi();
      updateFilesModalTitle();
      setStatus(`Agent 离线 · ${deviceId}`, false);
      setFilesHint(`设备: ${deviceId} · Agent 离线`);
      placeholder.style.display = "block";
      placeholder.textContent = "Agent 已离线";
      return;
    }

    if (msg.type === "agent_online" && msg.deviceId === deviceId) {
      agentOnline = true;
      patchDeviceStatus(deviceId, { online: true });
      updateTerminalUi();
      updateTerminalModalTitle();
      updateFilesUi();
      updateFilesModalTitle();
      setStatus(`Agent 在线 · 等待画面…`, true);
      setFilesHint(`设备: ${deviceId} · 等待首帧后可操作`);
      if (termOnline) {
        setTerminalHint(`设备: ${deviceId} · 终端已连接，点击「打开终端」`);
      }
      refreshDeviceVersions();
      pushAutoScreenshotToAgent(deviceId);
      return;
    }

    if (msg.type === "update_result") {
      handleUpdateResult(msg);
      return;
    }

    if (msg.type === "control_result") {
      if (!msg.ok && metaEl) {
        metaEl.textContent = `鼠标控制失败: ${msg.error || "unknown"}`;
      }
      return;
    }

    if (msg.type === "file_result") {
      handleFileResult(msg);
      return;
    }

    if (msg.type === "term_online" && msg.deviceId === deviceId) {
      termOnline = true;
      patchDeviceStatus(deviceId, { termOnline: true });
      updateTerminalUi();
      updateTerminalModalTitle();
      setTerminalHint(`设备: ${deviceId} · 终端已连接，点击「打开终端」`);
      refreshDeviceVersions();
      return;
    }

    if (msg.type === "term_offline" && msg.deviceId === deviceId) {
      termOnline = false;
      patchDeviceStatus(deviceId, { termOnline: false });
      clearPendingTerminal(`设备: ${deviceId} · 终端已离线`);
      updateTerminalUi();
      updateTerminalModalTitle();
      return;
    }

    if (msg.type === "terminal_output") {
      if (msg.id && pendingTerminal.has(msg.id)) {
        streamingTerminalIds.add(msg.id);
        setTerminalHint(`设备: ${deviceId} · 执行中...`);
      }
      if (msg.data) appendTerminalStream(msg.data);
      return;
    }

    if (msg.type === "terminal_result") {
      if (msg.id && pendingTerminal.has(msg.id)) {
        clearTimeout(pendingTerminal.get(msg.id));
        pendingTerminal.delete(msg.id);
      }
      if (msg.cwd) setTerminalCwd(msg.cwd);
      const wasStreaming = msg.id && streamingTerminalIds.has(msg.id);
      if (msg.id) streamingTerminalIds.delete(msg.id);
      if (!wasStreaming) {
        if (msg.stdout) appendTerminalBlock("", msg.stdout);
        if (msg.stderr) appendTerminalBlock("", msg.stderr);
        if (!msg.stdout && !msg.stderr) appendTerminalBlock("(no output)\n", "");
      } else if (msg.truncated) {
        appendTerminalStream("\n...[truncated]\n");
      }
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
      agentOnline = true;
      setStatus(`远程控制中 · ${deviceId}`, true);
      drawFrame(msg.data, msg.width, msg.height);
      updateFilesUi();
      updateFilesModalTitle();
    }
  };

  ws.onclose = (ev) => {
    if (ev.code === 4401) setStatus("令牌无效", false);
    else setStatus("未连接", false);
    connectBtn.disabled = false;
    disconnectBtn.disabled = true;
    screenshotBtn.disabled = true;
    termOnline = false;
    agentOnline = false;
    screenFrameReady = false;
    clearPendingTerminal();
    for (const timer of pendingFiles.values()) clearTimeout(timer);
    pendingFiles.clear();
    fileCurrentPath = "";
    deviceAgentVersion = "";
    deviceTermVersion = "";
    updateTerminalUi();
    setTerminalCwd("");
    terminalHistory = [];
    resetTerminalTabCycle();
    closeTerminalModal();
    closeFilesModal();
    setFilesHint("连接设备后可浏览被控端磁盘与下载文件（单文件最大 8MB）");
    setUpdateHint("连接后检查并安装 ReSA / ReST 最新版（更新时会短暂断开）");
    ws = null;
  };

  ws.onerror = () => setStatus("连接错误", false);
}

function disconnect() {
  stopClipboardRefresh();
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
  const coords = mapCoords(e.clientX, e.clientY);
  if (!coords) return;
  const { x, y } = coords;
  if (!isMouseTrackEnabled()) sendControl({ action: "mouse_move", x, y });
  const button = e.button === 2 ? "right" : e.button === 1 ? "middle" : "left";
  sendControl({ action: "mouse_click", button, down: true, x, y });
});

canvas.addEventListener("mouseup", (e) => {
  const coords = mapCoords(e.clientX, e.clientY);
  if (!coords) return;
  const { x, y } = coords;
  const button = e.button === 2 ? "right" : e.button === 1 ? "middle" : "left";
  sendControl({ action: "mouse_click", button, down: false, x, y });
});

canvas.addEventListener("contextmenu", (e) => e.preventDefault());

canvas.addEventListener(
  "wheel",
  (e) => {
    e.preventDefault();
    const coords = mapCoords(e.clientX, e.clientY);
    if (!coords) return;
    const { x, y } = coords;
    const dy = e.deltaY > 0 ? -1 : 1;
    sendControl({ action: "scroll", dx: 0, dy, x, y });
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
    else if (filesModalEl && !filesModalEl.hidden) closeFilesModal();
    else if (screenshotModalEl && !screenshotModalEl.hidden) closeScreenshotModal();
  }
});
openTerminalBtn?.addEventListener("click", openTerminalModal);
openFilesBtn?.addEventListener("click", openFilesModal);
updateNowBtn?.addEventListener("click", triggerUpdateNow);
filesModalCloseBtn?.addEventListener("click", closeFilesModal);
filesDrivesBtn?.addEventListener("click", () => sendFileRequest("drives"));
filesUpBtn?.addEventListener("click", fileGoUp);
filesRefreshBtn?.addEventListener("click", () => {
  if (fileCurrentPath) fileNavigate(fileCurrentPath);
  else sendFileRequest("drives");
});
filesGoBtn?.addEventListener("click", () => {
  const path = filesPathInputEl?.value?.trim() || "";
  if (!path) sendFileRequest("drives");
  else fileNavigate(path);
});
filesPathInputEl?.addEventListener("keydown", (e) => {
  if (e.key === "Enter") {
    e.preventDefault();
    const path = filesPathInputEl.value.trim();
    if (!path) sendFileRequest("drives");
    else fileNavigate(path);
  }
});
filesModalEl?.addEventListener("click", (e) => {
  if (e.target === filesModalEl) closeFilesModal();
});
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
  if (e.key === "Enter" && !e.shiftKey) {
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
deviceInput.addEventListener("change", () => {
  syncAutoScreenshotUi(currentDeviceId());
});
renderClipboard();
renderKeyboard();
renderScreenshots();
loadLatestVersions();
refreshDashboard();
connectDashboard();
setInterval(refreshDashboard, 25000);
