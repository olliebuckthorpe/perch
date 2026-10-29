// Long-lived bridge between Perch and the Grok Bot host.
//
// Perch used to launch the grokbot CLI for every action, which cost a second or more each
// time. This stays running instead: it reuses the CLI's own gateway client (so sign-in and
// the private host API stay the plugin's concern) and answers requests over stdin/stdout.
//
//   in : {"id": 1, "command": "listAgents", "body": {}}        one JSON object per line
//   out: {"id": 1, "ok": true, "data": ...} | {"id": 1, "ok": false, "error": "..."}
//   out: {"event": true}                                        whenever the host reports activity
import readline from "node:readline";
import { pathToFileURL } from "node:url";

const src = process.argv[2];
const { Gateway } = await import(pathToFileURL(`${src}/gateway.js`));
const session = await import(pathToFileURL(`${src}/session.js`));
const { resolveGatewaySession } = session;
const { CursorClient } = await import(pathToFileURL(`${src}/cursor.js`));
import { readFileSync, appendFileSync } from "node:fs";

// What went wrong, for working out why a message did not get through. Never the keys.
const logPath = `${process.env.HOME}/.perch/grok-bridge.log`;
const log = (line) => {
  try { appendFileSync(logPath, `${new Date().toISOString()} ${session.redact(String(line))}\n`); } catch {}
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Grok Bot 0.70 saves its connection in a newer file format the plugin does not read yet; the
// entries inside are the same. Used when the usual route (asking Cursor for a fresh one) fails.
function appSession() {
  const wrapped = JSON.parse(readFileSync(session.descriptorPath(), "utf8"));
  return session.parseDescriptorFile({ ...wrapped, version: 2 });
}

const out = (o) => process.stdout.write(JSON.stringify(o) + "\n");
let gw = null;

async function gateway() {
  if (!gw) {
    // The app's own saved connection first: it is what the app itself is using right now.
    // Asking Cursor for a fresh one is the fallback (it has been refusing since the app update).
    let found;
    try { found = appSession(); } catch { found = await resolveGatewaySession({}); }
    gw = new Gateway(found, { timeoutMs: 30_000 });
  }
  return gw;
}

// The cloud box goes to sleep when it has been idle, and until now only opening the Grok Bot
// app woke it, so a message sent from the notch first thing sat there undelivered. Ask Cursor
// whether it is running and start it if not, the way the app does on launch.
const RUNNING = "SAND_BOX_RUN_STATE_RUNNING";
async function wake() {
  let auth;
  try { auth = session.loadCursorAuth({}); } catch (err) { log(`wake: no sign-in: ${err?.message ?? err}`); return false; }
  if (!auth?.accessToken) return false;
  const cursor = new CursorClient(auth);
  for (let i = 0; i < 40; i++) {
    const state = (await cursor.runState().catch((err) => { log(`wake: run state: ${err?.message ?? err}`); return null; }))?.state;
    if (state === RUNNING) {
      if (i > 0) log(`wake: box running after ${i * 3}s`);
      return true;
    }
    if (i === 0) {
      log(`wake: box is ${state ?? "unknown"}, starting it`);
      try { gw = new Gateway(await session.ensureSandBox(auth), { timeoutMs: 30_000 }); }
      catch (err) { log(`wake: EnsureSandBox: ${err?.message ?? err}`); }
    }
    await sleep(3000);
  }
  log("wake: box still not running after two minutes");
  return false;
}

async function call(command, body) {
  if (command === "sendPrompt") await wake();
  try {
    return await (await gateway()).call(command, body);
  } catch (err) {
    log(`${command}: ${err?.message ?? err}`);
    // The stored session can go stale (app restart, token refresh). Re-read it once.
    gw = null;
    try {
      return await (await gateway()).call(command, body);
    } catch (again) {
      // Still failing: the box may be asleep. Wake it and try once more.
      log(`${command} again: ${again?.message ?? again}`);
      if (!(await wake())) throw again;
      return await (await gateway()).call(command, body);
    }
  }
}

readline.createInterface({ input: process.stdin }).on("line", async (line) => {
  let req;
  try { req = JSON.parse(line); } catch { return; }
  try {
    out({ id: req.id, ok: true, data: await call(req.command, req.body ?? {}) });
  } catch (err) {
    out({ id: req.id, ok: false, error: String(err?.message ?? err) });
  }
}).on("close", () => process.exit(0));

for (;;) {
  try {
    for await (const _ of (await gateway()).events()) out({ event: true });
  } catch {}
  gw = null;
  await new Promise((r) => setTimeout(r, 8000));
}
