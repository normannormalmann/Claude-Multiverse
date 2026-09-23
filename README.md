# Claude Multiverse

**Run multiple isolated Claude Desktop instances side by side on Windows** — one for
work, one for private use, each with its own account, connectors, MCP servers, settings
and Cowork environment. No logging in and out, no lost Cowork schedules.

*Deutsche Version: [README.de.md](README.de.md)*

![Two Claude Desktop instances side by side - Work and Private](docs/screenshot.png)

## Install

```powershell
irm https://raw.githubusercontent.com/normannormalmann/Claude-Multiverse/main/install.ps1 | iex
```

Then:

```powershell
cmv new private
```

The guided setup creates the instance, generates a coloured icon so you can tell the two
apart in the taskbar, registers a launch task so you never see a UAC prompt, puts a
shortcut on your desktop, and offers to start it right away.

Prefer a clone? `git clone`, then `.\install.ps1` — same result, files copied instead of
downloaded.

## How it works

Claude Desktop is an Electron app. Electron honours `--user-data-dir`, which redirects
the *entire* application data directory: auth tokens, `claude_desktop_config.json`, VM
bundles, session state, Cowork disk images. Two launches with two directories give you
two fully independent apps from one installation.

The Windows twist: Claude Desktop ships as an **MSIX package**, from the Microsoft Store
and from `ClaudeSetup.exe` alike. MSIX apps are activated by package identity, and the
usual routes (tile, `shell:AppsFolder`) drop command-line arguments on the floor. The
one way through is `Invoke-CommandInDesktopPackage`, which keeps package identity *and*
passes arguments — but needs elevation.

To keep that from meaning a UAC prompt on every launch, `register` creates a Task
Scheduler task that runs with highest privileges. Shortcuts then just trigger the task.
Windows doesn't re-prompt for your own scheduled tasks, so launches are silent.

The task is self-contained: its action is the launch command itself (load the Appx
module from System32, resolve the package, call `Invoke-CommandInDesktopPackage`). It
does not execute this script or any other file, so nothing a non-elevated process could
edit later runs with elevated rights behind your back. `stop`, `remove` and `register`
do run the script elevated, but only after you confirm a UAC prompt.

Classic (non-MSIX) installs are detected and launched directly — no task, no prompt.

## Commands

After install, `cmv` is on your PATH. Without arguments it opens an interactive menu.

| Command | What it does |
| --- | --- |
| `cmv new [name]` | Guided setup: directory, icon, task, shortcut, optional launch |
| `cmv launch <name>` | Start an instance |
| `cmv stop <name>` | Close an instance and all its helper processes |
| `cmv shortcut <name>` | Shortcut. `-Label "…"`, `-Icon x.ico`, `-StartMenu`, `-Force` |
| `cmv register <name>` | Scheduled task so launches skip UAC (MSIX only) |
| `cmv unregister <name>` | Remove that task |
| `cmv clone-config <from> <to>` | Copy local MCP config between instances; `default` = built-in |
| `cmv open <name>` | Open the instance's data folder |
| `cmv list` | Instances with size, running state, shortcut and task status |
| `cmv remove <name>` | Delete an instance, its task, shortcuts and icon |
| `cmv doctor` | Check the environment |

Instance data lives in `%USERPROFILE%\.claude-instances\<name>`, icons in
`%USERPROFILE%\.claude-icons`. The built-in data directory is always available as
`default` — launch Claude normally to use it.

## Signing in to a new instance

This is where everyone stumbles. The instance is isolated, but **the login runs in your
default browser**, which is already signed in with your other account. Google or
Microsoft then wave the login through silently and the new instance ends up with the
wrong account.

1. Close every other Claude instance, including the tray icon. The `claude://` callback
   goes to whichever instance handled the protocol last.
2. Sign out of the identity provider in your default browser, or open its account picker
   (`accounts.google.com/Logout` for Google).
3. Sign in from the new instance.
4. Sign back into your other account in the browser. Once both accounts are known there,
   future logins show a picker instead of reusing one silently.

Email-code sign-in bypasses the browser session and needs none of this. The script prints
this reminder when an instance is launched for the first time.

## What is shared and what isn't

**Per instance:** account, conversations, projects, connectors, MCP servers, settings,
Cowork environment, `claude_desktop_config.json`.

**Shared:** the Claude Desktop installation and therefore its version. One update, every
instance.

`cmv clone-config default private` copies your local MCP server configuration into a
new instance. It lists each server's `env` keys first so you can see which credentials
would travel, backs up the target's existing config, and refuses to run without
confirmation. Remote connectors are tied to the account and are *not* copied — authorise
them again in the new instance.

