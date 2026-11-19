/*
 * A stand-in for a coding agent in test/e2e.sh, built once per agent:
 *
 *   cc -DAGENT='"claude"' -DHOME_DIR='"/tmp/home"' -DHOOK='"integrations/agent-hook.sh"' \
 *      -o bin/claude test/fake_agent.c
 *
 * It leaves the traces the real agent leaves, then waits for a signal:
 *
 *   claude  HOME_DIR/.claude/sessions/<pid>.json  {"pid","sessionId","startedAt"}
 *           (none with --no-record, like an older Claude Code)
 *   codex   holds HOME_DIR/.codex/sessions/2026/11/19/rollout-<time>-<id>.jsonl open
 *   pi      HOME_DIR/.pi/agent/rex-revive/<pid>.json with its options, when the
 *           pi extension is installed; then blanks its arguments, as pi does
 *   gemini, droid  runs HOOK as their SessionStart hook does: sh HOOK AGENT, with
 *           {"session_id"} on stdin and HOME set to HOME_DIR
 *   amp     HOME_DIR/.local/share/amp/rex-revive/<pid>.json, when the amp plugin
 *           is installed; its threads are T-<uuid>
 *   cursor-agent  holds HOME_DIR/.cursor/chats/<md5>/<id>/store.db open
 *   opencode  HOME_DIR/.local/share/opencode/rex-revive/<pid>.json, when the opencode
 *           TUI plugin is installed; its sessions are ses_<letters and digits>
 *
 * The session is the one on the command line (--resume ID, -r ID, resume ID,
 * --session ID, continue ID), else a new one made from the pid.
 *
 * [INPUT]: depends on POSIX only; AGENT, HOME_DIR, and HOOK (integrations/agent-hook.sh) are set at build time
 * [OUTPUT]: a fake claude, codex, pi, gemini, droid, amp, cursor-agent, or opencode binary
 * [POS]: the agents of test/e2e.sh. It never touches the real home folder.
 * [PROTOCOL]: Update this header on change, then check CLAUDE.md
 */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static void mkdirs(const char *path) {
  char buf[4096];
  snprintf(buf, sizeof buf, "%s", path);
  for (char *p = buf + 1; *p; p++) {
    if (*p != '/') continue;
    *p = 0;
    mkdir(buf, 0755);
    *p = '/';
  }
  mkdir(buf, 0755);
}

static void put(const char *dir, const char *file, const char *text) {
  char path[8192];
  mkdirs(dir);
  snprintf(path, sizeof path, "%s/%s", dir, file);
  int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0) return;
  if (write(fd, text, strlen(text)) < 0) {
  }
  close(fd);
}

/* sh HOOK AGENT, with the hook's JSON on stdin, as Gemini CLI and Droid run it. */
static void run_hook(const char *agent, const char *session) {
  int fds[2];
  char json[256];
  if (pipe(fds) < 0) return;
  pid_t child = fork();
  if (child == 0) {
    dup2(fds[0], 0);
    close(fds[0]);
    close(fds[1]);
    setenv("HOME", HOME_DIR, 1);
    execl("/bin/sh", "sh", HOOK, agent, (char *)0);
    _exit(127);
  }
  close(fds[0]);
  int n = snprintf(json, sizeof json, "{\"session_id\": \"%s\", \"source\": \"startup\"}\n", session);
  if (write(fds[1], json, n) < 0) {
  }
  close(fds[1]);
  if (child > 0) waitpid(child, 0, 0);
}

