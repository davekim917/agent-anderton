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
tested on 2.1.312, and support for `--session-id`; `git`, `jq`, `gh`, and Python 3 (`python3`, which reads reports for the
send hook, the sweeps and retirement; `claim.sh`, `spawn.sh` and the launchers refuse to start without it);
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
Use `--provider claude`, `--provider codex` or `--provider agy` to choose explicitly.
`worker.sh message <name> "<direction>"` appends directions to a Codex worker's
queue in order. If `message` exits 4, run `worker.sh status <name>` and resend
only when status reports `never arrived` for the direction ID.
`worker.sh` also steers Claude workers from Codex through the Claude worker's
Anderton Stop hook. A Claude session you adopt must already have this plugin
loaded and end a turn to receive those directions. A worker a Claude Anderton
started has no such watcher while it is idle, since its turns ended under that
Anderton: after a take-over, `worker.sh message` types the direction into the
worker's herdr pane instead, only while herdr shows that worker's session there,
idle. A tmux or adopted worker has no recorded pane, so type it in its own pane.
Known limits of that typed direction: herdr reads the pane and then types into it in two calls, so a turn that starts
between them gets the direction while busy, as with the agy watch. And the transcript records typed input as human, so
`retire.sh` holds that worker until `--reviewed-through`. That makes it hold more often, never less. herdr checks the pane's
session and then types into the pane in a separate call, so a `/clear` between the two delivers the direction to the new
session in that pane.

### Open an agy Anderton

Prepare agy as for agy workers (below), then register the skill with agy, from a checkout of this plugin that you keep,
such as the clone Claude Code's marketplace keeps:

```sh
~/.claude/plugins/marketplaces/agent-anderton/skills/anderton/scripts/agy-hooks.sh skill
```

It writes `~/.gemini/config/skills/anderton/SKILL.md`, a short skill that names that checkout's `SKILL.md` and its
scripts by absolute path, since agy shows the model a skill's text but not where it lives. agy sessions started
afterwards list it as `/anderton`, and a pull in that checkout is the update. `agy plugin install` would copy the
scripts under `~/.gemini`, where the guard refuses every command, so they could never run. `skill` refuses a checkout
there and warns about a versioned copy such as Claude's plugin cache, which an update replaces. It refuses to replace
an `anderton` skill it did not write or one another checkout registered, and `skill --remove` removes only its own;
both run under one lock, so two installers cannot both take an empty slot. Once one is registered, `claim.sh` and
`agy-anderton.sh` refuse to run from any other copy of the scripts on disk, judged by the script that actually runs
(through any link) and the scripts it reads, and name the registered one. A registration that cannot be read, or that
`skill` did not write, refuses every copy until you register again.

Start agy in a herdr pane, in the repository, with no permission prompts, and type `/anderton`:

```sh
agy --dangerously-skip-permissions
```

An alias saves typing it, and `agy-yolo --conversation=<id>` then resumes a conversation the same way:

```sh
alias agy-yolo='agy --dangerously-skip-permissions'
```

