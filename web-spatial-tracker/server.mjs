import { createHash } from "node:crypto";
import { createServer } from "node:http";
import { readFile, stat } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import { hostname, networkInterfaces } from "node:os";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("./public/", import.meta.url));
const port = Number(process.env.PORT || 4173);
const host = process.env.HOST || "0.0.0.0";
const sockets = new Map();
let latestSnapshot = null;
let nextClientID = 1;

const mimeTypes = {
  ".css": "text/css; charset=utf-8",
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".webmanifest": "application/manifest+json; charset=utf-8",
};

function sendJson(response, status, body) {
  response.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
  });
  response.end(JSON.stringify(body));
}

function encodeFrame(payload, opcode = 0x1) {
  const body = Buffer.from(payload);
  let header;
  if (body.length < 126) {
    header = Buffer.from([0x80 | opcode, body.length]);
  } else if (body.length <= 65_535) {
    header = Buffer.alloc(4);
    header[0] = 0x80 | opcode;
    header[1] = 126;
    header.writeUInt16BE(body.length, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x80 | opcode;
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(body.length), 2);
  }
  return Buffer.concat([header, body]);
}

function send(socket, value) {
  if (!socket.destroyed && socket.writable) {
    const payload = typeof value === "string" ? value : JSON.stringify(value);
    socket.write(encodeFrame(payload));
  }
}

function broadcast(value, predicate = () => true) {
  const payload = JSON.stringify(value);
  for (const [socket, client] of sockets) {
    if (predicate(client)) send(socket, payload);
  }
}

function clientCounts() {
  const counts = { device: 0, viewer: 0 };
  for (const client of sockets.values()) counts[client.role] = (counts[client.role] || 0) + 1;
  return counts;
}

function statusMessage() {
  return { type: "server.status", clients: clientCounts(), timestamp: Date.now() };
}

function handleText(socket, client, text) {
  let message;
  try {
    message = JSON.parse(text);
  } catch {
    send(socket, { type: "server.error", error: "Expected a JSON WebSocket message" });
    return;
  }

  const envelope = {
    ...message,
    sourceClient: client.id,
    sourceRole: client.role,
    serverReceivedAt: Date.now(),
  };

  if (client.role === "device") {
    if (message.type === "snapshot" || message.sensors || message.windows || message.devices) {
      latestSnapshot = envelope;
    }
    broadcast(envelope, (target) => target.role === "viewer");
  } else {
    broadcast(envelope, (target) => target.role === "device");
  }
}

function consumeFrames(socket, client, incoming) {
  client.buffer = Buffer.concat([client.buffer, incoming]);

  while (client.buffer.length >= 2) {
    const first = client.buffer[0];
    const second = client.buffer[1];
    const opcode = first & 0x0f;
    const masked = Boolean(second & 0x80);
    let length = second & 0x7f;
    let offset = 2;

    if (length === 126) {
      if (client.buffer.length < 4) return;
      length = client.buffer.readUInt16BE(2);
      offset = 4;
    } else if (length === 127) {
      if (client.buffer.length < 10) return;
      const longLength = client.buffer.readBigUInt64BE(2);
      if (longLength > 1_048_576n) {
        socket.end(encodeFrame("Message too large", 0x8));
        return;
      }
      length = Number(longLength);
      offset = 10;
    }

    const maskBytes = masked ? 4 : 0;
    if (client.buffer.length < offset + maskBytes + length) return;
    const mask = masked ? client.buffer.subarray(offset, offset + 4) : null;
    offset += maskBytes;
    const payload = Buffer.from(client.buffer.subarray(offset, offset + length));
    client.buffer = client.buffer.subarray(offset + length);

    if (mask) {
      for (let index = 0; index < payload.length; index += 1) payload[index] ^= mask[index % 4];
    }

    if (opcode === 0x8) {
      socket.end(encodeFrame("", 0x8));
      return;
    }
    if (opcode === 0x9) {
      socket.write(encodeFrame(payload, 0x0a));
      continue;
    }
    if (opcode === 0x1) handleText(socket, client, payload.toString("utf8"));
  }
}

async function serveStatic(pathname, response) {
  const requested = pathname === "/" ? "index.html" : pathname.slice(1);
  const safePath = normalize(requested).replace(/^(\.\.(\/|\\|$))+/, "");
  let filePath = join(root, safePath);
  if (!filePath.startsWith(root)) {
    sendJson(response, 403, { error: "Forbidden" });
    return;
  }

  try {
    if ((await stat(filePath)).isDirectory()) filePath = join(filePath, "index.html");
    const data = await readFile(filePath);
    response.writeHead(200, {
      "content-type": mimeTypes[extname(filePath)] || "application/octet-stream",
      "cache-control": extname(filePath) === ".html" ? "no-cache" : "public, max-age=3600",
    });
    response.end(data);
  } catch {
    sendJson(response, 404, { error: "Not found" });
  }
}

const server = createServer(async (request, response) => {
  const url = new URL(request.url || "/", `http://${request.headers.host || "localhost"}`);
  if (url.pathname === "/api/health") {
    sendJson(response, 200, { ok: true, clients: clientCounts(), hasSnapshot: Boolean(latestSnapshot) });
    return;
  }
  await serveStatic(url.pathname, response);
});

server.on("upgrade", (request, socket) => {
  const url = new URL(request.url || "/", `http://${request.headers.host || "localhost"}`);
  const key = request.headers["sec-websocket-key"];
  if (url.pathname !== "/ws" || !key || request.headers.upgrade?.toLowerCase() !== "websocket") {
    socket.end("HTTP/1.1 400 Bad Request\r\n\r\n");
    return;
  }

  const role = url.searchParams.get("role") === "device" ? "device" : "viewer";
  const id = (url.searchParams.get("id") || `${role}-${nextClientID++}`).slice(0, 64);
  const accept = createHash("sha1")
    .update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`)
    .digest("base64");
  socket.write([
    "HTTP/1.1 101 Switching Protocols",
    "Upgrade: websocket",
    "Connection: Upgrade",
    `Sec-WebSocket-Accept: ${accept}`,
    "\r\n",
  ].join("\r\n"));

  const client = { id, role, buffer: Buffer.alloc(0), connectedAt: Date.now() };
  sockets.set(socket, client);
  send(socket, { type: "server.hello", client: { id, role }, timestamp: Date.now() });
  if (role === "viewer" && latestSnapshot) send(socket, latestSnapshot);
  broadcast(statusMessage());

  socket.on("data", (chunk) => consumeFrames(socket, client, chunk));
  socket.on("error", () => socket.destroy());
  socket.on("close", () => {
    sockets.delete(socket);
    broadcast(statusMessage());
  });
});

server.listen(port, host, () => {
  const localHostname = hostname().includes(".") ? hostname() : `${hostname()}.local`;
  const addresses = new Set([`http://localhost:${port}`, `http://${localHostname}:${port}`]);
  for (const group of Object.values(networkInterfaces())) {
    for (const item of group || []) {
      if (item.family === "IPv4" && !item.internal) addresses.add(`http://${item.address}:${port}`);
    }
  }
  console.log("Extend Reality debug station:");
  for (const address of addresses) {
    console.log(`  Debug UI:     ${address}`);
    console.log(`  Phone sender: ${address}/?mode=device`);
    console.log(`  Device WS:    ${address.replace("http", "ws")}/ws?role=device&id=iphone`);
  }
});

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => server.close(() => process.exit(0)));
}
