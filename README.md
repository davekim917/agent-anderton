<h1 align="center">Anderton</h1>

<p align="center"><b>One Claude Code or Codex session that runs all the others.</b></p>

<p align="center">
It starts real worker sessions, keeps track of every one, reviews what they build,<br>
and is the one session that deploys.
</p>

<p align="center">
  <a href="https://github.com/davekim917/agent-anderton/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/davekim917/agent-anderton/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="Claude Code plugin" src="https://img.shields.io/badge/Claude%20Code-plugin-d97757">
  <img alt="macOS and Linux" src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-lightgrey">
  <a href="LICENSE"><img alt="MIT license" src="https://img.shields.io/badge/license-MIT-blue"></a>
</p>

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/flow-dark.svg">
  <img src="assets/flow.svg" width="100%" alt="You talk to one session, the Anderton. It watches your other sessions, starts a worker session for each task, and is the only session that ships to production. Every worker's brief tells it to report to Anderton by name and not to deploy.">
</picture>

## Why

Claude Code handles one task per session well. Run several on one repo and the coordination falls
to you: which session is sitting on a permission prompt, which one already opened its PR, which one
is about to deploy something nobody reviewed.

Anderton hands that job to a Claude Code or Codex session in your repository. Invoke
`/anderton` in Claude Code or `$agent-anderton:anderton` in Codex.

## What it does

