# rex-revive

Bring back the coding agents in your [Rex](https://www.superlogical.com/rex) tabs after the Rex server restarts.

Rex restores your sessions, tabs, and splits after a restart, but every tab comes back as an empty shell. rex-revive remembers what ran in each tab and puts it back:

| Running in the tab | After a restart |
| --- | --- |
| Claude Code | Reopens on its conversation: `claude --resume <id>` |
| Codex | Reopens on its conversation: `codex resume <id>` |
| pi | Reopens on its session: `pi --session <id>` |
| Any other program | Typed at the prompt, not run. Press Enter if you want it. |
| An idle shell | Left alone |

Chats come back in the same tab and split, in the same folder, with their options such as `--model`. Any number of chats can share one folder: each one comes back on its own conversation.

## Install

```sh
git clone https://github.com/Snowyyyyyy1/rex-revive
cd rex-revive
./install.sh --add-to-config --pi
```

- `--add-to-config` loads the command palette actions from Rex's `init.lua`.
- `--pi` installs a small pi extension (see [pi](#pi)). Leave it out if you don't use pi.
- `--no-service` copies the files without starting the watcher.

The installer copies rex-revive to `~/Library/Application Support/rex-revive/app` (macOS) or `~/.local/share/rex-revive` (Linux) and starts it as a login service: a launchd agent, or a systemd user service. Run `./install.sh` again to update.

Requirements: Rex with a recent Lua API (control API revision 17 or later for **Choose Chats to Reopen…**), and `lsof`.

## Using it

There is nothing to do day to day. rex-revive saves what runs in each tab a few seconds after any change, and at least once a minute. When the Rex server starts again, it brings everything back within seconds and shows a notification such as "Reopened 6 chats."

From the command palette (search for "revive"):

- **Choose Chats to Reopen…** lists the saved chats that aren't open, all ticked, and reopens the ones you keep ticked.
- **Reopen Chats and Programs in Their Tabs** brings back everything at once.
- **Save Open Chats and Programs Now** saves right away.

From a terminal:

```sh
S="$HOME/Library/Application Support/rex-revive/app/revive.lua"   # Linux: ~/.local/share/rex-revive/revive.lua

rex do "$S" mode=status                      # what is saved, and the last restore
rex do "$S" mode=save                        # save now
rex do "$S" mode=restore dry_run=true        # show what a restore would type
rex do "$S" mode=restore                     # bring back what isn't running
rex do "$S" mode=restore only=claude:ID      # bring back just these chats (agent:id, comma separated)
rex do "$S" mode=restore programs=false      # chats only, no other programs
rex do "$S" mode=choices                     # the chats a restore would bring back, as JSON
```

## How it works

Rex keeps each tab's block ID across a restart. rex-revive records, per block, what runs in it, and after a restart types the right command into the same block.

**Which conversation is a chat on?**

- **Claude Code** writes `~/.claude/sessions/<pid>.json` for each running chat, with its session ID.
- **pi** writes nothing of the kind and hides its command line, so the extension (`install.sh --pi`) writes `~/.pi/agent/rex-revive/<pid>.json` the same way, with pi's options.
- **Codex** holds its session file, `~/.codex/sessions/…/rollout-…-<id>.jsonl`, open while it runs.
- Failing those, the session named on the command line (`--resume <id>`, `resume <id>`, `--session <id>`).

A pid can be reused, so a pid record only counts when its start time matches the process's own. A chat whose conversation isn't certain comes back typed, not run.

**Safety**

- It only types into a tab that sits at an idle shell. A busy tab is left alone.
- It never opens a chat twice: not if it already runs in a Rex tab, and not if it runs anywhere else on the machine.
- It restores once per server start. Running it again on the same server only saves.
- Programs other than chats are typed, never run.
- A save older than 30 days is never restored on its own.
- `dry_run=true` shows what a restore would do, without doing it.

## pi

pi hides which session it is on: it keeps no file open and blanks its command line. Without the extension, rex-revive sees that a tab runs pi, but not which session, so pi comes back typed as `pi`, not resumed.

The extension is about 50 lines ([integrations/pi-rex-revive.ts](integrations/pi-rex-revive.ts)). It writes one small JSON file per running pi and removes it when pi quits. It makes no network calls and prints nothing. pi chats started before you install it aren't covered.

## Limits

- A chat that was in the middle of a reply reopens, but the reply in progress is gone.
- Only this machine's tabs are saved. For a remote Rex server, install rex-revive on that machine.
- A chat that you moved out of Rex, or that ran elsewhere while Rex restarted, isn't brought into Rex: its tab is an idle shell now, and the saves say so.
- On macOS, `ps` gives a command line as one string, so an option value with a space in it (`--add-dir "My Projects"`) is cut at the space when a chat reopens. pi is not affected: its extension records the exact options.
- The saves hold the command line of each program in your tabs, as your shell history does. A secret passed as an argument is saved with it.

## Uninstall

```sh
./uninstall.sh          # stop the service, remove the files and the pi extension; keep the saves
./uninstall.sh --purge  # remove the saves too
```

If you added `require("rex_revive")` to `init.lua`, remove that line too.

## Development

```sh
test/e2e.sh          # unit tests, then end-to-end tests on a throwaway Rex server
test/e2e.sh --unit   # unit tests only
```

The end-to-end test needs Rex, `jq`, and a C compiler. It runs its own Rex server on its own socket, with fake agents in a throwaway home folder, and never touches your Rex server or your chats.

## Acknowledgements

The idea comes from [fazxes/rex-durable](https://github.com/fazxes/rex-durable). rex-revive is a separate implementation.

rex-revive is not made by or affiliated with Superlogical.

## License

[MIT](LICENSE)
