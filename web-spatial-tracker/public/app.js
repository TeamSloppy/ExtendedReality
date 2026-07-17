import { gazeDirection, projectedTransformSize } from "./spatial-math.js";

const app = document.getElementById("app");
const mode = new URLSearchParams(location.search).get("mode");

const brandMark = `
  <svg class="brand-mark" viewBox="0 0 32 32" fill="none" aria-hidden="true">
    <path d="M4.5 11.5c3-4.6 20-4.6 23 0l-2 9.4c-.6 2.7-3.7 3.8-5.9 2.1l-3-3h-1.2l-3 3c-2.2 1.7-5.3.6-5.9-2.1z" stroke="currentColor" stroke-width="2" stroke-linejoin="round"/>
    <circle cx="10.5" cy="15.5" r="2.5" fill="currentColor"/><circle cx="21.5" cy="15.5" r="2.5" fill="currentColor"/>
  </svg>`;

const clamp = (value, min, max) => Math.min(max, Math.max(min, Number(value) || 0));
const radians = (degrees) => Number(degrees || 0) * Math.PI / 180;
const fixed = (value, digits = 1) => Number.isFinite(Number(value)) ? Number(value).toFixed(digits) : "—";
const escapeHTML = (value) => String(value ?? "")
  .replaceAll("&", "&amp;")
  .replaceAll("<", "&lt;")
  .replaceAll(">", "&gt;")
  .replaceAll('"', "&quot;")
  .replaceAll("'", "&#039;");

function socketURL(role = "viewer") {
  const protocol = location.protocol === "https:" ? "wss:" : "ws:";
  return `${protocol}//${location.host}/ws?role=${role}&id=${role}-${crypto.randomUUID().slice(0, 8)}`;
}

function vector(value, fallback = { x: 0, y: 0, z: 0 }) {
  if (Array.isArray(value)) return { x: Number(value[0]) || 0, y: Number(value[1]) || 0, z: Number(value[2]) || 0 };
  return {
    x: Number(value?.x ?? fallback.x) || 0,
    y: Number(value?.y ?? fallback.y) || 0,
    z: Number(value?.z ?? fallback.z) || 0,
  };
}

function orientation(value = {}) {
  return {
    yaw: Number(value.yaw ?? value.alpha ?? value.heading) || 0,
    pitch: Number(value.pitch ?? value.beta) || 0,
    roll: Number(value.roll ?? value.gamma) || 0,
  };
}

function normalizeWindow(item, index) {
  const transform = item.transform || {};
  const yaw = Number(item.rotation?.yaw ?? item.yaw ?? transform.yaw) || 0;
  const pitch = Number(item.rotation?.pitch ?? item.pitch ?? transform.pitch) || 0;
  const distance = Number(item.distance ?? item.virtualDistance ?? transform.virtualDistance) || 1;
  let position = vector(item.position, { x: 0, y: 0, z: -2.7 });
  if (!item.position) {
    const worldDistance = 2.15 * distance;
    position = {
      x: Math.sin(radians(yaw)) * worldDistance,
      y: Math.sin(radians(pitch)) * worldDistance,
      z: -Math.cos(radians(yaw)) * worldDistance,
    };
  }
  const sizeValue = item.size || {};
  const hasExplicitWorldSize = Boolean(item.size || item.width || item.height);
  const widthFraction = Number(transform.width) || null;
  const heightFraction = Number(transform.height) || null;
  // WindowTransform3DoF width/height are viewport fractions, not meters.
  // Mirror WindowProjection using a 16:9 reference plane in the debug world.
  const projectedSize = projectedTransformSize(transform);
  const projectedWidthFraction = widthFraction === null ? null : projectedSize.viewportWidth;
  const projectedHeightFraction = heightFraction === null ? null : projectedSize.viewportHeight;
  return {
    id: String(item.id ?? `window-${index}`),
    title: String(item.title ?? item.name ?? `Window ${index + 1}`),
    position,
    rotation: orientation(item.rotation || { yaw, pitch, roll: transform.roll }),
    size: {
      width: hasExplicitWorldSize
        ? Number(sizeValue.width ?? item.width) || 1.35
        : projectedSize.worldWidth,
      height: hasExplicitWorldSize
        ? Number(sizeValue.height ?? item.height) || 0.78
        : projectedSize.worldHeight,
    },
    viewportSize: projectedWidthFraction === null ? null : {
      width: projectedWidthFraction,
      height: projectedHeightFraction,
    },
    visible: item.visible !== false && item.isMinimized !== true,
    focused: Boolean(item.focused ?? item.isActive),
    zIndex: Number(item.zIndex) || 0,
  };
}

