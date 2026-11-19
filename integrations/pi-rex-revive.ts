/**
 * [INPUT]: depends on pi's extension API (session_start, session_shutdown, ctx.sessionManager); node:fs, os, path
 * [OUTPUT]: default export, a pi extension that writes ~/.pi/agent/rex-revive/<pid>.json
 * [POS]: the pi side of rex-revive's pid records. lib/agents.lua reads these records the same
 *        way it reads Claude Code's ~/.claude/sessions/<pid>.json. install.sh --pi installs it.
 * [PROTOCOL]: Update this header on change, then check CLAUDE.md
 *
 * pi keeps no file open and hides its command line from ps, so nothing outside
 * pi can tell which session a running pi is on. For each interactive pi this
 * writes {"pid", "sessionId", "sessionFile", "cwd", "startedAt" (ms), "argv"},
 * rewrites it on /new, /resume, and /fork, and removes it when pi quits.
 * It does nothing else: no network, no output, no change to pi.
 */

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const dir = path.join(os.homedir(), ".pi", "agent", "rex-revive");
const file = path.join(dir, `${process.pid}.json`);
// When this process started; rex-revive checks it against ps, as pids are reused.
const startedAt = Date.now() - Math.round(process.uptime() * 1000);
// pi's options, such as --model, which pi hides from ps once it runs.
const argv = process.argv.slice(2);

function remove(): void {
  try {
    fs.rmSync(file, { force: true });
  } catch {
    // Nothing to remove.
  }
}

function record(ctx: any): void {
  try {
    const sessionId = ctx?.sessionManager?.getSessionId?.();
    const sessionFile = ctx?.sessionManager?.getSessionFile?.();
    // A session that isn't saved (--no-session) can't be reopened.
    if (typeof sessionId !== "string" || typeof sessionFile !== "string") return remove();
    fs.mkdirSync(dir, { recursive: true });
    const data = { pid: process.pid, sessionId, sessionFile, cwd: process.cwd(), startedAt, argv };
    fs.writeFileSync(`${file}.tmp`, JSON.stringify(data) + "\n");
    fs.renameSync(`${file}.tmp`, file);
  } catch {
    // Never get in pi's way.
  }
}

export default function (pi: any) {
  pi.on("session_start", (_event: any, ctx: any) => {
    // Only a pi someone works in, not pi -p or other runs without a UI.
    if (ctx?.hasUI) record(ctx);
  });
  pi.on("session_shutdown", (event: any) => {
    if (event?.reason === "quit") remove();
  });
}
