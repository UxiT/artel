# Artel ⚒️ — a crew of coding agents on your Mac

<p align="center">
  <img src="docs/assets/icon.png" width="160" alt="Artel: a grid of agent sessions, one waiting for a reply">
</p>

<p align="center">
  <a href="https://github.com/UxiT/artel/releases/latest"><img src="https://img.shields.io/github/v/release/UxiT/artel?style=flat-square&label=release" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B%20%C2%B7%20Apple%20Silicon-black?style=flat-square&logo=apple" alt="macOS 26+, Apple Silicon">
  <img src="https://img.shields.io/badge/Swift-6.2-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 6.2">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0-blue?style=flat-square" alt="License: GPL-3.0"></a>
</p>

Artel is a native macOS app that runs several Claude Code and Kimi Code sessions in parallel in one window. Next to them sits a lightweight task board: a task is a prompt with attachments that you drop into a session, optionally in its own git worktree. Each session card shows what the agent is doing: working, waiting for your reply, asking for permission, or finished.

**Agents keep running.** Sessions live in their own tmux server and survive quitting the app; after a reboot they come back via `--resume`. Tasks are plain files in the repository (`.artel/tasks/`): you can edit them by hand and commit them.

[Download](https://github.com/UxiT/artel/releases/latest) · [Specification](docs/SPEC.md) · [Keyboard shortcuts](#keyboard-shortcuts) · [Development](#development) · [License](#license)

## Installation

1. Download `Artel-<version>.dmg` from the [latest release](https://github.com/UxiT/artel/releases/latest), open it and drag `Artel.app` onto the Applications folder.
2. On first launch macOS blocks the app with "“Artel” Not Opened": the app is not notarized by Apple, which requires a paid developer account. Click "Done" (not "Move to Trash"), then open "System Settings → Privacy & Security", scroll down to the message about Artel and click "Open Anyway". Alternatively, run in Terminal:
   ```sh
   xattr -dr com.apple.quarantine /Applications/Artel.app
   ```
   This is needed only once; updates install without this step. The same instructions are included in the DMG as a first-launch note.
3. You need at least one agent: [Claude Code](https://github.com/anthropics/claude-code) (`claude`) or Kimi Code (`kimi`). tmux is bundled.

After that Artel updates itself via [Sparkle](https://sparkle-project.org): at every launch (and once a day while it is open) it checks for releases and, if a new version is out, offers to install it in a separate window with release notes. To check manually, use "Artel → Check for Updates…".

## Quick start

1. Add a project: any folder (⇧⌘O or drag it from Finder). If it has no `CLAUDE.md` or git, Artel offers a template and `git init`; you can decline. Without git, tasks run directly in the project folder, without a separate worktree.
2. Open a session (⇧⌘T), or create a task (⌘N) and drag it onto "+" in the session grid.
3. Work in the agent's terminal as usual. Sessions waiting for you are counted in the title bar and marked in the Agent Sessions panel; ⌘J jumps to the next one.

## Features

- **Workspace:** a grid of sessions with a terminal and agent status on every card, tabs, cards that stretch across grid cells, notifications and a Dock badge when an agent is waiting for you.
- **Task board:** "New / In Progress / Done". Files go into the task text as `@path` references or are copied into attachments.
- **Optional worktree:** a task gets its own working copy and branch `artel/<ID>-<slug>`; the "Changes" tab shows the diff. You merge the branch yourself: Artel never merges anything.
- **Sessions without a task** are kept in the no-task archive for 7 days; a useful one can be added to the board. The archive can be turned off in Settings, in the New Session window or in the card menu.
- **Project documentation** inside the app: pages in `docs/` (Docusaurus-compatible), Mermaid and Excalidraw diagrams (draw Excalidraw diagrams right in a page, like in Obsidian, after a one-time ~15 MB download in Settings), formulas, `:::note` admonitions, search, links with autocompletion, images pasted from the clipboard. You can hand a page or a selected fragment to an agent. Alongside are `CLAUDE.md` and the agent context rules; project files are behind the "Files" button in the title bar.
- **Markdown is always rendered** (tasks, documentation); "Edit" (⌘E) opens the source text, Esc / ⌘↩ / "Done" save and return to the rendered view, unsaved changes are marked with a dot.
- **Subscription limits** for Claude Code and Kimi Code in the status bar, with a notification at a threshold. They are read through your existing CLI logins, read-only.

## How it works

```
Artel.app ──tmux new-session──▶ tmux -L artel ──▶ claude --settings <hooks> --session-id <id>
   ▲                                               │ hooks
   │ unix socket (live)                            ▼
   └──────────────────────────────────────── artel-hook ──▶ events/<session>.jsonl (source of truth)
```

- The agent runs in a private tmux server; the app shows it in an embedded terminal (SwiftTerm).
- The agent's hooks call `artel-hook`: it appends the event to the session log and wakes the app through a socket. A card's status is restored from the log, including after a restart.
- App data lives in `~/Library/Application Support/Artel/`, tasks in each project's `.artel/`.

## Keyboard shortcuts

| | |
|---|---|
| ⌘N | new task |
| ⇧⌘T | new session without a task |
| ⌘R | launch the selected task |
| ⌘J | next session waiting for you |
| ⌘1…⌘9 | go to a session |
| ⌥⌘1 / 2 / 3 | sections: Workspace / Projects / Tasks |

<details>
<summary>All keyboard shortcuts</summary>

| | |
|---|---|
| ⌥⌘1 / ⌥⌘2 / ⌥⌘3 | sections: Workspace / Projects / Tasks |
| ⌘E | edit a document or the task text |
| ⌘S | save without leaving edit mode |
| Esc / ⌘↩ | save and return to the rendered view |
| ⌘N | new task (task window) |
| ⌘F | search tasks; in the Projects section, search the documentation |
| ⌘R | launch the selected task |
| ⌘O | open the selected task |
| ⌥⌘S | commit `.artel/` |
| ⌘T | new session with the settings of the last launched one |
| ⇧⌘T | new session without a task, choosing its settings |
| ⇧⌘O | add a project |
| ⌥⌘T | new tab |
| ⌘J | next session waiting for you |
| ⌘1…⌘9 | go to a session |
| ⌘↩ | expand / collapse |
| ⌘W / ⌘. | close / stop a session with confirmation (in the main window); in a task window and in Settings ⌘W closes the window |
| ⏎ / double-click | open the selected task or session archive |
| ⌥← / ⌥→ | on the board: move the selected task to the adjacent column |
| ⌃⌘S | show / hide the tool panel (or click the open section's icon in the rail) |
| ⇧↩ | in a session terminal: new line in the agent prompt |

</details>

## Development

Only the Command Line Tools are required; Xcode is not.

```sh
scripts/build-app.sh            # → build/Artel.app (--install also copies it to /Applications)
scripts/test.sh                 # unit tests
scripts/release.sh 0.2.0        # GitHub release; one-time setup is in the script header
```

Architecture, debug variables (`ARTEL_HOME`, `ARTEL_SNAPSHOT`…) and rules for coding agents are in [CLAUDE.md](CLAUDE.md); the product specification is in [docs/SPEC.md](docs/SPEC.md).

## License

[GNU GPL v3.0](LICENSE) © 2026 UxiT. Licenses of the dependencies (MIT, BSD, ISC, Apache-2.0) are in `Artel.app/Contents/Resources/Licenses/`.