function normalizeSnapshot(message) {
  const sensors = message.sensors || {};
  const head = sensors.head || sensors.headphones || message.headPose || message.pose || {};
  const phone = sensors.phone || message.phone || {};
  const watch = sensors.watch || message.watch || {};
  const devices = message.devices || {};
  const windows = Array.isArray(message.windows) ? message.windows.map(normalizeWindow) : [];
  return {
    timestamp: Number(message.timestamp ?? message.updatedAt ?? message.serverReceivedAt) || Date.now(),
    serverReceivedAt: Number(message.serverReceivedAt) || Date.now(),
    source: message.device || message.source || { id: message.sourceClient || "device" },
    sensors: {
      head: { ...head, orientation: orientation(head.orientation || head) },
      phone: { ...phone, orientation: orientation(phone.orientation || phone) },
      watch: { ...watch, orientation: orientation(watch.orientation || watch) },
    },
    devices: {
      head: { position: vector(devices.head?.position, { x: 0, y: 0.35, z: 0 }) },
      phone: { position: vector(devices.phone?.position || phone.position, { x: 0.86, y: -0.42, z: 0.24 }) },
      watch: { position: vector(devices.watch?.position || watch.position, { x: -0.72, y: -0.4, z: 0.15 }) },
      headphones: { position: vector(devices.headphones?.position, { x: 0, y: 0.35, z: 0 }) },
    },
    windows,
    raw: message,
  };
}

function renderViewer() {
  app.innerHTML = `
    <div class="app-shell">
      <header class="topbar">
        <div class="brand">${brandMark}<div><strong>Spatial debug station</strong><small>devices / sensors / windows / gaze</small></div></div>
        <form class="connection-form" id="connection-form">
          <label for="socket-address">WEBSOCKET</label>
          <input id="socket-address" spellcheck="false" autocomplete="off" aria-label="WebSocket address" />
          <button class="primary" id="connect-button" type="submit">Connect</button>
        </form>
        <div class="status-cluster">
          <span class="chip"><span>RX</span><strong id="rx-rate">0.0 Hz</strong></span>
          <span class="status" id="connection-status"><span class="status-dot"></span><span id="connection-label">offline</span></span>
        </div>
      </header>
      <main class="workspace">
        <section class="scene-panel" aria-label="Three-dimensional spatial debug view">
          <canvas id="scene" role="img" aria-label="Devices, gaze ray and spatial windows"></canvas>
          <div class="scene-hud">
            <div class="hud-group">
              <span class="chip">YAW <strong id="hud-yaw">0.0°</strong></span>
              <span class="chip">PITCH <strong id="hud-pitch">0.0°</strong></span>
              <span class="chip">ROLL <strong id="hud-roll">0.0°</strong></span>
            </div>
            <div class="hud-group">
              <span class="chip" id="gaze-chip">GAZE <strong id="gaze-hit">no hit</strong></span>
              <span class="chip">WINDOWS <strong id="hud-windows">0</strong></span>
            </div>
          </div>
          <div class="scene-help">drag: orbit · wheel: zoom · live coordinates in meters</div>
        </section>
        <aside class="inspector">
          <div class="tabs" role="tablist" aria-label="Debug data views">
            <button class="tab" role="tab" aria-selected="true" data-tab="sensors">Sensors</button>
            <button class="tab" role="tab" aria-selected="false" data-tab="windows">Windows</button>
            <button class="tab" role="tab" aria-selected="false" data-tab="raw">Raw JSON</button>
          </div>
          <div class="tab-panel" id="inspector-panel"></div>
        </aside>
      </main>
    </div>`;

  setupViewer();
}

