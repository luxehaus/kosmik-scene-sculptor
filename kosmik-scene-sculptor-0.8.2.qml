// kosmik-scene-sculptor-0.8.2 · SS
// Prose companion to the Beat Machine. QML only.
//
// ═════════════════════════════════════════════════════════════════════════════
// CHANGELOG 0.8.1 → 0.8.2  (from your first real run's log + testing)
//
//   FIXED — root cause of the missing widgets, duplicate "starting"/"document
//   adopted" log lines, and very likely a contributor to the line-reorder
//   corruption below:
//   · isScanned reads shell.isScanShell, but the API guide documents that
//     `shell` is assigned AFTER Component.onCompleted. Both the headless scan
//     copy and the live copy therefore saw shell === null at onCompleted
//     time and BOTH believed they were the live instance — matching your log
//     exactly (two "starting" lines, neither tagged, duplicate adopt calls).
//     Two live instances able to independently call BM, write files, and
//     mutate the same LocalStorage row is precisely the failure class the
//     API guide's own Jimmy write-up warns about. Moved the scan-gated
//     startup work into onShellChanged (guarded to run once), per the guide's
//     explicit instruction: "Decide ownership in onShellChanged, not at
//     construction."
//   · Also dropped a redundant duplicate adoptFile() call that ran right
//     after syncFromBM() had already adopted the same file — that alone was
//     producing the doubled "document adopted from file" log line even
//     within a single correctly-identified instance.
//
//   FIXED — reordering a line (especially monologue) corrupted content
//   · The 0.8.1 line editor stored lines as a plain JS array and relied on a
//     hand-rolled index-swap + manual TextArea resync to survive a reorder.
//     That mechanism had no real guarantee against a stale delegate showing
//     another row's text — which is exactly the bug you hit. Replaced with a
//     real per-beat QML ListModel, mutated via .append()/.remove()/.move()/
//     .setProperty() — Qt's own guaranteed-non-destructive mechanism for
//     "reorder rows without corrupting their contents or losing delegate
//     focus", which a hand-rolled array swap never actually had.
//
//   FIXED — monologue following narrative started its own line instead of
//   staying inline
//   · groupLines()'s merge step required an EXACT mode match, so a monologue
//     line after a "Continue" narrative line always broke into a new
//     paragraph. Narrative and monologue are now treated as one family for
//     flow purposes: consecutive "Continue" lines of either kind merge into
//     ONE paragraph, with only the monologue portion rendered italic within
//     it — matching what you asked for originally. The disk-read side
//     (linesFromDisk/splitItalicRuns) was updated to parse a mixed paragraph
//     back into separate narrative/monologue lines on reload, so this
//     round-trips instead of just looking right once.
//
//   CHANGED — Open file… vs Paste
//   · They were the same button in practice: openOwnFile() probed an
//     unconfirmed host FFI export name, and on ANY failure silently fell
//     through to the Paste dialog — so it always ended up as Paste. Per your
//     instruction, the host-dialog probe code is now commented out in place
//     (openFileViaHost()) rather than removed, the button is visibly present
//     but disabled, and it no longer falls through to Paste at all. The two
//     confirmed acquisition paths remain: the file BM already has open
//     (automatic) and an Emacs buffer via BM (Use Emacs buffer button).
//
//   ADDED — requested
//   · Expand all / Collapse all / Auto (accordion — opening a card while Auto
//     is on closes every other one, so only one beat's prose is open at a
//     time) in the top toolbar.
// ═════════════════════════════════════════════════════════════════════════════
//
// ═════════════════════════════════════════════════════════════════════════════
// WHAT 0.4.0 GOT WRONG — and the rule that still governs every line below
//
//   0.4.0 folded prose into each beat's NOTES array and handed that to
//   save_beats_ffi. BM faithfully serialised it, so prose ended up INSIDE the
//   [beatsheet] TOML and corrupted the document.
//
//   THE RULE:
//     SS NEVER SENDS BEATS TO BEAT MACHINE. It never calls save_beats_ffi,
//     never calls session_save_ffi, never mutates a beat. Beats are READ-ONLY
//     context. Only BM writes the beatsheet.
//
//   0.8.1 makes this a RUNTIME guard, not just a promise: bm() now refuses to
//   call anything not on an explicit allow-list (§ SAFETY). Even a future typo
//   or copy-paste mistake cannot send a write-shaped call to BM.
//
//   SS owns exactly one thing: the prose body BELOW the frontmatter. It writes
//   that and nothing else, wrapped in HTML-comment anchors that are invisible
//   in every Markdown renderer:
//       <!-- ss:beat=9F9059 mode=narrative para=cont time=20260904153012 -->
//       The prose.
//       <!-- /ss -->
//
// ═════════════════════════════════════════════════════════════════════════════
// CHANGELOG 0.7.1 → 0.8.1  (see inline "0.8.1:" comments for exact spots)
//
//   FIXED — data loss / corruption
//   · setProse() rebuilt each proseMap entry from a literal {text,mode,para},
//     silently dropping `.lines`. Any card that had already been edited with
//     the line-based dialogue editor lost all line/split/mode metadata the
//     moment it went through the *legacy* setProse() path (mode/para segment
//     buttons, or — worse — the orphan "attach to beat" flow below). Fixed:
//     setProse() now copies `.lines` forward.
//   · Orphan / unassigned "attach to beat" (⇄) read `ta.text` for the source
//     content. For any card OTHER than the special UNASSIGNED row, `ta` is an
//     invisible TextArea that is only ever set ONCE at Component.onCompleted
//     and never re-synced from the line editor — so by the time you clicked
//     ⇄, `ta.text` was stale (often stale-empty). The prose you saw on screen
//     was never what got attached: it looked like the prose "went away".
//     Fixed: attachToBeat() now reads the LIVE, authoritative lines/text
//     straight out of proseMap at click time, and moves the whole `.lines`
//     array (not a flattened, re-parsed blob) so per-line mode/split/para
//     survive the move.
//   · loadState() restored prose/path/frontmatter/unassigned but never
//     restored `headings` — so headings saved by saveLocalState() vanished on
//     next launch even though they were sitting right there in the DB row.
//     Fixed.
//
//   FIXED — performance / "freezes after one character"
//   · The per-line Repeater bound its `model` directly to `root.linesOf(key)`,
//     a freshly-allocated JS array. QML does not diff opaque array identity —
//     it treats a new array as a brand-new model, so EVERY keystroke (which
//     bumps proseRev, which re-evaluates the binding) destroyed and recreated
//     every line delegate, including the TextArea you were typing into. You'd
//     type one character, focus was destroyed with the old delegate, and a
//     brand-new unfocused TextArea appeared showing that one character —
//     exactly "single character at a time before freezing". Fixed: the
//     Repeater model is now the LINE COUNT (an int), which is stable across
//     edits, so delegates persist and only their bound values change. Content
//     resync (e.g. after a reorder shifts what index N holds) is handled by
//     an explicit Connections block instead of destroying the item.
//   · Same root cause made the dialogue split slider feel "slow" — every drag
//     tick rebuilt the whole delegate. Fixed by the above, and additionally:
//     slider drags no longer commit to the model on every pixel. They update
//     a local preview instantly and commit through a 60 ms debounce, so
//     dragging is smooth and a save still lands almost immediately after you
//     let go.
//
//   FIXED — sync / "widgets not updating in real time", "word counts don't match"
//   · 0.7.1 fired FOUR independently-scheduled timers off every edit
//     (saveTimer 900 ms, stateTimer 150 ms, previewTimer 220 ms, statsTimer
//     250 ms). stateTimer (150 ms) published nWords/previewHtml to the shared
//     DB row BEFORE statsTimer (250 ms) or previewTimer (220 ms) had actually
//     recomputed them — so an embedded Word Count widget could read a number
//     that didn't match what the main window or the Prose Preview widget
//     showed a moment later, and looked "frozen" until the next lucky publish
//     landed after all three had settled. Fixed: refreshStats(), repaint()
//     and saveLocalState() now run back-to-back, in dependency order, off a
//     SINGLE debounce (liveTimer, 180 ms). Nothing is published half-updated.
//     The expensive disk write stays on its own 900 ms debounce, unaffected.
//
//   FIXED — preview indentation
//   · Indent decisions were computed independently in blockToMarkdown() (disk)
//     and renderBlock() (preview), and 0.7.1 had no concept of "manual
//     no-indent" or of mode-transition rules, so the two could disagree and
//     neither matched what you'd expect from a novel. Fixed: both now consume
//     one shared groupLines() function (§ PARAGRAPH GROUPING), so preview and
//     file output are always the same decision from the same code.
//
//   ADDED — requested features
//   · Monologue line mode: inline like narrative, italic only, no quotes, no
//     structural indent of its own.
//   · Per-line manual "no-indent" override button (independent of position —
//     works even when a beat isn't first in the document).
//   · Traditional-rules paragraph grouping: consecutive narrative/monologue
//     lines marked "Continue" flow into ONE paragraph; dialogue always starts
//     its own paragraph; returning to narrative/monologue immediately after
//     dialogue always starts a new paragraph — matching standard prose
//     convention — regardless of what the per-line "¶" flag says, UNLESS you
//     explicitly force no-indent on that line.
//   · Beat-linked timestamp pill: `time=<14-char UTC>` written into the
//     anchor comment, generated once the first time a beat gets prose and
//     never overwritten after. Commented-out placeholder for shelling out to
//     an external `fingerprint` rust binary once you're ready (§ FINGERPRINT).
//   · Host-mediated file open/save, tried BEFORE falling back to raw XHR, so
//     SS does not require QML_XHR_ALLOW_FILE_READ/WRITE when the host offers
//     a native dialog (see § FILE I/O for why the env vars were ever needed
//     at all — short version: they were ALWAYS a fallback path in both 0.7.0
//     and 0.7.1, just one your launcher happened to satisfy already).
//   · .toml-only detection: if BM's open file has no prose to edit, SS says
//     so plainly instead of silently doing nothing useful.
//   · prose-with-zero-beats detection: tells you exactly how many beats to
//     add in BM to match the prose blocks already sitting in the file.
//   · Beat-ID mismatch alert: after adopting a file via BM's normal path, if
//     the file's anchored prose keys share NOTHING with BM's live beat keys,
//     SS raises a persistent banner telling you to stop and reload in BM,
//     instead of quietly turning everything into unlabeled orphans.
//
// ═════════════════════════════════════════════════════════════════════════════
// § FILE I/O — why the launch flags existed, and why they're now a fallback
//
//   Both 0.7.0 and 0.7.1 read/wrote files through Qt's synchronous/async XHR
//   against a file:// URL. Qt blocks that by default; QML_XHR_ALLOW_FILE_READ
//   and _WRITE lift the block. That requirement was NEVER new in 0.7.1 — it's
//   identical code to 0.7.0. If 0.7.0 "just worked" for you, the most likely
//   explanations are (a) your launcher already exports those two vars, or
//   (b) canRead/canWrite probing happened to succeed via the self-relaunch
//   path (relaunchWithFileAccess) the first time you ever ran it, so you never
//   saw the prompt. It wasn't that 070 avoided the requirement — it's that you
//   didn't notice it.
//
//   That said, you're right that this shouldn't be necessary at all when BM
//   already has the file open and there's FFI between plugins. 0.8.1 now
//   tries HOST-MEDIATED file access first:
//     · openFileViaHost() probes for a native open-dialog FFI export.
//     · saveFileViaHost() probes for a native write FFI export.
//   If the host build exposes either, SS uses it and never touches XHR for
//   that operation. If it doesn't, SS falls back to the same XHR path as
//   before (still needs the launch flags in that case) and says so clearly in
//   the UI instead of assuming.
//
//   The actual FFI function names for a host-side open/save dialog aren't
//   documented in the API guide (only BM's own beat-reading exports are), so
//   this file probes a short list of plausible names the same defensive way
//   relaunchWithFileAccess() always has. Tell me the real export name once you
//   have it and I'll collapse the probe list to a single direct call.
// ═════════════════════════════════════════════════════════════════════════════

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.LocalStorage
import Kosmik.Core 1.0

