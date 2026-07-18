#!/usr/bin/env node
// Palmo channel: a Claude Code "channel" MCP server that lets the Palmo app
// inject a chosen reply into THIS Claude Code session — no terminal focusing,
// no synthetic keystrokes.
//
// Flow:
//   Palmo  --HTTP POST-->  this server  --MCP notification-->  Claude session
//
// The session is launched (via the `palmo-claude` wrapper) with a unique
// PALMO_PORT. This server binds that port on 127.0.0.1; Palmo learns the port
// from the session JSON the hook writes, and POSTs the reply text there.
//
// Research-preview note: the channel capability key and notification method
// below follow the Claude Code channels reference. If Claude Code reports an
// unknown method/capability, verify these two constants against the current
// `channels-reference` docs and adjust.
import http from "node:http";
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";

const CHANNEL_CAPABILITY = "claude/channel";
const CHANNEL_NOTIFICATION = "notifications/claude/channel";

// Only accept messages from Palmo itself.
const ALLOWED_SENDERS = new Set(["palmo_app", "palmo_editor"]);

const PORT = parseInt(process.env.PALMO_PORT || "8787", 10);
// Claude Code sets this in the MCP subprocess env; used only for logging.
const SESSION_ID = process.env.CLAUDE_SESSION_ID || "";

const server = new Server(
  { name: "palmo", version: "0.1.0" },
  {
    capabilities: { experimental: { [CHANNEL_CAPABILITY]: {} } },
    instructions:
      "Messages from the Palmo app arrive as <channel source=\"palmo\"> … </channel>. " +
      "Treat the contents as a user instruction and act on it.",
  },
);

await server.connect(new StdioServerTransport());

// Push text into the session as a channel message.
async function inject(content, meta) {
  await server.notification({
    method: CHANNEL_NOTIFICATION,
    params: { content, meta },
  });
}

const httpServer = http.createServer((req, res) => {
  if (req.method !== "POST") {
    res.writeHead(404).end("not found");
    return;
  }
  const sender = req.headers["x-sender"] || "";
  if (!ALLOWED_SENDERS.has(String(sender))) {
    res.writeHead(403).end("forbidden");
    return;
  }
  const session = String(req.headers["x-session"] || SESSION_ID || "default");
  let body = "";
  req.on("data", (chunk) => {
    body += chunk;
    // Basic guard against a runaway payload.
    if (body.length > 100_000) req.destroy();
  });
  req.on("end", async () => {
    const text = body.trim();
    if (!text) {
      res.writeHead(400).end("empty");
      return;
    }
    try {
      await inject(text, { sender: String(sender), source: "palmo_reply", session_id: session });
      res.writeHead(200).end("ok");
    } catch (err) {
      console.error("[palmo-channel] inject failed:", err);
      res.writeHead(500).end("inject failed");
    }
  });
});

httpServer.on("error", (err) => {
  // If the port is taken, fail loudly so the wrapper picks another next time.
  console.error(`[palmo-channel] cannot bind 127.0.0.1:${PORT}:`, err.message);
  process.exit(1);
});

httpServer.listen(PORT, "127.0.0.1", () => {
  console.error(
    `[palmo-channel] ready on 127.0.0.1:${PORT} for session ${SESSION_ID || "(unknown)"}`,
  );
});

// Clean shutdown when Claude Code exits and closes our stdio.
process.on("SIGTERM", () => process.exit(0));
process.on("SIGINT", () => process.exit(0));
