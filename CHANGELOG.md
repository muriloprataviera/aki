# Changelog

What changed in each version of Aki. Versions follow [semantic versioning](https://semver.org); betas end in `-beta.N`. The release notes inside the app are written from this file.

## [Unreleased]

### Fixed
- History takes the keys as soon as it opens, so esc closes it without clicking it first.
- With a second copy of Chrome open (a test one, another profile folder), a mark on a localhost page could read that copy's page and go to the wrong session: now only the window with your page's title counts.

## [0.11.0] — 2026-10-21

### Added
- Settings → Marking → "Under the pointer": "Just a picture" works like the Mac's ⌘⇧4, with nothing outlined: drag an area or click a point, and the picture always goes with the mark. "Elements" (as before) outlines what's under the pointer, and a click marks it.
- Settings → Appearance → "Show at least" (3 to start): when fewer sessions than that are awake, the ones used last stay in sight instead of waiting in "+N", so the sidebar isn't empty after a night. 0 keeps the old way.

### Changed
- Limits card: each limit says the day and time it renews ("↻ Thu 12:00 · 23h30"), not only how long is left.

## [0.10.1] — 2026-10-20

### Changed
- A session you sent nothing to for five hours (no message, no mark; was: untouched for six) waits in "+N", even if it keeps running on its own, is the destination or has old marks waiting, and comes back as soon as you send it something (a `/clear` or `/resume` counts). One that finished a long job and is asking you something stays in sight. Codex sessions now do too. Sessions whose messages can't be known (the Claude app's, other agents') keep the old rule.
- Marking opens faster: the screens are known ahead, so it no longer asks the Mac for every window before showing.

### Fixed
- A mark on a localhost page goes to the agent working on it, Codex as much as Claude: the one you picked, if it's in that project, then the one that started the page's server, then the one that talked about its address lately, then the one used last. Codex sessions now know when they were last active, so they no longer lose to a Claude in the same folder.
- Two servers on one port (one on `[::1]`, another on `127.0.0.1` or all addresses): the page belongs to the one the browser opens at that address.

## [0.10.0] — 2026-10-18

### Added
- Limits rings: right-click one to choose, for that AI alone, what it shows and the line under it. New: the time left in the 5-hour session ("5H 1h47"), the time until the week renews, and the month on plans that have a monthly limit. Each menu offers only what that AI reports.
- Limits card: below the limits, the week's models and projects and your all-time numbers, as much as fits on the screen (nothing gets cut off). The rest is in Settings → Usage (also from "Models, projects and all time" at the foot of the card): each AI's models and projects this week, the days in a row, the busiest day and tokens week by week, counted from the logs on your Mac.
- Codex: "More from Codex" in Settings → Usage (off until you turn it on) asks OpenAI, with the sign-in Codex keeps on your Mac, for your limit resets saved, all-time tokens and chats, longest task and what you call most.

## [0.9.0] — 2026-10-17

### Added
- History: a mark sent to the wrong session can go to another one. "Send to another terminal" sends a copy and keeps the original where it went, even once it's done.

### Fixed
- A session's card stays open while you move the pointer up to it: the rings and the drag handle crossed on the way no longer close it or swap it for another.

## [0.8.9] — 2026-10-16

### Fixed
- Aki never types into a terminal while Claude Code is asking you something (a permission): its Enter used to answer it. The marks wait and go once you've answered.
- Esc on a queued mark you opened again closes it as it was, instead of deleting it.
- `aki wait` returns marks sent while the agent was busy, instead of waiting for the next one.
- The terminal message names only the marks not sent yet (an agent busy with one no longer starts it over), and `aki show` says when a mark is already done.
- Running `aki` from an agent's shell shows its usage instead of opening a second Aki; only one Aki runs at a time.
- An update never restarts Aki in the middle of a send.
- The picture limit never deletes a pending mark's picture.
- The Screen Recording alert offers to restart Aki when it comes back (macOS applies the permission only after a restart).
- A send to the Codex or Claude app without Accessibility fails at once, with the right message.
- Every program Aki runs (git, lsof, Orca's command, the shell) has a time limit: one stuck no longer stops the sidebar or a send.
- A rare crash while marking on a slow web page.
- A mark sent with no comment always goes with its picture (the agent used to get "(no comment)" alone).
- Marks sent while a send to the same session is still going wait their turn instead of being lost.
- A message left in the Codex or Claude app's box shows as "Left in its box: click to send", not as sent, and the card keeps its send button.
- History's send arrow shows sending, sent or not sent, sends every open mark of that session, and is hidden where Aki can't type (Terminal, iTerm).
- Aki stops pressing Return when it only adds blank lines to an app's box, and gives the clipboard back only if you didn't copy something meanwhile.
- A stuck Orca no longer leaves sends stuck "sending" for good.

- On a light Mac the sidebar and its cards are light, instead of black glass under dark text.
- The folded sidebar is easier to catch (a bigger area wakes it) and doesn't fold the moment the pointer strays.

### Changed
- Much lighter on the Mac: the rings and the agents' symbols turn in Core Animation (no redraw of the sidebar), the sidebar works its order out once per change, transcripts, Codex logs and the process list are read again only when they change, following Orca's tab never stalls Aki and Orca stops describing itself when it's not in front, and closed windows stop working.

## [0.8.8] — 2026-10-16

### Fixed
- The send arrow in History works again for the Codex and Claude apps: a mark that didn't go is sent again (from the box when it's still there), and one that already went isn't sent twice.
- Marks sent to a new Codex conversation are counted as sent: Aki waits a little longer for the message to show.

## [0.8.7] — 2026-10-16

### Changed
- Sessions and conversations untouched for six hours (not a day) wait in "+N", so the sidebar keeps only what you're using.

## [0.8.6] — 2026-10-16

### Fixed
- A double-click on a Claude app or Codex app conversation's ring opens that conversation in the app, like an Orca tab.
- The marks already with the agent ("1 to do") are always listed on the ring's card, and a click on them opens that session's History, where you can see and resolve each one.

## [0.8.5] — 2026-10-16

### Added
- Your conversations in the Claude app (chats) and the Codex app show in the sidebar, one ring each (the recent ones; those untouched for a day wait in "+N"): marks sent to one open that conversation in the app and go in there. Listed in Settings → Claude Code / Codex too, to switch any off.

### Fixed
- The "+N" card no longer runs off the bottom of the screen with many sessions: it lists the ones that fit and says how many more there are.

## [0.8.4] — 2026-10-15

### Added
- History → Sessions: your conversations of the last 7 days (Claude Code in a terminal or the Claude app, Codex), open or closed, with search, like Orca's session history. An open one takes you to it; a closed one resumes in a new Orca tab (or, with only the Claude app, a new Code session opens in its folder). Also from the "+N": "This week's sessions…".

### Fixed
- The Claude app's Code sessions are found by their own process, also when the app writes no session record for them (in 0.8.3 they could still be missing).

## [0.8.3] — 2026-10-15

### Added
- The Claude app's Code sessions show on the sidebar like terminals, and marks sent to one go into it in the app (picked on the app's list when another is open; if Aki can't make sure, nothing is sent).
- "What Aki found" counts the Claude app's Code sessions.
- Settings → Claude Code and Codex: "Search for sessions", to look for them again right away.
- With more than one display, right-click the sidebar → Screen: choose which one the bar lives on.
- A "looking…" ring turns while Aki looks for your open sessions (after Connect, on "Search again"), and they fill in as they're found.

### Fixed
- The sidebar no longer hides under a Dock kept on the same edge (it sits beside it).

## [0.8.2] — 2026-10-15

### Fixed
- The rings' numbers go in order (1, 2, 3…) without skipping the sessions kept in "+N", and ⌘1, ⌘2… while marking follow the same numbers.
- "Connect" also connects the Claude app's Code tab when there is no `claude` command (it uses the Claude Code that comes with the app).

## [0.8.1] — 2026-10-15

### Added
- Settings → Agents → "What Aki found": whether Aki sees the Claude and Codex apps, their terminals and their limits, with "Search again".
- Right-click a limits ring: "Search again" and "What Aki found…".
- A limits ring shows as soon as Aki sees Claude or Codex (the app open, a terminal), empty until its numbers come, and right after "Connect".

### Changed
- Aki uses less of the Mac with many terminals open: the Orca tab you're in is looked up once while you stay in it, and each terminal's folder comes straight from macOS.

### Fixed
- Claude's limits ring shows for people who use the Claude app and not Claude Code (read from the app's own usage answer on this Mac).