int main(int argc, char **argv) {
  const char *agent = AGENT;
  char session[128] = "", dir[4096], file[256], text[8192];
  int record = 1;
  long long started = (long long)time(NULL) * 1000;

  for (int i = 1; i < argc; i++) {
    if (!strcmp(argv[i], "--no-record")) record = 0;
    int names_session = !strcmp(argv[i], "--resume") || !strcmp(argv[i], "resume") ||
                        !strcmp(argv[i], "--session") || !strcmp(argv[i], "-r") ||
                        !strcmp(argv[i], "continue") || !strcmp(argv[i], "-s");
    if (names_session && i + 1 < argc) snprintf(session, sizeof session, "%s", argv[i + 1]);
  }
  if (!session[0] && !strcmp(agent, "opencode"))
    snprintf(session, sizeof session, "ses_fake%018d", (int)getpid());
  if (!session[0])
    snprintf(session, sizeof session, "%s00000000-0000-4000-8000-%012d", strcmp(agent, "amp") ? "" : "T-",
             (int)getpid());
  snprintf(file, sizeof file, "%d.json", (int)getpid());

  if (!strcmp(agent, "claude") && record) {
    snprintf(dir, sizeof dir, "%s/.claude/sessions", HOME_DIR);
    snprintf(text, sizeof text, "{\"pid\":%d,\"sessionId\":\"%s\",\"startedAt\":%lld}\n",
             (int)getpid(), session, started);
    put(dir, file, text);
  } else if (!strcmp(agent, "codex")) {
    char path[8192];
    snprintf(dir, sizeof dir, "%s/.codex/sessions/2026/11/19", HOME_DIR);
    mkdirs(dir);
    snprintf(path, sizeof path, "%s/rollout-2026-11-19T10-00-00-%s.jsonl", dir, session);
    if (open(path, O_WRONLY | O_CREAT | O_APPEND, 0644) < 0) return 1; /* held until exit */
  } else if (!strcmp(agent, "cursor-agent")) {
    char path[8192];
    snprintf(dir, sizeof dir, "%s/.cursor/chats/0123456789abcdef0123456789abcdef/%s", HOME_DIR, session);
    mkdirs(dir);
    snprintf(path, sizeof path, "%s/store.db", dir);
    if (open(path, O_RDWR | O_CREAT, 0644) < 0) return 1; /* held until exit, as its SQLite store is */
  } else if (!strcmp(agent, "pi")) {
    char extension[4096];
    snprintf(extension, sizeof extension, "%s/.pi/agent/extensions/rex-revive.ts", HOME_DIR);
    if (access(extension, R_OK) == 0) {
      int n = snprintf(text, sizeof text, "{\"pid\":%d,\"sessionId\":\"%s\",\"startedAt\":%lld,\"argv\":[",
                       (int)getpid(), session, started);
      for (int i = 1; i < argc && n < (int)sizeof text - 512; i++)
        n += snprintf(text + n, sizeof text - n, "%s\"%s\"", i > 1 ? "," : "", argv[i]);
      snprintf(text + n, sizeof text - n, "]}\n");
      snprintf(dir, sizeof dir, "%s/.pi/agent/rex-revive", HOME_DIR);
      put(dir, file, text);
    }
    for (int i = 1; i < argc; i++) memset(argv[i], ' ', strlen(argv[i]));
  } else if (!strcmp(agent, "gemini") || !strcmp(agent, "droid")) {
    run_hook(agent, session);
  } else if (!strcmp(agent, "amp") || !strcmp(agent, "opencode")) {
    char plugin[4096];
    int amp = !strcmp(agent, "amp");
    snprintf(plugin, sizeof plugin, amp ? "%s/.config/amp/plugins/rex-revive.ts"
                                        : "%s/.config/opencode/plugins/rex-revive/tui.js", HOME_DIR);
    if (access(plugin, R_OK) == 0) {
      snprintf(dir, sizeof dir, amp ? "%s/.local/share/amp/rex-revive" : "%s/.local/share/opencode/rex-revive",
               HOME_DIR);
      snprintf(text, sizeof text, "{\"pid\":%d,\"sessionId\":\"%s\",\"startedAt\":%lld}\n",
               (int)getpid(), session, started);
      put(dir, file, text);
    }
  }
  printf("fake %s on %s\n", agent, session);
  fflush(stdout);
  for (;;) pause();
}
