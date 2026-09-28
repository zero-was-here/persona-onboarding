// Tiny WebSocket bridge for the Swift call simulator (FoundationNetworking on Linux has no WebSockets).
// stdin: one JSON client event per line → server.  stdout: one JSON server event per line.
// Audio deltas are replaced by their byte count (the simulator only needs durations).
//
//   OPENAI_API_KEY=... node harness/ws-bridge.mjs gpt-realtime-2.1
import WebSocket from "ws";
import readline from "node:readline";

const model = process.argv[2] || "gpt-realtime-2.1";
const ws = new WebSocket(`wss://api.openai.com/v1/realtime?model=${model}`, {
  headers: { Authorization: `Bearer ${process.env.OPENAI_API_KEY}` },
});
const out = (o) => process.stdout.write(JSON.stringify(o) + "\n");
const pending = [];
let open = false;

ws.on("open", () => {
  open = true;
  for (const m of pending) ws.send(m);
  pending.length = 0;
  out({ type: "bridge.open" });
});
ws.on("message", (data) => {
  let e;
  try { e = JSON.parse(data.toString()); } catch { return; }
  if (e.type === "response.output_audio.delta" && typeof e.delta === "string") {
    e.bytes = Buffer.from(e.delta, "base64").length;
    delete e.delta;
  }
  out(e);
});
ws.on("close", (code, reason) => { out({ type: "bridge.closed", code, reason: reason.toString() }); process.exit(0); });
ws.on("error", (err) => out({ type: "bridge.error", message: String(err && err.message) }));

const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
rl.on("line", (line) => {
  if (line === "__close__") { ws.close(1000); return; }
  if (open) ws.send(line); else pending.push(line);
});
rl.on("close", () => { try { ws.close(1000); } catch {} });