Under this flag the guard is the gate, as for agy workers. Started plainly, agy runs in its auto mode, whose terminal sandbox runs each
command in a PID namespace of its own and hides herdr's socket. An Anderton there cannot see its pane or the agy
process it runs under, and the sandbox hides most of your home, this checkout included, so `claim.sh` either cannot
start or refuses. Either way `/anderton` stops, claims nothing, and names the relaunch:
`agy --dangerously-skip-permissions --conversation=<id>`, with the id of that conversation, which agy also prints as
it quits. (`--continue` resumes the workspace's most recent conversation, which may be another one.) agy's default mode, the unlabelled one
Shift+Tab reaches, runs commands outside the sandbox but asks before each one it does not auto-approve. There
`/anderton` claims the role, and says once that workers' reports and the watch's messages will wait behind those
prompts, naming the same relaunch. It reads that from the flags agy was started with, so it does not see a mode you
switch to with Shift+Tab afterwards.

Its tool shells carry agy's own variables, not an Anderton's, so the scripts take the identity from the agy process
they run under, found by walking up from the shell: its pid and start time, the checkout at the top of its working
directory, and the herdr pane and socket. Nothing a shell supplies counts: no `ANDERTON_AGY_*` value, nor a Claude Code
or Codex session's variables that leaked in from where agy was started. A command acts as an agy claim's holder only when
it runs under the agy process the claim records, in the claim's pane and socket, so one agy process holds one role. The
role's watch runs beside agy rather than under it; the commands it runs to list and sweep the role's workers read as the
claim, and nothing else it starts acts as the Anderton.

`claim.sh` refuses unless herdr shows that same process, as agy, in that pane and checkout (`herdr pane process-info`,
which herdr 0.9.5 has), and `agy-hooks.sh check` passes against agy's own home, read from the agy process's environment
rather than the shell's `HOME`, and against the workspace roots of every directory from agy's working directory up to
the checkout's top, all of which agy loads hooks from. A workspace root it cannot read refuses the claim. It also refuses
an agy worker's session, by the pane `spawn.sh` recorded for it. The claim records that home and those directories, and
the watch reports a change in any of them. The claim is named `agy-<checkout>`, plus `-<project>` for a named project.
It claims with `claim.sh`, or `claim.sh --project <name>`, as any Anderton does. The role is live while herdr shows that
agy process in that pane, in that checkout, so it survives `/clear`, which starts a new conversation in the same
process, as a Claude Anderton's role does. It is free once herdr says the pane is gone or shows any other process there,
or agy was quit and relaunched there. An answer from herdr that is incomplete or that it cannot read is no evidence either
way: the role stays held and its watch keeps running. After an update of these scripts, an agy Anderton's running watch
cannot list its workers: run `claim.sh` again, which replaces it, and `waiting.sh` says so until then.

`skills/anderton/scripts/agy-anderton.sh --name <name>` still opens an agy Anderton the earlier way. It names the role,
starts agy without prompts on a prompt that points it at `SKILL.md`, and leaves the identity to agy's process as
above.

agy has no Stop hook, so `claim.sh` starts the role's watch in the background. The watch runs as long as the role and
tells the Anderton what Claude's watch would: blocked sessions, probe news, peer messages and worker reports, the same
ways a Codex Anderton hears them. It types each message into the Anderton's pane once agy there is idle. The claim also
records what agy loads hooks, plugins and agents from for the repository, and the watch tells the Anderton once when any
of it changes.

Workers start from it with `spawn.sh` as from any Anderton. Its default provider is agy, as a repository Anderton's
provider is the default for its workers. A Claude worker under it runs in Claude's default permission mode and reports
in its final replies, as under a Codex Anderton. A Claude worker it inherits, which still reports with `SendMessage`, has
that send held and read from its transcript, as a Codex Anderton reads one. Known limit: a final reply that restates
that milestone in other words can be reported twice after a take-over, by a Codex Anderton too; only a reply with the
same text is dropped.

The watch reads the pane's state, then prompts it, in two herdr calls, and checks the claim before it reads. A
take-over, or a turn you start, between those calls can send one notice to the former holder or into a busy pane. A "workgroup" Anderton is the same thing in a workgroup's own
repository: the role is per repository, and per named project with `--project`.

### Prepare agy workers

`spawn.sh --provider agy` starts an agy (Antigravity CLI) worker in its own worktree, in a herdr tab, the way Claude and
Codex workers start. It runs the `agy` on your PATH with your own environment, so it pushes and opens PRs with your
normal `gh` login. agy's guard hook, from your bootstrap checkout, gates every tool call it makes. Three steps, once:

1. **Install agy** the way its README says. It installs to `~/.local/bin/agy` and updates itself:

   ```sh
   curl -fsSL https://antigravity.google/cli/install.sh | bash
   ```

   Run `agy` once, sign in and accept its terms, so it sets up `~/.gemini/config`.
2. **Optionally, install herdr's agy integration:** `herdr integration install antigravity-cli`. It adds a
   `herdr` entry to `~/.gemini/config/hooks.json` that tells herdr each agy pane's session, so later steps act
   only on the session `spawn.sh` started. Without it they act on the agy herdr shows in the worker's pane and
   worktree. Install it before step 3: herdr cannot write the read-only file step 3 leaves. If you install it
   afterwards, run `chmod u+w ~/.gemini/config/hooks.json` first, then repeat step 3.
3. **Register the guard:**

   ```sh
   skills/anderton/scripts/agy-hooks.sh register --guard /path/to/bootstrap
   ```

   It writes a `PreToolUse` entry that runs that checkout's
   `plugins/workflow-agents/hooks/agy-guard.sh` in place, as Claude Code runs the checkout's guard hooks, with a
   3660-second timeout, above the guard supervisor's own deadline. The entry points the guard at the checkout's
   `merge-scope.local.json` and `response-secrets.local.json`, and leaves the dev and lab scopes empty. It keeps
   herdr's entry and refuses any other hook unless you pass `--replace`, which drops them. It refuses links, and
   leaves the file read-only (0444); rerunning it rewrites the file the same way.

Then start a worker:

```sh
skills/anderton/scripts/spawn.sh --provider agy --effort high <name> brief.md
```

Before it starts agy, `spawn.sh` runs `agy-hooks.sh check`. The check refuses unless all of these hold:

- the registration holds exactly the guard's entry, plus herdr's when present;
- the file is read-only;
- the guard and `bun` are in place;
- neither of agy's other global hook files defines hooks;
- none of the new worktree's workspace roots (`.agents`, `.agent`, `_agents`, `_agent`) names either entry.

Otherwise agy would run unguarded, and `spawn.sh` says so and starts nothing.

herdr reports agy ready while agy still shows a screen only you may answer: its terms, again after an update, or
its sign-in. So `spawn.sh` sends the brief only once agy shows its prompt (the footer `? for shortcuts`), within 30
seconds (`ANDERTON_AGY_READY_WAIT`, in half-seconds). On any other screen it closes the tab, undoes the spawn, and
says which screen it found when it knows it ("agy is waiting for its terms screen: run agy once yourself and complete
it."). agy asks whether to trust each new folder, and the trust it saves for a folder does not reach the folders under it
when that folder is your home, where worktrees of a repository at `~/<repo>` sit. So `spawn.sh` trusts the new
worktree for that agy session only, with agy's `--settings`, which is never saved. `--settings` replaces each key it
names for the session, so it carries your saved `~/.gemini/antigravity-cli/settings.json` with the worktree added to
its `trustedWorkspaces`. In a trusted workspace agy loads the worktree's `.agents`, `.agent`, `_agents` and
`_agent` with no prompt, as Claude Code does in a trusted folder; `agy-hooks.sh check --workspace` runs on the
worktree before agy starts, and refuses one whose workspace hooks would replace the guard's. With `--model`, the model id names the effort (`gemini-4-neon-low`), and
`--effort` is not passed, since agy rejects it beside one. agy runs its default model when it does not know the one
named, and says so only in a warning on its screen, so `spawn.sh` reads the screen once more after the prompt shows and
refuses the worker on that warning; `agy models` lists the ids it knows.

agy runs with `--dangerously-skip-permissions`. Its prompting mode would stop on routine commands, which a Claude
worker in auto mode does not, and its auto mode needs a terminal sandbox that a plain Linux host may lack, in which case
agy falls back to prompting. The guard is the gate. `--mode accept-edits|auto|plan` runs that agy mode instead, and
its prompts wait in the pane, where `waiting.sh` lists the worker as blocked. agy keeps no transcript these scripts
read, so `worker.sh status`, `output` (a screen read) and `message` go through the worker's herdr pane, only
while herdr shows agy there in its worktree. `retire.sh` holds every agy worker until you pass
`--reviewed-through`, then closes its pane and removes its worktree as for any worker.

agy reloads hooks mid-session. A same-named entry with `"enabled": false` in a workspace `.agent/hooks.json`
switched the guard off on the next turn, and a custom agent that does not inherit customizations runs its subagent
unhooked. So `spawn.sh` records what agy loads hooks, plugins and agents from as the worker starts:

- `~/.gemini/config/hooks.json`, `hooks/`, `plugins/`, `plugins.json` and `agents/`, and the plugins
  `~/.gemini/config/config.json` enables (only its `plugins` key: agy also saves other settings there);
- `~/.gemini/hooks.json`;
- `~/.gemini/antigravity-cli/hooks.json`, `plugins/`, `plugins.json`, `agents/`, `agents.json` and `secplugins/`;
- `hooks.json`, `plugins/`, `plugins.json` and `agents/` in each of the worktree's four workspace roots.

`waiting.sh` compares them on each pass. Each changed state is one header, which your watch tells you once.

**Known limits:**

- The watch detects a change and does not undo it: the worker keeps running until you act. It notices within one
  watch tick (30 seconds by default), and only while your Anderton's watch runs. There is no inotify on macOS, and
  `inotifywait` is not a dependency here, so each tick compares digests.
- Hook files a worktree already has at its base are recorded as they are. `spawn.sh` lists them when it starts the
  worker.
- The 0444 lock stops an accidental write, not a process running as you: such a process can rename over the file or
  chmod it. The guard denies agy's own writes to hook config, and the watch reports any change.
- The dev and lab scopes are off for agy: their approval exemptions do not apply to agy workers.
- agy updates itself, and an update that rewrites its built-in plugins (`~/.gemini/antigravity-cli/builtin`) is not
  watched.
- A link is recorded by where it points, not by what it points at: an edit inside a linked plugin's folder is not
  seen.

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

Add `--speed fast` or `--speed ultrafast` to ask for that speed for one worker. Codex falls back to Standard where the account or model doesn't allow it.
The tier is a session override. The account keeps its configured default.

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

Andertons message each other only for shared or host-level work: a deploy to run, a host fix or
lookup only the other can do, a fact only it can read, or an answer to its question. They never
relay their workers' progress to each other; each project's results stay in its own tab.

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

**`spawn.sh --effort LEVEL [--provider claude|codex|agy] [--model M] [--mode MODE] [--speed standard|fast|ultrafast] [--base REF] <name> [brief-file]`**
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
- `--speed` applies only to Codex workers. `fast` and `ultrafast` request that service tier for
  the worker's launch; it is a request, not an account choice. If the account or model the worker
  starts on doesn't allow that tier, Codex runs it at Standard. `standard` or omitting the flag uses
  the account's configured tier.
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

**`retire.sh <name> [--reviewed-through <ISO time>]`** stops that worker, then removes its worktree and record. A herdr tab or tmux
window is closed only when it still carries the label it was opened with, in the server recorded at spawn, and
the worker counts as stopped only when that tab or window is gone and its name has left
`claude agents`; an existing background worker is stopped with `claude stop`. It exits 3 and keeps the
worktree when the worktree has uncommitted changes, or commits since it started that no remote
branch has. Untracked files count whatever `status.showUntrackedFiles` says, and a worktree git
cannot read or compare with its base is kept too. Gitignored files don't count as changes.

Before it closes anything, `retire.sh` reads the worker's conversation since its last completion report (`RESULT:`) to
its Anderton: a delivered `SendMessage` one, or for a Codex Anderton reading a Claude worker's transcript, a
final reply that is one; for a Codex worker, a completed turn whose final message is one. A question, a block, an
answer or any other send never clears a hold, from anyone: a worker that just asked is not done. A message after it
from anyone but that Anderton (typed in the worker's tab, a voice relay, another session, a Codex TUI turn)
holds the retirement: it exits 4, lists each message's time and first line, and writes `<name>.held` beside the
record, which `waiting.sh` (and so the watch) lists until the worker is retired. The Anderton's own messages are
known from the record alone, never from a display name or the caller: the processes Claude Code verified as the
record's spawner session, and for Codex, the client ids of the directions `worker.sh message` recorded sending (on a
record from before that ledger, whose finished directions left no id, the text `worker.sh` adds to each). An
entry a person typed counts whatever its text, apart from the launch brief itself. What Claude Code injects does not
count: tool results, skill bodies, compaction summaries, hook and Stop feedback, system reminders, task
notifications, usage-reset and permission-grant prompts, sub-agent hand-backs and agent-team teammates. A report
counts only on the send's own evidence that it arrived, and a call Claude Code appends again counts once. A conversation it
cannot read is held, never read as quiet, and so is every agy worker, which keeps no transcript.
`--reviewed-through <ISO time>`, not in the future, clears the messages up to that time. On an unreadable
conversation or an agy worker it is the whole evidence, and `retire.sh` says so when it retires on it. Before each close
it reads the conversation again, so a message that arrives while it works holds it too.

**Known limits, the held check:** it guards oversight, not an adversarial worker. A Codex worker's ledger of the
Anderton's directions lives in its record, which a worker with write access to the worker registry can edit. The
ledger keeps the last 500 directions: after 501 with no report between them, the oldest, once its pending entry is
pruned, reads as someone else's message and holds the retirement until reviewed. The Anderton's own messages are known
by the processes its recorded session ran as; one sent from a process of that session that has left Claude Code's
registry reads as another session's.

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

A machine can also be told what its Anderton roles are doing, with no text from them. Set
**`ANDERTON_EVENT_COMMAND`** in the sessions' environment to a command, and each event runs it once in the
background with one JSON object on stdin: `{claimId, scope, kind, status?, milestoneKind?, links?, worker?}`.
Only a role claimed with `--project workgroup:<id>[/<project>]` emits, and its events are:
- `start`, from the claim (not a rebind) and from each `spawn.sh`, with `worker`;
- `status`: `working` when a Claude holder's or worker's turn starts (a `UserPromptSubmit` hook, which prints
  nothing) and `idle` when it ends (the `Stop` hook), so a long turn shows working throughout; the holder's watch adds
  `waiting` when a worker blocks on a person mid-turn, and `working` when it goes back to work;
- `milestone`, after a worker's `RESULT:`, `QUESTION:` or `BLOCKED:` was sent: its kind and up to ten GitHub
  URLs from the message, never the message itself;
- `done`, from `retire.sh`, with `worker`.
- `warning` with `status` `python3-missing` and `worker`, once per session, when a worker's send hook finds no `python3` (a
  `/reload-plugins` can load the hook without the preflight). The send passes, and Claude is told in the call's context.

Each claim has a `claimId`, kept by the same session through a re-claim, rebind or resume and new for any other
session, so whatever trusts one claim does not trust the next holder of the same scope. A worker's record names
its claim as `spawnerClaimId`. The command never holds a script up or fails it: it runs detached, holds none of
the caller's descriptors, is ended after `ANDERTON_EVENT_TIMEOUT` seconds (3), and its output and exit status are
ignored, and it runs in its own process group, which the timeout ends with `TERM` and then `KILL`. Unset, the prompt
hook returns before reading anything; set, it hands the lookup to a detached job. A scope is passed on only when it
is `workgroup:` and plain ids, and a link only as a PR or issue URL rebuilt from its parts. A Codex holder or worker
reports no status, since it has no registry entry. Known limit: a take-over while `spawn.sh` waits for its brief can
record the new holder's claim on a worker the old holder started, so that worker's events show under the new claim.

**`report-gate.sh`** is a hook on `SendMessage`, run before and after each send. It judges two kinds of
message: a worker's to the session `spawn.sh` started it from, and any session's to its repository's Anderton,
named in the claim file, checked to be the live process the record names, and addressed by name, by name
with a listing ref, or by socket. A worker's message, and one from a session that holds no role, is held unless
it opens with `RESULT:`, `QUESTION:`, `BLOCKED:` or `ANSWER:` followed by text (a session that holds no role also has
`DIRECTION:`, for passing on a person's instruction). A worker's kind is what the milestone event and a Codex or
agy Anderton's transcript sweep read; a session that holds no role learns the kinds only from the hold, since
nothing else from the plugin reaches it. One Anderton writing to another, the repository's or a named
project's, needs no kind: whether it should write at all is the skill's rule (shared or host-level work only,
never a worker's progress), not a label's. Any of these is also held when it repeats, word for word, the
sender's last message to that recipient within 30 minutes (`ANDERTON_REPEAT_WINDOW`, in seconds); an
`ANSWER:` is never a repeat, since two questions can have the same short answer. A message counts as sent
only once the send succeeds, so a failed or denied send can be retried. The repository's Anderton's own
messages, messages to anyone else, and sessions in other repositories pass untouched, and the repository is
the one the session started in. It only blocks: it prints no decision, so it can't approve a call, and it
allows whenever it can't tell, a crash included.

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
