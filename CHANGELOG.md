# Changelog

What changed in each version of Aki. Versions follow [semantic versioning](https://semver.org); betas end in `-beta.N`. The release notes inside the app are written from this file.

## [Unreleased]

### Added
- ⇧-click while marking is a normal click on the app below (another sheet, a tab, a link), without making a mark; the screen is captured again right after. Marking a point moved to ⌘-click.

### Changed
- Marking opens almost at once (about 0.06 s instead of half a second): sessions are refreshed after the screen is up.
- The session picker while marking shows four sessions and a "+N" button: the others, hidden ones from the sidebar included, open in a list beside the card that you can drag.
- Updates are announced, not downloaded: a pill by the sidebar and a dot on the menu bar pin, like Orca. Click it to see what's new and install.

### Fixed
- Marks reach Orca tabs again after Orca restarts (its tabs keep running in a helper Aki didn't recognise, so nothing was typed).
- The sidebar's resize corner works again next to the last ring (its card no longer covers it), with a bigger spot to grab and a shorter drag between sizes.

## [0.2.0] — 2026-10-04

The first version for everyone.

### Mark anything
- Mark an element, an area or lines of text in any app with **⇧⌘A** — Chrome, Brave, Edge, Arc and Vivaldi give the exact element (selector, text, HTML, React source), no extension.
- Arrow keys walk the page like DevTools; elements in other apps, the browser's own bar and floating panels work too.
- Each mark carries its text and, when it helps, a crop — you choose what's ticked by default.
- A queue: **Queue it**, **Only this one** or **Send all**; queued marks survive leaving and restarting.

### Your agents
- One ring per Claude Code / Codex session, with the AI and the app it runs in (Orca, VS Code, Terminal…).
- Marks go to the right session by itself (the localhost port), then Aki types the request into its tab — waiting while you type or the agent works, with a countdown on the ring and a ✓ when the agent is done.
- MCP server and `aki` command for any agent; links `aki://` and Raycast commands.

### Around it
- History (**⇧⌘H**) with search and filters by AI, app, project and session.
- Get started: every permission, why, and a button straight to it.
- Nine languages, light and dark, four sizes, shortcuts you choose, updates by itself.
- Security: secrets on screen are never read, local server locked to your Mac, signed updates.