The built-in instance keeps its data in `%APPDATA%\Claude`, even on the MSIX install —
the package is not virtualised. `cmv open default` takes you there.

## Requirements

- Windows 10 or 11
- Claude Desktop installed
- For MSIX installs: an account in the Administrators group. `new` prompts once to
  register the launch task; after that, launches are silent. `stop` and `remove` prompt
  once more, because the instance runs elevated.
- PowerShell 5.1 or 7 — the script bounces itself to 5.1 automatically because the
  Appx and ScheduledTasks modules live there.

## Troubleshooting

**`%LOCALAPPDATA%\AnthropicClaude` doesn't exist.** You have the MSIX install; that path
belongs to the old classic installer. `cmv doctor` shows what was detected.

**The new instance loaded my existing account.** Browser SSO reused your session. See
[Signing in](#signing-in-to-a-new-instance).

**I still get a UAC prompt.** No task registered — `cmv register <name>`, then recreate
the shortcut with `cmv shortcut <name> -Force`. `cmv list` shows task status.

**The shortcut shows the wrong icon.** Windows caches icons aggressively. Run
`ie4uinit.exe -show`, or sign out and back in.

**Nothing happens when I click the shortcut.** A failed launch shows a message box and
appends the error to `%USERPROFILE%\.claude-instances\last-error.log`. Run
`cmv launch <name>` in a terminal to see it live. Most likely the task's script path
moved — reinstall, or re-run `cmv register <name>`.

**`Invoke-CommandInDesktopPackage` not found.** You're in PowerShell 7 and the automatic
bounce failed. Run it explicitly:
`powershell.exe -File "$env:LOCALAPPDATA\ClaudeMultiverse\claude-multiverse.ps1" doctor`

## Known limitations

- **Elevated token.** MSIX instances run from an elevated context. Cowork should be tested
  in a fresh instance before you depend on it. Closing such an instance needs elevation
  too, so `stop` and `remove` show one UAC prompt.
- **A silently elevating task is a trust decision.** The task carries its complete launch
  command and touches no editable file, but it still means "start Claude with this data
  directory" runs as administrator whenever the shortcut is clicked. `cmv unregister
  <name>` removes the task if you would rather confirm UAC on every launch.
- **The data directory is writable without elevation.** The instance runs elevated but
  reads its configuration from a folder any process under your account can modify.
  `claude_desktop_config.json` lists MCP servers as commands that Claude starts as child
  processes, so malware already running as you could plant an entry there and have it
  started with administrator rights on the next launch. This is inherent to "elevated
  app, user-writable data" and not specific to this tool. It does not give an attacker a
  way in, but it turns an existing foothold into full administrator access. Treat your
  Windows account with the same care you would give an administrator account, because
  with these instances it effectively is one.
- **Disk.** Each instance builds its own Cowork environment. Budget several GB — a fully
  set-up instance with Cowork can reach ~10 GB.
- **Slow first launch** while the empty data directory is populated.
- **Console flash.** Shortcuts briefly show a minimized console window; that's `schtasks`
  starting. Cosmetic.
- Untested with enterprise-managed deployments (Intune, SCCM) and standard-user accounts.

## macOS and Linux

Not covered here. For macOS, use Philipp Stracker's
[`claude_quick.sh`](https://gist.github.com/stracker-phil/9f84927a556632c7f9cc06663b534f14),
which does the same thing with `open -n -a` and needs none of the MSIX handling. There is
no official Claude Desktop for Linux. Pull requests welcome, but only for code you've run.

## Credits

The `--user-data-dir` approach, and the analysis of why symlink and directory swapping
break the Cowork VM, come from Philipp Stracker's
[Running Multiple Claude Desktop Instances Side by Side](https://philippstracker.com/multiple-claude-instances/),
which builds on [weidwonder/claude-desktop-multi-instance](https://github.com/weidwonder/claude-desktop-multi-instance).
This repository is the Windows counterpart, including the MSIX handling that macOS
doesn't need.

## Disclaimer

Not affiliated with or endorsed by Anthropic. Claude and Claude Desktop are Anthropic's
products. This script passes a documented Electron flag to an app you already have
installed — unsupported usage that may need adjusting when Claude Desktop changes.

Use at your own risk. The instances run with administrator rights, and the trade-offs
this involves are described under [Known limitations](#known-limitations). Read them
before you rely on this tool, especially on a machine you share or use for work.

## Licence

MIT
