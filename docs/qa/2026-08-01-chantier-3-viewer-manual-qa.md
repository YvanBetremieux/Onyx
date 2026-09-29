# Onyx — Chantier 3 (viewer) manual QA checklist

Plan: `docs/superpowers/plans/2026-07-31-onyx-chantier-3-viewer.md`, Task 41.
Target: macOS 13+. Build under test: `./scripts/build-app.sh` → `dist/Onyx.app`.

This is not a restatement of the task list. It is ordered by *what actually
broke* during the build, so the expensive checks come first. Sections **A**
through **E** are the sharp edges; **F** onward is routine coverage.

---

## 0. Setup

Paths a tester will need:

| What | Where |
|---|---|
| Meetings library | `~/Meetings/<slug>/` (slug = `2026-08-01_14h30`) |
| Live notes (yours) | `~/Meetings/<slug>/notes/live.md` |
| Generated notes | `~/Meetings/<slug>/notes/{brief,synthese,detaillee}.md` |
| Transcript | `~/Meetings/<slug>/transcripts/transcript.{json,md}` |
| Audio | `~/Meetings/<slug>/audio/{mic,system}.m4a`, `waveform.json` |
| Search index | `~/Library/Application Support/Onyx/index.sqlite` |
| Viewer UI state | `~/Library/Application Support/Onyx/viewer_state.json` |

Useful terminal helpers, keep a shell open:

```bash
tail -f ~/Meetings/*/notes/live.md          # watch live notes hit disk
cat  ~/Library/Application\ Support/Onyx/viewer_state.json | jq .
ls -la ~/Meetings/<slug>/audio/             # which streams survived cleanup
```

