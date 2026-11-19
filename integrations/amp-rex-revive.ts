// @i-know-the-amp-plugin-api-is-wip-and-very-experimental-right-now
/**
 * [INPUT]: depends on amp's plugin API (session.start and agent.start events, event.thread.id);
 *          node:child_process (ps), fs, os, path
 * [OUTPUT]: default export, an amp plugin that writes ~/.local/share/amp/rex-revive/<amp pid>.json
 * [POS]: the amp side of rex-revive's pid records. lib/agents.lua reads these records the same
 *        way it reads Claude Code's ~/.claude/sessions/<pid>.json. install.sh --amp copies it
 *        to ~/.config/amp/plugins/rex-revive.ts.
 * [PROTOCOL]: Update this header on change, then check CLAUDE.md
 *
 * amp keeps no file open and no record of its own, so nothing outside amp can
 * tell which thread a running amp is on. This writes {"pid", "threadId" as
 * "sessionId", "startedAt" (ms)} when a session starts and whenever the thread
 * changes, and removes it when the plugin stops. The first line is the marker
 * amp requires of a plugin. No network, no output, no change to amp.
 *
 * amp runs its plugins in a child process (amp .../plugin-runtime.ts PLUGIN), so
 * the amp the person started, the one Rex sees in the tab, is the parent:
 * the record is the parent's pid, and when ps says it started.
 */

import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const dir = path.join(os.homedir(), ".local", "share", "amp", "rex-revive");
const amp = process.ppid;
const file = path.join(dir, `${amp}.json`);
let startedAt: number | undefined;
let recorded = "";

// ps prints elapsed time as [[dd-]hh:]mm:ss.
function seconds(etime: string): number {
  const [days, rest] = etime.includes("-") ? etime.split("-") : ["0", etime];
  return Number(days) * 86400 + rest.split(":").reduce((s, n) => s * 60 + Number(n), 0);
}

// When amp started; rex-revive checks it against ps, as pids are reused.
function ampStartedAt(): number {
  const etime = execFileSync("ps", ["-o", "etime=", "-p", String(amp)], { encoding: "utf8" }).trim();
  const age = seconds(etime);
  if (!etime || !Number.isFinite(age)) throw new Error(`no age for pid ${amp}`);
  return Date.now() - age * 1000;
}

function remove(): void {
  try {
    fs.rmSync(file, { force: true });
  } catch {
    // Nothing to remove.
  }
}

// Forget the records of amps that quit.
function sweep(): void {
  for (const name of fs.readdirSync(dir)) {
    const pid = Number(name.replace(/\.json$/, ""));
    if (!Number.isInteger(pid) || pid === amp) continue;
    try {
      process.kill(pid, 0);
    } catch {
      fs.rmSync(path.join(dir, name), { force: true });
    }
  }
}

function record(threadId: unknown): void {
  if (typeof threadId !== "string" || !threadId.startsWith("T-") || threadId === recorded) return;
  try {
    startedAt ??= ampStartedAt();
    fs.mkdirSync(dir, { recursive: true });
    const data = { pid: amp, sessionId: threadId, startedAt };
    fs.writeFileSync(`${file}.tmp`, JSON.stringify(data) + "\n");
    fs.renameSync(`${file}.tmp`, file);
    recorded = threadId;
    sweep();
  } catch {
    // Never get in amp's way.
  }
}

export default function (api: any) {
  const thread = (event: any) => record(event?.thread?.id ?? api?.threadId);
  api.on("session.start", thread);
  // A new or continued thread in the same amp shows here first.
  api.on("agent.start", thread);
  process.on("exit", remove);
}
