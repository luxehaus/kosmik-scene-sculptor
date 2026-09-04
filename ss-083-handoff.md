# Scene Sculptor — 0.8.2 Audit & 0.8.3 Handoff Notes

Audit performed against `kosmik-scene-sculptor-0.8.2.qml`, cross-checked with
the Kosmik Kaleidoscope API guide and the user's runtime test logs. This
document is a handoff for whichever agent (Claude Code or otherwise)
implements 0.8.3. Start from the **0.8.2 file the user has** — no partial
patch exists elsewhere.

---

## Ground rules to preserve — do not regress these

- SS never calls anything at BM outside the `bmAllowedFns` allow-list inside
  `bm()`. Never add a call that writes beats.
- SS only ever rewrites the prose **body** below the frontmatter fence.
  `frontMatter` is always re-read fresh from disk immediately before a save
  and passed through byte-for-byte.
- `saveDoc()` refuses to write if the frontmatter appears to have vanished
  between read and write, and refuses outright on a `.toml` path.
- The scan-copy vs. live-copy split (`isScanned`) must be decided inside
  `onShellChanged`, **not** `Component.onCompleted` — `shell` is assigned
  late, per the API guide's own documented edge case. This was fixed in 0.8.2
  and confirmed working in the user's log (single clean startup sequence, no
  more duplicate "starting" / duplicate adopt lines). **Do not revert this.**

---

## 1. Collapse-all / Auto not working — ROOT CAUSE FOUND, FIX KNOWN

**Symptom:** Collapse-all / Auto (accordion mode) appeared to do nothing,
specifically on beats that already had prose ("sub beats").

**Root cause:** During the 0.8.2 rewrite from hand-rolled array+index line
storage to a per-card `ListModel`, the Repeater's `model:` binding lost its
`card.open &&` guard:

```qml
// 0.8.2 (bug) — the line editors keep rendering even when the card is
// toggled "closed". The card's outer chrome collapses (title bar, mode
// buttons) but the child line rows never actually hide.
Repeater {
    model: !card.isUnassigned ? root.lineModels[card.bkey] : null
```

A beat with zero lines looks like it collapsed fine (nothing to hide); a beat
with any lines doesn't — matching exactly what was reported.

**Fix:**

```qml
Repeater {
    model: (card.open && !card.isUnassigned) ? root.lineModels[card.bkey] : null
```

Setting `model:` to `null` while collapsed does **not** destroy the
underlying `ListModel` — it stays referenced by `root.lineModels[bkey]`, so
reopening just recreates delegates from existing data. No data-loss risk.

**Also do:** make "Auto" enforce immediately when toggled on (currently it
only takes effect the next time a card is opened) — collapse everything
except whatever's currently open (or nothing) at the moment the toggle flips
on. Minor UX nicety, not a correctness fix, but was requested.

---

## 2. Dialogue tag losing its comma — ROOT CAUSE FOUND, FIX KNOWN

**Symptom:** `"Yes, she replied."` renders/writes as `*"Yes"* she replied.` —
comma silently disappears. Quote placement is correct; only the comma is
lost.

**Root cause:** `autoSplit()` returns the **index of the comma itself**
(intending the comma to belong to the tag side). But `tagPart()` strips
leading commas/whitespace off the tag side:

```js
function tagPart(line) {
    var sp = splitOf(line)
    var t = String(line.t || "")
    return (sp < 0 || sp >= t.length) ? "" : t.substring(sp).replace(/^[\s,]+/, "")
}
```

So the comma sits exactly in the gap between `spokenPart()` (which stops
*before* it) and `tagPart()` (which strips it going *forward*) — it belongs
to neither and is deleted.

**Fix:** nudge the split point one character to the right whenever it lands
exactly on a comma, at the single choke-point (`splitOf`) that every caller —
`spokenPart`, `tagPart`, and the slider's default `value:` — already goes
through, so it protects both auto-detected and manually-dragged splits
identically:

