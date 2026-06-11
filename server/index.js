require("dotenv").config();

const http = require("http");
const path = require("path");
const express = require("express");
const { WebSocketServer } = require("ws");

const PORT = Number(process.env.PORT) || 8080;
const ACCESS_TOKEN = process.env.ACCESS_TOKEN || "remote-screen-dev";
const MAX_AUDIT = Number(process.env.MAX_AUDIT) || 200;
const MAX_CLIPBOARD = Number(process.env.MAX_CLIPBOARD) || 300;
const MAX_KEYBOARD = Number(process.env.MAX_KEYBOARD) || 300;
const MAX_SCREENSHOTS = Number(process.env.MAX_SCREENSHOTS) || 80;

const agents = new Map();
const agentMeta = new Map();
const viewers = new Map();
const dashboardClients = new Set();
const auditLog = [];
const clipboardLog = new Map();
const keyboardLog = new Map();
const screenshotLog = new Map();

const app = express();
app.use(express.json());

function publicBaseUrl(req) {
  const proto = req.headers["x-forwarded-proto"]?.split(",")[0]?.trim() || req.protocol || "http";
  const host = req.headers["x-forwarded-host"]?.split(",")[0]?.trim() || req.get("host");
  return `${proto}://${host}`;
}

app.get("/install", (_req, res) => {
  res.redirect("/install.html");
});

app.get("/download/install.bat", (req, res) => {
  const base = `${publicBaseUrl(req)}/download`;
  const psCmd =
    "Write-Host '正在获取安装脚本...' -ForegroundColor Cyan; " +
    "$b='%BASE%'; $f=Join-Path $env:TEMP 'ReSA-install.ps1'; " +
    "Invoke-WebRequest -Uri ($b+'/install.ps1') -OutFile $f -UseBasicParsing; " +
    "Unblock-File -LiteralPath $f -ErrorAction SilentlyContinue; " +
    "& $f -BaseUrl $b";
  const body = [
    "@echo off",
    "chcp 65001 >nul",
    "title ReSA 一键安装",
    "echo.",
    "echo === ReSA 一键安装 ===",
    "echo.",
    `set "BASE=${base}"`,
    `powershell -NoProfile -ExecutionPolicy Bypass -Command "${psCmd}"`,
    "if errorlevel 1 (",
    "  echo.",
    "  echo [错误] 安装失败，请检查网络或联系管理员。",
    "  pause",
    "  exit /b 1",
    ")",
    "echo.",
    "echo 安装完成。可在控制端设备列表查看是否在线。",
    "pause",
  ].join("\r\n");
  res.setHeader("Content-Type", "application/octet-stream");
  res.setHeader("Content-Disposition", 'attachment; filename="ReSA-Install.bat"');
  res.send(body);
});

app.get("/download/uninstall.bat", (req, res) => {
  const base = `${publicBaseUrl(req)}/download`;
  const psCmd =
    "Write-Host '正在获取卸载脚本...' -ForegroundColor Cyan; " +
    "$b='%BASE%'; $f=Join-Path $env:TEMP 'ReSA-uninstall.ps1'; " +
    "Invoke-WebRequest -Uri ($b+'/uninstall.ps1') -OutFile $f -UseBasicParsing; " +
    "Unblock-File -LiteralPath $f -ErrorAction SilentlyContinue; " +
    "& $f; exit $LASTEXITCODE";
  const body = [
    "@echo off",
    "chcp 65001 >nul",
    "title ReSA 卸载",
    "echo.",
    "echo === ReSA 卸载 ===",
    "echo.",
    `set "BASE=${base}"`,
    `powershell -NoProfile -ExecutionPolicy Bypass -Command "${psCmd}"`,
    "set RC=%ERRORLEVEL%",
    "echo.",
    "if %RC% NEQ 0 (",
    "  echo [错误] 卸载未完全成功，请关闭 ReSA 后重试，或以管理员身份运行。",
    ") else (",
    "  echo 卸载已完成。",
    ")",
    "pause",
    "exit /b %RC%",
  ].join("\r\n");
  res.setHeader("Content-Type", "application/octet-stream");
  res.setHeader("Content-Disposition", 'attachment; filename="ReSA-Uninstall.bat"');
  res.send(body);
});

app.use("/download", express.static(path.join(__dirname, "..", "downloads")));
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
    viewerCount,
    hostname: meta.hostname || "",
    platform: meta.platform || "",
    monitor: meta.monitor ?? null,
    connectedAt: meta.connectedAt || null,
    lastSeen: meta.lastSeen || null,
  };
}

function listDevices() {
  const ids = new Set([...agents.keys(), ...agentMeta.keys()]);
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

    send(ws, { type: "registered", role: "agent", deviceId });
    notifyAgentViewerCount(deviceId);
    addAudit("agent_online", { deviceId, ip: clientIp });
    broadcastDashboard("devices_changed", { devices: listDevices() });
    console.log(`[agent] online: ${deviceId} (${clientIp})`);
  } else if (role === "viewer") {
    if (!viewers.has(deviceId)) viewers.set(deviceId, new Set());
    viewers.get(deviceId).add(ws);
    send(ws, {
      type: "registered",
      role: "viewer",
      deviceId,
      agentOnline: agents.has(deviceId),
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