function setupViewer() {
  const canvas = document.getElementById("scene");
  const context = canvas.getContext("2d");
  const address = document.getElementById("socket-address");
  const connectButton = document.getElementById("connect-button");
  const connectionStatus = document.getElementById("connection-status");
  const connectionLabel = document.getElementById("connection-label");
  const inspector = document.getElementById("inspector-panel");
  const gazeHit = document.getElementById("gaze-hit");
  const gazeChip = document.getElementById("gaze-chip");
  const eventLines = [];
  let activeTab = "sensors";
  let ws;
  let snapshot = normalizeSnapshot({ timestamp: Date.now(), windows: [] });
  let rawMessage = null;
  let paused = false;
  let messageCount = 0;
  let receivedTimes = [];
  let serverClients = { device: 0, viewer: 0 };
  let orbitYaw = -0.58;
  let orbitPitch = 0.38;
  let zoom = 1;
  let drag = null;
  let gazeTarget = null;

  address.value = localStorage.getItem("xr-debug-url") || socketURL("viewer");

  const style = getComputedStyle(document.documentElement);
  const colors = Object.fromEntries(["text", "muted", "faint", "line", "cyan", "blue", "orange", "green", "red"].map((name) => [name, style.getPropertyValue(`--${name}`).trim()]));

  function log(text, kind = "") {
    const now = new Date().toLocaleTimeString([], { hour12: false });
    eventLines.unshift({ now, text, kind });
    eventLines.splice(30);
    if (activeTab === "raw") renderInspector();
  }

  function setConnection(state, label) {
    connectionStatus.className = `status ${state}`;
    connectionLabel.textContent = label;
    connectButton.textContent = state === "online" ? "Disconnect" : "Connect";
    connectButton.classList.toggle("danger", state === "online");
    connectButton.classList.toggle("primary", state !== "online");
  }

  function connect() {
    if (ws?.readyState === WebSocket.OPEN || ws?.readyState === WebSocket.CONNECTING) {
      ws.close(1000, "Viewer disconnected");
      return;
    }
    const url = address.value.trim();
    if (!/^wss?:\/\//i.test(url)) {
      setConnection("error", "invalid URL");
      return;
    }
    localStorage.setItem("xr-debug-url", url);
    setConnection("", "connecting");
    log(`connecting ${url}`);
    try { ws = new WebSocket(url); } catch (error) { setConnection("error", "invalid URL"); log(error.message, "bad"); return; }
    ws.addEventListener("open", () => { setConnection("online", "connected"); log("socket connected", "ok"); });
    ws.addEventListener("close", (event) => { setConnection("", "offline"); log(`socket closed (${event.code})`, "warn"); });
    ws.addEventListener("error", () => { setConnection("error", "socket error"); log("WebSocket error", "bad"); });
    ws.addEventListener("message", (event) => {
      let message;
      try { message = JSON.parse(event.data); } catch { log("ignored non-JSON message", "warn"); return; }
      if (message.type === "server.status") {
        serverClients = message.clients || serverClients;
        renderInspector();
        return;
      }
      if (message.type === "server.hello") { log(`assigned ${message.client?.id}`, "ok"); return; }
      if (message.type === "server.error") { log(message.error, "bad"); return; }
      messageCount += 1;
      receivedTimes.push(performance.now());
      receivedTimes = receivedTimes.filter((time) => performance.now() - time <= 1000);
      document.getElementById("rx-rate").textContent = `${receivedTimes.length.toFixed(1)} Hz`;
      if (paused) return;
      rawMessage = message;
      snapshot = normalizeSnapshot(message);
      updateHUD();
      renderInspector();
    });
  }

  document.getElementById("connection-form").addEventListener("submit", (event) => { event.preventDefault(); connect(); });
  document.querySelectorAll(".tab").forEach((tab) => tab.addEventListener("click", () => {
    activeTab = tab.dataset.tab;
    document.querySelectorAll(".tab").forEach((item) => item.setAttribute("aria-selected", String(item === tab)));
    renderInspector();
  }));

  function sensorMetrics(label, sensor) {
    const pose = sensor.orientation || orientation(sensor);
    const extras = Object.entries(sensor)
      .filter(([key, value]) => !["orientation", "position", "yaw", "pitch", "roll"].includes(key) && typeof value === "number")
      .slice(0, 3);
    return `<div class="sensor-block"><div class="sensor-head"><strong>${escapeHTML(label)}</strong><span>ACTIVE</span></div>
      <div class="metric-grid">
        <div class="metric"><label>yaw</label><output>${fixed(pose.yaw)}°</output></div>
        <div class="metric"><label>pitch</label><output>${fixed(pose.pitch)}°</output></div>
        <div class="metric"><label>roll</label><output>${fixed(pose.roll)}°</output></div>
        ${extras.map(([key, value]) => `<div class="metric"><label>${escapeHTML(key)}</label><output>${fixed(value, 2)}</output></div>`).join("")}
      </div></div>`;
  }

  function renderInspector() {
    if (activeTab === "sensors") {
      const latency = rawMessage ? Math.max(0, snapshot.serverReceivedAt - snapshot.timestamp) : 0;
      inspector.innerHTML = `
        <section class="section"><div class="section-title"><h2>Stream</h2><span>${serverClients.device || 0} device · ${serverClients.viewer || 0} viewer</span></div>
          <div class="metric-grid">
            <div class="metric"><label>messages</label><output class="accent">${messageCount}</output></div>
            <div class="metric"><label>latency</label><output>${fixed(latency, 0)} ms</output></div>
            <div class="metric"><label>source</label><output>${escapeHTML(snapshot.source?.name || snapshot.source?.id || snapshot.source || "—")}</output></div>
          </div></section>
        <section class="section"><div class="section-title"><h2>Orientation</h2><span>degrees</span></div>
          ${sensorMetrics("Head / headphones", snapshot.sensors.head)}
          ${sensorMetrics("Phone", snapshot.sensors.phone)}
          ${sensorMetrics("Watch", snapshot.sensors.watch)}
        </section>`;
      return;
    }
    if (activeTab === "windows") {
      inspector.innerHTML = `<section class="section"><div class="section-title"><h2>Spatial windows</h2><span>${snapshot.windows.length} received</span></div>
        ${snapshot.windows.length ? `<table class="window-list"><thead><tr><th>name</th><th>x</th><th>y</th><th>z</th><th>yaw</th></tr></thead><tbody>
          ${snapshot.windows.map((item) => `<tr><td>${escapeHTML(item.title)}${item.viewportSize ? `<br><span class="text-faint">${fixed(item.viewportSize.width * 100, 0)}×${fixed(item.viewportSize.height * 100, 0)}% viewport</span>` : ""}</td><td>${fixed(item.position.x, 2)}</td><td>${fixed(item.position.y, 2)}</td><td>${fixed(item.position.z, 2)}</td><td>${fixed(item.rotation.yaw)}°</td></tr>`).join("")}
        </tbody></table>` : `<div class="empty">Waiting for a message with a <code>windows</code> array</div>`}</section>`;
      return;
    }
    inspector.innerHTML = `<section class="section"><div class="section-title"><h2>Last message</h2><span>${rawMessage ? new Date(snapshot.serverReceivedAt).toLocaleTimeString() : "empty"}</span></div>
      <div class="raw-toolbar"><button id="pause-button" class="ghost">${paused ? "Resume" : "Pause"}</button><button id="copy-button" class="ghost" ${rawMessage ? "" : "disabled"}>Copy JSON</button></div>
      <pre class="raw-output">${escapeHTML(rawMessage ? JSON.stringify(rawMessage, null, 2) : "No device payload received")}</pre></section>
      <section class="section"><div class="section-title"><h2>Socket events</h2><span>latest first</span></div><div class="event-log">${eventLines.map((item) => `<div class="event-line"><time>${item.now}</time><span class="${item.kind}">${escapeHTML(item.text)}</span></div>`).join("") || "No events"}</div></section>`;
    document.getElementById("pause-button")?.addEventListener("click", () => { paused = !paused; renderInspector(); });
    document.getElementById("copy-button")?.addEventListener("click", async () => { if (rawMessage) await navigator.clipboard.writeText(JSON.stringify(rawMessage, null, 2)); });
  }

  function updateHUD() {
    const head = snapshot.sensors.head.orientation;
    document.getElementById("hud-yaw").textContent = `${fixed(head.yaw)}°`;
    document.getElementById("hud-pitch").textContent = `${fixed(head.pitch)}°`;
    document.getElementById("hud-roll").textContent = `${fixed(head.roll)}°`;
    document.getElementById("hud-windows").textContent = String(snapshot.windows.filter((item) => item.visible).length);
  }

  function resizeCanvas() {
    const box = canvas.getBoundingClientRect();
    const ratio = Math.min(devicePixelRatio || 1, 2);
    canvas.width = Math.max(1, Math.round(box.width * ratio));
    canvas.height = Math.max(1, Math.round(box.height * ratio));
    context.setTransform(ratio, 0, 0, ratio, 0, 0);
  }
  new ResizeObserver(resizeCanvas).observe(canvas);

  function project(point) {
    const width = canvas.clientWidth;
    const height = canvas.clientHeight;
    const cosY = Math.cos(orbitYaw), sinY = Math.sin(orbitYaw);
    const x1 = point.x * cosY - point.z * sinY;
    const z1 = point.x * sinY + point.z * cosY;
    const cosP = Math.cos(orbitPitch), sinP = Math.sin(orbitPitch);
    const y2 = point.y * cosP - z1 * sinP;
    const depth = point.y * sinP + z1 * cosP;
    const scale = Math.min(width, height) * 0.205 * zoom;
    return { x: width * 0.5 + x1 * scale, y: height * 0.55 - y2 * scale, depth, scale };
  }

  function line3D(from, to, color, width = 1, dash = []) {
    const a = project(from), b = project(to);
    context.beginPath(); context.moveTo(a.x, a.y); context.lineTo(b.x, b.y);
    context.strokeStyle = color; context.lineWidth = width; context.setLineDash(dash); context.stroke(); context.setLineDash([]);
  }

  function drawGrid() {
    for (let index = -5; index <= 5; index += 1) {
      line3D({ x: index * 0.5, y: -0.65, z: 0.6 }, { x: index * 0.5, y: -0.65, z: -5 }, colors.line);
      line3D({ x: -2.5, y: -0.65, z: index * 0.5 }, { x: 2.5, y: -0.65, z: index * 0.5 }, colors.line);
    }
    line3D({ x: 0, y: -0.65, z: 0.6 }, { x: 0, y: -0.65, z: -5 }, colors.faint, 1.2);
  }

  function polygon(points, fill, stroke, lineWidth = 1) {
    const projected = points.map(project);
    context.beginPath();
    projected.forEach((point, index) => index ? context.lineTo(point.x, point.y) : context.moveTo(point.x, point.y));
    context.closePath(); context.fillStyle = fill; context.fill(); context.strokeStyle = stroke; context.lineWidth = lineWidth; context.stroke();
    return projected;
  }

  function drawWindow(item) {
    if (!item.visible) return;
    const { x, y, z } = item.position;
    const width = clamp(item.size.width, 0.25, 3);
    const height = clamp(item.size.height, 0.2, 2);
    const points = [
      { x: x - width / 2, y: y + height / 2, z }, { x: x + width / 2, y: y + height / 2, z },
      { x: x + width / 2, y: y - height / 2, z }, { x: x - width / 2, y: y - height / 2, z },
    ];
    const isHit = gazeTarget?.id === item.id;
    const projected = polygon(points, isHit ? "rgba(124,231,210,.15)" : "rgba(17,36,59,.76)", isHit ? colors.cyan : item.focused ? colors.blue : colors.line, isHit ? 2 : 1);
    const topLeft = projected[0], topRight = projected[1];
    context.beginPath(); context.moveTo(topLeft.x, topLeft.y); context.lineTo(topRight.x, topRight.y); context.strokeStyle = isHit ? colors.cyan : colors.faint; context.lineWidth = 3; context.stroke();
    context.fillStyle = colors.text; context.font = "600 11px ui-monospace, monospace"; context.fillText(item.title.slice(0, 24), topLeft.x + 7, topLeft.y + 15);
    context.fillStyle = colors.faint; context.font = "10px ui-monospace, monospace"; context.fillText(`${fixed(x, 2)} ${fixed(y, 2)} ${fixed(z, 2)} m`, topLeft.x + 7, topLeft.y + 29);
  }

  function drawDevice(position, type, label, color) {
    const point = project(position);
    context.save(); context.translate(point.x, point.y);
    context.strokeStyle = color; context.fillStyle = "rgba(7,17,31,.9)"; context.lineWidth = 2;
    if (type === "phone") { context.beginPath(); context.roundRect(-9, -17, 18, 34, 4); context.fill(); context.stroke(); context.beginPath(); context.moveTo(-3, -12); context.lineTo(3, -12); context.stroke(); }
    if (type === "watch") { context.strokeRect(-7, -8, 14, 16); context.beginPath(); context.moveTo(0, -17); context.lineTo(0, -8); context.moveTo(0, 8); context.lineTo(0, 17); context.stroke(); }
    if (type === "head") { context.beginPath(); context.arc(0, 0, 13, 0, Math.PI * 2); context.fill(); context.stroke(); context.beginPath(); context.arc(-15, 2, 3, 0, Math.PI * 2); context.arc(15, 2, 3, 0, Math.PI * 2); context.fillStyle = colors.cyan; context.fill(); }
    context.restore();
    context.fillStyle = colors.muted; context.font = "10px ui-monospace, monospace"; context.fillText(label, point.x + 16, point.y - 12);
  }

  function gazeIntersection(origin, direction) {
    let nearest = null;
    for (const item of snapshot.windows.filter((windowItem) => windowItem.visible)) {
      if (Math.abs(direction.z) < 0.0001) continue;
      const distance = (item.position.z - origin.z) / direction.z;
      if (distance <= 0) continue;
      const hit = { x: origin.x + direction.x * distance, y: origin.y + direction.y * distance, z: item.position.z };
      if (Math.abs(hit.x - item.position.x) <= item.size.width / 2 && Math.abs(hit.y - item.position.y) <= item.size.height / 2) {
        if (!nearest || distance < nearest.distance) nearest = { ...item, distance, hit };
      }
    }
    return nearest;
  }

  function drawGaze() {
    const origin = snapshot.devices.head.position;
    const pose = snapshot.sensors.head.orientation;
    const direction = gazeDirection(pose);
    gazeTarget = gazeIntersection(origin, direction);
    const length = gazeTarget?.distance || 5.2;
    const end = { x: origin.x + direction.x * length, y: origin.y + direction.y * length, z: origin.z + direction.z * length };
    line3D(origin, end, gazeTarget ? colors.cyan : colors.orange, 2, gazeTarget ? [] : [7, 6]);
    const point = project(end); context.beginPath(); context.arc(point.x, point.y, gazeTarget ? 5 : 3, 0, Math.PI * 2); context.fillStyle = gazeTarget ? colors.cyan : colors.orange; context.fill();
    gazeHit.textContent = gazeTarget?.title || "no hit";
    gazeChip.classList.toggle("hit", Boolean(gazeTarget));
  }

  function drawAxes() {
    const origin = { x: -2.15, y: -0.62, z: 0.35 };
    line3D(origin, { ...origin, x: origin.x + 0.35 }, colors.red, 2);
    line3D(origin, { ...origin, y: origin.y + 0.35 }, colors.green, 2);
    line3D(origin, { ...origin, z: origin.z - 0.35 }, colors.blue, 2);
    const p = project(origin); context.font = "9px ui-monospace, monospace"; context.fillStyle = colors.faint; context.fillText("XYZ", p.x - 8, p.y + 17);
  }

  function draw() {
    const width = canvas.clientWidth, height = canvas.clientHeight;
    context.clearRect(0, 0, width, height);
    const gradient = context.createRadialGradient(width * 0.5, height * 0.48, 20, width * 0.5, height * 0.48, Math.max(width, height) * 0.65);
    gradient.addColorStop(0, "rgba(24,57,82,.32)"); gradient.addColorStop(1, "rgba(4,12,23,0)"); context.fillStyle = gradient; context.fillRect(0, 0, width, height);
    drawGrid();
    [...snapshot.windows].sort((a, b) => a.position.z - b.position.z).forEach(drawWindow);
    drawGaze();
    drawDevice(snapshot.devices.head.position, "head", "HEAD + AIRPODS", colors.cyan);
    drawDevice(snapshot.devices.phone.position, "phone", "PHONE", colors.blue);
    drawDevice(snapshot.devices.watch.position, "watch", "WATCH", colors.orange);
    drawAxes();
    requestAnimationFrame(draw);
  }

  canvas.addEventListener("pointerdown", (event) => { canvas.setPointerCapture(event.pointerId); drag = { x: event.clientX, y: event.clientY, yaw: orbitYaw, pitch: orbitPitch }; });
  canvas.addEventListener("pointermove", (event) => { if (!drag) return; orbitYaw = drag.yaw + (event.clientX - drag.x) * 0.006; orbitPitch = clamp(drag.pitch + (event.clientY - drag.y) * 0.006, -0.2, 1.15); });
  canvas.addEventListener("pointerup", () => { drag = null; });
  canvas.addEventListener("pointercancel", () => { drag = null; });
  canvas.addEventListener("wheel", (event) => { event.preventDefault(); zoom = clamp(zoom * Math.exp(-event.deltaY * 0.001), 0.55, 2.2); }, { passive: false });

  renderInspector(); updateHUD(); resizeCanvas(); draw(); connect();
}