- **Starts full worker sessions.** Each task gets a full Claude Code or Codex session in its own git
  worktree, started from `origin/HEAD`. It loads your user settings and the repo's committed config
  (CLAUDE.md, skills, hooks, plugins) and shares the repo's auto memory. Inside
  [herdr](https://herdr.dev) or tmux it opens in a tab you can watch and type into. New worker
  launches require one of those multiplexers.
- **Receives milestones and blockers.** Workers report a result, a question, a blocker or an answer.
  Claude workers reporting to Claude use SendMessage. Codex workers and Claude workers
  reporting to Codex use their final replies, which the watch reads from the native runtime.
  You can open either worker's tab to see its work.
- **Shows you what's waiting on you.** Before every status report it lists the sessions in the repo
  that have stopped for a person: a finished reply, a permission prompt, a multiple-choice question,
  a tool call stuck for over a minute, a blocked background session. Its own workers report to it
  instead, unless one is stuck on a prompt and can't.
- **Reviews before anything deploys.** Each change gets three questions: is it the right thing to
  build, is it built right ([the engineering bar](skills/anderton/references/good-code.md)), and,
  for data work, are the numbers right. It treats passing tests and a bot review as evidence to
  weigh, not as the decision. Work that falls short goes back to the session that wrote it, with the file, the defect
  and the check that proves the fix.
- **Owns deploys.** Workers stop at a PR, or a merge if your repo lets them merge, and report. The
  Anderton deploys using your repo's own steps, and asks you before any restart. If a merge to your
  main branch deploys on its own, protect the branch or tell the Anderton that workers must not
  merge; otherwise a worker's merge is a deploy.
- **Turns repeat mistakes into checks.** When the same mistake happens twice, the fix becomes a
  check rather than another instruction. It prefers, in order: a design that can't express the
  mistake, a type, a CI rule, a test, and a written rule only as a last resort. Each new check must fail on the
  original mistake.
- **Cleans up.** Retiring a worker stops its session, closes its tab and removes its worktree. A
  worktree with uncommitted or unpushed work is kept; gitignored files are not.

The scripts enforce one deploying Anderton per repo and do the starting, listing and cleanup. Reviewing,
routing and deploying are instructions the Anderton follows, not a sandbox.

## Quick start

Install the plugin:

```
/plugin marketplace add davekim917/agent-anderton
/plugin install agent-anderton@agent-anderton
```

Installed before the rename, as `anderton@anderton`? Run the two lines above, then
`/plugin disable anderton@anderton`, and restart your running sessions. Only then run
`/plugin uninstall anderton@anderton` and `/plugin marketplace remove anderton`, since running
sessions load their hooks from the old install. The role and worker records in `~/.claude/anderton/`
carry over.

Run Claude Code inside [herdr](https://herdr.dev) or tmux to launch workers. Each worker opens
in a tab or window you can watch and type into.

In the session you want in charge, give it a name (workers report to it by name), then start it:

```
/rename anderton
/anderton
```

Then tell it what you want done:

> Add CSV export to the reports page, and find out why the nightly import is slow. Report back
> before changing the import.

It writes a brief for each task and starts a worker for each. From then on the workers ask the
Anderton, not you. It answers what it can, brings you the decisions that are yours, reviews each
PR, and deploys what passes.

**Requirements:** Claude Code with `claude agents`, built and
tested on 2.1.312, and support for `--session-id`; `git`, `jq`, `gh`, and `uuidgen` or Python 3;
and herdr or tmux. It runs on Linux and on macOS,
including macOS's stock bash 3.2.

### Open a Codex Anderton

Install from a local checkout of this plugin into the Codex home you use for the role:

```sh
codex plugin marketplace add /path/to/agent-anderton
codex plugin add agent-anderton@agent-anderton
```

With the local Codex daemon running, open `skills/anderton/scripts/codex-anderton.sh`
from a herdr or tmux pane in the repository and invoke `$agent-anderton:anderton`.
The launcher gives that interactive thread the current pane's context for opening
workers. For a separate Claude profile, set the same `CLAUDE_CONFIG_DIR` Claude
uses before launching Codex. Both coordinators read their claims and worker
records there, under `anderton/`. A custom directory isolates standalone plugin
state. NanoClaw deployment authority comes from `$HOME/.claude/anderton`.

The Codex workflow uses the local thread APIs in Codex CLI 0.171.0 and needs
Python 3. Anderton commands access the control socket, shared registry and worker
worktrees. If the sandbox blocks that access, approve the specific host command
through Codex's approval prompt. The launcher leaves your approval and sandbox
settings alone. Codex workers open with workspace writes and user-reviewed
approvals. A Codex Anderton directs the operator to the worker pane for approvals
and input requests.

The watcher commits a Codex notification after its exact input is visible in a
terminal turn on the claimed thread. A turn the operator interrupted still
retains the notification in its history, so the watcher leaves it there for
the operator to review.

The repository Anderton sets the default worker provider for all of its projects.
An inherited Codex default uses the daemon home of the repository Anderton.
Use `--provider claude` or `--provider codex` to choose explicitly.
`worker.sh message <name> "<direction>"` appends directions to a Codex worker's
queue in order. If `message` exits 4, run `worker.sh status <name>` and resend
only when status reports `never arrived` for the direction ID.
`worker.sh` also steers Claude workers from Codex through the Claude worker's
Anderton Stop hook. A Claude session you adopt must already have this plugin
loaded and end a turn to receive those directions.

## Questions

**Why full sessions instead of sub-agents?**

A sub-agent runs inside the Anderton's own session and hands back a summary. You can't open it or
talk to it. A worker is an ordinary Claude Code session with its own context, in its own tab, so
you can watch it, steer it, and leave it running for hours.

**What does it cost?**

Each worker is a full Claude Code session and uses your plan the same way a session you open
yourself does: three workers cost about what three sessions cost, plus the Anderton itself, which
reads every diff.

**Is it safe to let it run?**

Workers run in the Anderton's permission mode, because a session in a different mode holds
incoming messages until you approve them. If your Anderton runs with permissions bypassed, so do
its workers. The rule against deploying is in every worker's brief, not a sandbox.

**What does "deploy" mean here?**

Whatever your repo says it means. The plugin has no deploy config of its own: the Anderton reads
your CLAUDE.md and docs for the deploy and health-check steps, and goes through your merge gate if
you have one.

**What if the Anderton session ends?**

The workers keep running. Start a new session, give it the same name, and run `/anderton`; it takes
the role once the old session has exited. Then ask the workers where they stand, since a report
sent while no session had that name may not have arrived.

For Codex, resume its exact thread. Closing a pane or restarting the daemon
leaves the claim in place. Archive the thread to release its claim, or have
the replacement session use `--take-over` after you authorize it.

**How do I stop everything?**

Ask the Anderton to retire its workers. A plain shell can also retire Claude workers with `retire.sh <name>`; it
lives in the plugin's `skills/anderton/scripts/` folder under `~/.claude/plugins/cache/`. Then
`/plugin uninstall agent-anderton@agent-anderton`. Uninstalling leaves `~/.claude/anderton/` (the role and
worker records) and any worktree that was kept for unpushed work; delete those by hand.

**Can my Claude Code Anderton run a Codex worker?**

Yes, in herdr and tmux. Ask your Claude Code Anderton to use a Codex worker, or
pass `--provider codex` to `spawn.sh`. This requires Python 3 and a running
local Codex daemon with the thread and turn APIs in Codex CLI 0.171.0.

The worker opens in its own worktree and tab. Anderton sends follow-ups to
the worker's Codex thread ID and receives milestone replies and blocker
alerts through its existing watch. Open the worker's tab to handle a Codex
permission prompt or input request.
A Codex worker's pane is titled with its thread ID. `retire.sh` closes only that pane, found by the id it was
opened with wherever it now is, and only while it still shows that thread: after `/resume` or `/new` there, close
it yourself.

**What happens when a Codex account hits its usage limit?**

Nothing changes unless you install a Codex account helper: an executable named by `ANDERTON_CODEX_ACCOUNTS`, or
`codex-accounts` on `PATH`. Anderton asks it, with `CODEX_HOME` set to the home in question:

- `--start-home [-- <codex options>]` prints the home a new session starts on.
- `--move-thread <id> [--message <text>] [-- <codex options>]` marks the account limited and prints the next home,
  which must read the same conversation store, so the thread resumes there as it is. It exits non-zero, marking
  nothing, when a codex still has the thread open, and exits non-zero when no account may take it.
- `--locate-thread <id>` prints the home that last ran the thread.
- `--is-limited` exits 0 while `CODEX_HOME` is marked limited, and 1 once it is not.

The helper decides which accounts qualify, and must print only a home that runs the same hook guards: Anderton runs the
session there as given. An answer it cannot read (an older helper's exit 2) leaves the session where it is.

With a helper, `spawn.sh` and `codex-anderton.sh` start on the home it names, judged under their codex options, and
start that home's daemon if it is not running. When a worker's latest turn failed at the usage limit (Codex's
structured `usageLimitExceeded`, or with no structured kind its own "You've hit your usage limit" sentence), the watch
moves it over sweeps, so no sweep waits:

1. A sweep stops the Codex client in its pane. Until the move ends, `codex-workers.sh message` refuses the worker: a
   turn started then would run on the old account. A loaded thread whose turn failed reads `systemError` until its
   next turn, and counts as waiting on nothing.
2. A later sweep, once the old daemon has let go of the thread (about a minute after its last client leaves), asks the
   helper for the next home and resumes the thread on that home's daemon. Then one write points the worker's record
   there and records the steps still owed: reopen the pane there, and tell the worker to continue without repeating
   completed work.
3. That sweep, or a later one if it was cut short, runs the owed steps. A direction to continue that did not go
   through is retried.

Only the record's writes hold the repository lock, and a sweep takes a step for one worker at most. A thread another
client still has open after three minutes is not moved, and a pane showing another conversation is left alone. If
the new daemon does not start or take the thread, the worker stays on its old home, with nothing to undo. A move that
could not run is retried quietly: the worker continues on its own home once that home's limit has reset, or moves once
the helper names another home.

A Codex Anderton at its limit moves with `codex-anderton.sh --move <thread-id>` after you close its window: it resumes
the thread on the home the helper names. The claim keeps naming the old home until the new home's daemon has the
thread loaded. Then, under the repository lock, the old home's watch is stopped, the claim names the new home, and a
watch for the new home starts. A hand-over that finds the lock held past its ten-second wait logs that next to the
claim (`<claim>.handover.log`) and tries again, ten times. `retire.sh` keeps a worker whose thread a daemon on another
account's home has open. A claim whose hand-over never ran follows its thread when `claim.sh` runs from the home
that last ran it.

**How is it different from firstmate?**

[firstmate](https://github.com/kunchenguid/firstmate) inspired it. firstmate is a full agent
distro: it runs from its own directory, supports many harnesses and backends, adds second mates,
and has a watcher process that notices a stalled crewmate by itself. Anderton is a lighter take for
Claude Code and Codex. Workers report at each milestone and a local watch wakes
the Anderton when an owned session blocks on a person.

**Can I have more than one?**

Yes, one per project. Open an Anderton for each thing you're working on in the same repo
(`claim.sh --project <name>`, or invoke the skill and name the project). Each starts and reviews its
own workers, and hears when they block. Only one per repository deploys, though: the others send
their deploys to it, since two sessions that both ship is the problem this exists to stop. One
session holds one role.

<details>
<summary><b>How it works</b></summary>

The skill is [`skills/anderton/SKILL.md`](skills/anderton/SKILL.md). It reviews
against [`references/good-code.md`](skills/anderton/references/good-code.md).

**What a repository is.** The session's repository, named by its main checkout (or, for a bare
repository, its git dir), so every worktree of it belongs to one repository. Outside a repository,
it is the session's directory. A project is a name within a repository, with its own Anderton.

**`claim.sh`** records the claiming session as the repository's Anderton in
`~/.claude/anderton/<key>.json`. The key is `git hash-object` of the repository root, which the
record also holds. It exits 3 while another live session holds that role; `--take-over`
replaces it. `--project <name>` claims a named project within the repository instead, with its own
Anderton and a key hashed from the root and the name (`--scope`, its earlier name, still works).
One session holds one role per repository: a session holding the repository's role or another
project's is refused (exit 3), `--take-over` included. The record names a Claude Code process (its
pid plus its registry start time) and the session it runs, and the watch keeps both current, so the
role survives `/clear` (same process, new session id), `--resume` (same session, new process) and
`/restart` (same process, new start time). The watch takes a role back only for the session that
held it, and never from a live holder; any other session still claims it explicitly, with
`--take-over` while its holder is live.
Codex records its daemon home, thread UUID and original directory. An unloaded
thread still holds its role. If the daemon cannot answer, the claim is treated as
unknown and blocks an ordinary takeover.
An Anderton must release an adopted worker before that session can claim a role.
A worker launched by Anderton must be retired before it can be replaced by a coordinator session.
Changing the worker's Claude display name leaves that claim restriction in place.

**`waiting.sh`** lists the live sessions in the caller's repository (`--all`: every repository) that
wait on a person, leaving out every Anderton in the caller's repository, the repository's and each
project's: each is a tab the user reads directly. Run by an Anderton, it lists only the sessions that
role answers for: the workers it started or adopted, and, for the repository's, a project's workers
once that project's Anderton is gone. A session nobody started is the user's own tab, which no
Anderton hears about until the user asks one to adopt it. Verified Claude workers keep their recorded
worker name for Anderton commands after a display rename. It lists a
session when:

- the turn ended with Claude's text;
- the registry's `status` says the session is blocked on a permission prompt or an
  `AskUserQuestion`, in the main thread or a sub-agent;
- without that status, a tool call has gone unanswered for over a minute (`PERMISSION PROMPT?`,
  with the tool and the first 200 characters of its input).

It reads `~/.claude/sessions/*.json`, keeps sessions whose process is alive and started when the
registry says, and finds each transcript under `~/.claude/projects/*/<session id>.jsonl`.
Background sessions have no registry entry, so it also reads `claude agents --json`. It lists one
that is `blocked`, and one that is `done` with a turn in the last two days. A worker `spawn.sh`
started is listed, marked `(worker)`, only while the registry or `claude agents` says it is
blocked on a prompt; otherwise it reports to the Anderton.

Then, under `Ready to retire`, it names each recorded worker the caller answers for whose work is
finished, with the reason: its worktree is gone; its HEAD, past the commit it started from, is on
origin's default branch as the cached remote ref has it (no fetch), with how long ago it landed; or,
with `gh` installed, a PR whose head is its HEAD is merged or closed and none for its branch is open.
A worker is left out while any session that may be it is busy: one under its name or recorded id, or
one working in its worktree, so renaming it does not hide it. When `claude agents` fails, no Claude
worker is judged ready. After those reasons, a worker found none of them for, and idle for a day, is listed as
`idle Nd, no finished work found — check its PR`, since one whose work sits in another repository's
worktree leaves its own at its base. Idle time runs from the newest transcript entry of any session
that may be it, else from when it was started. A line notes uncommitted work, or commits no remote branch has, which `retire.sh`
would keep. `--blocked` leaves this section out.

**`spawn.sh --effort LEVEL [--provider claude|codex] [--model M] [--mode MODE] [--base REF] <name> [brief-file]`**
starts a full Claude Code or Codex worker labelled `<name>` in a new git worktree at
`$ANDERTON_WORKTREES/wt-<name>` (default: the folder that holds the repository). The base is
`origin/HEAD`, else `origin/main`, `origin/master` or `HEAD`.
New Claude workers launch interactively from herdr or tmux. A failed launch stops there, with
startup details for the operator. Existing background sessions use `claude attach`.

- Inside herdr (`HERDR_ENV=1`), the worker opens in a new tab of the caller's workspace, labelled
  `<name>`, or `<caller>/<name>` when the caller is a named project's Anderton, its name folded to
  lowercase letters, digits and hyphens. If Claude Code stops at a startup prompt, the spawn shows
  the screen, closes the tab and fails. If it cannot confirm the session stopped, it keeps the
  worktree and record for `retire.sh`. On a Codex startup issue, the spawn keeps the tab for
  inspection. Worker names in herdr start with a letter and use at most 32 characters.
- With tmux context and no usable herdr context, it opens a new detached tmux window with that same label. The spawn
  waits up to `$ANDERTON_START_WAIT` seconds (default 30) for the session to register: a window
  that closes first fails the spawn, and one still open is kept with a note that it may wait at a
  startup prompt.
- A Claude Code Anderton starts Claude workers in its own permission mode unless `--mode` is
  supplied. A Codex Anderton uses Claude Code's default mode for Claude workers unless `--mode`
  is supplied. Codex workers use workspace writes and user-reviewed approvals.
- `--effort` is required (`low`, `medium`, `high`, `xhigh` or `max`), so a worker never runs at the
  default just because nobody chose. The Anderton picks it from your request and says so; a level you
  name wins.
- Claude workers default to Opus, and Codex workers use the configured Codex model. The Anderton
  passes `--model` when you name a model.
- The brief, from the file or stdin, asks the worker to report a `RESULT:`, `QUESTION:`,
  `BLOCKED:` or `ANSWER:` at each milestone. Claude workers reporting to Claude Code use
  SendMessage. Other pairings report in final replies. The brief also sets the rules for sub-agents
  and external actions.
- The worker is recorded in `~/.claude/anderton/workers/<name>.json`, with the herdr or tmux server
  it was opened in. For Claude the record reserves its session UUID before opening the worker.
  The startup hook records its process identity. A `/clear` in the same process keeps the worker's
  previous transcript available for unread reports. An older Codex-launched Claude worker can bind
  on its next Stop when its original pane and launch brief still verify its identity. Direct other
  unbound workers in their own panes or retire them and start fresh workers.
- When a worker messages its former Claude Anderton, the SendMessage hook can hold the stale route
  and let its current Codex Anderton read that milestone from the transcript. This applies when
  the repository's Codex Anderton inherits a scoped worker. Recovery of native sends with an unknown
  recipient requires the worker to report again in its final reply.

**`retire.sh <name>`** stops that worker, then removes its worktree and record. A herdr tab or tmux
window is closed only when it still carries the label it was opened with, in the server recorded at spawn, and
the worker counts as stopped only when that tab or window is gone and its name has left
`claude agents`; an existing background worker is stopped with `claude stop`. It exits 3 and keeps the
worktree when the worktree has uncommitted changes, or commits since it started that no remote
branch has. Untracked files count whatever `status.showUntrackedFiles` says, and a worktree git
cannot read or compare with its base is kept too. Gitignored files don't count as changes.

**`adopt.sh <name>`** makes the calling Anderton answer for a live session the user opened in its
repository, as for a worker it started: it writes a worker record naming the caller, so the session's
messages to it are judged as a worker's and its blocks wake the caller. The record keeps the session's
id, pid and start time. It recognizes the same session on resume, restart or display rename, and the
same process after `/clear`. It refuses a caller holding no
role, another Anderton, and a session another Anderton already answers for. The Anderton then tells
the session by SendMessage that it reports there. `retire.sh <name>` releases an adopted session
without stopping it.
Re-adopting a Codex thread starts reporting at the new adoption point. A change in Anderton for an
existing adoption keeps its report bookmark.

**`watch.sh`** runs as Claude's background `Stop` hook and as the Codex coordinator's detached watcher.
The Codex watcher keeps checking for blockers while a notice is pending. Consecutive requests can
appear as one if the Codex daemon exposes the same turn, request kind and tool item for both.
The Claude hook exits quickly in an ordinary session. In an Anderton, the
repository's or a project's, it keeps running and checks `waiting.sh --blocked` every 30 seconds,
about 0.8 seconds of work on a repository of a dozen sessions. When a session it answers for newly
blocks on a permission prompt or `AskUserQuestion`,
sub-agents included, it exits 2 and Claude Code's `asyncRewake` wakes the holder with the session's
name, even when the holder is idle. The next `Stop` starts it again. The alert carries none of the
blocked session's text. The hook can't answer a prompt: a background hook can't return a decision.
While a woken holder is mid-turn no watch runs, so a block in that turn is reported when the turn ends.
One watch runs per role. A second `Stop` from the same install leaves at once, but one from another
install path, after a plugin update and `/reload-plugins`, replaces the running watch and its probe, so an
update reaches a live role without a restart.

A role can also name a **probe** (`claim.sh --probe '<command>' [--probe-every <seconds>]`, default 60;
`--no-probe` removes it): a plain script that checks sources outside Claude Code and prints new items, or
nothing. The watch runs it on its interval, in the holder's directory, and wakes the holder with what it
prints (cut at 6,000 bytes), so a role whose sources are quiet costs no tokens. The probe belongs to the
role, so a rebind or take-over keeps it. It reads bookmarks from `$ANDERTON_PROBE_STATE` and writes the
ones it would advance to into `$ANDERTON_PROBE_STAGE`; the watch moves them over only once the holder has
been woken with that output, or when the probe printed nothing. A run that exits non-zero or outlasts
`ANDERTON_PROBE_TIMEOUT` (120 seconds, which ends its whole process group) is a failure: after
`ANDERTON_PROBE_FAILURES` (3) in a row the holder is woken with `probe failing:` and the probe's last
stderr line, at most once an hour, so a probe that fails and recovers by turns cannot loop. A timed-out run's
output and stage are both dropped, since they would come back unchanged every run. Output identical to the last
delivery that moves no bookmark wakes no one, a stage must hold only plain files, and a run of a probe that was
replaced or removed meanwhile is dropped. State lives in `~/.claude/anderton/<key>.probe/`.

Claude Code ends the watch at the timeout `hooks.json` gives it (14 days), and only the holder's next turn
starts it again. So a watch that has had nothing to tell for 13 days wakes the holder once with "renewing";
ending that turn starts a new watch. Without it, a quiet role would stop being watched without a word.

**`report-gate.sh`** is a hook on `SendMessage`, run before and after each send. It judges two kinds of
message: a worker's to the session `spawn.sh` started it from, and any session's to its repository's Anderton,
named in the claim file, checked to be the live process the record names, and addressed by name, by name
with a listing ref, or by socket. It holds a message whose first line doesn't open with `RESULT:`,
`QUESTION:`, `BLOCKED:` or `ANSWER:` (any session other than a worker also has `DIRECTION:`, for passing
on a person's instruction, and a named project's Anderton has only `DEPLOY:`, `LOOKUP:` and `ANSWER:`), and one that repeats, word for word, the sender's last message to that
recipient within 30 minutes (`ANDERTON_REPEAT_WINDOW`, in seconds); an `ANSWER:` is never a repeat,
since two questions can have the same short answer. A message counts as sent only once the
send succeeds, so a failed or denied send can be retried. A named project's Anderton answers to the user in its own tab, so it
messages the repository's Anderton only to ship something, to ask a fact about the host that only it
can read, or to answer it. The other way, the repository's Anderton writes to a named project's Anderton
only with `DIRECTION:`, `QUESTION:` or `ANSWER:`, and the hook appends to each such message (as the
call's `updatedInput`) a footer telling the project's Anderton to report results and the user's calls in
its own tab and to reply only with a fact. Its other messages, messages to anyone else, and sessions in
other repositories pass untouched, and the repository is the one the session started in. It blocks or
appends that footer: it prints no decision, so it can't approve a call, and it allows whenever it can't
tell, a crash included.

**`prompt.sh <name>`** reads a Claude Code permission prompt from the session's herdr tab or tmux pane.
Approve or deny the request directly in that pane. A dialog taller than its screen has lost its top,
and neither herdr nor tmux can bring it back, so for a Bash command the script reads
the full text from the transcripts of the session and its sub-agents and workflow agents. It does so
only if exactly one waiting Bash call ends with the lines still on screen, and no call of another
kind is waiting, since a clipped dialog hides its title. It shows the reason a permission rule or hook
gave, from the screen. A hook that rewrites a command above those lines
wouldn't show. Any other dialog taller than its screen is refused. Only a session holding an Anderton
role in the target's repository can inspect it. Codex Anderton can inspect its own Claude workers.
The script only sees what the terminal draws. Use `claude attach` to handle an existing background
session. Answer `AskUserQuestion` directly in its session.

All six honour `CLAUDE_CONFIG_DIR` and need `jq`, `git` and a POSIX `ps`.

**Tests.** `bash test/structure.test.sh` and `bash test/scripts.test.sh`. The second drives the
scripts against a throwaway Claude Code home, with fake `claude`, `herdr` and `tmux` commands and
sessions in several repositories. CI runs both on Linux and on macOS's own `/bin/bash`, and runs
shellcheck.

</details>

## Built with it

Anderton runs the development of [AxisClaw](https://github.com/davekim917/axisclaw), an AI
workforce run from Slack and Discord, where it is the one session that deploys.

## Credits

The name is John Anderton, Tom Cruise's character in *Minority Report*: the one at the wall of
screens who sees everything coming in and steps in before it goes wrong. Parts of the skill are
adapted from [pstack](https://github.com/cursor/plugins) by Lauren Tan; see
[NOTICE.md](NOTICE.md). MIT licensed.