Preconditions: at least **three** meetings in the library —
1. one recorded with **this** build (has `waveform.json`, both streams),
2. one **system-audio-only** (mic muted / no input device during recording),
3. one **pre-chantier-3** (no `waveform.json`, WAVs already deleted by the
   pipeline's cleanup step — only `.m4a` left).

If you have no pre-chantier-3 meeting, fake one:
`rm ~/Meetings/<slug>/audio/waveform.json` and confirm no `*.wav` remain.

Keyboard shortcuts under test (viewer window must be focused):

| Key | Effect |
|---|---|
| `⌘⇧V` | open viewer (global, from menu bar) |
| `⌘⇧L` | open live notes on the **in-progress** meeting (global, only while recording) |
| `⌘⇧R` | start/stop recording (global Carbon hotkey — works even when the viewer is focused) |
| `⌘K` | focus the sidebar search field |
| `⌘1` / `⌘2` / `⌘3` / `⌘4` | notes tab Direct / Brief / Synthèse / Détaillée |
| `⌘\` | show/hide the transcript panel |
| `⌘R` | regenerate the active note (**not** `⌘⇧R` — that one records) |

There is deliberately **no** Space shortcut for play/pause: the notes editor is a
real text view where Space must insert a space. Use the ▶ button.

---

## A. Live notes during an active recording — the data-corruption case

This was a real bug: `⌘⇧L` switched to the Direct tab **without retargeting the
selection**, so the next keystroke overwrote a *previously selected* meeting's
`notes/live.md`. Test it deliberately.

- [ ] **A1.** Open the viewer (`⌘⇧V`). Select an **old** meeting, e.g. the
      pre-chantier-3 one. Note its slug. Leave the viewer open.
- [ ] **A2.** In a terminal: `cat ~/Meetings/<OLD-slug>/notes/live.md`. Record its
      exact content (it may be empty — that is fine, note that it is empty).
- [ ] **A3.** Start a recording (`⌘⇧R`, or join a Meet/huddle and let autotrigger
      fire). Menu bar must switch to "Stop recording" and show
      **"Open live notes ⌘⇧L"**.
      *Expected:* `~/Meetings/<NEW-slug>/notes/live.md` exists and is empty.
- [ ] **A4.** Press `⌘⇧L`.
      *Expected:* viewer comes forward, the right pane header shows the **NEW**
      slug, the **Direct** tab is selected, the editor is empty with the
      placeholder "Tes notes du meeting. Tape ici pendant l'appel…".
- [ ] **A5.** Type `LIVE-TEST-A5` in the Direct tab. Wait ~1 s.
      *Expected:* `~/Meetings/<NEW-slug>/notes/live.md` contains `LIVE-TEST-A5`.
      **`~/Meetings/<OLD-slug>/notes/live.md` is byte-for-byte unchanged from A2.**
      ⚠️ If the old file changed, this is a **stop-ship** regression.
- [ ] **A6.** With the recording still running, click the old meeting in the
      sidebar, then press `⌘⇧L` again.
      *Expected:* selection jumps **back** to the in-progress meeting. It does not
      stay on the old one.
- [ ] **A7.** Stop the recording. Wait for the menu bar to leave "Transcribing…".
      Now press `⌘⇧L`.
      *Expected:* nothing happens — no tab switch, no window change (nothing is
      recording, so there is nothing to target). Specifically the Direct tab must
      **not** open on the currently selected meeting.

## B. The in-progress meeting has no sidebar row

Deliberate: `MeetingIndexer.upsert` only runs from `RescanRunner`, so a meeting
gets an index row at the earliest when its pipeline finishes. The viewer
synthesizes the header from `meta.json` instead.

- [ ] **B1.** Start a recording and press `⌘⇧L`.
      *Expected:* right pane shows a full header (slug, source badge, title, date)
      and a working notes editor, while the **sidebar has nothing highlighted** and
      no row for this meeting. This is correct, not a bug.
- [ ] **B2.** *Expected:* the transcript panel shows "Transcription en cours…",
      not a blank pane. The notes tabs Brief/Synthèse/Détaillée also read
      "Transcription en cours… les notes seront générées à la fin du traitement."
- [ ] **B3.** *Expected:* there is **no** "Générer maintenant" button on the
      Brief/Synthèse/Détaillée tabs while transcribing (there is no transcript to
      generate from yet).
- [ ] **B4.** Stop the recording and wait for the pipeline to finish.
      *Expected:* the meeting **appears** in the sidebar under today's group, the
      header switches from the synthesized listing to the real row, and the
      transcript + notes populate without you having to re-select anything.

## C. Search must match transcript text only

The FTS table indexes transcript segment text. Speaker labels and dates must not
be in it — if they are, every segment of every meeting matches and search is
useless.

- [ ] **C1.** `⌘K` → *Expected:* the search field takes focus (accent ring
      appears) even if the notes editor had focus a moment before.
- [ ] **C2.** Type a word you know is spoken in one meeting only.
      *Expected:* results within ~300 ms, snippets with the match highlighted,
      each row showing title · date · speaker · `mm:ss`.
- [ ] **C3.** Type `MOI` (the speaker label for yourself).
      *Expected:* results **only** where the word "moi" is actually spoken. **Not**
      every segment of every meeting. ⚠️ Hundreds of results here = the speaker
      column leaked into the FTS index.
- [ ] **C4.** Type `2026` (a fragment of every slug and every date).
      *Expected:* zero results, or only genuine spoken occurrences of "2026".
      **Not** the whole library.
- [ ] **C5.** Type the meeting's slug, e.g. `2026-08-01_14h30`.
      *Expected:* no results (unless spoken). The slug is not searchable text.
- [ ] **C6.** Click a result belonging to a **different** meeting.
      *Expected:* the main panel switches to that meeting **and** the transcript
      scrolls to / highlights the matching turn; if the meeting has audio the
      playhead lands at that timestamp (within a turn's width).
- [ ] **C7.** Click a result in the **currently selected** meeting.
      *Expected:* the playhead jumps immediately; no reload flash, no waveform
      redraw from scratch.
- [ ] **C8.** Type a nonsense string, then delete it fast, character by character.
      *Expected:* no stale result list. The list matches what is in the field when
      you stop typing (there is a stale-result guard; an out-of-order FTS response
      must never win).
- [ ] **C9.** Check the `mm:ss` on a hit at > 1 h.
      *Expected:* `01:02:05` style, never `-1:-5` and never a crash.

## D. Fresh-upgrade search without a manual rescan

The index migrations (v2 FTS rebuild, v3 `source` / `detected_app`) null out
`indexed_at`. Nothing else repopulates it, so before the boot-time backfill an
upgrading user got **zero search results** until they found "Rescan meetings" in
the menu.

- [ ] **D1.** Quit Onyx. Simulate a migrated index:
      ```bash
      sqlite3 ~/Library/Application\ Support/Onyx/index.sqlite \
        "UPDATE meetings SET indexed_at = NULL;"
      ```
- [ ] **D2.** Launch `dist/Onyx.app`. **Do not** touch "Rescan meetings".
- [ ] **D3.** Wait ~5 s (the backfill is a `.utility` detached task), open the
      viewer, search for a word you know is in an old transcript.
      *Expected:* results appear. ⚠️ Zero results = the boot-time backfill did not
      run.
- [ ] **D4.** `Console.app`, filter on Onyx: *Expected:* one
      `Index is stale after migration — backfilling` line.
- [ ] **D5.** Quit and relaunch again.
      *Expected:* **no** second backfill log line (the sweep only visits stale
      rows, so it is a no-op on a current index) and search still works.

## E. Regeneration must never touch `live.md`

`paths.notesFile(.live)` resolves to the **same file** as `paths.liveNotes`, so
any mistake here is silent and destroys user data.

- [ ] **E1.** Select a finished meeting. Put a recognisable string in its Direct
      tab (e.g. `KEEP-ME-E1`), wait ~1 s, confirm it is in
      `~/Meetings/<slug>/notes/live.md`.
- [ ] **E2.** With the **Direct** tab active, look at "Régénérer notes" in the
      header.
      *Expected:* visibly greyed out and unclickable; hovering shows
      "Les notes du direct sont les tiennes — elles ne sont jamais régénérées."
- [ ] **E3.** With the Direct tab active, press `⌘R`.
      *Expected:* nothing happens. `notes/live.md` still contains `KEEP-ME-E1`.
- [ ] **E4.** Switch to **Synthèse** (`⌘3`). *Expected:* the button is enabled and
      accent-coloured.
- [ ] **E5.** Press `⌘R`. Wait for Claude.
      *Expected:* `notes/synthese.md` is rewritten; `notes/live.md` **still**
      contains `KEEP-ME-E1`.
- [ ] **E6.** Menu bar → Recent Meetings → this meeting → "Regenerate notes as".
      *Expected:* the submenu offers **Brief / Synthese / Detaillee** only. **No
      "Live" entry.**
- [ ] **E7.** Settings → Notes → default note level picker.
      *Expected:* the same three options, no "Live".
- [ ] **E8.** Force a stale preference:
      ```bash
      defaults write <bundle-id> defaultNoteLevel live
      ```
      Relaunch. *Expected:* the picker shows **Synthèse** (coerced), the value on
      disk has been rewritten to `synthese`, and the next recording's pipeline
      generates `synthese.md` — not an overwritten `live.md`.
- [ ] **E9.** Record a short meeting with live notes in it, let the pipeline run.
      *Expected:* the generated Synthèse **integrates** your live notes
      (restructured, not copy-pasted verbatim), and `live.md` is unchanged.

## F. Audio — one stream, and old meetings still play

- [ ] **F1.** Meeting recorded with **both** streams: press ▶.
      *Expected:* audio plays; it is the **mic** stream (you hear yourself
      clearly). Only one stream — the remote side is not mixed in. That is a known
      limitation of this phase, not a bug.
- [ ] **F2.** *Expected:* the waveform fills / the playhead advances smoothly, and
      the drawn waveform describes what you hear (it comes from the mic stream).
- [ ] **F3.** **System-audio-only** meeting (`ls audio/` shows `system.m4a` but no
      `mic.m4a`): press ▶.
      *Expected:* system audio plays **and** a waveform is drawn — generated on
      the fly from `system.m4a`. It must not be the mic waveform and it must not
      be a flat line.
      *Also expected:* `audio/waveform.json` is **not** created for this meeting
      (a system-derived waveform must never be cached where the pipeline expects a
      mic-derived one). Verify with `ls audio/`.
- [ ] **F4.** **Pre-chantier-3** meeting (no `waveform.json`, no WAVs): select it.
      *Expected:* it plays from `mic.m4a`, and a waveform appears after a short
      delay (a full decode). ⚠️ No crash, no beachball — the decode is off the
      main thread, so the UI stays responsive while it runs.
- [ ] **F5.** Reopen the same pre-chantier-3 meeting.
      *Expected:* the waveform is now instant — `audio/waveform.json` was written
      on first open (mic source only).
- [ ] **F6.** Corrupt-audio case: `echo x > ~/Meetings/<slug>/audio/mic.m4a` on a
      throwaway meeting, select it.
      *Expected:* graceful degradation — inert transport, empty waveform track,
      panel height unchanged, no crash and no error dialog.
- [ ] **F7.** Zero-byte case: `: > audio/mic.m4a`, select it.
      *Expected:* falls through to `system.m4a` if present, otherwise inert
      transport. A 0-byte file must never be chosen.
- [ ] **F8.** Click a turn in the transcript.
      *Expected:* audio seeks there and that turn highlights. On a meeting with
      **no** audio at all, clicking a turn must still move the highlight.
- [ ] **F9.** Drag the scrubber to the far right, past the end.
      *Expected:* clamps to the duration; pressing ▶ rewinds to 0 and plays rather
      than being a dead button.
- [ ] **F10.** Change speed to 2.0×, then 0.5×.
      *Expected:* it takes effect immediately while playing, and survives a
      pause/play. The playhead keeps ticking while the speed menu is **open**.
- [ ] **F11.** While playing, select a different meeting.
      *Expected:* playback stops, the previous waveform disappears immediately.
      Meeting A's waveform must never be visible under meeting B's header.
- [ ] **F12.** While playing, click through 4–5 meetings quickly.
      *Expected:* the meeting finally selected is the one loaded. No older
      recording resumes a second later.

### F13. Playback stops when the viewer is hidden

The viewer window is never truly closed (`windowShouldClose` returns `false`,
the window is `orderOut`-ed), so audio used to keep playing with the transport
off screen and no way to stop it short of quitting.

- [ ] **F13a.** Start playback, then click the window's red close button. (Onyx is
      a menu-bar accessory app with no application menu, so `⌘W` is not bound —
      use the button.)
      *Expected:* **audio stops immediately.** Silence.
- [ ] **F13b.** Reopen with `⌘⇧V`.
      *Expected:* same meeting, same note tab, and the playhead is **where you
      left it** (paused, not rewound to 0 and not unloaded).
- [ ] **F13c.** Start playback, then minimise the window.
      *Expected:* audio stops. Restore → playhead preserved.

## G. Notes editing, the hand-edit banner, and empty states

- [ ] **G1.** Type in the Synthèse editor. Wait ~1 s (debounce is 700 ms).
      *Expected:* `~/Meetings/<slug>/notes/synthese.md` updated on disk.
- [ ] **G2.** *Expected:* a yellow banner appears at the top of the notes panel
      warning that the note was hand-edited.
- [ ] **G3.** Click "Ignorer" → banner disappears. Switch tab and back →
      *Expected:* the banner state resets per tab / per meeting (it is not sticky
      across a tab switch).
- [ ] **G4.** Click "Régénérer quand même" → *Expected:* the note reverts to a
      freshly generated version and the banner disappears.
- [ ] **G5.** Type fast in the editor for ~10 s.
      *Expected:* no dropped characters, and the insertion point never jumps to
      the start or end. (The editor must not be torn down mid-typing.)
- [ ] **G6.** Switch tabs while a save is still pending (type, then `⌘2`
      immediately).
      *Expected:* the text you typed lands in the tab you typed it in, not in the
      tab you switched to.
- [ ] **G7.** Direct tab: type something. *Expected:* **no** hand-edit banner ever
      appears on the Direct tab (those notes are always user-authored).
- [ ] **G8.** A finished meeting whose Brief was never generated: open `⌘2`.
      *Expected:* placeholder "Pas encore de note à ce niveau…" **and** a
      "Générer maintenant" button at the bottom of the notes pane.
- [ ] **G9.** Click "Générer maintenant". *Expected:* the Brief is generated and
      the button disappears (the note is no longer empty).
- [ ] **G10.** A meeting whose pipeline **failed** (`job.json` state `failed`):
      *Expected:* "Le traitement de ce meeting a échoué : aucune note n'a pu être
      générée." and **no** "Générer maintenant" button (there is no transcript).
- [ ] **G11.** A meeting with a transcript but zero speech segments:
      *Expected:* transcript panel says "Aucune parole détectée dans cet
      enregistrement." — not a blank pane, not "Transcription en cours…".

## H. Layout, persistence, and window behaviour

- [ ] **H1.** Sidebar: meetings grouped by date, most recent group first, most
      recent meeting first within a group. Each row carries a source badge (Meet /
      Slack huddle / manual).
- [ ] **H2.** Click a meeting: header, notes, transcript and waveform all present
      within ~500 ms (waveform may lag on a pre-chantier-3 meeting — see F4).
- [ ] **H3.** Drag the notes ↔ transcript divider slowly, then fast, then past
      both edges.
      *Expected:* smooth, no jitter, no negative widths, and it stops at the
      minimum pane widths (notes ≥ 320 pt, transcript ≥ 280 pt).
- [ ] **H4.** Click `»` in the transcript header. *Expected:* transcript hides,
      the FAB appears top-right. Click the FAB → it returns. Same via `⌘\`.
- [ ] **H5.** Resize the window very narrow (down to the 960 pt minimum).
      *Expected:* nothing clips, no overlapping text, the divider stays usable.
- [ ] **H6.** **Persistence within half a second.** Change the split ratio, then
      quit Onyx **immediately** (⌘Q within ~0.5 s — the persistence debounce is
      500 ms, and terminate flushes it synchronously).
      Relaunch, open the viewer. *Expected:* the new ratio is there.
      Repeat for: selected meeting, active note tab, transcript-hidden state,
      search query.
      Cross-check `viewer_state.json`.
- [ ] **H7.** Same again but "close" the viewer window instead of quitting.
      *Expected:* state also flushed at that moment (closing is the last point the
      user expects their layout to stick).
- [ ] **H8.** Close the viewer window. *Expected:* the **app keeps running** (menu
      bar icon still there, recording unaffected).
- [ ] **H9.** Move and resize the window, quit, relaunch, `⌘⇧V`.
      *Expected:* window frame restored (autosave). On a genuinely first run
      (`defaults delete <bundle-id> "NSWindow Frame onyx.viewer"`) it must be
      **centred**, not at 0,0.
- [ ] **H10.** Empty library (`~/Meetings` empty / fresh install): open the
      viewer. *Expected:* empty sidebar plus "Sélectionne un meeting dans la
      sidebar" — one empty state, not three empty panes with dividers.

## I. Dark mode and appearance

- [ ] **I1.** System Settings → Appearance → Dark. With the viewer open.
      *Expected:* it re-themes live. Check specifically: the "Enregistré"
      indicator (must stay readable — it is a green that was too dark in dark
      mode), the yellow hand-edit banner, the speaker colours in the transcript,
      the search field's focus ring, the disabled "Régénérer notes" button.
- [ ] **I2.** Switch back to Light and re-check the same list.
- [ ] **I3.** *Expected:* no element is invisible in either mode, and no white
      box on a dark background.

## J. Speaker colours are stable

Speaker colours used to come from `String.hashValue`, which is seeded per
process — every speaker changed colour on every launch.

- [ ] **J1.** Open a multi-speaker meeting, screenshot the transcript.
- [ ] **J2.** Quit, relaunch, reopen the same meeting.
      *Expected:* **identical** colours per speaker.
- [ ] **J3.** Repeat once more. Still identical.

## K. Regression sweep on the rest of the app

The viewer is new; the recorder is not. Confirm chantier 2 still works.

- [ ] **K1.** `⌘⇧R` while the **viewer window is focused**.
      *Expected:* it starts/stops a **recording**. It must not be swallowed by the
      viewer or be interpreted as "regenerate".
- [ ] **K2.** Autotrigger: join a Google Meet. *Expected:* recording starts, the
      notification appears, the meeting is matched to a calendar event if one
      exists.
- [ ] **K3.** Menu bar → "Open meetings folder", "Rescan meetings", "Settings…",
      "Recent Meetings" → all still functional.
- [ ] **K4.** Onboarding: `rm -rf` the onboarding-complete flag and relaunch.
      *Expected:* the onboarding window appears and completes.

---

## Reporting

Any failing item is a follow-up task. Log it in
`docs/superpowers/plans/2026-07-31-onyx-chantier-3-viewer.md` under a
`## Follow-ups` section at the end of the file, as:

```
### FU-<n>: <one-line symptom>
- QA item: <e.g. A5>
- Observed: <what happened>
- Expected: <what the checklist says>
- Repro: <shortest steps>
- Severity: stop-ship | major | minor | cosmetic
```

Treat as **stop-ship**: anything in section **A** (live-notes data loss),
**E1–E5** (regeneration overwriting `live.md`), or a crash in **F**.