```js
function splitOf(line) {
    if (!line) return -1
    var t = String(line.t || "")
    var sp = (line.split !== undefined && line.split >= 0) ? line.split : autoSplit(t)
    if (sp >= 0 && sp < t.length && t.charAt(sp) === ",") sp += 1
    return sp
}
```

This moves the comma inside the spoken/quoted part (`"Yes,"` — standard
convention), which is the correct behavior.

---

## 3. Paragraph spacing — unwanted blank lines — DESIGN DRAFTED, NEEDS FINISHING

**Request:** a new paragraph should be signaled by indentation alone
(manuscript/novel convention) — no blank line between paragraphs on disk —
*unless* a specific line is explicitly marked to force a real blank-line gap
("hard break").

This is the biggest structural change and touches four functions that all
have to agree with each other.

### Schema change

Add `hardbreak: bool` (default `false`) to every place a line object is
constructed:

- `blankLine()`
- `textToLines()`
- `ensureLineModel()` (seeding the ListModel from `proseMap`)
- `syncLineModel()` (reading the ListModel back into a plain array)
- `linesFromDisk()`
- `attachSelection()` / `attachWholeCard()` — any inline
  `{ t:..., mode:..., ... }` literal needs the field added
- The line delegate needs `required property bool hardbreak` added alongside
  `noindent`

### `groupLines()` — thread `hardbreak` through each group

Each group (`kind:"dialogue"` or `kind:"prose"`) needs a `hardbreak` field
taken from the **line that started that group** (for merged prose groups,
only the leading line's flag matters — a line merged into an existing group
never itself starts a new paragraph, so its own hardbreak flag is moot).

### `blockToMarkdown()` — join with `\n` normally, `\n\n` only on hard break

Instead of `out.join("\n\n")`, build the string incrementally:

```js
function blockToMarkdown(p, isFirst, key) {
    var arr = key ? linesOf(key) : textToLines(p.text, p.mode, p.para)
    var groups = groupLines(arr)
    var out = ""
    for (var q = 0; q < groups.length; q++) {
        var g = groups[q]
        var indentThis = isFirst ? false : g.indent
        // A single "\n" between paragraphs (indent alone marks the break);
        // a blank line ("\n\n") only where this group's leading line was
        // explicitly marked hard break.
        var sep = (q === 0) ? "" : (g.hardbreak ? "\n\n" : "\n")
        var text
        if (g.kind === "dialogue") {
            text = fileIndent + "*\u201c" + g.text + "\u201d*"
            if (g.tag !== "") text += " " + g.tag
        } else {
            var parts = []
            for (var ri = 0; ri < g.runs.length; ri++) {
                var r = g.runs[ri]
                parts.push(r.italic ? "*" + r.text + "*" : r.text)
            }
            text = (indentThis ? fileIndent : "") + parts.join(" ")
        }
        out += sep + text
        isFirst = false
    }
    return out
}
```

Indent and blank-line-gap are now two independent decisions instead of one.

### `renderBlock()` (preview) — mirror the same distinction visually

Give hard-break groups extra top margin (e.g. `14px` vs `0`) instead of every
group having uniform spacing, so the preview visually communicates the same
distinction the file now encodes:

```js
var topGap = (q === 0) ? "0" : (g.hardbreak ? "14px" : "0")
// use topGap as the first value in each <p style="margin:...">
```

### `linesFromDisk()` — the part most likely to still have bugs; needs careful re-testing

The old parser split on blank-line-delimited blocks
(`raw.split(/\n\s*\n/)`). Since paragraphs are no longer blank-line-delimited
by default, this must change to splitting on **raw lines**, treating a blank
line as "the next content line has `hardbreak: true`" rather than as a
paragraph boundary itself:

```js
function linesFromDisk(raw, mode) {
    var arr = []
    var rawLines = String(raw).split("\n")
    var pendingHardbreak = false
    var seenContent = false
    for (var i = 0; i < rawLines.length; i++) {
        var rl = rawLines[i]
        if (rl.trim() === "") { pendingHardbreak = true; continue }
        var indented = /^\u2003/.test(rl)
        var body = rl.replace(/^\u2003+/, "").trim()
        if (body === "") continue

        var m2 = body.match(/^\*\u201c([\s\S]*?)\u201d\*\s*([\s\S]*)$/)
        if (m2) {
            var spoken = m2[1], tag = m2[2] ? m2[2].trim() : ""
            var joined = spoken + (tag ? " " + tag : "")
            arr.push({ t: joined, mode: "dialogue", para: "cont", split: spoken.length,
                       noindent: false, hardbreak: pendingHardbreak && seenContent })
            pendingHardbreak = false; seenContent = true
            continue
        }

        var runs = splitItalicRuns(body)
        for (var ri = 0; ri < runs.length; ri++) {
            var firstRun = (ri === 0)
            arr.push({
                t: runs[ri].text,
                mode: runs[ri].italic ? "monologue" : "narrative",
                para: firstRun ? ((indented || seenContent) ? "new" : "cont") : "cont",
                split: -1,
                noindent: firstRun ? (!indented && !seenContent) : false,
                hardbreak: firstRun ? (pendingHardbreak && seenContent) : false
            })
        }
        pendingHardbreak = false; seenContent = true
    }
    return arr
}
```

**This needs a real round-trip test**: write a beat with a mix of Continue
lines, New¶ lines, and one Hard-break line, save, then reload the file and
confirm the reconstructed lines produce identical rendered output. This was
reasoned through but not executed against a live runtime.

