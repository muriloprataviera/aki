# Changelog

What changed in each version of Aki. Versions follow [semantic versioning](https://semver.org); betas end in `-beta.N`. The release notes inside the app are written from this file.

## [Unreleased]

## [0.4.0] — 2026-10-10

### Added
- The card says when a mark's picture is on the clipboard ("Copied · ⌘V pastes it").
- Each mark's picture also goes to the clipboard (⌘V pastes it anywhere); Settings turns it off.
- A mark on a localhost page switches the destination to that port's session right then (unless you chose one yourself); two sessions named with the port: the one used last.
- Sessions untouched for more than two days wait in "+N" by themselves and come back when they move (never one with marks, the destination, or one working or waiting for you).
- The message typed to the agent says which session it's for and where the marks came from ("→ 3001 CONTACTS (from localhost:3001)"), and asks the agent to speak up if they aren't its own.
- Marking a localhost page picks the session named with its port ("3001 …"), even when the folder serving it can't be found.
- Each mark has a folder of its own, ~/.aki/marks/<day>/<code>/ (its picture and a record of the request); older pictures move there once.
- The message typed to the agent names the marks by code (`aki show df9f68`), so it works pasted into any terminal; `aki done` takes codes too.
- The comment card's buttons show their keys: ⏎ queues, ⌘⏎ sends.
- While marking, the arrows walk the screen (the thing above, below or beside, about the same size); ⇧↑ / ⇧↓ make it bigger or smaller.
- The History's queue sends right there (all, or one), and each mark's session can be changed from a menu.
- Drag a project by its name on the sidebar to move all its sessions together.
- The sidebar's destination follows the agent tab you click in Orca (other apps and tabs keep it; Settings turns it off).
- ⏎ marks what's outlined (after walking with ↑ ↓), as a click would.
- The "+N" list of sessions has a search field (name or project, any case or accent); ⏎ takes the first match, esc closes the list.
- Two bigger sidebar sizes, Extra large and Huge, for big monitors (the resize corner and Settings).
- The short `aki` command in Terminal: the one-line installer adds it (your password, once), and Get started offers it to those who came by the DMG.

### Changed
- The comment card shows the crop first, then the text read.
- Marking no longer takes the focus from the app below (as the Mac's own ⌘⇧4): its open menu stays open, its selection stays. Aki takes the keyboard only when you write a comment.
- Aki also looks for a new version when the Mac wakes up, not only on the hour.
- The sidebar's rings, in Aki's colours: the AI's symbol in the middle, and the ring tells the state — a light arc turning slowly while it works, red when it waits for you, quiet otherwise. Under each name, its state in a word (working, idle, waiting for you). The session your marks go to is framed, with "destination" and Aki's pin; your requests an AI hasn't finished show as "1 to do". No more initials, one colour per project or gradients.
- What Aki types to your agent is shorter and says what the marks are about ("📍 Aki: 2 new marks — “…” · “…”"), uses `aki` when it's there, asks to open a picture only when it matters, and to close all marks in one go.

### Fixed
- A copied mark is one picture on the clipboard (PNG and TIFF), so clipboard histories like Raycast's show it with its preview.
- A mark says the app and page where it was made, even when marking began in another app.
- The comment card's buttons fit again with three of them (the keys show when there's room).
- While marking, scrolling over Aki's own lists (other sessions, the queue) scrolls them, not the page below.
- The sessions list opens to the card's right (below it when the card is at the edge), and the queue moves out of its way.
- Session names no longer carry a frozen copy of the tab's status sign (✳); the ring shows the state live.
- What floats over an Orca terminal (its update notice, a dialog) can be outlined: Aki looks past the terminal's see-through layer.
- ⌘Tab works while marking: holding ⌘ lets the app switcher show over the marking screen.
- A page's elements are asked to the page again where Aki wrongly thought a menu had closed (the picture-only lookup and its half-page outlines are gone there).
- On a page, ↑ reaches the whole page at last (some sites, like Airtable, stopped short of it).
- The outline of something as big as the screen (a whole page) stays inside it, all four corners in sight.
- A ring no longer spins for a session that's resting while a background task runs (Orca's tab says so).
- In a frozen picture, ↓ goes from a menu item down to one line of its words (a subtitle).
- An open menu (a page's drop-down or <select>, a right-click menu) stays in the picture when you press the shortcut, and its items can be marked.
- Pointing inside things a page embeds from elsewhere (Claude's artifacts, videos, payment forms) finds the button or text under the pointer; the browser keeps their inside closed, so Aki used to see only the whole box.

## [0.3.3] — 2026-10-06

### Added
- Betas read short on screen: "0.3.3 beta".
- The History shows the queue (marks saved but not sent) in its own block on top, apart from the rest; the menu bar pin's menu has "See the queue". esc closes the History even from the search field.

### Changed
- The tag over what you point at says "↑ bigger · ↓ smaller": ↑ takes what holds it (a block, the whole terminal, the window).
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
