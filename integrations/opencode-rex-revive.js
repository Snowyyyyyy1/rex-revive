/**
 * [INPUT]: depends on opencode's TUI plugin API (api.ui.router.current(), api.data.session.root());
 *          node:fs, os, path
 * [OUTPUT]: default export, an opencode TUI plugin that writes
 *           ~/.local/share/opencode/rex-revive/<pid>.json
 * [POS]: the opencode side of rex-revive's pid records. lib/agents.lua reads these records the
 *        same way it reads Claude Code's ~/.claude/sessions/<pid>.json. install.sh --opencode
 *        copies it to ~/.config/opencode/plugins/rex-revive/tui.js, where opencode loads TUI plugins.
 * [PROTOCOL]: Update this header on change, then check CLAUDE.md
 *
 * opencode keeps no file per session open, and its sessions live in one shared
 * database, so nothing outside it can tell which session a running opencode
 * shows. A TUI plugin runs in the opencode process the person started (checked
 * against opencode 2.3.2: process.pid is the TUI's pid) and can read the TUI's
 * route. This checks the route every second and writes {"pid", "sessionId",
 * "startedAt" (ms)} when the session shown changes, removes it when no session
 * is shown, and when the plugin stops. No network, no output, no change to opencode.
 */

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const DIR = path.join(os.homedir(), ".local", "share", "opencode", "rex-revive");
const TICK_MS = 1000;

export default {
  id: "rex-revive",
  setup(api) {
    const router = api?.ui?.router;
    if (typeof router?.current !== "function") return;
    const file = path.join(DIR, `${process.pid}.json`);
    // When this process started; rex-revive checks it against ps, as pids are reused.
    const startedAt = Date.now() - Math.round(process.uptime() * 1000);
    let recorded = "";

    // The session shown; a subagent's session counts as the session that started it.
    const shown = () => {
      const route = router.current();
      if (route?.type !== "session" || typeof route.sessionID !== "string") return "";
      try {
        return api.data.session.root(route.sessionID) || route.sessionID;
      } catch {
        return route.sessionID;
      }
    };

    const remove = () => fs.rmSync(file, { force: true });

    // Forget the records of opencodes that quit.
    const sweep = () => {
      for (const name of fs.readdirSync(DIR)) {
        const pid = Number(name.replace(/\.json$/, ""));
        if (!Number.isInteger(pid) || pid === process.pid) continue;
        try {
          process.kill(pid, 0);
        } catch {
          fs.rmSync(path.join(DIR, name), { force: true });
        }
      }
    };

    const tick = () => {
      try {
        const id = shown();
        if (id === recorded) return;
        if (id) {
          fs.mkdirSync(DIR, { recursive: true });
          fs.writeFileSync(`${file}.tmp`, JSON.stringify({ pid: process.pid, sessionId: id, startedAt }) + "\n");
          fs.renameSync(`${file}.tmp`, file);
          sweep();
        } else {
          remove();
        }
        recorded = id;
      } catch {
        // Never get in opencode's way.
      }
    };

    tick();
    const timer = setInterval(tick, TICK_MS);
    timer.unref?.();
    return () => {
      clearInterval(timer);
      try {
        remove();
      } catch {
        // Nothing to remove.
      }
    };
  },
};
