# Security

The app runs with access to sensitive parts of your Mac: Accessibility (optional), your calendar, and the config files of coding agents (Claude Code, Codex, Cursor), where it installs a small hook script when you click **Connect**. Please report anything that could be abused.

## Reporting a vulnerability

Please **don't open a public issue**. Use GitHub's private reporting instead: **Security → Report a vulnerability** on this repository. Include steps to reproduce, the affected version, and your macOS version.

You'll get a reply within a few days. Fixes ship as a normal update through the built-in updater.

## What the app does with your data

- Usage numbers are read from local agent logs (`~/.claude`, `~/.codex`) and never uploaded.
- Hook events are written to `~/Library/Application Support/<App>/AgentEvents` and deleted once read.
- Network access is limited to weather (MET Norway) and update checks (GitHub). The app has no analytics or tracking.