function renderDeviceSender() {
  app.innerHTML = `
    <main class="device-shell">
      <header class="device-header"><div class="brand">${brandMark}<div class="device-title"><h1>Device sender</h1><p>WebSocket sensor producer</p></div></div><span class="status" id="device-status"><span class="status-dot"></span><span id="device-status-label">offline</span></span></header>
      <div class="device-orbit"><div class="phone-glyph" id="phone-glyph" aria-label="Current phone orientation"></div></div>
      <div class="device-actions"><button class="primary" id="sensor-button">Enable sensors</button><button id="device-connect">Connect socket</button></div>
      <section class="device-card"><h2>Live orientation</h2><div class="metric-grid"><div class="metric"><label>yaw</label><output id="device-yaw">0.0°</output></div><div class="metric"><label>pitch</label><output id="device-pitch">0.0°</output></div><div class="metric"><label>roll</label><output id="device-roll">0.0°</output></div></div></section>
      <section class="device-card"><h2>Stream</h2><div class="metric-grid"><div class="metric"><label>rate</label><output>20 Hz</output></div><div class="metric"><label>windows</label><output id="device-windows">3</output></div><div class="metric"><label>sent</label><output id="device-sent">0</output></div></div><p class="device-note">This browser sender is for testing the debug station. The native app can use the same JSON protocol and send AirPods, Watch and real workspace data.</p></section>
      <section class="device-card"><h2>Test windows JSON</h2><textarea id="window-json" spellcheck="false" aria-label="Test window layout"></textarea><div class="device-actions" style="margin:10px 0 0"><button id="apply-windows">Apply layout</button><button id="recenter-device" class="ghost">Recenter</button></div></section>
    </main>`;
  setupDeviceSender();
}