**Known tradeoff to state to the user, not silently absorb:** a generic
CommonMark-compliant markdown viewer (GitHub, most renderers) treats a single
`\n` as a soft wrap, not a paragraph break — so paragraphs separated only by
indent (no blank line) will visually run together in a *rendered* markdown
preview elsewhere, even though the raw source (what the user is actually
viewing in MarkText's source mode) looks correct. This is an intentional
tradeoff per the user's explicit request, but should be stated plainly so it
isn't mistaken for a new bug later.

**Also worth doing while touching this:** collapse embedded newlines within a
single line's raw text (`L.t`) to spaces before use in `groupLines()`, in
case a user presses Enter inside a line's TextArea — otherwise a literal
embedded `\n` could produce an ambiguous raw disk line under the new
single-`\n`-separator scheme:

```js
var t = String(L.t || "").replace(/\s*\n\s*/g, " ").trim()
```

---

## 4. Per-line "continue after" button — DRAFTED, needs wiring/testing

Add `insertLineAfter(k, i, mode)`:

```js
function insertLineAfter(k, i, mode) {
    var lm = ensureLineModel(k)
    if (!lm) return
    var at = Math.min(Math.max(i + 1, 0), lm.count)
    lm.insert(at, { t: "", mode: mode || "narrative", para: "cont", split: -1,
                     noindent: false, hardbreak: false })
    syncLineModel(k)
}
```

`insert` (not `append`) is the key — it must land immediately after the
current line, not at the end of the beat. Wire a small `+` button into each
line's toolbar row:

```qml
KTool { text: "+"
        ToolTip.visible: hovered
        ToolTip.text: "Add a continuing line after this one"
        onClicked: root.insertLineAfter(card.bkey, lrow.index, "narrative") }
```

Default `para:"cont"` is safe even after dialogue, since `groupLines()`'s
dialogue-transition rule forces a fresh paragraph regardless of the new
line's own flag.

---

## 5. Second desync bug found during audit (not user-reported) — DRAFTED

`attachWholeCard()` and `attachSelection()` write to `proseMap` **directly**,
bypassing the per-card `ListModel`. If the target or source card's
`ListModel` already exists (card was open when the attach happened), the
on-screen editor for that card goes stale — `proseMap`/disk would be
correct, but what's displayed wouldn't be. Same *class* of problem as the
already-fixed reorder corruption, different code path.

**Fix:** add a `refreshLineModel(k)` that clears and repopulates an existing
`lineModels[k]` from the current `proseMap[k].lines`, and call it after every
direct `proseMap` write in both attach functions (for both source and target
keys, wherever applicable):

```js
function refreshLineModel(k) {
    var lm = lineModels[k]
    if (!lm) return   // not created yet — ensureLineModel() will read fresh proseMap when it is
    lm.clear()
    var arr = linesOf(k)
    for (var i = 0; i < arr.length; i++) {
        lm.append({ t: arr[i].t, mode: arr[i].mode, para: arr[i].para,
                    split: arr[i].split, noindent: !!arr[i].noindent,
                    hardbreak: !!arr[i].hardbreak })
    }
}
```

Call `refreshLineModel(targetKey)` (and `refreshLineModel(sourceKey)` where a
source card still exists afterward) at the end of both `attachWholeCard()`
and `attachSelection()`.

---

## 6. "No file in BM" handling — PARTIALLY DONE, INCOMPLETE

**Request:** if BM has no file open, SS should say so plainly and wait — not
touch or show any previously-restored prose.

**Done:** `syncFromBM()` sets a persistent banner (`idMismatch` /
`idMismatchMsg`) and returns early without touching `proseMap` when `s.path`
is empty, and logs the no-file → has-file transition explicitly (rather than
silently adopting), since the user specifically flagged that exact moment:

```js
if (!s.path || s.path === "") {
    if (docMode !== "no-file") {
        docMode = "no-file"
        idMismatch = true
        idMismatchMsg = "Beat Machine has no file open. Scene Sculptor only reads what "
            + "Beat Machine reports — it cannot open, change, or auto-load a file in Beat "
            + "Machine itself. Waiting until Beat Machine has a file open."
        log("Beat Machine reports no file — waiting, not touching any restored prose")
    }
    return
}
if (docMode === "no-file") {
    log("Beat Machine now reports a file (" + s.path + ") — was previously none. "
      + "SS did not request this; it only observed BM's own report change.")
}
```

**Also done:** the main editor `GridLayout` has
`visible: root.docMode !== "no-file"` so the card list is hidden entirely in
that state.

**NOT done / left broken:** the editor's visibility was gated but no
replacement message was added — currently that state renders as a **blank
panel** with no explanation. Needs a simple placeholder bound to
`visible: root.docMode === "no-file"`, showing `idMismatchMsg` as primary
content (not a small top banner), roughly next to/instead of the GridLayout,
e.g.:

```qml
ColumnLayout {
    visible: root.docMode === "no-file"
    Layout.fillWidth: true; Layout.fillHeight: true
    Item { Layout.fillHeight: true }
    Text {
        Layout.alignment: Qt.AlignHCenter
        text: "\u23f3  " + root.idMismatchMsg
        color: root.cDim; font.pixelSize: 13
        wrapMode: Text.Wrap
        horizontalAlignment: Text.AlignHCenter
        Layout.maximumWidth: 420
    }
    Item { Layout.fillHeight: true }
}
```
(Placement/styling is a starting point, not final — fit it into the existing
layout conventions.)

**Unresolved investigation, worth another pass:** tracing the
proseMap-clearing logic in `syncFromBM()`'s `pathChanged` branch shows it
*looks* structurally correct — `proseMap` is reset to `{}` synchronously
before `adoptFile()` runs, so restored/stale prose from a previous session
should already be wiped before any fresh file is adopted. No concrete code
path was found that would produce "one massive orphan" from stale prose
given that ordering. Best guess: the exact mechanism was a *timing gap*
between `loadState()` restoring prose at construction and the first
successful `resync()` — something may have been visible briefly before the
BM sync completed — but this was not confirmed. The no-file gating above
should close that window regardless of the exact mechanism, but it's worth
adding a one-line log at any point stale prose would be visible, to catch
this if it recurs.

**Also unresolved and outside SS's control:** the user reported BM's *own*
displayed file changing when SS started up. SS's `bmAllowedFns` allow-list
contains no call capable of instructing BM to open/load a file (only
`session_load_ffi`, a read). If this is real, it is happening on BM's Rust
side — most plausibly a side effect of BM's own FFI handler for
`session_load_ffi` (e.g. "if no file is open, fall back to last-session
file" logic living in BM, not SS). This needs to be checked against BM's
actual Rust implementation. State this plainly to the user rather than
guessing further from the QML side.

---

## 7. Widgets never exposed — NOT STARTED, highest-uncertainty item

The `property var widgets: [...]` declaration is byte-identical to the
user's working 0.7.0 baseline and has not been touched across any version.
The shell-timing fix (item preserved above, confirmed working via clean
logs) ruled out the double-instantiation theory. No further root cause has
been confirmed.

**Recommended next step, not yet attempted:** the API guide documents two
registration paths — the passive `widgets` property (what SS uses now) *and*
an active `shell.publish(id, title, icon, component)` +
`shell.rescanWidgets()` call. SS has only ever used the passive path. Add the
active path as a belt-and-suspenders measure once `shell` is available, from
the live (non-scan) copy only:

```js
if (shell && shell.publish) {
    try {
        for (var i = 0; i < widgets.length; i++)
            shell.publish(widgets[i].id, widgets[i].title, widgets[i].icon, widgets[i].component)
        if (shell.rescanWidgets) shell.rescanWidgets()
        log("actively published 3 widgets + requested rescan")
    } catch (e) { log("shell.publish/rescanWidgets not available or failed: " + e) }
} else {
    log("shell.publish not available on this host — relying on the declarative widgets property only")
}
```

Call this from `initForShellState()`, live-copy branch only, wrapped in
try/catch (some hosts may not expose `publish`/`rescanWidgets` at all —
degrade gracefully per the API guide's own checklist item 10).

**Also add:** an explicit log line stating which widget IDs are being
exposed (`"SS: exposing widgets: prose, words, status"`), since the user
specifically asked to see confirmation that registration was *attempted*,
not just silence either way.

**Be transparent with the user about this one specifically** — it has been
"fixed" twice without landing. Frame it as the next thing to try, backed by
an actual unused documented API surface, not as a confirmed fix. Ask the
user whether BM/Jimmy's real source (not just the API doc's summary) shows a
concrete `publish()` call pattern to mirror exactly — that would resolve
this immediately instead of continuing to guess.

---

## 8. The file-corruption incident — investigated, most likely external, low priority

The corrupted file the user showed had its `+++...+++` TOML frontmatter
collapsed onto one line and wrapped in a markdown code fence
(```` ```toml ````). `splitDoc()`/`buildDoc()` only ever locate the `+++`
fence boundaries via regex and pass everything between them through
byte-for-byte — there is no code path in SS that would re-wrap frontmatter
in a markdown fence or strip its internal newlines. This strongly points to
MarkText's own frontmatter re-serialization when saved from its source-mode
view (complex multi-line nested-array TOML is exactly the kind of content a
lightweight frontmatter parser mishandles), matching the user's own
suspicion. The user has already resolved this by re-pasting the clean
`copyDoc()` output and confirmed 0.8.2 has been stable since.

**No action needed for 0.8.3** beyond keeping this reasoning on record in
case it recurs.

---

## Suggested order of work for 0.8.3

1. Repeater `card.open` fix (§1) — one line, zero risk, immediately testable.
2. Dialogue comma fix (§2) — one function, zero risk.
3. `refreshLineModel` + wiring into both attach functions (§5) — small,
   contained.
4. `insertLineAfter` + button (§4) — small, additive.
5. Paragraph-spacing overhaul (§3) — biggest change; needs a real
   save → reload round-trip test before calling it done.
6. No-file placeholder message (§6) — finish the half-done gating.
7. Widget active-publish attempt + diagnostic logging (§7) — flag
   uncertainty explicitly to the user.
8. Full regression pass before handing back to the user:
   - reorder a monologue line and confirm text stays attached to the right
     row
   - collapse / expand / auto-accordion on a beat that has prose
   - attach an orphan (both whole-card and Ctrl+L selection) to a beat
   - drag the dialogue split slider across a comma and confirm it's
     preserved
   - save in place, then reopen the file in a plain text viewer and confirm
     frontmatter and `[beatsheet]` are byte-identical to before the edit
   - a mixed paragraph (Continue narrative → monologue → Continue narrative,
     plus one Hard-break line) round-tripped through save + reload
