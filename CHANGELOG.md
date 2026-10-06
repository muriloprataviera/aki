# Changelog

What changed in each version of Aki. Versions follow [semantic versioning](https://semver.org); betas end in `-beta.N`. The release notes inside the app are written from this file.

## [Unreleased]

### Added
- Versions read short: "0.3.3 beta", not "0.3.3-beta.3".
- The History shows the queue (marks saved but not sent) in its own block on top, apart from the rest; the menu bar pin's menu has "See the queue". esc closes the History even from the search field.

### Changed
- Updates never restart Aki while marks wait to be sent: it downloads, says "updates once the queue is sent", and restarts after. The update's state also shows in the menu bar pin's menu and in Settings, for those who hide the sidebar. Checking for updates only shows what's new; installing is always a click.

### Changed
- Every grab spot (comment card, queue, "+N" list) has the same six dots as the sidebar's handle.
- In the queue, the destination is plainly a chooser ("To: … Change", outlined) and the button plainly says "Send".

### Fixed
- The sidebar's resize corner no longer vanishes after the pointer goes back and forth over it.
- Pointing at Orca's own pop-ups (and anything over its terminals) finds the button or text under the pointer; Orca answered with a see-through layer over the whole window.
- The sidebar's rings no longer show a tiny crop of each waiting mark (it read as a stray window icon); the number says how many wait.
- The sidebar's pointer (the resize arrows in its corner, the hand on buttons) no longer falls back to the plain arrow when the app below puts it back.
- Betas now update to the next beta and to the final version: each build carries a number that only grows (Sparkle read "0.3.3-beta.1", "0.3.3-beta.2" and "0.3.3" as the same version).
- **Marks could go to the wrong conversation**: session names came from a copy of Orca's tab names that Orca stopped updating, so an old name ("ORDERS TAB") showed on a conversation that is now another one. Names now come only from Orca's live list.
- Marking opens on the session you chose last — never one guessed from activity (a session also starts working on its own).
- A dragged comment card or queue stays on its screen; the next mark's card opens in its own place.
- The number of marks in the queue on the sidebar stays right.

## [0.3.2] — 2026-10-06

### Added
- Updates happen inside Aki, like Orca: the pill says there's a new version; a click downloads it right in the pill (a bar filling up, Aki's pin riding its tip), then Aki restarts by itself on the new version and says so for a moment. No Sparkle windows.
- The comment card can be dragged by its top, off what you want to see.

### Changed
- Anonymous notices to the maker, said plainly in Get started with what goes and why: one when Aki is installed and one each time it updates (its version and the one before, macOS version and language; no account, no identifier, nothing you mark). They tell how many people use Aki and on which version. One switch turns them off (Get started or Settings → General → Privacy).
- The queue's destination is a field you can see is clickable: the AI, the app and the session's whole name, with the menu arrows.
- Aki looks for a new version every hour (was once a day), so the update pill shows up soon after a release.

## [0.3.1] — 2026-10-05

### Fixed
- Pointing inside apps that answer nothing at all (Telegram) now finds the message, button or icon from the picture; in 0.3.0 it still took the whole window.

## [0.3.0] — 2026-10-05

### Added
- Apps that don't say what's in their window (Telegram, games, some design apps) and pages drawn as one canvas: Aki finds the box under the pointer in the picture itself — a message bubble, a row, a button, an icon, a photo, a spreadsheet cell — with ↑ for what holds it (a cell's row, a bubble's chat).
- The History lists the queue (marks saved but not sent) at the top: keep marking with it, drop one, or clear it.
- ⌘+ / ⌘− / ⌘0 while marking zoom the page below (the browser's own zoom); the screen is captured again right after.
- The queue shows every mark (it scrolls), can be dragged by its top, and marks can be ticked and removed together before sending ("Remove N" or ⌫).
- Zoom on a mark's picture: "Zoom" on the card's crop, or click the thumbnail in the queue or the history. Pinch or ⌘-scroll to zoom, double-click for fit / 100 %, esc to close.
- ⇧-click while marking is a normal click on the app below (another sheet, a tab, a link — Chrome too, which is brought forward first), without making a mark; the screen is captured again right after. Marking a point moved to ⌘-click. While ⇧ is held the pointer is the normal arrow everywhere (buttons too) and nothing is outlined.
- The session picker shows whether each session is working, waiting for you or idle (as on the rings), and Claude Code's state now shows within half a second instead of up to 3.5 s.

### Changed
- Marking opens with the session you last sent a message in as the destination (unless you picked another one after that).
- Marks go to the terminal 3 s after you stop (was 5 s); still adjustable in Settings.
- Marking opens almost at once (about 0.06 s instead of half a second): sessions are refreshed after the screen is up.
- The session picker while marking shows four sessions and a "+N" button: the others, hidden ones from the sidebar included, open in a list beside the card that you can drag.
- Updates are announced, not downloaded: a pill by the sidebar and a dot on the menu bar pin, like Orca. Click it to see what's new and install.

### Fixed
- The crop tile and the on/off keys in the card show the hand pointer.
- Sessions take the name you gave their tab in Orca (e.g. "ORDERS TAB") instead of the conversation's topic.
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