function setupDeviceSender() {
  const status = document.getElementById("device-status");
  const statusLabel = document.getElementById("device-status-label");
  const connectButton = document.getElementById("device-connect");
  const sensorButton = document.getElementById("sensor-button");
  const glyph = document.getElementById("phone-glyph");
  const sampleWindows = [
    { id: "left", title: "Browser", position: { x: -1.15, y: 0.2, z: -3.1 }, size: { width: 1.4, height: 0.85 } },
    { id: "center", title: "Workspace", position: { x: 0, y: 0.35, z: -2.7 }, size: { width: 1.5, height: 0.9 }, focused: true },
    { id: "right", title: "Media", position: { x: 1.2, y: 0.15, z: -3.2 }, size: { width: 1.35, height: 0.8 } },
  ];
  let windows = sampleWindows;
  let ws;
  let sent = 0;
  let reference = null;
  let pose = { yaw: 0, pitch: 0, roll: 0 };
  let motion = { acceleration: { x: 0, y: 0, z: 0 }, accelerationIncludingGravity: { x: 0, y: 0, z: 0 }, rotationRate: { alpha: 0, beta: 0, gamma: 0 }, interval: 0 };
  const editor = document.getElementById("window-json");
  editor.value = JSON.stringify(sampleWindows, null, 2);

  function setStatus(state, label) { status.className = `status ${state}`; statusLabel.textContent = label; connectButton.textContent = state === "online" ? "Disconnect" : "Connect socket"; }
  function connect() {
    if (ws?.readyState === WebSocket.OPEN || ws?.readyState === WebSocket.CONNECTING) { ws.close(); return; }
    setStatus("", "connecting"); ws = new WebSocket(socketURL("device"));
    ws.addEventListener("open", () => setStatus("online", "streaming"));
    ws.addEventListener("close", () => setStatus("", "offline"));
    ws.addEventListener("error", () => setStatus("error", "socket error"));
  }

  function updatePose(event) {
    const raw = { yaw: Number(event.alpha) || 0, pitch: Number(event.beta) || 0, roll: Number(event.gamma) || 0 };
    if (!reference) reference = raw;
    pose = { yaw: ((raw.yaw - reference.yaw + 540) % 360) - 180, pitch: raw.pitch - reference.pitch, roll: raw.roll - reference.roll };
    document.getElementById("device-yaw").textContent = `${fixed(pose.yaw)}°`;
    document.getElementById("device-pitch").textContent = `${fixed(pose.pitch)}°`;
    document.getElementById("device-roll").textContent = `${fixed(pose.roll)}°`;
    glyph.style.setProperty("--phone-yaw", `${clamp(pose.yaw, -40, 40)}deg`);
    glyph.style.setProperty("--phone-pitch", `${clamp(-pose.pitch, -40, 40)}deg`);
    glyph.style.setProperty("--phone-roll", `${clamp(pose.roll, -40, 40)}deg`);
  }

  function updateMotion(event) {
    motion = {
      acceleration: vector(event.acceleration),
      accelerationIncludingGravity: vector(event.accelerationIncludingGravity),
      rotationRate: { alpha: Number(event.rotationRate?.alpha) || 0, beta: Number(event.rotationRate?.beta) || 0, gamma: Number(event.rotationRate?.gamma) || 0 },
      interval: Number(event.interval) || 0,
    };
  }

  async function enableSensors() {
    try {
      if (typeof DeviceOrientationEvent?.requestPermission === "function") {
        const result = await DeviceOrientationEvent.requestPermission();
        if (result !== "granted") throw new Error("Orientation permission denied");
      }
      if (typeof DeviceMotionEvent?.requestPermission === "function") {
        const result = await DeviceMotionEvent.requestPermission();
        if (result !== "granted") throw new Error("Motion permission denied");
      }
      window.addEventListener("deviceorientation", updatePose);
      window.addEventListener("devicemotion", updateMotion);
      sensorButton.textContent = "Sensors enabled"; sensorButton.disabled = true;
    } catch (error) { sensorButton.textContent = error.message; }
  }

  setInterval(() => {
    if (ws?.readyState !== WebSocket.OPEN) return;
    const now = Date.now();
    ws.send(JSON.stringify({
      type: "snapshot", timestamp: now,
      device: { id: navigator.userAgent.includes("iPhone") ? "iphone-web" : "browser-device", name: "Phone sensor page", platform: navigator.platform },
      sensors: {
        head: { orientation: pose, source: "deviceOrientation" },
        phone: { orientation: pose, ...motion },
        watch: { connected: false, orientation: { yaw: 0, pitch: 0, roll: 0 } },
      },
      devices: { head: { position: { x: 0, y: 0.35, z: 0 } }, phone: { position: { x: 0.86, y: -0.42, z: 0.24 } }, watch: { position: { x: -0.72, y: -0.4, z: 0.15 } } },
      windows,
    }));
    sent += 1; document.getElementById("device-sent").textContent = String(sent);
  }, 50);

  connectButton.addEventListener("click", connect);
  sensorButton.addEventListener("click", enableSensors);
  document.getElementById("recenter-device").addEventListener("click", () => { reference = null; });
  document.getElementById("apply-windows").addEventListener("click", () => {
    try { const value = JSON.parse(editor.value); if (!Array.isArray(value)) throw new Error("Expected array"); windows = value; document.getElementById("device-windows").textContent = String(windows.length); editor.setCustomValidity(""); }
    catch (error) { editor.setCustomValidity(error.message); editor.reportValidity(); }
  });
  connect();
}

if ("serviceWorker" in navigator && location.protocol !== "file:") navigator.serviceWorker.register("/sw.js").catch(() => {});
if (mode === "device" || mode === "phone") renderDeviceSender(); else renderViewer();