Rectangle {
    id: root
    anchors.fill: parent
    color: kosmikTheme && kosmikTheme.bgStage !== undefined
           ? kosmikTheme.bgStage
           : Qt.rgba(0.05, 0.05, 0.09, 0.42)
    radius: 12
    border.color: cPhr; border.width: 1

    KosmikHost { id: host }

    readonly property string ver:   "0.8.2"
    readonly property string bmPid: "kosmik-beat-machine"
    readonly property string pid:   "kosmik-scene-sculptor"

    property var  shell: null
    property var  kosmikTheme: null
    property bool shellActive: false

    readonly property bool narrow: width < 1000

    // ── document ──
    property string filePath: ""
    property string bodyText: ""
    property string frontMatter: ""     // +++ ... +++  (READ-ONLY here)
    property string bodySource: "none"  // none | paste | file | host | state
    property bool   dirty: false
    property var    emacs: ({ running:false, server:false, usable:false, file:"", short:"", beats:0 })

    property string bmStatus: "checking"
    property int    bmBeats: -1

    // 0.8.1: what BM currently has open, so we can tell the difference
    // between "no file", "a .toml with no prose to edit", "a document with
    // prose but zero beats", and the normal "markdown + beatsheet" case.
    property string docMode: "unknown"   // unknown|no-file|toml-only|prose-no-beats|markdown

    // 0.8.1: beat-identity mismatch banner (see adoptFromBM / checkIdMismatch).
    property bool   idMismatch: false
    property string idMismatchMsg: ""

    readonly property color cOk:   "#00ffa3"
    readonly property color cWarn: "#ffb300"
    readonly property color cBad:  "#ff2fb9"
    readonly property color cNote: "#b39dff"
    readonly property color cPlot: "#c56bff"
    readonly property color cPhr:  "#00e5ff"
    readonly property color cEdge: "#242433"
    readonly property color cText: "#e8e8f0"
    readonly property color cDim:  "#6a6a7c"

    property int proseRev: 0
    function log(m) { console.log("SS: " + m) }

    property var widgets: [
        { id: "prose",  title: "Prose Preview",   icon: "▤", component: prosePreviewComp },
        { id: "words",  title: "Word Count",      icon: "#", component: wordCountComp },
        { id: "status", title: "Sculptor Status", icon: "✎", component: statusComp }
    ]
    readonly property bool isScanned: {
        var v = shell
        if (!shell) return false
        try { return shell.isScanShell === true } catch (e) { return false }
    }

    // ═══════════════ primitives ═══════════════
    component KGroup: Rectangle {
        default property alias items: inner.data
        implicitWidth: inner.implicitWidth + 8
        implicitHeight: 32
        radius: 8; color: "#12121b"
        border.color: "#1f1f2b"; border.width: 1
        Row { id: inner; anchors.centerIn: parent; spacing: 2 }
    }
    component KSeg: AbstractButton {
        id: sg
        property color accent: "#9a9aab"
        property bool active: false
        implicitHeight: 26
        leftPadding: 11; rightPadding: 11
        focusPolicy: Qt.NoFocus
        contentItem: Text {
            text: sg.text
            color: !sg.enabled ? "#3d3d4a" : (sg.hovered || sg.active ? sg.accent : "#8f8fa0")
            font.pixelSize: 11; verticalAlignment: Text.AlignVCenter
        }
        background: Rectangle {
            radius: 5
            color: sg.down ? "#2c2c40" : (sg.active ? "#1d1d2b" : (sg.hovered ? "#1a1a26" : "transparent"))
            border.color: sg.active ? sg.accent : "transparent"
        }
    }
    component KTool: ToolButton {
        id: kt
        implicitWidth: 25; implicitHeight: 25
        focusPolicy: Qt.NoFocus
        contentItem: Text {
            text: kt.text
            color: !kt.enabled ? "#3a3a48" : (kt.hovered ? "#00e5ff" : "#8b8b9c")
            font.pixelSize: 12
            horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
        }
        background: Rectangle { radius: 5
            color: kt.down ? "#2f2f45" : (kt.hovered ? "#1f1f2e" : "transparent") }
    }
    component KScroll: ScrollBar {
        id: ks
        implicitWidth: 9
        policy: ScrollBar.AsNeeded
        contentItem: Rectangle {
            implicitWidth: 9; radius: 4
            color: ks.pressed ? "#00e5ff" : "#3f3f52"
            opacity: ks.active ? 0.95 : 0.3
        }
        background: Rectangle { color: "transparent" }
    }

    // ═══════════════ SAFETY: bridge + hard allow-list ═══════════════
    // 0.8.1: this is now the ONE place any call ever leaves SS. Every call
    // site in this file goes through call()/bm(). bm() refuses anything not
    // on bmAllowedFns before it ever reaches host.executePlugin — so a future
    // typo, a pasted snippet, or a careless edit cannot accidentally ask BM
    // to write beats. This is enforcement, not just a comment promising it.
    readonly property var bmAllowedFns: [
        "session_load_ffi",       // read beats + path (existing)
        "parse_beats_ffi",        // read beats from an emacs buffer (existing)
        "emacs_status_ffi",       // read emacs status (existing)
        "open_file_dialog_ffi",   // 0.8.1: probe — native open dialog, if BM exposes one
        "save_file_dialog_ffi",   // 0.8.1: probe — native "save as" dialog, if exposed
        "write_prose_file_ffi"    // 0.8.1: probe — host-mediated write, PROSE FILE ONLY.
                                   //   SS still builds the byte content itself (buildDoc());
                                   //   this only asks the host to perform the write so we
                                   //   don't need XHR file permissions. It is never given
                                   //   anything but the exact bytes SS already computed.
    ]
    property string lastError: ""
    function call(target, fn, payload) {
        var raw
        try { raw = host.executePlugin(target, fn, JSON.stringify(payload)) }
        catch (e) { lastError = "bridge threw: " + e; return undefined }
        if (typeof raw !== "string") { lastError = "bridge returned " + typeof raw; return undefined }
        var r
        try { r = JSON.parse(raw) }
        catch (e2) { lastError = "bad JSON: " + raw.substring(0,90); return undefined }
        if (r.error !== undefined) { lastError = String(r.error); return null }
        lastError = ""
        return r.ok
    }
    function bm(fn, payload) {
        if (bmAllowedFns.indexOf(fn) === -1) {
            log("REFUSED: '" + fn + "' is not on bmAllowedFns — SS never calls "
                + "anything at BM outside this list. This is a bug if you see it.")
            lastError = "refused (not allow-listed): " + fn
            return null
        }
        return call(bmPid, fn, payload)
    }
    function say(m, bad) { status.text = (bad ? "✕  " : "●  ") + m; status.color = bad ? cBad : cOk }

    // ═══════════════ beat identity ═══════════════
    // SS computes this key itself from beat content (plot+phrase+question).
    // BM never supplies an id. See the 0.8.1 header note on what that implies
    // for identity stability, and § TIMESTAMP below for the new pill.
    function keyOf(b) {
        var s = (b.plot || "") + "\u0001" + (b.phrase || "") + "\u0001" + (b.question || "")
        var h1 = 0x811c9dc5, h2 = 0x01000193
        for (var i = 0; i < s.length; i++) {
            h1 = (h1 ^ s.charCodeAt(i)) >>> 0
            h1 = (h1 * 16777619) >>> 0
            h2 = ((h2 << 5) - h2 + s.charCodeAt(i)) >>> 0
        }
        return (("0000" + h1.toString(16)).slice(-4)
              + ("0000" + h2.toString(16)).slice(-4)).toUpperCase().substring(0, 6)
    }

    // ═══════════════ § TIMESTAMP (new in 0.8.1) ═══════════════
    // Since SS — not BM — mints the beat key, we can safely attach a stable
    // "when this beat first got prose in SS" timestamp to it. 14-char UTC:
    // YYYYMMDDHHMMSS. Set once, never overwritten, carried in the anchor
    // comment as `time=...` so it survives file round-trips without SS
    // needing any separate storage. If BM ever starts minting its own beat
    // ids instead, this still works exactly the same way — it's keyed off
    // whatever `keyOf()`/BM's id ends up being, not off how the key was made.
    property var beatStamps: ({})   // key -> { time: "14charUTC", fingerprint: null }
    function nowStamp14() {
        var d = new Date()
        function p(n, w) { var s = String(n); while (s.length < w) s = "0" + s; return s }
        return p(d.getUTCFullYear(), 4) + p(d.getUTCMonth() + 1, 2) + p(d.getUTCDate(), 2)
             + p(d.getUTCHours(), 2) + p(d.getUTCMinutes(), 2) + p(d.getUTCSeconds(), 2)
    }
    function stampFor(k) {
        if (!k) return ""
        if (beatStamps[k] && beatStamps[k].time) return beatStamps[k].time
        var t = nowStamp14()
        var m = {}
        for (var x in beatStamps) m[x] = beatStamps[x]
        m[k] = { time: t, fingerprint: null }
        beatStamps = m
        return t
    }
    // § FINGERPRINT — placeholder only, intentionally inert until you're ready.
    // Shells out (via host FFI, never direct process spawn from QML) to the
    // external `fingerprint` rust binary, keyed on the beat's timestamp, and
    // stashes whatever it returns (GPS / other metadata) onto beatStamps[k].
    // Left fully commented out. Wire up the real FFI export name and the
    // response shape when the binary is ready, then:
    //   1. uncomment runFingerprint() and its call site in stampFor()
    //   2. add `fp=<value>` to the anchor emission in buildBody()/ingestBody()
    //      the same way `time=` is handled below
    //
    // function runFingerprint(k) {
    //     if (!beatStamps[k] || !beatStamps[k].time) return
    //     var r = call("fs", "exec_ffi", { bin: "fingerprint", args: [beatStamps[k].time] })
    //     if (r && r.value !== undefined) {
    //         var m = {}
    //         for (var x in beatStamps) m[x] = beatStamps[x]
    //         m[k] = { time: beatStamps[k].time, fingerprint: r.value }
    //         beatStamps = m
    //     }
    // }

    // ═══════════════ model ═══════════════
    ListModel { id: rows }
    property var proseMap: ({})     // key -> { text, mode, para, lines: [...] }
    property var beatList: []       // READ-ONLY copy of BM's beats
    property int rowCount: 0
    property string unassigned: ""

    // A beat's prose is a LIST of child lines:
    //   line = { t, mode: narrative|dialogue|monologue, para: cont|new,
    //            split: -1 (auto) | index, noindent: bool }
    function blankLine(mode) {
        return { t: "", mode: mode ? mode : "narrative", para: "cont", split: -1, noindent: false }
    }
    function blank() { return { text: "", mode: "narrative", para: "cont", lines: [] } }

    readonly property var sayVerbs: [
        "said","says","asked","asks","replied","replies","answered","answers",
        "whispered","whispers","shouted","shouts","murmured","murmurs",
        "muttered","mutters","called","calls","cried","cries","added","adds",
        "continued","continues","breathed","breathes","laughed","laughs",
        "paused","pauses","offered","offers","admitted","admits","insisted",
        "snapped","snaps","hissed","growled","sighed","echoed","repeated"
    ]
    function autoSplit(t) {
        if (!t) return -1
        var s2 = String(t)
        var q = s2.search(/[\u201d"]/)
        if (q > 0) return q + 1
        var words = s2.split(/\s+/)
        var pos = 0
        for (var i = 0; i < words.length; i++) {
            var wclean = words[i].toLowerCase().replace(/[^a-z]/g, "")
            if (sayVerbs.indexOf(wclean) !== -1) {
                var upto = s2.lastIndexOf(",", pos)
                if (upto > 0) return upto
                var dot = s2.lastIndexOf(".", pos)
                if (dot > 0 && dot < pos) return dot + 1
                return pos
            }
            pos += words[i].length + 1
        }
        return -1
    }
    function splitOf(line) {
        if (!line) return -1
        if (line.split !== undefined && line.split >= 0) return line.split
        return autoSplit(line.t)
    }
    function spokenPart(line) {
        var sp = splitOf(line)
        var t = String(line.t || "")
        return (sp < 0 || sp > t.length) ? t : t.substring(0, sp).replace(/\s+$/, "")
    }
    function tagPart(line) {
        var sp = splitOf(line)
        var t = String(line.t || "")
        return (sp < 0 || sp >= t.length) ? "" : t.substring(sp).replace(/^[\s,]+/, "")
    }
    function proseFor(k) { var p = proseMap[k]; return p ? p : blank() }
    function proseText(k) { return proseFor(k).text }

    // ── child-line operations ──
    function linesOf(k) {
        var p = proseFor(k)
        if (p.lines && p.lines.length) return p.lines
        return textToLines(p.text, p.mode, p.para)
    }
    function textToLines(text, mode, firstPara) {
        var out = []
        var body = String(text || "").trim()
        if (body === "") return out
        var parts = body.split(/\n\s*\n/)
        for (var i = 0; i < parts.length; i++) {
            var t = parts[i].replace(/\n/g, " ").trim()
            if (t !== "") out.push({ t: t, mode: mode || "narrative",
                                      para: (i > 0 ? "new" : (firstPara || "cont")),
                                      split: -1, noindent: false })
        }
        return out
    }

    // ═══════════════ 0.8.2 REWRITE: per-card ListModel for lines ═══════════
    // The 0.8.1 approach kept lines as a plain JS array and had the Repeater
    // re-derive it on every proseRev bump, relying on a hand-rolled index+
    // Connections resync to keep each TextArea in step after a reorder. That
    // was fragile: you found the exact failure mode — moving a monologue line
    // ended up showing/writing another line's text into it. Rather than
    // patch that mechanism further, this switches to what Qt actually built
    // for "reorderable rows, each with independently-editable, live-bound
    // fields, safe to move without recreating or cross-contaminating rows":
    // a real ListModel per beat, mutated with .append()/.remove()/.move()/
    // .setProperty(). ListModel.move() is guaranteed non-destructive — it
    // relocates the row's data, not the delegate, and every role stays
    // attached to the row it belongs to. That guarantee is exactly what was
    // missing before.
    //
    // proseMap[k].lines remains the PERSISTED, saved/loaded/on-disk
    // representation — unchanged. The ListModel is purely a live UI-editing
    // cache, lazily created per beat, always synced back into proseMap (and
    // from there into the normal autosave/state/stats pipeline) after every
    // mutation via syncLineModel().
    property var lineModels: ({})   // bkey -> ListModel instance (dynamic)

    function ensureLineModel(k) {
        if (lineModels[k]) return lineModels[k]
        var lm
        try {
            lm = Qt.createQmlObject('import QtQuick; ListModel {}', root, "ss_lm_" + k)
        } catch (e) { log("could not create line model for " + k + ": " + e); return null }
        var arr = linesOf(k)
        for (var i = 0; i < arr.length; i++) {
            lm.append({ t: arr[i].t, mode: arr[i].mode, para: arr[i].para,
                        split: arr[i].split, noindent: !!arr[i].noindent })
        }
        var m = {}
        for (var x in lineModels) m[x] = lineModels[x]
        m[k] = lm
        lineModels = m
        return lm
    }
    // Pull the ListModel's current rows back into proseMap and run the
    // normal save/state/disk pipeline. Called after every mutation below.
    function syncLineModel(k) {
        var lm = lineModels[k]
        if (!lm) return
        var arr = []
        for (var i = 0; i < lm.count; i++) {
            var r = lm.get(i)
            arr.push({ t: r.t, mode: r.mode, para: r.para, split: r.split, noindent: r.noindent })
        }
        writeLines(k, arr)
    }
    function lineAt(k, i) {
        var lm = lineModels[k]
        if (lm) return (i >= 0 && i < lm.count) ? lm.get(i) : blankLine()
        var a = linesOf(k)
        return (i >= 0 && i < a.length) ? a[i] : blankLine()
    }
    function lineCount(k) {
        var lm = lineModels[k]
        if (lm) return lm.count
        return linesOf(k).length
    }

    function writeLines(k, arr) {
        var cur = proseMap[k] ? proseMap[k] : blank()
        var m = {}
        for (var x in proseMap) m[x] = proseMap[x]
        var flat = []
        for (var i = 0; i < arr.length; i++) if (String(arr[i].t).trim() !== "") flat.push(arr[i].t)
        m[k] = { text: flat.join("\n\n"), mode: cur.mode, para: cur.para, lines: arr }
        proseMap = m
        proseRev++
        dirty = true
        if (arr.length && flat.join("").trim() !== "") stampFor(k)
        saveTimer.restart()
        queueLive()
    }
    function addLine(k, mode) {
        var lm = ensureLineModel(k)
        if (!lm) return
        lm.append({ t: "", mode: mode || "narrative", para: "cont", split: -1, noindent: false })
        syncLineModel(k)
    }
    function delLine(k, i) {
        var lm = ensureLineModel(k)
        if (!lm || i < 0 || i >= lm.count) return
        lm.remove(i)
        syncLineModel(k)
    }
    // THE fix: ListModel.move() relocates row data without touching delegate
    // identity or cross-contaminating other rows — the guarantee the old
    // array-swap-and-hope approach didn't actually have.
    function moveLine(k, i, d) {
        var lm = ensureLineModel(k)
        if (!lm) return
        var j = i + d
        if (i < 0 || i >= lm.count || j < 0 || j >= lm.count) return
        lm.move(i, j, 1)
        syncLineModel(k)
    }
    function setLine(k, i, field, v) {
        var lm = ensureLineModel(k)
        if (!lm || i < 0 || i >= lm.count) return
        if (lm.get(i)[field] === v) return
        lm.setProperty(i, field, v)
        syncLineModel(k)
    }

    // 0.8.1 FIX: this used to rebuild the proseMap entry as a literal object
    // that omitted `.lines`, silently discarding every line/split/mode a card
    // had once it went through the mode/para segment buttons. Now it copies
    // `.lines` (and everything else) forward and only overwrites the one
    // field being changed.
    function setProse(k, field, v) {
        if (!k || isScanned) return
        var cur = proseMap[k] ? proseMap[k] : blank()
        if (cur[field] === v) return
        var m = {}
        for (var x in proseMap) m[x] = proseMap[x]
        m[k] = { text: cur.text, mode: cur.mode, para: cur.para, lines: cur.lines }
        m[k][field] = v
        // Mode/para segment buttons act on ALL existing lines of this beat too,
        // so the card-level control and the line-level controls never disagree.
        if (field === "mode" || field === "para") {
            var arr = (cur.lines || []).slice()
            for (var i = 0; i < arr.length; i++) {
                var L = { t: arr[i].t, mode: arr[i].mode, para: arr[i].para,
                          split: arr[i].split, noindent: arr[i].noindent }
                L[field] = v
                arr[i] = L
            }
            m[k].lines = arr
        }
        proseMap = m
        proseRev++
        dirty = true
        saveTimer.restart()
        queueLive()
    }

    readonly property string unassignedKey: "UNASSIGNED"

    function resync() {
        var openFlags = {}
        for (var q = 0; q < rows.count; q++) openFlags[rows.get(q).bkey] = rows.get(q).open
        rows.clear()
        var seen = {}
        for (var i = 0; i < beatList.length; i++) {
            var b = beatList[i]
            var k = keyOf(b)
            seen[k] = true
            rows.append({ bkey: k, idx: i + 1,
                          plot: b.plot || "", phrase: b.phrase || "", question: b.question || "",
                          orphan: false,
                          open: openFlags[k] === undefined ? true : openFlags[k] })
        }
        if (unassigned.trim() !== "")
            rows.append({ bkey: unassignedKey, idx: 0, plot: "",
                          phrase: "EXISTING PROSE FROM THE FILE", question: "",
                          orphan: true,
                          open: openFlags[unassignedKey] === undefined ? true : openFlags[unassignedKey] })
        for (var ok in proseMap) {
            if (seen[ok]) continue
            if (!proseMap[ok].text || proseMap[ok].text.trim() === "") continue
            rows.append({ bkey: ok, idx: 0, plot: "", phrase: "(unlinked prose — press \u21c4 to attach)",
                          question: "", orphan: true,
                          open: openFlags[ok] === undefined ? true : openFlags[ok] })
        }
        rowCount = rows.count
        // 0.8.1: prose-with-zero-beats banner (see docMode).
        if (beatList.length === 0 && rowCount > 0) {
            var nOrphanBlocks = 0
            for (var oi = 0; oi < rows.count; oi++) if (rows.get(oi).bkey !== unassignedKey) nOrphanBlocks++
            docMode = "prose-no-beats"
            idMismatchMsg = "This document has " + nOrphanBlocks + " prose block(s) but Beat Machine "
                + "reports 0 beats. Add at least " + nOrphanBlocks + " beat(s) in Beat Machine so "
                + "Scene Sculptor has beats to link this prose to and can follow reordering."
            idMismatch = true
        }
        refreshStats()
        queueLive()
    }

    // ═══════════════ validation ═══════════════
    function beatComplete(i) {
        if (i < 0 || i >= rows.count) return false
        var r = rows.get(i)
        return r.plot.trim() !== "" && r.phrase.trim() !== "" && r.question.trim() !== ""
    }
    property int nComplete: 0
    property int nDone: 0
    property int nWords: 0
    function refreshStats() {
        if (isScanned) return
        var c = 0, d = 0
        for (var i = 0; i < rows.count; i++) {
            if (rows.get(i).orphan) continue
            if (beatComplete(i)) c++
            if (beatComplete(i) && proseText(rows.get(i).bkey).trim() !== "") d++
        }
        var w = 0
        for (var k in proseMap) w += countWords(proseMap[k].text)
        w += countWords(unassigned)
        nComplete = c; nDone = d; nWords = w
        rowCount = rows.count
    }
    function countWords(t) {
        if (!t) return 0
        var lines = String(t).split("\n"), n = 0
        for (var i = 0; i < lines.length; i++) {
            var L = lines[i].trim()
            if (L === "") continue
            if (L.indexOf("#") === 0) continue
            if (L.indexOf("<!--") === 0) continue
            var parts = L.split(/\s+/)
            for (var j = 0; j < parts.length; j++) if (parts[j] !== "") n++
        }
        return n
    }

    // 0.8.1: ONE debounce for every "live" (non-disk) side effect, run in
    // strict dependency order, replacing 0.7.1's four independently-timed
    // timers that could publish inconsistent numbers to shared state. See
    // CHANGELOG "FIXED — sync".
    Timer { id: liveTimer; interval: 180; onTriggered: {
        root.refreshStats()
        root.repaint()
        root.saveLocalState()
    } }
    function queueLive() { liveTimer.restart() }

    // ═══════════════ document parsing ═══════════════
    function splitDoc(doc) {
        if (!doc) return { front: "", body: "" }
        var m = doc.match(/^(\+\+\+[\s\S]*?\n\+\+\+[ \t]*\n?)([\s\S]*)$/)
        if (m) return { front: m[1], body: m[2] }
        m = doc.match(/^(---[\s\S]*?\n---[ \t]*\n?)([\s\S]*)$/)
        if (m) return { front: m[1], body: m[2] }
        return { front: "", body: doc }
    }

    // ── REAL FILE I/O ──
    property int canRead: -1     // -1 unknown · 0 blocked · 1 works
    property int canWrite: -1

    property bool relaunchTried: false
    function relaunchWithFileAccess() {
        if (relaunchTried) return false
        relaunchTried = true
        var cmd = "QML_XHR_ALLOW_FILE_READ=1 QML_XHR_ALLOW_FILE_WRITE=1"
        var probes = [
            { p: "proc",  f: "restart_with_env" },
            { p: "shell", f: "restart_with_env" },
            { p: "fs",    f: "restart_with_env" }
        ]
        for (var i = 0; i < probes.length; i++) {
            var r = call(probes[i].p, probes[i].f, { read: true, write: true, env: cmd })
            if (r !== undefined && r !== null) { log("relaunching via " + probes[i].p); return true }
        }
        log("no host exec available — cannot self-relaunch")
        return false
    }

    // 0.8.2: DISABLED per your request. You're right that this shouldn't be
    // guesswork — BM already opens files via FFI, and this was probing
    // plausible-sounding export names ("open_file_dialog_ffi") that were
    // never confirmed against BM's actual exports. Rather than ship a button
    // that silently falls through to something else when the guess fails
    // (which is exactly what made "Open file…" behave identically to
    // "Paste document" before — see openOwnFile() below), the button now
    // just sits disabled and this function is inert. The real acquisition
    // paths for now are the confirmed ones: the file BM already has open
    // (syncFromBM(), automatic) and an Emacs buffer via BM (useEmacs()).
    // Once you have the real FFI export name, uncomment the body below and
    // flip the button's `enabled:` binding.
    function openFileViaHost() {
        return false
        // var probes = ["shell", "fs"]
        // var r = bm("open_file_dialog_ffi", { filter: "*.md" })
        // if (r && r.path) {
        //     log("opened via host dialog (bm): " + r.path)
        //     adoptFile(r.path, "host")
        //     filePath = r.path
        //     say("opened " + r.path)
        //     return true
        // }
        // for (var i = 0; i < probes.length; i++) {
        //     var r2 = call(probes[i], "open_file_dialog_ffi", { filter: "*.md" })
        //     if (r2 && r2.path) {
        //         log("opened via host dialog (" + probes[i] + "): " + r2.path)
        //         say("opened " + r2.path)
        //         return true
        //     }
        // }
        // return false
    }
    // 0.8.1: try a host-mediated write before XHR. SS still builds the exact
    // bytes itself (buildDoc()) — the host is only asked to place them on
    // disk, never to compose or alter content.
    function writeFileViaHost(p, content, cb) {
        // bmPid through bm() (allow-listed); shell/fs through call() directly.
        var r = bm("write_prose_file_ffi", { path: p, content: content })
        if (r !== undefined && r !== null) { canWrite = 1; if (cb) cb(true); return true }
        var probes = ["shell", "fs"]
        for (var i = 0; i < probes.length; i++) {
            var r2 = call(probes[i], "write_prose_file_ffi", { path: p, content: content })
            if (r2 !== undefined && r2 !== null) {
                canWrite = 1
                if (cb) cb(true)
                return true
            }
        }
        return false
    }

    function toUrl(p) {
        var u = String(p)
        return (u.indexOf("file:") === 0) ? u : "file://" + u
    }
    function readFile(p) {
        if (!p) return ""
        try {
            var x = new XMLHttpRequest()
            x.open("GET", toUrl(p), false)
            x.send()
            if ((x.status === 200 || x.status === 0) && x.responseText) {
                canRead = 1
                return String(x.responseText)
            }
        } catch (e) { canRead = 0; log("read blocked: " + e); return "" }
        canRead = 0
        return ""
    }
    function writeFile(p, content, cb) {
        if (!p) { if (cb) cb(false); return }
        // 0.8.1: host path first.
        if (writeFileViaHost(p, content, cb)) return
        try {
            var w = new XMLHttpRequest()
            w.onreadystatechange = function () {
                if (w.readyState !== XMLHttpRequest.DONE) return
                var ok = (w.status === 0 || w.status === 200 || w.status === 201)
                root.canWrite = ok ? 1 : 0
                if (cb) cb(ok)
            }
            w.open("PUT", toUrl(p))
            w.send(content)
        } catch (e) { canWrite = 0; log("write blocked: " + e); if (cb) cb(false) }
    }

    // 0.8.1: `time=` (and a reserved, currently-unused `fp=`) added to the
    // anchor grammar. Both optional so old files without them still parse.
    readonly property string reAnchor:
        "<!--\\s*ss:beat=([A-Za-z0-9]+)\\s+mode=(\\w+)\\s+para=(\\w+)"
      + "(?:\\s+time=(\\d{14}))?(?:\\s+fp=(\\S+))?\\s*-->([\\s\\S]*?)<!--\\s*/ss\\s*-->"

    function stripTypography(t, mode) {
        var lines = String(t).split("\n"), out = []
        for (var i = 0; i < lines.length; i++) {
            var L = lines[i].replace(/^\u2003+/, "")
            if (mode === "dialogue") {
                var m2 = L.match(/^\*\u201c([\s\S]*?)\u201d\*\s*([\s\S]*)$/)
                if (m2) L = m2[1] + (m2[2] ? " " + m2[2] : "")
                else {
                    L = L.replace(/^\*(.*)\*$/, "$1")
                    L = L.replace(/^\u201c/, "").replace(/\u201d$/, "")
                }
            } else if (mode === "monologue") {
                L = L.replace(/^\*(.*)\*$/, "$1")
            }
            out.push(L)
        }
        return out.join("\n")
    }
    // 0.8.2: splits a paragraph's text into alternating plain / *italic*
    // runs. This is what lets a disk paragraph that mixes narrative and
    // monologue (e.g. "She paused. *Not like this.* She kept walking.")
    // round-trip back into separate narrative/monologue lines that will
    // re-merge into the same shared paragraph next render — matching what
    // groupLines()/blockToMarkdown() now write. Reserved convention: SS only
    // ever emits `*...*` for a monologue run, so literal asterisks a user
    // typed as their own markdown emphasis inside narrative text will be
    // reinterpreted as a monologue span on the next reload — a known
    // trade-off of using the same marker for both, not a new one 0.8.2
    // introduced (the tool already used `*...*` as its own convention).
    function splitItalicRuns(body) {
        var out = []
        var re = /\*([^*]+)\*|([^*]+)/g, m
        while ((m = re.exec(body)) !== null) {
            if (m[1] !== undefined) out.push({ text: m[1].trim(), italic: true })
            else out.push({ text: m[2].trim(), italic: false })
        }
        return out.filter(function (r) { return r.text !== "" })
    }
    function linesFromDisk(raw, mode) {
        var arr = []
        var blocks = String(raw).split(/\n\s*\n/)
        for (var i = 0; i < blocks.length; i++) {
            var b = blocks[i]
            var indented = /^\u2003/.test(b)
            var body = b.replace(/^\u2003+/, "").replace(/\n/g, " ").trim()
            if (body === "") continue
            var m2 = body.match(/^\*\u201c([\s\S]*?)\u201d\*\s*([\s\S]*)$/)
            if (m2) {
                var spoken = m2[1], tag = m2[2] ? m2[2].trim() : ""
                var joined = spoken + (tag ? " " + tag : "")
                arr.push({ t: joined, mode: "dialogue", para: "cont", split: spoken.length, noindent: false })
                continue
            }
            // 0.8.2: one disk paragraph may hold multiple runs (mixed
            // narrative/monologue). The FIRST run carries this block's
            // indent/para decision; later runs in the same block are always
            // "cont" so groupLines() re-merges them into one paragraph again.
            var runs = splitItalicRuns(body)
            for (var ri = 0; ri < runs.length; ri++) {
                var firstRun = (ri === 0)
                arr.push({
                    t: runs[ri].text,
                    mode: runs[ri].italic ? "monologue" : "narrative",
                    para: firstRun ? ((indented || i > 0) ? "new" : "cont") : "cont",
                    split: -1,
                    noindent: firstRun ? (!indented && i === 0) : false
                })
            }
        }
        return arr
    }

    function ingestBody(body) {
        var m = {}, leftover = body
        var rescued = []
        var stamps = {}
        try {
            var re = new RegExp(reAnchor, "g"), x
            while ((x = re.exec(body)) !== null)
            {
                var raw = x[6].replace(/^\n+|\n+$/g, "")
                var ls = raw.split("\n"), keep = []
                for (var y = 0; y < ls.length; y++) {
                    if (/^\s{0,3}#{1,6}\s+\S/.test(ls[y])) rescued.push(ls[y].replace(/\s+$/, ""))
                    else keep.push(ls[y])
                }
                var kept = keep.join("\n").replace(/^\n+|\n+$/g, "")
                m[x[1]] = { mode: x[2], para: x[3],
                            text: stripTypography(kept, x[2]),
                            lines: linesFromDisk(kept, x[2]) }
                if (x[4]) stamps[x[1]] = { time: x[4], fingerprint: x[5] || null }   // 0.8.1
            }
            leftover = body.replace(new RegExp(reAnchor, "g"), "")
        } catch (e) {}

        var lines = leftover.split("\n")
        var head = [], rest = []
        for (var i = 0; i < lines.length; i++) {
            var L = lines[i]
            if (/^\s{0,3}#{1,6}\s+\S/.test(L)) head.push(L.replace(/\s+$/, ""))
            else rest.push(L)
        }
        var restText = rest.join("\n").replace(/\n{3,}/g, "\n\n").replace(/^\s+|\s+$/g, "")
        var allHead = rescued.concat(head)
        if (rescued.length)
            log("recovered " + rescued.length + " heading(s) that were trapped inside anchors")
        return { prose: m, rest: restText, head: allHead.join("\n\n"), stamps: stamps }
    }

    function mergeProse(fromDoc) {
        var m = {}
        for (var d in fromDoc) m[d] = fromDoc[d]
        for (var k in proseMap) {
            var mine = proseMap[k]
            if ((mine.text && mine.text.trim() !== "") ||
                (mine.lines && mine.lines.length)) m[k] = mine
        }
        return m
    }

    function adoptDocument(doc, srcLabel) {
        var s = splitDoc(doc)
        frontMatter = s.front
        var got = ingestBody(s.body)
        headings = got.head
        proseMap = mergeProse(got.prose)
        unassigned = got.rest
        bodyText = s.body
        bodySource = srcLabel
        // 0.8.1: restore timestamps found on disk; anything already minted
        // this session (e.g. re-adopting the same file) wins, matching the
        // "typed text this session always beats disk" rule mergeProse uses.
        var sm = {}
        for (var x in got.stamps) sm[x] = got.stamps[x]
        for (var y in beatStamps) sm[y] = beatStamps[y]
        beatStamps = sm
        proseRev++
        log("document adopted from " + srcLabel
            + " — " + Object.keys(got.prose).length + " anchored blocks, "
            + (got.rest.length) + " chars of existing prose preserved")
    }

    property string headings: ""

    // ═══════════════ beats (READ-ONLY from BM) ═══════════════
    property string lastBeatSig: ""
    property string adoptedPath: ""
    function beatSig(list) {
        var s = []
        for (var i = 0; i < list.length; i++) s.push(keyOf(list[i]))
        return s.join(",")
    }
    property bool syncFlash: false

    function pathExt(p) {
        var m = String(p || "").match(/\.([a-zA-Z0-9]+)$/)
        return m ? m[1].toLowerCase() : ""
    }

    function syncFromBM() {
        var s = bm("session_load_ffi", {})
        if (s === undefined || s === null) {
            bmStatus = "unreachable"; bmBeats = -1
            return
        }
        var incoming = s.beats ? s.beats : []
        bmBeats = incoming.length
        bmStatus = "live"

        // 0.8.1: no file at all in BM.
        if (!s.path || s.path === "") {
            docMode = "no-file"
        }

        var sig = beatSig(incoming)
        var pathChanged = (s.path && s.path !== "" && s.path !== adoptedPath)
        if (sig === lastBeatSig && !pathChanged) return
        lastBeatSig = sig
        beatList = incoming
        if (pathChanged) {
            log("file changed -> " + s.path + " (dropping previous prose)")
            filePath = s.path
            idMismatch = false; idMismatchMsg = ""

            // 0.8.1: .toml-only detection — a beatsheet with nothing to write
            // prose into. Don't attempt to parse it as a markdown document at
            // all; that would silently misparse a TOML file as "empty prose".
            if (pathExt(s.path) === "toml") {
                docMode = "toml-only"
                proseMap = ({}); unassigned = ""; frontMatter = ""; headings = ""
                proseRev++
                idMismatch = true
                idMismatchMsg = "Beat Machine has a .toml beatsheet open with no prose document — "
                    + "there's nothing here for Scene Sculptor to write into. Switch Beat Machine to "
                    + "a Markdown file (frontmatter + [beatsheet] + prose) to continue, or open a "
                    + "Markdown file directly in Scene Sculptor to edit its prose."
                resync()
                syncFlash = true; flashTimer.restart()
                return
            }

            proseMap = ({})
            unassigned = ""
            frontMatter = ""
            headings = ""
            proseRev++
            adoptFile(s.path, "file")
            docMode = "markdown"
            checkIdMismatch()   // 0.8.1
        }
        resync()
        syncFlash = true
        flashTimer.restart()
    }
    Timer { id: followTimer; interval: 700; repeat: true; running: !root.isScanned
            onTriggered: root.syncFromBM() }
    Timer { id: flashTimer; interval: 900; onTriggered: root.syncFlash = false }

    // 0.8.1: after adopting a file that BM says it has open, check whether
    // the file's own anchored prose has ANYTHING in common with BM's live
    // beat keys. Zero overlap with non-trivial anchored content means this
    // markdown's embedded beat links don't correspond to what BM is showing
    // right now — classic "wrong file loaded, or BM's beatsheet moved on
    // without this file" situation. Say so plainly rather than quietly
    // turning every anchor into an unlabeled orphan.
    function checkIdMismatch() {
        var anchored = []
        for (var k in proseMap) {
            if (k === unassignedKey) continue
            if (proseMap[k].text && proseMap[k].text.trim() !== "") anchored.push(k)
        }
        if (anchored.length === 0) return   // nothing to compare — fine
        var live = {}
        for (var i = 0; i < beatList.length; i++) live[keyOf(beatList[i])] = true
        if (Object.keys(live).length === 0) return   // handled by prose-no-beats banner instead
        var overlap = 0
        for (var j = 0; j < anchored.length; j++) if (live[anchored[j]]) overlap++
        if (overlap === 0) {
            idMismatch = true
            idMismatchMsg = "This file's prose anchors (" + anchored.length + " block(s)) don't match "
                + "any of Beat Machine's " + beatList.length + " current beat(s). This usually means "
                + "the wrong file is loaded, or Beat Machine's beatsheet has moved on since this file "
                + "was last saved. Stop and reload this file in Beat Machine before editing — "
                + "otherwise prose may attach to the wrong beats."
        } else {
            idMismatch = false; idMismatchMsg = ""
        }
    }

    function adoptFile(p, srcLabel) {
        var doc = readFile(p)
        if (doc === "") {
            bodySource = (canRead === 0) ? "unreadable" : "empty"
            log("could not read " + p + (canRead === 0 ? " (needs QML_XHR_ALLOW_FILE_READ=1, or a host open dialog)" : ""))
            return false
        }
        adoptDocument(doc, srcLabel || "file")
        adoptedPath = p
        return true
    }

    function useEmacs() {
        if (!emacs.usable) return
        var k = bm("parse_beats_ffi", { path: emacs.file })
        if (!k) { say("beat machine could not parse that buffer: " + lastError, true); return }
        beatList = k.beats
        filePath = k.path
        lastBeatSig = beatSig(k.beats)
        docMode = (pathExt(k.path) === "toml") ? "toml-only" : "markdown"
        resync()
        checkIdMismatch()
        say("loaded " + k.beats.length + " beats from " + emacs.short)
    }

    // 0.8.1: the "open a file myself" path the user asked for — no BM link
    // implied. Tries the host dialog; falls back to Paste if unavailable.
    // 0.8.2: no longer falls through to the Paste dialog — that's why "Open
    // file…" and "Paste document" looked like the same button before: the
    // host dialog probe always failed, so every click silently landed on
    // Paste. They're two distinct, separate actions now. Open file… stays
    // disabled (see openFileViaHost() above and the button's `enabled:`
    // binding) until there's a confirmed FFI export to call.
    function openOwnFile() {
        log("Open file… is disabled in this build — use the file Beat Machine already "
          + "has open, or an Emacs buffer via Beat Machine (Use Emacs buffer)")
    }

    // ═══════════════ § PARAGRAPH GROUPING ═══════════════
    // Single source of truth for "does this line start a new paragraph and
    // get indented, or does it flow into the previous one" — consumed by
    // BOTH blockToMarkdown() (disk) and renderBlock() (preview), so the two
    // can never disagree.
    //
    // Traditional-prose rules, in priority order:
    //   1. Dialogue always starts its own paragraph (own quoted, indented,
    //      italic line) — never merges with anything.
    //   2. Narrative/monologue immediately following dialogue always starts a
    //      new paragraph (returning to narration after a quote conventionally
    //      breaks).
    //   3. Narrative and monologue are the SAME FAMILY for flow purposes —
    //      consecutive lines of EITHER kind merge into ONE paragraph as long
    //      as each is marked "Continue" (para == "cont"); only the monologue
    //      portion renders italic within that shared paragraph. A line
    //      marked "New ¶" always breaks, regardless of which of the two it
    //      is. 0.8.1 wrongly required an exact mode match to merge, so a
    //      monologue line after a "Continue" narrative line always broke
    //      into its own paragraph instead of flowing inline with only its
    //      own portion italicized — that's the fix here.
    //   4. A per-line manual "no-indent" override always wins for whether
    //      the resulting paragraph is INDENTED — it only ever suppresses
    //      indent, never forces an unwanted merge/split.
    //   5. The very first rendered paragraph of the whole document is never
    //      indented, no matter what the flags say (classic first-line rule).
    //
    // Returns groups of two shapes:
    //   dialogue: { kind:"dialogue", text, tag, indent }
    //   prose:    { kind:"prose", indent, runs:[{ text, italic }, ...] }
    //             — a prose group can mix plain (narrative) and italic
    //             (monologue) runs within ONE paragraph.
    function groupLines(arr) {
        var out = []
        var prevMode = null
        for (var i = 0; i < arr.length; i++) {
            var L = arr[i]
            var t = String(L.t || "").trim()
            if (t === "") continue
            if (L.mode === "dialogue") {
                var spoken = spokenPart(L).replace(/^[\u201c"]+/, "").replace(/[\u201d"]+$/, "").trim()
                var tag = tagPart(L)
                if (spoken === "") { prevMode = "dialogue"; continue }
                out.push({ kind: "dialogue", text: spoken, tag: tag, indent: !L.noindent })
                prevMode = "dialogue"
                continue
            }
            // narrative / monologue — same family, distinguished only by
            // whether their run renders italic.
            var breaksHere = (prevMode === null) || (prevMode === "dialogue") || (L.para === "new")
            var run = { text: t, italic: (L.mode === "monologue") }
            if (!breaksHere && out.length > 0 && out[out.length - 1].kind === "prose") {
                var g = out[out.length - 1]
                var lastRun = g.runs[g.runs.length - 1]
                if (lastRun && lastRun.italic === run.italic) lastRun.text += " " + run.text
                else g.runs.push(run)
                if (L.noindent) g.indent = false
            } else {
                out.push({ kind: "prose", indent: !L.noindent, runs: [run] })
            }
            prevMode = L.mode
        }
        return out
    }

    // ═══════════════ writing — PROSE ONLY ═══════════════
    readonly property string fileIndent: "\u2003"

    function blockToMarkdown(p, isFirst, key) {
        var arr = key ? linesOf(key) : textToLines(p.text, p.mode, p.para)
        var groups = groupLines(arr)
        var out = []
        for (var q = 0; q < groups.length; q++) {
            var g = groups[q]
            var indentThis = isFirst ? false : g.indent
            if (g.kind === "dialogue") {
                var line = fileIndent + "*\u201c" + g.text + "\u201d*"
                if (g.tag !== "") line += " " + g.tag
                out.push(line)
            } else {
                // prose: join runs, wrapping only the italic (monologue) runs
                var parts = []
                for (var ri = 0; ri < g.runs.length; ri++) {
                    var r = g.runs[ri]
                    parts.push(r.italic ? "*" + r.text + "*" : r.text)
                }
                out.push((indentThis ? fileIndent : "") + parts.join(" "))
            }
            isFirst = false
        }
        return out.join("\n\n")
    }

    function buildBody() {
        var out = []
        if (headings.trim() !== "") { out.push(headings.trim()); out.push("") }
        if (unassigned.trim() !== "") { out.push(unassigned.trim()); out.push("") }
        var first = true
        for (var i = 0; i < rows.count; i++) {
            var r = rows.get(i)
            if (r.bkey === unassignedKey) continue
            var p = proseFor(r.bkey)
            if (!p.text || p.text.trim() === "") continue
            var md = blockToMarkdown(p, first, r.bkey)
            if (md === "") continue
            first = false
            var stamp = stampFor(r.bkey)   // 0.8.1: minted if this is the first time
            out.push("<!-- ss:beat=" + r.bkey + " mode=" + p.mode + " para=" + p.para
                    + (stamp ? " time=" + stamp : "") + " -->")
            // fp= intentionally omitted until § FINGERPRINT is wired up.
            out.push(md)
            out.push("<!-- /ss -->")
            out.push("")
        }
        return out.join("\n").replace(/\s+$/, "") + "\n"
    }
    function buildDoc() { return frontMatter + (frontMatter !== "" ? "\n" : "") + buildBody() }

    // AUTOSAVE IN PLACE.
    property string saveState_: "idle"      // idle | saving | saved | failed
    function saveDoc(quiet) {
        if (isScanned || filePath === "") return false
        // 0.8.1: hard guards — never write into a .toml, and refuse rather
        // than clobber if the frontmatter looks like it evaporated between
        // the last read and now (would indicate something went badly wrong
        // upstream; better to stop than to write a beatsheet-less file).
        if (pathExt(filePath) === "toml") {
            say("refusing to save: this is a .toml beatsheet, not a prose document", true)
            return false
        }
        var disk = readFile(filePath)
        if (disk !== "") {
            var sp = splitDoc(disk)
            if (sp.front !== "") frontMatter = sp.front
            else if (frontMatter !== "") {
                say("refusing to save: frontmatter vanished from disk since last read — "
                  + "stopping instead of risking the beatsheet", true)
                log("ABORT save: disk has no frontmatter fence but we previously had one for " + filePath)
                return false
            }
        }
        var doc = buildDoc()
        saveState_ = "saving"
        writeFile(filePath, doc, function (ok) {
            root.saveState_ = ok ? "saved" : "failed"
            if (ok) { root.dirty = false; root.savedAt = new Date() }
            saveFlashTimer.restart()
            if (!ok) root.say("write failed — no host writer available and "
                             + "QML_XHR_ALLOW_FILE_WRITE=1 is not set", true)
        })
        saveLocalState()
        return true
    }
    property var savedAt: null
    Timer { id: saveFlashTimer; interval: 1600
            onTriggered: if (root.saveState_ !== "failed") root.saveState_ = "idle" }
    Timer { id: saveTimer; interval: 900; onTriggered: root.saveDoc(true) }

    TextEdit { id: clip; visible: false }
    function copyDoc() {
        var t = buildDoc()
        clip.text = t; clip.selectAll(); clip.copy(); clip.deselect()
        say("copied " + t.length + " chars — paste over your .md")
    }
    function copyBody() {
        var t = buildBody()
        clip.text = t; clip.selectAll(); clip.copy(); clip.deselect()
        say("copied prose body only (" + t.length + " chars)")
    }

    // ═══════════════ state ═══════════════
    function db() {
        try { return LocalStorage.openDatabaseSync("KosmikSceneSculptor", "1.0", "SS state", 1000000) }
        catch (e) { log("LocalStorage unavailable: " + e); return null }
    }
    property bool stateReady: false
    function saveLocalState() {
        if (!stateReady || isScanned) return
        var d = db(); if (!d) return
        try {
            d.transaction(function (tx) {
                tx.executeSql("CREATE TABLE IF NOT EXISTS st(k TEXT UNIQUE, v TEXT)")
                tx.executeSql("INSERT OR REPLACE INTO st(k,v) VALUES('main',?)",
                    [JSON.stringify({ schema: 2, path: filePath, prose: proseMap,
                                      front: frontMatter, unassigned: unassigned,
                                      headings: headings, beatStamps: beatStamps,
                                      words: nWords, done: nDone, total: nComplete,
                                      html: previewHtml, htmlMarks: buildHtml(true),
                                      src: bodySource, dirty: dirty })])
            })
        } catch (e) { log("saveState failed: " + e) }
    }
    function loadState() {
        var d = db(); if (!d) return
        try {
            d.transaction(function (tx) {
                tx.executeSql("CREATE TABLE IF NOT EXISTS st(k TEXT UNIQUE, v TEXT)")
                var rs = tx.executeSql("SELECT v FROM st WHERE k='main'")
                if (rs.rows.length === 0) return
                var o = JSON.parse(rs.rows.item(0).v)
                if (o.prose) proseMap = o.prose
                if (o.path) filePath = o.path
                if (o.front) frontMatter = o.front
                if (o.unassigned) unassigned = o.unassigned
                if (o.headings !== undefined) headings = o.headings   // 0.8.1 FIX: was never restored
                if (o.beatStamps) beatStamps = o.beatStamps            // 0.8.1
                if (o.src) bodySource = o.src
                proseRev++
                log("restored " + Object.keys(proseMap).length + " prose blocks"
                    + (unassigned !== "" ? " + existing prose" : ""))
            })
        } catch (e) { log("loadState failed: " + e) }
    }
    Timer { id: mirrorTimer; interval: 200; repeat: true; running: root.isScanned
            onTriggered: root.mirrorFromState() }
    property string lastMirror: ""
    property string mirrorHtml: ""
    property string mirrorHtmlMarks: ""
    property int mirrorRev: 0
    function mirrorFromState() {
        var d = db(); if (!d) return
        try {
            d.transaction(function (tx) {
                tx.executeSql("CREATE TABLE IF NOT EXISTS st(k TEXT UNIQUE, v TEXT)")
                var rs = tx.executeSql("SELECT v FROM st WHERE k='main'")
                if (rs.rows.length === 0) return
                var raw = rs.rows.item(0).v
                if (raw === lastMirror) return
                lastMirror = raw
                var o = JSON.parse(raw)
                if (o.prose) { proseMap = o.prose; proseRev++ }
                if (o.unassigned !== undefined) unassigned = o.unassigned
                if (o.headings !== undefined) headings = o.headings
                if (o.path) filePath = o.path
                if (o.words !== undefined) { nWords = o.words; nDone = o.done; nComplete = o.total }
                if (o.html !== undefined) { mirrorHtml = o.html; mirrorHtmlMarks = o.htmlMarks }
                mirrorRev++
            })
        } catch (e) {}
    }
    onShellActiveChanged: if (!shellActive) { saveLocalState(); if (dirty) saveDoc(true) }

    // ═══════════════ preview ═══════════════
    readonly property string indentRun: "&nbsp;&nbsp;&nbsp;&nbsp;"
    property bool showMarks: false
    property string previewHtml: ""

    function esc(s) {
        return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    }
    function inline(s) {
        var t = esc(s)
        t = t.replace(/\*\*([^*]+)\*\*/g, "<b>$1</b>")
        t = t.replace(/(^|[^*])\*([^*]+)\*/g, "$1<i>$2</i>")
        t = t.replace(/_([^_]+)_/g, "<i>$1</i>")
        return t
    }
    // 0.8.1: rebuilt on top of groupLines() — same paragraph/indent decisions
    // as blockToMarkdown(), so preview and disk output can't drift apart, and
    // the "indents not showing" bug has one place left to hide, not two.
    function renderBlock(p, first, marks, key) {
        var h = []
        var arr = key ? linesOf(key) : textToLines(p.text, p.mode, p.para)
        var groups = groupLines(arr)
        for (var q = 0; q < groups.length; q++) {
            var g = groups[q]
            var indentThis = first.v ? false : g.indent
            if (g.kind === "dialogue") {
                h.push('<p style="margin:6px 0 6px 0; line-height:145%">'
                     + indentRun + '<i>\u201c' + inline(g.text) + '\u201d</i>'
                     + (g.tag !== "" ? " " + inline(g.tag) : "") + '</p>')
            } else {
                var parts = []
                for (var ri = 0; ri < g.runs.length; ri++) {
                    var r = g.runs[ri]
                    parts.push(r.italic ? '<i>' + inline(r.text) + '</i>' : inline(r.text))
                }
                h.push('<p align="justify" style="margin:0 0 2px 0; line-height:140%">'
                     + (indentThis ? indentRun : "") + parts.join(" ") + '</p>')
            }
            first.v = false
        }
        return h
    }
    function buildHtml(marks) {
        var h = ['<div style="color:#e8e8f0">']
        var first = { v: true }
        var any = false
        if (unassigned.trim() !== "") {
            if (marks) h.push('<p style="margin:8px 0 2px 0"><font color="#ffb300" size="1">'
                            + '▸ existing prose (not assigned to a beat)</font></p>')
            var ps = unassigned.trim().split(/\n\s*\n/)
            for (var u = 0; u < ps.length; u++) {
                var c0 = ps[u].replace(/\n/g, " ").trim()
                if (c0 === "") continue
                h.push('<p align="justify" style="margin:0 0 2px 0; line-height:140%">'
                     + inline(c0) + '</p>')
                any = true; first.v = false
            }
        }
        for (var i = 0; i < rows.count; i++) {
            var r = rows.get(i)
            var p = proseFor(r.bkey)
            if ((p.text || "").trim() === "" && !marks) continue
            if (marks) {
                var stampTxt = (beatStamps[r.bkey] && beatStamps[r.bkey].time) ? beatStamps[r.bkey].time : "—"
                h.push('<p style="margin:10px 0 2px 0"><font color="#6a6a7c" size="1">'
                     + '▸ ' + (r.orphan ? "orphan" : "beat " + r.idx) + ' · ' + esc(r.bkey)
                     + ' · ' + p.mode + ' · ' + p.para + ' · ' + stampTxt
                     + (r.phrase ? ' · ' + esc(r.phrase) : '') + '</font></p>')
            }
            var blk = renderBlock(p, first, marks, r.bkey)
            for (var z = 0; z < blk.length; z++) { h.push(blk[z]); any = true }
        }
        if (!any && !marks)
            h.push('<p style="color:#4a4a5c">No prose yet. Type into a beat on the left.</p>')
        h.push("</div>")
        return h.join("")
    }
    // 0.8.1: no longer calls saveLocalState() itself — that happens once, in
    // strict order, from liveTimer. See CHANGELOG "FIXED — sync".
    function repaint() { previewHtml = buildHtml(showMarks) }
    onShowMarksChanged: repaint()

    // ═══════════════ emacs ═══════════════
    Timer { interval: 3000; repeat: true; running: !root.isScanned
            onTriggered: { var s = bm("emacs_status_ffi", {}); if (s) emacs = s } }
    function emacsLabel() {
        if (!emacs.running) return "emacs off"
        if (!emacs.server)  return "emacs · no server"
        if (emacs.short === "") return "emacs · no file"
        return emacs.short + " · " + emacs.beats
    }
    function emacsColor() { return emacs.usable ? cOk : (emacs.running ? cWarn : "#3a3a48") }

    // ═══════════════ dialogs ═══════════════
    Dialog {
        id: pasteDlg
        title: "Paste the document (frontmatter + prose)"; modal: true
        width: Math.min(800, root.width - 40); height: Math.min(580, root.height - 60)
        anchors.centerIn: parent
        standardButtons: Dialog.Ok | Dialog.Cancel
        onAccepted: {
            root.adoptDocument(pasteArea.text, "paste")
            root.docMode = "markdown"
            root.resync(); root.repaint(); root.saveLocalState()
            root.say("document adopted — beatsheet untouched")
        }
        background: Rectangle { color: "#15151f"; radius: 10; border.color: "#3a3a4c" }
        contentItem: ColumnLayout {
            spacing: 6
            Text {
                Layout.fillWidth: true; wrapMode: Text.Wrap
                text: "SS reads the prose body only. Your frontmatter and [beatsheet] "
                    + "are passed through untouched — SS never rewrites beats. Opening a file "
                    + "this way is NOT linked to Beat Machine: if it has no beats yet, prose stays "
                    + "unassigned until the same file is loaded into Beat Machine and beats are added."
                color: root.cDim; font.pixelSize: 10
            }
            Flickable {
                Layout.fillWidth: true; Layout.fillHeight: true
                clip: true
                ScrollBar.vertical: KScroll {}
                TextArea.flickable: TextArea {
                    id: pasteArea
                    wrapMode: TextArea.Wrap; selectByMouse: true
                    font.family: "Monospace"; font.pixelSize: 12; color: root.cPhr
                    background: Rectangle { color: "#0d0d16"; radius: 6; border.color: root.cEdge }
                }
            }
        }
    }

    Popup {
        id: linkPop
        property string sourceKey: ""
        property bool fromUnassigned: false
        modal: true; dim: false; padding: 8
        width: Math.min(340, root.width - 24)
        height: Math.min(400, root.height - 80)
        onClosed: root._pendingSelection = ""   // 0.8.1: never let a cancelled Ctrl+L leak into the next attach
        background: Rectangle { color: "#15151f"; radius: 9; border.color: "#4a4a60" }
        contentItem: ColumnLayout {
            spacing: 6
            Text {
                text: root._pendingSelection !== "" ? "Attach selection to which beat?" : "Attach to which beat?"
                color: root.cText; font.pixelSize: 12
            }
            ListView {
                Layout.fillWidth: true; Layout.fillHeight: true
                clip: true; model: rows
                ScrollBar.vertical: KScroll {}
                delegate: ItemDelegate {
                    id: ld
                    required property string bkey
                    required property string phrase
                    required property int idx
                    required property bool orphan
                    height: orphan ? 0 : 30
                    visible: !orphan
                    width: ListView.view.width
                    background: Rectangle { radius: 5; color: ld.hovered ? "#26263a" : "transparent" }
                    contentItem: Text {
                        text: ld.idx + " · " + (ld.phrase === "" ? "(untitled)" : ld.phrase)
                        color: "#d4d4e0"; font.pixelSize: 12; leftPadding: 8
                        verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight
                    }
                    // 0.8.1 FIX: reads LIVE content at click time instead of
                    // a stale `ta.text` snapshot captured when the popup was
                    // opened — this is the "orphaned prose vanished after
                    // linking" fix. Two paths share this popup:
                    //   · a pending SELECTION (Ctrl+L) -> attachSelection()
                    //   · the whole ⇄ card                -> attachWholeCard()
                    onClicked: {
                        if (root._pendingSelection !== "") {
                            root.attachSelection(root._pendingSelection, ld.bkey,
                                                  linkPop.sourceKey, linkPop.fromUnassigned)
                            root._pendingSelection = ""
                        } else {
                            root.attachWholeCard(linkPop.sourceKey, ld.bkey, linkPop.fromUnassigned)
                        }
                        linkPop.close()
                        root.say("attached to beat " + ld.idx)
                    }
                }
            }
        }
    }

    // 0.8.1: moves the FULL, current, authoritative content of a source
    // (either the special unassigned block, or another beat's proseMap
    // entry) onto a target beat's line list. Never touches a UI control's
    // cached text — always reads root.linesOf()/root.unassigned directly.
    function attachWholeCard(sourceKey, targetKey, fromUnassigned) {
        var tgt = linesOf(targetKey).slice()
        if (fromUnassigned) {
            var srcLines = textToLines(unassigned, "narrative")
            if (!srcLines.length) return
            tgt = tgt.concat(srcLines)
            writeLines(targetKey, tgt)
            unassigned = ""
        } else {
            var srcLines2 = linesOf(sourceKey)
            if (!srcLines2.length) return
            tgt = tgt.concat(srcLines2)
            writeLines(targetKey, tgt)
            var m = {}
            for (var x in proseMap) if (x !== sourceKey) m[x] = proseMap[x]
            proseMap = m
        }
        proseRev++
        resync(); queueLive()
        saveTimer.restart()
    }
    // 0.8.1: selection-based attach (Ctrl+L). Appends the selected text as a
    // single new narrative line on the target, and trims exactly that
    // substring from the source — using the LIVE source text, not a stale
    // copy, same fix as attachWholeCard.
    function attachSelection(selText, targetKey, sourceKey, fromUnassigned) {
        if (!selText || selText.trim() === "") return
        var tgt = linesOf(targetKey).slice()
        tgt.push({ t: selText.trim(), mode: "narrative", para: "new", split: -1, noindent: false })
        writeLines(targetKey, tgt)
        if (fromUnassigned) {
            unassigned = unassigned.replace(selText, "").replace(/\n{3,}/g, "\n\n").trim()
        } else {
            var srcLines = linesOf(sourceKey).slice()
            for (var i = 0; i < srcLines.length; i++) {
                if (srcLines[i].t.indexOf(selText) !== -1) {
                    var L = srcLines[i]
                    var nt = L.t.replace(selText, "").trim()
                    srcLines[i] = { t: nt, mode: L.mode, para: L.para, split: -1, noindent: L.noindent }
                    break
                }
            }
            writeLines(sourceKey, srcLines.filter(function (l) { return l.t.trim() !== "" }))
        }
        resync(); queueLive()
        saveTimer.restart()
    }

    // ═══════════════ shortcuts ═══════════════
    Shortcut { sequences: ["Ctrl+S"]; onActivated: root.saveDoc(false) }
    Shortcut { sequences: ["Ctrl+Shift+C"]; onActivated: root.copyDoc() }
    Shortcut { sequences: ["Ctrl+Shift+V"]; onActivated: { pasteArea.text = ""; pasteDlg.open() } }
    Shortcut { sequences: ["Ctrl+P"]; onActivated: { pane.visible = !pane.visible; root.repaint() } }
    Shortcut { sequences: ["Ctrl+M"]; onActivated: { root.showMarks = !root.showMarks } }

    // ═══════════════ 0.8.2: expand/collapse/accordion ═══════════════
    function expandAll() { for (var i = 0; i < rows.count; i++) rows.setProperty(i, "open", true) }
    function collapseAll() { for (var i = 0; i < rows.count; i++) rows.setProperty(i, "open", false) }
    // When on, opening any card closes every other one — one prose section
    // open at a time. Enforced at the point a card is opened (see the card's
    // ⌃/⌄ toggle below), not retroactively when you flip this switch.
    property bool accordionMode: false

    // ═══════════════ layout ═══════════════
    ColumnLayout {
        anchors.fill: parent; anchors.margins: 12; spacing: 8

        Flow {
            Layout.fillWidth: true; spacing: 6
            KGroup {
                // 0.8.2: DISABLED — see openFileViaHost()/openOwnFile() above.
                // This was silently falling through to the Paste dialog
                // whenever the (unconfirmed) host FFI probe failed, which is
                // why it looked identical to "Paste document". It stays here,
                // visibly present but inert, until there's a real FFI export
                // to wire it to — for now the file comes from Beat Machine
                // directly (automatic) or from an Emacs buffer via Beat
                // Machine (button to the right).
                KSeg { text: "Open file…"; accent: root.cDim; enabled: false
                       ToolTip.visible: hovered
                       ToolTip.text: "Disabled — no confirmed host FFI export yet. "
                                   + "Use the file Beat Machine has open, or Use Emacs buffer."
                       onClicked: root.openOwnFile() }
                KSeg { text: "Paste document"; accent: root.cPhr
                       onClicked: { pasteArea.text = ""; pasteDlg.open() } }
                KSeg { text: "Use Emacs buffer"; accent: root.cOk
                       enabled: root.emacs.usable; onClicked: root.useEmacs() }
            }
            KGroup {
                KSeg { text: "Copy document"; accent: root.cOk; onClicked: root.copyDoc() }
                KSeg { text: "Copy prose only"; accent: root.cNote; onClicked: root.copyBody() }
            }
            KGroup {
                KSeg { text: "Preview"; accent: root.cPhr; active: pane.visible
                       onClicked: { pane.visible = !pane.visible; root.repaint() } }
                KSeg { text: "Beat markers"; accent: root.cNote; active: root.showMarks
                       onClicked: root.showMarks = !root.showMarks }
            }
            // 0.8.2: requested expand/collapse-all + accordion ("work one
            // beat at a time"; opening a new one closes the rest).
            KGroup {
                KSeg { text: "Expand all"; accent: root.cOk; onClicked: root.expandAll() }
                KSeg { text: "Collapse all"; accent: root.cWarn; onClicked: root.collapseAll() }
                KSeg { text: "Auto (one at a time)"; accent: root.cNote
                       active: root.accordionMode
                       onClicked: root.accordionMode = !root.accordionMode }
            }
        }

        // 0.8.1: persistent guidance / mismatch banner. Covers toml-only,
        // prose-no-beats, and beat-id mismatch — the three edge cases asked
        // for. Dismissible so it doesn't trap the user, but reappears if the
        // underlying condition is still true next sync.
        Rectangle {
            visible: root.idMismatch && root.idMismatchMsg !== ""
            Layout.fillWidth: true
            implicitHeight: bannerTxt.implicitHeight + 16
            radius: 8
            color: Qt.rgba(1, 0.18, 0.73, 0.10)
            border.color: root.cBad; border.width: 1
            RowLayout {
                anchors.fill: parent; anchors.margins: 8; spacing: 8
                Text { text: "⚠"; color: root.cBad; font.pixelSize: 14 }
                Text {
                    id: bannerTxt
                    Layout.fillWidth: true
                    text: root.idMismatchMsg
                    color: root.cText; font.pixelSize: 11; wrapMode: Text.Wrap
                }
                KTool { text: "\u2715"; ToolTip.visible: hovered; ToolTip.text: "Dismiss"
                        onClicked: root.idMismatch = false }
            }
        }

        RowLayout {
            Layout.fillWidth: true; spacing: 9
            Rectangle { Layout.preferredWidth: 8; Layout.preferredHeight: 8; radius: 4
                        color: root.dirty ? root.cWarn : root.cOk }
            Label {
                text: root.nWords + " words · " + root.nDone + " of " + root.nComplete + " beats have prose"
                color: root.cDim; font.pixelSize: 11
            }
            Rectangle {
                Layout.preferredHeight: 19; Layout.preferredWidth: svT.implicitWidth + 18
                radius: 9
                color: root.saveState_ === "saved" ? Qt.rgba(0, 1, 0.64, 0.18) : "transparent"
                Behavior on color { ColorAnimation { duration: 200 } }
                border.color: root.saveState_ === "failed" ? root.cBad
                            : (root.saveState_ === "saving" ? root.cWarn
                            : (root.dirty ? root.cWarn : root.cOk))
                Text {
                    id: svT; anchors.centerIn: parent
                    text: root.saveState_ === "saving" ? "saving…"
                        : root.saveState_ === "saved"  ? "saved to file"
                        : root.saveState_ === "failed" ? "write blocked"
                        : (root.dirty ? "unsaved" : "in sync")
                    color: root.saveState_ === "failed" ? root.cBad
                         : (root.saveState_ === "saving" ? root.cWarn
                         : (root.dirty ? root.cWarn : root.cOk))
                    font.pixelSize: 9; font.bold: true
                }
                ToolTip.visible: svMa.containsMouse
                ToolTip.text: root.canWrite === 0
                    ? "writes are blocked — no host writer available and QML_XHR_ALLOW_FILE_WRITE=1 is not set"
                    : "prose is written into " + (root.filePath === "" ? "(no file)" : root.filePath)
                       + " ~0.9 s after you stop typing"
                MouseArea { id: svMa; anchors.fill: parent; hoverEnabled: true }
            }
            Rectangle {
                Layout.preferredHeight: 19; Layout.preferredWidth: bmT.implicitWidth + 18
                radius: 9
                color: root.syncFlash ? Qt.rgba(0, 1, 0.64, 0.18) : "transparent"
                Behavior on color { ColorAnimation { duration: 250 } }
                border.color: root.bmStatus === "live" ? root.cOk : root.cBad
                Text { id: bmT; anchors.centerIn: parent
                       text: root.bmStatus === "live"
                             ? "BM live · " + root.bmBeats + " beats · " + root.docMode
                             : "BM " + root.bmStatus
                       color: root.bmStatus === "live" ? root.cOk : root.cBad
                       font.pixelSize: 9; font.bold: true }
                ToolTip.visible: bmMa.containsMouse
                ToolTip.text: root.bmStatus === "live"
                    ? "session_load_ffi answered; auto-syncing every 0.7 s"
                    : "beat machine did not answer: " + root.lastError
                MouseArea { id: bmMa; anchors.fill: parent; hoverEnabled: true }
            }
            Rectangle {
                visible: root.canRead === 0 || root.canWrite === 0
                Layout.preferredHeight: 19
                Layout.preferredWidth: fxT.implicitWidth + 18
                radius: 9; color: "transparent"; border.color: root.cBad
                Text { id: fxT; anchors.centerIn: parent
                       text: "file access blocked — click"
                       color: root.cBad; font.pixelSize: 9; font.bold: true }
                ToolTip.visible: fxMa.containsMouse
                ToolTip.text: "No host-mediated file access answered, and Qt blocks local file XHR "
                            + "unless launched with\nQML_XHR_ALLOW_FILE_READ=1 QML_XHR_ALLOW_FILE_WRITE=1\n"
                            + "Click to copy the fallback launch command."
                MouseArea {
                    id: fxMa; anchors.fill: parent; hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        clip.text = "QML_XHR_ALLOW_FILE_READ=1 QML_XHR_ALLOW_FILE_WRITE=1 "
                                  + "./kosmik-kaleidoscope"
                        clip.selectAll(); clip.copy(); clip.deselect()
                        root.say("fallback launch command copied — paste it in your terminal")
                    }
                }
            }
            Rectangle {
                Layout.preferredHeight: 19; Layout.preferredWidth: srcT.implicitWidth + 18
                radius: 9; color: "transparent"
                border.color: root.unassigned !== "" ? root.cWarn : "#3a3a48"
                Text { id: srcT; anchors.centerIn: parent
                       text: root.unassigned !== "" ? "existing prose kept" : "body: " + root.bodySource
                       color: root.unassigned !== "" ? root.cWarn : root.cDim
                       font.pixelSize: 9; font.bold: true }
                ToolTip.visible: srcMa.containsMouse
                ToolTip.text: root.unassigned !== ""
                    ? "prose found in the document that is not tied to a beat — preserved verbatim"
                    : "where SS got the prose body from"
                MouseArea { id: srcMa; anchors.fill: parent; hoverEnabled: true }
            }
            Item { Layout.fillWidth: true }
            Label { text: root.filePath === "" ? "no file" : root.filePath
                    color: "#4a4a5c"; font.pixelSize: 11
                    elide: Text.ElideLeft; Layout.maximumWidth: root.narrow ? 170 : 300 }
        }

        GridLayout {
            Layout.fillWidth: true; Layout.fillHeight: true
            columns: root.narrow ? 1 : 2
            columnSpacing: 12; rowSpacing: 10

            ColumnLayout {
                Layout.fillWidth: true; Layout.fillHeight: true
                spacing: 8

                ListView {
                    id: view
                    Layout.fillWidth: true; Layout.fillHeight: true
                    model: rows; spacing: 10; clip: true
                    cacheBuffer: 8000
                    ScrollBar.vertical: KScroll {}

                    delegate: Rectangle {
                        id: card
                        required property int index
                        required property string bkey
                        required property int idx
                        required property string plot
                        required property string phrase
                        required property string question
                        required property bool orphan
                        required property bool open

                        property string localMode: "narrative"
                        property string localPara: "cont"
                        property bool ready: false
                        property bool hasProse: false

                        readonly property bool isUnassigned: bkey === root.unassignedKey
                        // 0.8.1: line count, recomputed whenever proseRev moves —
                        // this is what the Repeater model binds to (stable int),
                        // NOT the array itself. See CHANGELOG.
                        readonly property int lc: root.proseRev >= 0 ? root.lineCount(bkey) : 0

                        Component.onCompleted: {
                            if (isUnassigned) {
                                ta.text = root.unassigned
                                hasProse = root.unassigned.trim() !== ""
                            } else {
                                var p = root.proseFor(bkey)
                                localMode = p.mode; localPara = p.para
                                hasProse = p.text.trim() !== ""
                                root.ensureLineModel(bkey)   // 0.8.2: create the card's line model once, up front
                            }
                            ready = true
                        }
                        readonly property bool complete:
                            plot.trim() !== "" && phrase.trim() !== "" && question.trim() !== ""

                        width: ListView.view.width
                        height: col.implicitHeight + 24
                        radius: 10
                        color: root.kosmikTheme && root.kosmikTheme.bgTile !== undefined
                               ? root.kosmikTheme.bgTile : Qt.rgba(1, 1, 1, 0.045)
                        border.width: 1
                        border.color: orphan ? root.cWarn : (hasProse && complete ? root.cOk : root.cEdge)

                        ColumnLayout {
                            id: col
                            anchors { top: parent.top; left: parent.left; right: parent.right; margins: 12 }
                            spacing: 8

                            RowLayout {
                                Layout.fillWidth: true; spacing: 6
                                Rectangle {
                                    Layout.preferredWidth: 42; Layout.preferredHeight: 24; radius: 12
                                    color: card.orphan ? root.cWarn
                                         : (card.hasProse && card.complete ? root.cOk
                                         : (card.complete ? "#3a3a52" : "#2a2a38"))
                                    Text {
                                        anchors.centerIn: parent
                                        text: card.orphan ? "⚠"
                                            : ((card.hasProse && card.complete ? "● "
                                              : (card.complete ? "◐ " : "○ ")) + card.idx)
                                        color: card.hasProse && card.complete ? "#0d0d16" : "#c9c9d6"
                                        font.bold: true; font.pixelSize: 11
                                    }
                                }
                                Rectangle {
                                    Layout.preferredHeight: 24; radius: 12
                                    Layout.preferredWidth: Math.min(kt.implicitWidth + 20, 90)
                                    color: "transparent"; border.color: root.cDim
                                    Text { id: kt; anchors.centerIn: parent; text: card.bkey
                                           color: root.cDim; font.pixelSize: 9; font.family: "Monospace" }
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: card.phrase === "" ? "(no key phrase)" : card.phrase
                                    color: card.orphan ? root.cWarn : root.cPhr
                                    font.pixelSize: 11; font.bold: true; elide: Text.ElideRight
                                }
                                KTool {
                                    visible: card.orphan
                                    text: "\u21c4"
                                    ToolTip.visible: hovered; ToolTip.text: "Attach this prose to a beat"
                                    onClicked: {
                                        root._pendingSelection = ""   // 0.8.1: whole-card path, not a selection
                                        linkPop.sourceKey = card.bkey
                                        linkPop.fromUnassigned = card.isUnassigned
                                        linkPop.x = Math.round((root.width - linkPop.width) / 2)
                                        linkPop.y = 60
                                        linkPop.open()
                                    }
                                }
                                KTool { text: card.open ? "⌃" : "⌄"
                                        ToolTip.visible: hovered
                                        ToolTip.text: card.open ? "Collapse" : "Expand"
                                        onClicked: {
                                            var opening = !card.open
                                            // 0.8.2: accordion — opening a card while Auto is on
                                            // closes every other one, so only one beat's prose is
                                            // being worked on at a time.
                                            if (root.accordionMode && opening) {
                                                for (var qi = 0; qi < rows.count; qi++)
                                                    rows.setProperty(qi, "open", qi === card.index)
                                            } else {
                                                rows.setProperty(card.index, "open", opening)
                                            }
                                        } }
                            }

                            Text {
                                visible: card.open && card.question !== ""
                                Layout.fillWidth: true
                                text: card.question
                                color: root.cDim; font.pixelSize: 11; wrapMode: Text.Wrap
                            }

                            RowLayout {
                                visible: card.open && !card.isUnassigned
                                Layout.fillWidth: true; spacing: 6
                                KGroup {
                                    KSeg { text: "Narrative"; accent: root.cPhr
                                           active: card.localMode === "narrative"
                                           onClicked: { card.localMode = "narrative"
                                                        root.setProse(card.bkey, "mode", "narrative") } }
                                    KSeg { text: "Dialogue"; accent: root.cNote
                                           active: card.localMode === "dialogue"
                                           onClicked: { card.localMode = "dialogue"
                                                        root.setProse(card.bkey, "mode", "dialogue") } }
                                    // 0.8.1: monologue — inline like narrative, italic only.
                                    KSeg { text: "Monologue"; accent: root.cPlot
                                           active: card.localMode === "monologue"
                                           onClicked: { card.localMode = "monologue"
                                                        root.setProse(card.bkey, "mode", "monologue") } }
                                }
                                KGroup {
                                    KSeg { text: "Continue"; accent: root.cDim
                                           active: card.localPara === "cont"
                                           onClicked: { card.localPara = "cont"
                                                        root.setProse(card.bkey, "para", "cont") } }
                                    KSeg { text: "New ¶"; accent: root.cOk
                                           active: card.localPara === "new"
                                           onClicked: { card.localPara = "new"
                                                        root.setProse(card.bkey, "para", "new") } }
                                }
                                Item { Layout.fillWidth: true }
                            }

                            // ── CHILD LINES ──
                            // 0.8.1: model is the LINE COUNT (a stable int),
                            // not the lines array. This is the core fix for
                            // the freeze/single-character bug — delegates now
                            // persist across edits instead of being destroyed
                            // and recreated on every keystroke.
                            // 0.8.2: model is now a REAL ListModel (see
                            // ensureLineModel/§ 0.8.2 REWRITE above), not a
                            // plain array or a bare count. ListModel.move()
                            // is Qt's own guaranteed-non-destructive reorder —
                            // each row's fields travel with it and delegates
                            // are reused correctly. This is the actual fix
                            // for "moving a monologue line showed/wrote
                            // another line's text" — the old array-swap +
                            // manual resync approach didn't have that
                            // guarantee; ListModel does.
                            Repeater {
                                model: !card.isUnassigned ? root.lineModels[card.bkey] : null
                                delegate: Rectangle {
                                    id: lrow
                                    required property int index
                                    required property string t
                                    required property string mode
                                    required property string para
                                    required property int split
                                    required property bool noindent

                                    Layout.fillWidth: true
                                    implicitHeight: lcol.implicitHeight + 12
                                    radius: 6
                                    color: mode === "dialogue"
                                           ? Qt.rgba(0.70, 0.62, 1, 0.07)
                                           : (mode === "monologue"
                                              ? Qt.rgba(0.77, 0.42, 1, 0.07)
                                              : Qt.rgba(1, 1, 1, 0.03))
                                    border.width: 1
                                    border.color: mode === "dialogue"
                                                  ? Qt.rgba(0.70, 0.62, 1, 0.30)
                                                  : (mode === "monologue"
                                                     ? Qt.rgba(0.77, 0.42, 1, 0.30) : "#22222e")

                                    ColumnLayout {
                                        id: lcol
                                        anchors { left: parent.left; right: parent.right
                                                  top: parent.top; margins: 6 }
                                        spacing: 4

                                        RowLayout {
                                            Layout.fillWidth: true; spacing: 4
                                            Text {
                                                text: (lrow.index + 1)
                                                color: root.cDim; font.pixelSize: 9
                                                font.family: "Monospace"
                                            }
                                            KGroup {
                                                KSeg { text: "N"; accent: root.cPhr
                                                       ToolTip.visible: hovered; ToolTip.text: "Narrative"
                                                       active: lrow.mode === "narrative"
                                                       onClicked: root.setLine(card.bkey, lrow.index, "mode", "narrative") }
                                                KSeg { text: "D"; accent: root.cNote
                                                       ToolTip.visible: hovered; ToolTip.text: "Dialogue"
                                                       active: lrow.mode === "dialogue"
                                                       onClicked: root.setLine(card.bkey, lrow.index, "mode", "dialogue") }
                                                KSeg { text: "M"; accent: root.cPlot
                                                       ToolTip.visible: hovered; ToolTip.text: "Monologue (inline, italic only)"
                                                       active: lrow.mode === "monologue"
                                                       onClicked: root.setLine(card.bkey, lrow.index, "mode", "monologue") }
                                            }
                                            KGroup {
                                                visible: lrow.mode !== "dialogue"
                                                KSeg { text: "\u00b6"; accent: root.cOk
                                                       ToolTip.visible: hovered; ToolTip.text: "New paragraph (indent)"
                                                       active: lrow.para === "new"
                                                       onClicked: root.setLine(card.bkey, lrow.index, "para",
                                                                  lrow.para === "new" ? "cont" : "new") }
                                                // manual no-indent override, independent of position.
                                                KSeg { text: "no-indent"; accent: root.cWarn
                                                       ToolTip.visible: hovered
                                                       ToolTip.text: "Force this paragraph to render with no indent"
                                                       active: lrow.noindent === true
                                                       onClicked: root.setLine(card.bkey, lrow.index, "noindent",
                                                                  !lrow.noindent) }
                                            }
                                            Item { Layout.fillWidth: true }
                                            KTool { text: "\u25b2"; enabled: lrow.index > 0
                                                    ToolTip.visible: hovered; ToolTip.text: "Move up"
                                                    onClicked: root.moveLine(card.bkey, lrow.index, -1) }
                                            KTool { text: "\u25bc"
                                                    enabled: lrow.index < card.lc - 1
                                                    ToolTip.visible: hovered; ToolTip.text: "Move down"
                                                    onClicked: root.moveLine(card.bkey, lrow.index, 1) }
                                            KTool { text: "\u2715"
                                                    ToolTip.visible: hovered; ToolTip.text: "Delete line"
                                                    onClicked: root.delLine(card.bkey, lrow.index) }
                                        }

                                        TextArea {
                                            id: lta
                                            property bool suppress: false
                                            Layout.fillWidth: true
                                            Layout.minimumHeight: 42
                                            wrapMode: TextArea.Wrap
                                            selectByMouse: true
                                            persistentSelection: true
                                            color: root.cText
                                            font.pixelSize: 13
                                            font.italic: lrow.mode === "monologue"
                                            placeholderText: lrow.mode === "dialogue"
                                                ? "Spoken words, then the tag: Yes, she replied."
                                                : (lrow.mode === "monologue"
                                                   ? "Monologue (renders italic, inline)\u2026"
                                                   : "Narrative\u2026")
                                            placeholderTextColor: "#4a4a5c"
                                            background: Rectangle {
                                                color: Qt.rgba(0, 0, 0, 0.30); radius: 4
                                                border.color: lta.activeFocus ? root.cPhr : "transparent"
                                            }
                                            Component.onCompleted: { text = lrow.t; suppress = false }
                                            onTextChanged: if (!suppress) root.setLine(card.bkey, lrow.index, "t", text)
                                            // 0.8.2: driven by the ListModel role's OWN change signal
                                            // (onTChanged, auto-generated for the required `t` property)
                                            // instead of a synthetic whole-object comparison. Fires
                                            // precisely when THIS row's text actually changed — whether
                                            // from a reorder (move() carries t with its row) or a direct
                                            // edit — and never clobbers text you're actively typing.
                                            Connections {
                                                target: lrow
                                                function onTChanged() {
                                                    if (lta.activeFocus) return
                                                    if (lta.text === lrow.t) return
                                                    lta.suppress = true
                                                    lta.text = lrow.t
                                                    lta.suppress = false
                                                }
                                            }
                                            Keys.onPressed: function (e) {
                                                if (e.key === Qt.Key_L && (e.modifiers & Qt.ControlModifier)) {
                                                    if (lta.selectedText !== "") {
                                                        linkPop.sourceKey = card.bkey
                                                        linkPop.fromUnassigned = false
                                                        root._pendingSelection = lta.selectedText
                                                        linkPop.x = Math.round((root.width - linkPop.width) / 2)
                                                        linkPop.y = 60
                                                        linkPop.open()
                                                    }
                                                    e.accepted = true
                                                }
                                            }
                                        }

                                        // ── the tag slider ──
                                        // Drag updates a local preview instantly; the actual model
                                        // commit is debounced 60 ms so dragging stays smooth.
                                        ColumnLayout {
                                            visible: lrow.mode === "dialogue" && String(lrow.t).length > 0
                                            Layout.fillWidth: true; spacing: 1
                                            Slider {
                                                id: sp
                                                Layout.fillWidth: true
                                                implicitHeight: 18
                                                from: 0
                                                to: Math.max(1, String(lrow.t).length)
                                                stepSize: 1
                                                snapMode: Slider.SnapAlways
                                                value: {
                                                    var s0 = root.splitOf({ t: lrow.t, split: lrow.split })
                                                    return s0 < 0 ? String(lrow.t).length : s0
                                                }
                                                onMoved: sliderCommit.restart()
                                                Timer { id: sliderCommit; interval: 60
                                                        onTriggered: root.setLine(card.bkey, lrow.index,
                                                                     "split", Math.round(sp.value)) }
                                                background: Rectangle {
                                                    x: sp.leftPadding
                                                    y: sp.topPadding + sp.availableHeight / 2 - 2
                                                    width: sp.availableWidth; height: 4; radius: 2
                                                    color: "#22222e"
                                                    Rectangle { width: sp.visualPosition * parent.width
                                                                height: parent.height; radius: 2
                                                                color: root.cNote }
                                                }
                                                handle: Rectangle {
                                                    x: sp.leftPadding + sp.visualPosition * (sp.availableWidth - width)
                                                    y: sp.topPadding + sp.availableHeight / 2 - height / 2
                                                    width: 12; height: 12; radius: 6
                                                    color: sp.pressed ? root.cNote : "#15151f"
                                                    border.color: root.cNote; border.width: 2
                                                }
                                            }
                                            Text {
                                                Layout.fillWidth: true
                                                // Reads sp.value directly (not the committed model split)
                                                // so the label tracks the drag with zero lag.
                                                text: {
                                                    var synth = { t: lrow.t, split: Math.round(sp.value) }
                                                    var sk = root.spokenPart(synth)
                                                    var tg = root.tagPart(synth)
                                                    return "\u201c" + sk + "\u201d"
                                                         + (tg !== "" ? "  \u00b7  " + tg : "  \u00b7  (no tag)")
                                                }
                                                color: root.cDim; font.pixelSize: 9
                                                elide: Text.ElideRight
                                            }
                                        }
                                    }
                                }
                            }

                            RowLayout {
                                visible: card.open && !card.isUnassigned
                                Layout.fillWidth: true; spacing: 6
                                KGroup {
                                    KSeg { text: "+ narrative"; accent: root.cPhr
                                           onClicked: root.addLine(card.bkey, "narrative") }
                                    KSeg { text: "+ dialogue"; accent: root.cNote
                                           onClicked: root.addLine(card.bkey, "dialogue") }
                                    KSeg { text: "+ monologue"; accent: root.cPlot
                                           onClicked: root.addLine(card.bkey, "monologue") }
                                }
                                Item { Layout.fillWidth: true }
                            }

                            TextArea {
                                id: ta
                                visible: card.open && card.isUnassigned
                                Layout.fillWidth: true
                                Layout.minimumHeight: 96
                                wrapMode: TextArea.Wrap
                                selectByMouse: true
                                color: root.cText; font.pixelSize: 14
                                placeholderText: "Prose from the file, not yet attached to a beat"
                                placeholderTextColor: "#4a4a5c"
                                background: Rectangle { color: Qt.rgba(0, 0, 0, 0.34); radius: 6
                                                        border.color: ta.activeFocus ? root.cPhr : "#22222e" }
                                Component.onCompleted: { text = root.unassigned }
                                onTextChanged: {
                                    if (!card.ready) return
                                    root.unassigned = text
                                    root.dirty = true; root.proseRev++
                                    saveTimer.restart(); root.queueLive()
                                }
                                Keys.onPressed: function (e) {
                                    if (e.key === Qt.Key_L && (e.modifiers & Qt.ControlModifier)) {
                                        if (ta.selectedText !== "") {
                                            linkPop.sourceKey = card.bkey
                                            linkPop.fromUnassigned = true
                                            root._pendingSelection = ta.selectedText
                                            linkPop.x = Math.round((root.width - linkPop.width) / 2)
                                            linkPop.y = 60
                                            linkPop.open()
                                        }
                                        e.accepted = true
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Rectangle {
                id: pane
                visible: false
                Layout.fillWidth: true
                Layout.fillHeight: !root.narrow
                Layout.preferredWidth:  root.narrow ? -1 : Math.round(root.width * 0.42)
                Layout.preferredHeight: root.narrow ? Math.round(root.height * 0.34) : -1
                color: Qt.rgba(0, 0, 0, 0.28); radius: 8; border.color: "#22222e"
                Flickable {
                    anchors.fill: parent; anchors.margins: 14
                    contentHeight: prev.implicitHeight
                    clip: true
                    ScrollBar.vertical: KScroll {}
                    Text {
                        id: prev
                        width: parent.width
                        textFormat: Text.RichText
                        wrapMode: Text.WordWrap
                        color: root.cText; font.pixelSize: 14
                        text: root.previewHtml
                    }
                }
            }
        }

        Label { id: status; text: "starting…"; color: "#5a5a6c"; font.pixelSize: 11
                Layout.fillWidth: true; elide: Text.ElideRight }
    }

    // 0.8.1: linkPop is shared by two attach flows. sourceKey/fromUnassigned
    // (declared on the Popup itself) identify WHERE the prose is coming from;
    // _pendingSelection, when non-empty, means the user Ctrl+L'd a text
    // selection rather than asking to attach a whole orphan card — the
    // popup's click handler (above) checks this to route to attachSelection()
    // vs attachWholeCard(). Always cleared immediately after use.
    property string _pendingSelection: ""

    // ═══════════════ embeddable components ═══════════════
    Component {
        id: prosePreviewComp
        Rectangle {
            id: pp
            color: Qt.rgba(0, 0, 0, 0.30); radius: 8
            border.color: "#22222e"; border.width: 1
            property bool marks: false
            readonly property int rev: root.isScanned
                                       ? root.mirrorRev
                                       : (root.proseRev + root.rowCount)
            function refresh() {
                pv.text = root.isScanned
                    ? (pp.marks ? root.mirrorHtmlMarks : root.mirrorHtml)
                    : root.buildHtml(pp.marks)
            }
            onRevChanged: refresh()
            onMarksChanged: refresh()
            Component.onCompleted: refresh()

            Flickable {
                anchors.fill: parent
                anchors.margins: 12
                anchors.topMargin: 34
                contentHeight: pv.implicitHeight
                clip: true
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                Text {
                    id: pv
                    width: parent.width
                    textFormat: Text.RichText
                    wrapMode: Text.WordWrap
                    color: root.cText; font.pixelSize: 14
                }
            }
            Text {
                anchors.top: parent.top; anchors.left: parent.left; anchors.margins: 11
                text: "PROSE PREVIEW"; color: root.cPhr
                font.pixelSize: 9; font.bold: true; font.letterSpacing: 1.1
            }
            Rectangle {
                anchors.top: parent.top; anchors.right: parent.right; anchors.margins: 7
                width: mkT.implicitWidth + 16; height: 20; radius: 10
                color: pp.marks ? Qt.rgba(0.70, 0.62, 1, 0.20) : "transparent"
                border.color: pp.marks ? root.cNote : root.cEdge
                Text { id: mkT; anchors.centerIn: parent
                       text: pp.marks ? "markers on" : "markers off"
                       color: pp.marks ? root.cNote : root.cDim
                       font.pixelSize: 9; font.bold: true }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                            onClicked: pp.marks = !pp.marks }
            }
        }
    }

    Component {
        id: statusComp
        Rectangle {
            id: sc
            color: "#0d0d16"; radius: 8
            border.color: root.cPhr; border.width: 1
            readonly property bool tiny: height < 54
            Column {
                anchors.centerIn: parent; spacing: 3
                Text { text: "SCENE SCULPTOR"; color: root.cPhr
                       visible: !sc.tiny
                       font.pixelSize: 10; font.bold: true; font.letterSpacing: 1.2 }
                Text { text: root.nWords + " words"
                       color: root.cOk; font.pixelSize: 11; font.bold: true }
                Text { text: root.nDone + "/" + root.nComplete + " beats have prose"
                       visible: !sc.tiny
                       color: root.cDim; font.pixelSize: 9 }
            }
        }
    }

    Component {
        id: wordCountComp
        Rectangle {
            id: wc
            color: "#0d0d16"; radius: 8
            border.color: root.cOk; border.width: 1
            readonly property bool tiny: height < 46
            Column {
                anchors.centerIn: parent; spacing: 2
                Text { text: root.nWords
                       anchors.horizontalCenter: parent.horizontalCenter
                       color: root.cOk; font.pixelSize: wc.tiny ? 13 : 20; font.bold: true }
                Text { text: "words"; visible: !wc.tiny
                       anchors.horizontalCenter: parent.horizontalCenter
                       color: root.cDim; font.pixelSize: 9; font.letterSpacing: 1.1 }
            }
        }
    }

    // 0.8.2 FIX: `shell` arrives AFTER Component.onCompleted (documented in
    // the API guide's own edge-case table — "Decide ownership in
    // onShellChanged, not at construction"). isScanned reads shell.isScanShell,
    // so at Component.onCompleted time it was ALWAYS false for BOTH the
    // headless scan copy and the live copy — neither instance could tell it
    // was the scan copy, so BOTH ran the full live startup: both called
    // syncFromBM()/adoptFile(), both could later call bm()/writeFile(), and
    // both wrote to the same LocalStorage row. That's the double "starting"
    // log with neither tagged "(scan copy)", the duplicate "document adopted"
    // lines, the widgets never settling into the shell's scan (a live second
    // instance mutating things mid-scan is exactly the corruption pattern the
    // API guide's Jimmy war-story describes), and very likely a contributor
    // to the monologue reorder corruption too — two live instances editing
    // the same beat's lines is a genuine race, not just a UI bug.
    //
    // Fix: do the scan-gated work in onShellChanged, guarded so it only runs
    // once — covering both "shell already set by onCompleted time" (some
    // hosts) and "shell arrives later" (this host, per the log).
    property bool shellInited: false
    function initForShellState() {
        if (shellInited) return
        shellInited = true
        log("scene sculptor " + ver + (isScanned ? " (scan copy — read-only)" : "") + " ready")
        if (isScanned) { repaint(); return }   // scan copy: never touch BM, disk, or local state beyond this
        syncFromBM()
        // 0.8.2: removed the old unconditional re-adopt here. syncFromBM()'s
        // pathChanged branch already adopts on first sync (adoptedPath starts
        // empty every session, so pathChanged is always true the first time)
        // — calling adoptFile() again right after was pure duplicate work and
        // is what produced the doubled "document adopted from file" log line.
        if (canRead === 0) {
            log("XHR file reads blocked by Qt — trying self-relaunch before giving up")
            if (!relaunchWithFileAccess())
                log("no host file access available yet — Open file… is disabled in this build; "
                  + "use the BM-linked file or an Emacs buffer, or fall back to "
                  + "QML_XHR_ALLOW_FILE_READ=1 QML_XHR_ALLOW_FILE_WRITE=1 ./kosmik-kaleidoscope")
        }
        var e = bm("emacs_status_ffi", {}); if (e) emacs = e
        log(bmStatus === "live"
            ? "beat machine answered session_load_ffi with " + bmBeats + " beats"
            : "beat machine did not answer: " + lastError)
        repaint()
        say(canRead === 0 && canWrite === 0
            ? "file access blocked — see the launcher note in the header"
            : "ready · " + rowCount + " rows · " + nWords + " words")
    }
    onShellChanged: if (shell) initForShellState()

    Component.onCompleted: {
        loadState()
        stateReady = true
        // Covers hosts that set `shell` before Component.onCompleted fires.
        // If shell isn't set yet, onShellChanged (above) will run this once
        // it arrives — either way initForShellState() runs exactly once.
        if (shell) initForShellState()
    }
    Component.onDestruction: { saveLocalState(); if (dirty) saveDoc(true) }
}
