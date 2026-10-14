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
import { readFileSync } from "node:fs";

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
    let found;
    try { found = await resolveGatewaySession({}); } catch (err) { found = appSession(); }
    gw = new Gateway(found, { timeoutMs: 30_000 });
  }
  return gw;
}

async function call(command, body) {
  try {
    return await (await gateway()).call(command, body);
  } catch (err) {
    // The stored session can go stale (app restart, token refresh). Re-read it once.
    gw = null;
    return await (await gateway()).call(command, body);
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