## [0.8.0] — 2026-10-15

### Added
- "Wake the agent after" can be set to instant: marks go into the session's tab the moment you send them.
- Each ring shows, in a small badge, the app its session runs in (Orca, the Codex or Claude app, Terminal…).
- The Claude and Codex desktop apps' rings show the name of the conversation you last sent to.
- A limits ring turns whenever its AI is at work: also while the Claude or Codex app is answering, and during runs with no window of their own (like a `codex exec`).

### Changed
- Codex's ring turns blue while it works, the colour of its icon (it was green).
- The line under a limits ring that said "TODAY" is now "PACE": how much you've used against an even week so far. Under 100% is on track, and it only turns orange or red past that.

### Fixed
- The Codex app no longer adds a ring named "Resources" (one of its own helpers, not a session).
- The message Aki sends to an app names its marks (#3ba324…) in its first line.
- Sending to the Claude and Codex desktop apps works in a new conversation (its box in the middle of the window), with the app minimized, its window closed or just opened, and with the focus elsewhere in it; a send that went is no longer left as "pasted", and your own text in the box stays apart from Aki's.
- Aki no longer slows the Mac down: apps it looked into while you marked (Chrome, the Claude and ChatGPT apps) are left as they were afterwards, instead of describing every change on screen for good, and the app rings no longer search the app's window every few seconds.
- Aki does far less in the background: token counts saved every ten minutes instead of every half minute, one process listing per pass, the sidebar redrawn only when something changed, and the History doing nothing while closed.
- Marking opens at once, like the Mac's own screenshot: all screens are captured together, and the page's address is asked after the overlay is up.
- "Connect" works for people who only use the Claude or ChatGPT/Codex app, with no `claude` or `codex` command installed.

## [0.7.1] — 2026-10-13

### Changed
- A Codex ring in a terminal shows the name Codex gave the conversation (like "Revisar NFs no Drive") instead of the folder; an app's ring shows the conversation its window names.

### Fixed
- A mark on a localhost page goes to the session serving that page's port, also in a browser window that isn't the one in front (another screen) and right after you were in another session's tab.
- Send in the History's queue held every mark back with just a beep when one of them was meant for a session that had closed; now the others go, and that one asks where to go.

## [0.7.0] — 2026-10-13

### Added
- Codex's and Claude's desktop apps are destinations too: with one open, it shows as a ring, and its marks are pasted into the conversation open in it, pictures and all, and sent.

### Fixed
- A Codex session working with subagents keeps showing it's working.

## [0.6.3] — 2026-10-13

### Added
- A session in Orca shows the name you gave its tab there (like "ENVIO CNPJ"), not only the title the agent set.
- The Claude and Codex limits rings show when they're in use: the AI's symbol turns slowly while one of its sessions is working.
- A working session's turning arc is in its AI's colour (Claude's orange, Codex's green), and so is the turning symbol on the limits ring.

### Fixed
- The first time you marked in Chrome, the Mac asked whether Aki may control it, under the marking overlay: Allow couldn't be clicked and the screen stayed covered. Now marking never brings that question up; the Mac asks once marking is over.
- Marking a page on localhost picks the session serving that port (or named with it, like "3000 …") even right after you were in another session's tab.
- A long first project name no longer covers the eye that shows or hides the projects.
- A Codex session now shows it's working (turning arc, turning symbol on its limits ring) the whole time it's thinking, not only in the moments it used the processor.
- Marking a page's own menu (an account dropdown, for example): it closed as you clicked to write the comment and the mark was left over nothing; now the screen keeps it, and you can go on marking its items.

### Added
- While marking, the chosen session shows the start of what its agent wrote last (and the pointer on any other session shows its own), so you can tell it's the right one without switching to it.
- Right-click a limits ring to choose what it shows (week, today's share or the 5-hour session), the line under it (or just the name of what the ring shows), and to hide that AI's ring; the sidebar menu brings it back.

### Changed
- Sessions untouched for more than a day (it was two) move into the "+N" ring, also when they are waiting for you or have a shell open; they come back as soon as they move.
- The "+N" ring is a quiet dashed outline with the count, so it no longer looks like a session's ring. Its card lists the sessions you hid apart, under their own title.

## [0.6.2] — 2026-10-12

### Fixed
- Aki quit when marking started while the same Claude conversation was open in two tabs.
- Marking a menu bar app's dropdown (like iStat Menus): it closed at the first click; now it stays in the picture, like other menus.
- When you had something written in the agent's box, Aki typed its request after it but didn't send; now both are sent.

### Changed
- Aki looks for a new version every 10 minutes (it was every hour), so the update pill shows soon after a release.

## [0.6.1] — 2026-10-11

### Added
- Support Aki and Check for Updates at the foot of the Settings sidebar, above Quit.

### Fixed
- Settings → Agents → Connect said “Failed” for Claude Code when it was installed with its own installer (in ~/.local/bin).

### Changed
- Right-clicking a session's ring shows only what you can do with that session; hiding the sidebar, settings and quitting moved to the Aki submenu at the end, so nothing there reads as acting on the session. The open card (or the "+N" list) closes when the menu opens, and no other card opens while it is up.

## [0.6.0] — 2026-10-11

### Added
- Get started asks how you'll use Aki: only your week (limits and cost, no permissions needed), only pointing at things for your agents, or both. Change it any time in Appearance → Use Aki for; with only your week, the marking shortcuts are off.
- Screenshots piling up (Get started and Storage): Aki counts the Mac's screenshots on the Desktop, in Downloads and in your screenshot folder, and moves the ones older than 7, 30 or 90 days to the Trash in one click.

## [0.5.0] — 2026-10-10

### Added
- Usage limits in the sidebar: one ring for Claude and one for Codex with how much of the week is used (green, yellow from 50%, orange from 70%, red from 90%) and how much of today's share of it. Hover for today's tokens and their cost at API prices, the 5-hour window, when each renews, the pace, today's share of the week, the last 7 days and the projects that used most.
- Settings → Show in the sidebar: sessions and limits, only limits (a usage meter) or only sessions.
- `aki usage` prints the same in the terminal.

## [0.4.4] — 2026-10-10

### Added
- ⌘Z undoes the last mark; Space held while dragging moves the whole area (as the Mac's ⌘⇧4).

### Fixed
- Marking starts on the agent tab you're in even after marks went to another session from it.
- ⇧ pressed in the middle of a drag no longer turns the screen see-through.

### Changed
- Marking starts on the agent tab you were in a moment ago (the last two minutes), before the page's port; coming back to the same Orca tab counts as a click again. A session you pick on the sidebar still wins.

## [0.4.3] — 2026-10-10

### Changed
- Holding ⇧ while marking lets the pointer through to the page below (click, hover, open its menus); let go and Aki is back with a fresh picture.
- Each session has its own colour (two of one project too), so a mark's colour says which session it goes to.
- ⇧ with the arrows adds the next thing to what's outlined (they're marked together as one area); bigger and smaller moved to ⌘↑ / ⌘↓. While ⇧ is held for that, the pin and the outline stay; the opposite arrow takes the last one back out, as a text selection shrinks.

## [0.4.2] — 2026-10-10

### Changed
- When the sidebar is full, every project still shows (its most active session, with its name); the other places go by activity.

## [0.4.1] — 2026-10-10

### Fixed
- The message typed to your agent names exactly the marks it records as delivered (one arriving meanwhile is no longer left out).
- Coming back to an Orca tab through one with no agent makes it the destination again.
- esc and ⌘⏎ still work after switching apps while writing a comment.
- The commands in the message use each mark's full code, so two marks can't be confused.

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
