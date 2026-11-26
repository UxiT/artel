# Artel — Specification v0.1

A native macOS app (Apple Silicon, macOS 26+): a single environment for working with coding agents on several projects in parallel, with a lightweight task board.

The main goal is to see, in one window, all running agent sessions, which of them are waiting for the operator's reply, and what questions the agent has asked.

---

## 1. Terms

| Term | Meaning |
|---|---|
| Operator | The user of the app (a developer) |
| Project | A folder on disk; usually a git repository with `CLAUDE.md`, but neither is required |
| Task | A prompt with attachments: an `.md` file plus a task folder |
| Session | A slot in the workspace: a terminal running an agent (`claude`) inside tmux |
| Agent | A coding CLI agent: Claude Code and Kimi Code; the architecture allows others |

---

## 2. Project

### 2.1. Contents
- **Directory path** (required). A git repository is not required, but without one task worktrees, diff, the base branch and committing `.artel/` are unavailable; tasks run directly in the project folder.
- **Description and specs** live in `CLAUDE.md` at the project root (recommended, not required). Stack/architecture specs go into separate files (`docs/stack.md`, `docs/arch.md` …) referenced from `CLAUDE.md`. The app does not duplicate this data; it reads and edits the files.
- **Tasks**: see section 3.
- **Project settings** (stored in the app):
  - name, color/icon;
  - **task ID prefix**: `ARTEL` by default, changed in Project Settings (numbering is continuous within a project; changing the prefix does not rename existing tasks);
  - base branch for task worktrees and diff (defaults to the repository's current branch);
  - agent permission mode (`auto` by default);
  - default model (optional);
  - **keep `.artel/` in git**: yes by default (committed); option "add `.artel/` to `.gitignore`".

### 2.2. Adding a project
1. The operator picks a folder (or drags a folder into the window).
2. Checks: it is a git repository; it has a `CLAUDE.md` with a filled-in description. Both checks are recommendations: the project can be added without them.
3. If the folder is not a git repository, the dialog offers to run `git init` (off by default) and explains what is unavailable without git.
4. If `CLAUDE.md` is missing or empty, the dialog offers to fill it in from a template (description, stack, architecture, links to spec files). The file can be saved only with a filled-in description; the "Add Without CLAUDE.md" button adds the project without creating the file (it can be created later in the Projects section).

### 2.3. Code editor
Code (the project, a task worktree, a file from the diff) opens in the editor chosen for the project:
- if nothing has been chosen yet, an installed JetBrains IDE is picked automatically from the project stack (`go.mod` → GoLand, `Cargo.toml` → RustRover, `composer.json` → PhpStorm, `package.json` → WebStorm, Python → PyCharm, `Gemfile` → RubyMine, Java/Kotlin → IntelliJ IDEA; IntelliJ IDEA Ultimate is the universal fallback);
- if no suitable JetBrains IDE is installed, the app asks what to open it in (a list of installed editors or any application);
- the choice is remembered per project and changed in Project Settings.

### 2.4. Editing
Markdown (task text, documentation pages, `CLAUDE.md`, context rules) is always shown rendered. "Edit" (`⌘E`) opens the source text; `⌘S` saves, "Done", `Esc` and `⌘↩` save and return to the rendered view, "Discard Changes" reloads the text from disk. Saving is explicit only: a document with unsaved edits shows a dot (in the title and in the tree), and quitting the app asks "Save?". While there are no edits, changes to the file on disk (by an agent or another editor) are picked up automatically. Unsaved task text is saved before the task is launched. Links like `@docs/arch.md` / `[..](docs/arch.md)` are clickable. Project documentation: §4.9.

---

## 3. Task

A task is a prompt with attachments that the operator hands to an agent in a session. Artel does not lead the agent through stages: after the first message, work continues in the terminal like in a regular session. (The plan → review → testing → acceptance cycle with an MCP server, review comments and automatic merge existed in v0.1 and was removed: it caused more problems than it solved.)

### 3.1. Storage
Each task is a folder `<project>/.artel/tasks/<ID>-<slug>/`:

```
.artel/tasks/ARTEL-12-login-form/
├── task.md          # frontmatter + task text (= prompt)
├── history.jsonl    # history: creation, statuses, launches
├── attachments/     # screenshots and files dropped into the task
└── logs/            # events and transcripts of the task's sessions
```

`.artel/` is stored in the project's **main working copy** (not in a worktree); the agent gets the absolute path to the task folder (`--add-dir`). This way task data is immediately visible to the app and to other sessions.

Files of old tasks (`plan.md`, `progress.md`, `comments.md`, `review.md`, `testing.md`, `summary.md`) stay in the folder, but the app no longer shows them; they can be opened with the "Folder" button.

**Sessions without a task:** on launch, an archive `.artel/no-task/<session-id>/` is created with the same `task.md`, `history.jsonl` and `logs/`. The first non-empty line of the first prompt (up to 80 characters) becomes the title of the session and the archive; later prompts don't change it. The events JSONL is copied on every hook, the agent's native transcript at turn boundaries and on close. Archives live for 7 days after their last update; cleanup runs on every read and write of `no-task/`, and active sessions are never removed. The operator can add an archive to the board: the folder moves to `.artel/tasks/<ID>-<slug>/`, gets the project's next number and status `done`, the first prompt stays as the `task.md` body, and history and logs are kept. If the session is still running, further logs go to the new task's folder. The archive can be turned off: the "Save to the no-task archive" checkbox in the New Session window (its default comes from the "Sessions Without a Task" section of Settings; ⌘T takes the value from Settings) and the "Save to Archive" item in the card menu. Without the archive nothing is written to `no-task/`, the title from the first prompt is still set, and an archive already written lives out its 7 days. The archive costs no agent tokens: the app does the copying, and the folder is not passed to the agent.

**`.artel/` and git:**
- By default `.artel/` is committed to the repository. Project Settings has the option "add `.artel/` to `.gitignore`".
- `logs/` and the temporary `no-task/` are never committed: the app creates `.artel/.gitignore` with `tasks/*/logs/` and `no-task/`.
- **The operator decides when to commit `.artel/`.** There are no automatic commits. The app has a "Commit Tasks" action (in the task list and at the project level, shortcut `⌥⌘S`) with an indicator "uncommitted changes in `.artel/`". The commit is made in the main working copy and only for `.artel/` paths (`git commit --only -- .artel/`), leaving the operator's other changes untouched; the message is prefilled with a list of changes (`artel: ARTEL-12 → in-progress, ARTEL-14 created`) and can be edited before committing.
- In task worktrees `.artel/` is excluded via `git sparse-checkout`, so the agent doesn't edit a stale copy of the task files.

### 3.2. `task.md` format

```markdown
---
id: ARTEL-12
title: Login form
project: artel
status: in-progress       # new | in-progress | done
agent: claude
model: opus               # empty → ask on launch
branch: artel/ARTEL-12-login-form            # only if the task has a worktree
worktree: ~/.artel/worktrees/artel/ARTEL-12
sessions: [s-3f2a]
created: 2026-11-05T10:12:00Z
updated: 2026-11-05T14:40:00Z
---

## What to do
...

## Context
...

## References
- @src/auth/session.ts
- https://example.com/design
- ![mockup](attachments/login.png)

## Acceptance criteria
- [ ] ...

## Constraints
- ...
```

**The task text is the prompt.** The sections are an editor template, not separate fields. All links and references go directly into the text:
- project files: `@path` (autocompletion over project files);
- URLs: as is;
- images/files: drag-and-drop into the editor → copied into `attachments/` → a link is inserted.

Unknown frontmatter keys are kept as is. Keys of the former cycle (`priority`, `depends_on`, `review`, `testing`, `iteration`, `awaiting_agent`, `merge_conflict`) are read without errors and dropped on the next write.

### 3.3. Statuses

`new` → `in-progress` → `done`.

| Transition | Who | When |
|---|---|---|
| `new → in-progress` | the app | the task is launched in a session for the first time |
| any → any | the operator | status menu, dragging the card on the board |
| `* → done` for a task with a worktree | the operator | dialog: stop sessions, remove the worktree, delete the branch (only if already merged: `git branch -d`) |

Statuses of the former cycle are read as follows: `plan`, `plan-review`, `review`, `testing` → `in-progress`; `cancelled` → `done`.

### 3.4. Launch
A task can be dragged into the workspace (or `⌘R`) if it is not closed and is not currently running in another session. The launch dialog:
- model, if the task doesn't specify one (with an option to save it to the task);
- **"Separate git worktree"**: a checkbox, the last choice is remembered; a task that already has a worktree always uses it. In a project without git there is no checkbox: the task runs in the project folder;
- for an existing session: clearing the context (see 4.4).

The first message to the agent is the prompt wrapper from Settings (§6) plus the text of `task.md`. Relaunching a task (in the same or a new session) sends it again.

### 3.5. Git worktree
- If a worktree is chosen at launch, a branch `artel/<ID>-<slug>` is created from the base branch along with a worktree in `~/.artel/worktrees/<project>/<ID>/`; the agent works in it, and parallel tasks of the same project don't interfere with each other. Without a worktree the agent works directly in the project's working copy.
- The "Changes" tab in the task window shows the branch diff against the base: commits, uncommitted edits, new files.
- **Artel does not merge the branch.** The operator merges it (or asks the agent to); when closing a task, the worktree and an already merged branch can be removed.

---

## 4. Interface

Window sections (toolbar segments, `⌥⌘1…3`): **Workspace** (session grid), **Projects** (documentation), **Tasks** (board). Workspace has no search or filters: the sidebar shows all tasks; search (`⌘F`) and filters are on the task board.

### 4.1. Overall layout
```
┌──────────────┬─────────────────────────────────────────────┬────────────┐
│ Tasks        │ Workspace          [Tab 1] [Tab 2] [+]      │ Inspector  │
│ [filters]    │ ┌─────────┐ ┌─────────┐ ┌─────────┐         │ (task /    │
│ ▾ Project A  │ │ session │ │ session │ │   +     │→→ scroll│  session,  │
│   ● task     │ │ ⏳ waits │ │ ▶ works │ │  new    │         │  hideable) │
│   ● task     │ └─────────┘ └─────────┘ └─────────┘         │            │
│ ▾ Project B  │                                             │            │
│   ● task     │                                             │            │
├──────────────┴─────────────────────────────────────────────┴────────────┤
│ Subscription limits: 5h ▓▓▓▓░░ 62% · week ▓▓░░░░ 31% │ waiting: 2       │
└─────────────────────────────────────────────────────────────────────────┘
```

### 4.2. Task list (left)
- One list across all projects, **grouped by project**; within a group, sorted by status (in funnel order, active first), then by modification time (newest first).
- Filters: project (multi-select), status (multi-select); search by title and text.
- Task row: ID, title, status (colored badge), "in session" / "waiting for reply" indicator, a branch icon if the task has a worktree.
- New task: the "New Task" toolbar button (and `⌘N`) opens a compact sheet with a draft: title, project (defaults to that of the selected task/session), agent, model, text. "Create" (`⌘⏎` or ⏎ in the title) creates the task in `new` and opens its window; "Cancel" (`Esc`) closes without creating.
- A single click selects a task; a double-click or ⏎ opens it in a separate (non-modal) task window.

### 4.3. Workspace (center)
- By default, a **grid** of sessions; when space runs out, horizontal scrolling.
- **Tabs**: the operator creates tabs and moves sessions between them by dragging (onto the tab title). Closing a tab force-terminates all its sessions; if any of them are active, the app asks for confirmation first.
- **Expand a session** to fill the whole workspace and collapse it back.
- **Resize a session** by dragging the right or bottom edge of the card (the corner changes both dimensions). Size changes in grid cells: the card occupies a whole number of rows and columns, and the other sessions reflow in their previous order. The size is saved in the workspace state; the context menu can reset it to one cell.
- While a task is being dragged, a **"+"** area appears on the right: dropping the task there → a new session. Normally it is hidden, and a new session is created with a compact toolbar button; its tooltip uses the same shortcut definition as the menu command.

**Collapsed session card:**
- task (ID + title), project (color), model;
- state: `working` / `waiting for reply` / `waiting for permission` / `finished (idle)` / `error` / `stopped`;
- the agent's last question or last message (1–2 lines);
- time in the current state.

Sessions waiting for a reply are highlighted (border highlight, sorted first; configurable).

### 4.4. Drag-and-drop scenarios
**Task → "+" (new session):**
1. If the task doesn't specify a model: model selection (with an option to save it to the task).
2. The "Separate git worktree" choice (if the task doesn't have one yet).
3. Confirmation → (the worktree is created/reused) → the session starts, and a `new` task moves to `in-progress`.

**Task → existing session (only if the session is idle):**
- **The same task** (continuation): a modal "Clear the previous session's context?", **"Yes" by default**, confirmation required.
- **A different task** (including one from another project): clearing the context is **mandatory**. The modal shows a warning: "The session is currently bound to task ARTEL-9 (project X). The context will be cleared and the session will restart in the working directory of task ARTEL-12 (project Y)". The clear checkbox is shown checked and disabled.
- Then model selection, if not set.
- The session is renamed for the task/project and switches to the new task's working directory.

If the session is busy, the drop is refused (with a hint).

### 4.5. Task window
Top left: title, text (editor with drag-and-drop of files), task files; on the right: status, "Launch", go to session, project, agent, model, branch and base (if there is a worktree), dates, the "Code" and "Folder" buttons; at the bottom: history (`history.jsonl`) and, for a task with a worktree, the "Changes" tab (diff).

### 4.6. Notifications
macOS system notifications: the agent is waiting for a reply, waiting for permission, finished its turn, error. Clicking a notification focuses the session. The Dock icon badge = the number of sessions waiting for a reply. Everything can be turned off in Settings (per event type).

### 4.7. Subscription limits
A shared status bar segment holds a compact column for each selected agent: **Claude** and **Kimi**, each with the **5 hours** and **week** windows. A click opens a shared popover with all windows, the Claude plan (Pro / Max), reset time and per-agent visibility checkboxes; the same checkboxes are in Settings and are persisted. If no agent is selected, the status bar keeps a "Limits" icon so the popover can be opened and agents selected again. Agents turned off in Settings (General → AI Agents) are not offered for new sessions and tasks, and their limits are neither requested nor shown; the last enabled agent cannot be turned off. Claude additionally shows **Opus week** and **Sonnet week**, Kimi shows **month (total)**, if those windows are present in the response.

**Data sources** (Claude modeled on [aiusagebar](https://github.com/alxrepin/aiusagebar)):
- Tokens come from **existing CLI logins, read-only**. Claude: Keychain item `Claude Code-credentials` (field `claudeAiOauth.accessToken`); fallback: `~/.claude/.credentials.json` (or `$CLAUDE_CONFIG_DIR`). Kimi: `$KIMI_CODE_HOME/credentials/<oauth-key>.json` (by default `~/.kimi-code/credentials/kimi-code.json`); the key and the regional `baseUrl` are read from `[providers."managed:kimi-code"]` in `config.toml`. The app **never refreshes or writes** these tokens, so as not to break the CLI; on 401/403 it re-reads them (the CLI refreshes them itself).
- Claude: `GET https://api.anthropic.com/api/oauth/usage` with headers `Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20`. Response: `five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet`, each with `utilization` (%) and `resets_at`. Plan: `GET https://api.anthropic.com/api/oauth/profile` (`has_claude_max` / `has_claude_pro`).
- Kimi: `GET <baseUrl>/usages` (by default `https://api.kimi.com/coding/v1/usages`) with a Bearer token. Response: `usages.limit_5h`, `limit_7d`, `limit_month_total`, each with `used_ratio` (0…1) and `reset_time`.
- Refresh once a minute (configurable, 1–30 min) and immediately when the popover opens; each agent has its own request and exponential backoff on 429/5xx/network errors (honoring `Retry-After`), and the last data stays on screen.
- On 401/403, re-read the token; if that doesn't help, show "Sign in to Claude Code / Kimi Code again" (`claude` / `kimi` → `/login`).
- A notification when the remaining share drops below a threshold (15% by default), one per agent window until it resets; can be turned off in Settings.
- The endpoints are not public and may change: URLs and headers are kept in one configuration.
- On the first Keychain read macOS asks for access permission; onboarding should explain why.

### 4.9. Project documentation
The Projects section opens the selected project's documentation: a Confluence/Docusaurus equivalent inside the app.
- **Where it lives.** The documentation folder is stored in the app's `state.json` (`Project.docsFolder`); nothing is written to the project. If none is chosen, it is detected: the `docs/` of a Docusaurus site (`docusaurus.config.*` at the root or in `website/`), then `docs/`, `documentation/`, `website/docs/`, `doc/`. If there is no folder, the app offers "Create Documentation…" (`docs/` by default, another project folder can be chosen) with a starter `index.md`, or "Choose Existing Folder…". A colleague with the same repository points their own Artel at the folder (the "Documentation" header menu or Project Settings).
- **Structure, as in Docusaurus.** A page is `.md`/`.mdx`, a section is a folder; a section's page is `index.md`, `README.md` or `<folder>.md`. Page label: `sidebar_label` → `title` in frontmatter → the first `# heading` → the file name; order: `sidebar_position`, then name. Section: `label`/`position` from `_category_.json` or `_category_.yml`. Files and folders starting with `_` or `.` are skipped; folders without pages (images) are not shown. `.excalidraw` files are separate diagram pages (view only; edit them in Excalidraw). `sidebars.js` is not read.
- **Section sidebar:** search across all pages (all words, case-insensitive; matches are highlighted on the page), the "Agent Context" group (`CLAUDE.md`, `CLAUDE.local.md`, `AGENTS.md`, `.claude/rules/`, specs from `CLAUDE.md` outside the documentation folder; a new rule via "+"), and the documentation tree. Right-clicking anywhere in the sidebar opens a menu: on a page, drawing or section — New Page / New Excalidraw / New Section there, "Ask Agent…", rename, "Move To" a section, Show in Finder, delete (to the Trash); on an Agent Context file — its own actions; on empty space and the group headers — New Page / New Excalidraw / New Section at the docs root, New Context Rule, Show in Finder, another docs folder. Dragging a page onto a section or onto the "Documentation" header moves it. On move and rename, relative links to the page and the page's own links are rewritten in all pages and in the `@` imports of context files.
- **A new page** opens straight in the editor; the file name is a transliteration of the title (can be changed). A new section is a folder with `_category_.json` and `index.md`.
- **Rendering** (WKWebView, `Resources/DocsRenderer`, no network): markdown-it, Docusaurus admonitions `:::note|tip|info|warning|caution|danger|important` (title after the type or in `[ ]`), ```` ```mermaid ```` diagrams (Mermaid), formulas `$…$`, `$$…$$` and ```` ```math ```` (KaTeX), Excalidraw: ```` ```excalidraw ```` with scene JSON or `![](diagram.excalidraw)` (a built-in simplified renderer on rough.js, or Excalidraw's own export once the Excalidraw download is installed, see below); a click on an embedded drawing opens it, code highlighting (highlight.js), tables, task lists, heading anchors. In `.mdx`, `import`/`export` lines are hidden and JSX tags are rendered as HTML. Images and links resolve relative to the page; a link to another page (including one without an extension, as in Docusaurus, and with a `#anchor`) opens it here, other files open in the code editor or their own app.
- **Editor:** source text (§2.4). `](` and `[[` suggest pages (`[[` inserts the whole link); the "Link" button does the same from a menu. An image from the clipboard is saved to `assets/` next to the page; a dropped project file becomes a relative link, an external one is copied to `assets/`.
- **Agent.** "Agent" on a page, "Ask Agent…" in the tree or in the context menu of selected text (rendered view) / a button on selection (editor) open a sheet for an instruction. A session without a task is started in the project folder (not in a worktree) with a prompt: the page, the fragment with the file's line numbers (a selection in the rendered view is mapped to source lines), the instruction and the documentation style rules. Unsaved page edits are saved before launch. While the session is alive, its status and "Open Session" are shown under the page title; the agent's edits appear on the page by themselves.
- **Drawing with Excalidraw** (like the Excalidraw plugin of Obsidian). An optional download, not part of the installer: Excalidraw's editor and exporter (`@excalidraw/excalidraw`, MIT, with React and Excalidraw's fonts), ~15 MB. Built by `scripts/build-excalidraw-editor.sh` (Bun) and published as a separate GitHub release of Artel (`excalidraw-<version>`); the app downloads it via a button in Settings (General → Documentation) or on an `.excalidraw` page, verifies the pinned sha256 and unpacks it into `Application Support/Artel/renderers/`. Without it, drawings are rendered by the built-in renderer and can't be edited in Artel. With it:
  - an `.excalidraw` page has "Edit": Excalidraw's own editor in place of the page (English UI, the app's theme); saving is explicit as for pages (⌘S, "Done" or ⌘↩, the unsaved dot); Excalidraw's ⌘-shortcuts (undo/redo, select all, duplicate, group…) go to the drawing, copy/paste go through the clipboard;
  - "New Excalidraw…" in the documentation menus creates an empty `<name>.excalidraw` and opens it for editing;
  - "Draw" in a page's editor creates `assets/<page>-drawing.excalidraw`, embeds it at the cursor and opens it; "Done" returns to the page. A click on an embedded drawing in the preview opens it the same way;
  - previews use Excalidraw's own SVG export.
  `assets/` folders are not shown in the documentation tree.
- **Project files**: the "Files" toolbar button shows a file tree (excluding `.gitignore`d files); markdown opens the same way, everything else in Quick Look.

### 4.8. Keyboard shortcuts (proposal)
| Action | Keys |
|---|---|
| New task (task window) | `⌘N` |
| Search tasks (in Projects: search documentation) | `⌘F` / `⌘K` (command palette) |
| Edit a document / task text | `⌘E`; leave with saving: `Esc` / `⌘↩` |
| Next session waiting for a reply | `⌘J` |
| Go to session 1–9 | `⌘1` … `⌘9` |
| Expand / collapse a session | `⌘↩` |
| Switch workspace tab | `⌃Tab` / `⌃⇧Tab` |
| New session with the settings of the last launched one | `⌘T` |
| New session without a task, choosing its settings | `⌘⇧T` |
| New workspace tab | `⌥⌘T` |
| Show / hide the task list | `⌘0` |
| Show / hide the inspector | `⌥⌘0` |
| Commit `.artel/` changes | `⌥⌘S` |
| Launch the selected task in a new session | `⌘R` |
| Close / stop a session | `⌘W` / `⌘.` (with confirmation) |
| Settings | `⌘,` |

---

## 5. Sessions and the agent

### 5.1. Launch
- The agent is started **through the `claude` CLI** (subscription resources are used, not API tokens).
- Each session is a process inside **tmux** on the app's own socket (`tmux -L artel`). The terminal in the UI is an embedded emulator (SwiftTerm) attached to the tmux session.
- Launch parameters:
  - working directory: the task worktree;
  - `--model <model>`;
  - `--permission-mode` from Project Settings (`auto` by default);
  - `--settings <app file>`: integration hooks (the user's project settings are left untouched);
  - `--add-dir <task folder>`: access to attachments;
  - the `ARTEL_SESSION_ID` environment variable.
- The first message in the session is the wrapper (task ID and title, project, worktree and branch, path to the task folder) plus the text of `task.md`.

### 5.2. Integration: session state
Via **Claude Code hooks** → a small `artel-hook` binary → the app's unix socket:
- `UserPromptSubmit` / `PreToolUse` → `working`;
- `Notification` → `waiting for reply` / `waiting for permission` (+ the question text);
- `Stop` → `finished (idle)`, end of turn;
- `SessionStart` → the Claude `session_id` is saved for restoring.

Questions and permissions are answered **inside the terminal** (no separate buttons in v1).

### 5.3. Integration: the agent working on a task
There is no separate channel: the agent gets the task as its first message and the task folder via `--add-dir`. The task status is changed only by the app (on launch) and by the operator. Manual edits to `task.md` are picked up on file change.

### 5.4. Clearing the context and switching tasks in a session
- Same task, no clearing: continue in the current context.
- Clearing the context, or a task from another worktree/project: the agent process in the slot restarts in the new working directory; the session slot (grid position, tab) is kept and renamed.
- Switching the model without a restart: `/model`.

### 5.5. Saving and restoring
- The workspace state (tabs, grid, session-to-task bindings, `session_id`) is saved continuously.
- Quitting the app **does not stop** sessions: tmux keeps running; on launch the app reattaches and everything is where it was.
- If a tmux session is gone (Mac reboot), the session is restored via `claude --resume <session_id>` in the same directory.
- A session is stopped only by an explicit action in the app.

### 5.6. Agent abstraction
The `CodingAgent` protocol: launch command, parameters (model, permission mode), integration method (hooks), list of models, commands for clearing the context / switching the model, the source of limits data. v1: `ClaudeCodeAgent` and `KimiCodeAgent` (Kimi Code's hooks are in `~/.kimi-code/config.toml`, resume via `kimi --session <id>`); later: Codex CLI, Gemini CLI, etc.

---

## 6. App settings
- Path to `claude` and `tmux` (auto-detection, version check).
- Whether to keep `.artel/` in git by default for new projects.
- Limits: refresh interval, notification threshold.
- Worktree root (`~/.artel/worktrees` by default).
- Notifications: on/off per event type, sound.
- Grid behavior: card size, sorting waiting sessions first.
- New task template and the system prompt wrapper.
- List of models and the default model.

---

## 7. Technology
- Swift 6, SwiftUI (+ AppKit where needed: terminal, file drag-and-drop), macOS 26+, arm64.
- Terminal: SwiftTerm.
- Markdown rendering: WKWebView with a custom `artel-res://` scheme and the markdown-it, markdown-it-container, KaTeX, Mermaid, highlight.js and rough.js libraries (MIT/BSD); `scripts/fetch-docs-web.sh` downloads pinned versions with sha256 verification, `build-app.sh` puts them into `Contents/Resources/DocsRenderer/vendor`. By default Excalidraw is drawn by a custom renderer on rough.js; Excalidraw's editor and exporter (~15 MB, built with Bun by `scripts/build-excalidraw-editor.sh`, published as a GitHub release) are downloaded at the operator's request (§4.9).
- Sessions: tmux. On first launch the app looks for an installed `tmux` (`PATH`, `/opt/homebrew/bin`, `/usr/local/bin`). If there is none, it uses the **tmux bundled with the app** (tmux 3.5a with static libevent and the system ncurses, arm64, signed together with the app): it copies it to `~/Library/Application Support/Artel/bin/` and works with that. Homebrew is not needed; the operator installs nothing by hand. The bundled one can be selected explicitly in Settings.
- `claude` is checked the same way: if it is not found, onboarding shows the install command and an "Install" button (the official Claude Code installer), then asks to sign in (`claude` → `/login`).
- Git: the system `git` CLI.
- App state (project registry, layout, settings): JSON/SQLite in `~/Library/Application Support/Artel/`; task data lives only in the projects' `.md` files.

### Modules
- `ArtelApp`: UI.
- `ArtelCore`: models, parsing/writing `task.md`, the session status state machine, file watching.
- `AgentKit`: the `CodingAgent` protocol, `ClaudeCodeAgent`.
- `SessionKit`: tmux, session lifecycle, restoring.
- `GitKit`: worktree, diff.
- `IntegrationServer`: the unix socket; the `artel-hook` binary.

---

## 8. Milestones
1. **MVP-0: sessions.** Projects, manual `claude` launch in a grid with tmux, state hooks, "waiting for reply" cards, notifications, restoring after a restart.
2. **MVP-1: tasks.** `.artel/tasks`, a task editor with drag-and-drop of references, a list with grouping/filters/search, quick entry, dragging a task into a session, worktree.
3. **MVP-2: cycle** (removed). MCP server, statuses and transitions by the agent, plan/review comments/progress, review and testing, merge on `done`. The diff tab is what remains of it.
4. **v1.** Tabs, subscription limits, keyboard shortcuts, polish.

---

## 9. Decisions made (history)
- `.artel/` is kept in git by default, with a `.gitignore` option in settings; the operator chooses when to commit `.artel/` (an action in the app); there are no automatic commits.
- The task ID prefix is `ARTEL` by default, configurable per project.
- Moving a task into a session of another task: clearing the context is mandatory, with a warning.
- Limits: via the existing Claude Code and Kimi Code OAuth logins (read-only) and their `/usage` / `/usages` APIs; each agent's visibility is set with checkboxes.
- tmux: the system one if present; otherwise the one bundled with the app.
- The task cycle (plan → review → testing → acceptance, review comments, `aide-mcp`, automatic merge) was removed: a task is a prompt with attachments, the worktree is optional at launch, and merging the branch is up to the operator. Task priorities and dependencies were removed along with it.

## 10. Open questions
None. Next step: implementing MVP-0.
