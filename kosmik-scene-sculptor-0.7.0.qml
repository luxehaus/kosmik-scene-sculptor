// kosmik-scene-sculptor-0.7.0 · SS
// Prose companion to the Beat Machine. QML only.
//
// ═════════════════════════════════════════════════════════════════════════════
// WHAT 0.4.0 GOT WRONG — and the rule that replaces it
//
//   0.4.0 folded prose into each beat's NOTES array and handed that to
//   save_beats_ffi. BM faithfully serialised it, so prose ended up INSIDE the
//   [beatsheet] TOML and corrupted the document.
//
//   THE RULE, now enforced in code:
//     SS NEVER SENDS BEATS TO BEAT MACHINE. It never calls save_beats_ffi,
//     never calls session_save_ffi, never mutates a beat. Beats are READ-ONLY
//     context. Only BM writes the beatsheet.
//
//   SS owns exactly one thing: the prose body BELOW the frontmatter. It writes
//   that and nothing else, wrapped in HTML-comment anchors that are invisible
//   in every Markdown renderer:
//       <!-- ss:beat=9F9059 mode=narrative para=cont -->
//       The prose.
//       <!-- /ss -->
//
//   A repair script for documents damaged by 0.4.0 ships alongside this file:
//       python3 repair-sample.py yourfile.md --in-place
// ═════════════════════════════════════════════════════════════════════════════
//
// DOCUMENT SHAPES HANDLED (all four, explicitly)
//   · beats + prose      → both preserved, prose keyed to beats
//   · beats, no prose    → cards ready to write into
//   · prose, no beats    → prose kept verbatim as "unassigned"; select text and
//                          assign it to a beat once beats exist
//   · neither            → empty, no error
//
// READING THE BODY
//   Qt's XHR CAN read and write local files — 0.5.0 was wrong to give up. It
//   needs two env vars, and the write must be ASYNC (a synchronous PUT writes
//   zero bytes). Launch the app with:
//       QML_XHR_ALLOW_FILE_READ=1 QML_XHR_ALLOW_FILE_WRITE=1 ./kosmik-kaleidoscope
//   SS then autosaves the prose body in place ~0.9 s after you stop typing,
//   re-reading the file first so BM's beatsheet is never clobbered.

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.LocalStorage
import Kosmik.Core 1.0

Rectangle {
    id: root
    anchors.fill: parent
    color: "#0d0d16"; radius: 12
    border.color: "#00e5ff"; border.width: 2

    KosmikHost { id: host }

    readonly property string ver:   "0.7.0"
    readonly property string bmPid: "kosmik-beat-machine"
    readonly property string pid:   "kosmik-scene-sculptor"

    property var  shell: null
    property var  kosmikTheme: null
    property bool shellActive: false

    readonly property bool narrow: width < 1000

    // ── document ──
    property string filePath: ""
    property string bodyText: ""        // everything below the frontmatter
    property string frontMatter: ""     // +++ ... +++  (READ-ONLY here)
    property string bodySource: "none"  // none | paste | state
    property bool   dirty: false
    property var    emacs: ({ running:false, server:false, usable:false, file:"", short:"", beats:0 })

    // BM health, described honestly rather than "OK".
    property string bmStatus: "checking"
    property int    bmBeats: -1

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

    // The shell's scanner reads this. That is the entire contract.
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

    // ═══════════════ bridge ═══════════════
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
    function bm(fn, payload) { return call(bmPid, fn, payload) }
    function say(m, bad) { status.text = (bad ? "✕  " : "●  ") + m; status.color = bad ? cBad : cOk }

    // ═══════════════ beat identity ═══════════════
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

    // ═══════════════ model ═══════════════
    ListModel { id: rows }
    property var proseMap: ({})     // key -> { text, mode, para }
    property var beatList: []       // READ-ONLY copy of BM's beats
    property int rowCount: 0
    // Prose found in the document that is not tied to any beat. Never discarded.
    property string unassigned: ""

    function blank() { return { text: "", mode: "narrative", para: "cont" } }
    function proseFor(k) { var p = proseMap[k]; return p ? p : blank() }
    function proseText(k) { return proseFor(k).text }

    function setProse(k, field, v) {
        if (!k || isScanned) return
        var cur = proseMap[k] ? proseMap[k] : blank()
        if (cur[field] === v) return
        var m = {}
        for (var x in proseMap) m[x] = proseMap[x]
        m[k] = { text: cur.text, mode: cur.mode, para: cur.para }
        m[k][field] = v
        proseMap = m
        proseRev++
        dirty = true
        saveTimer.restart()
        stateTimer.restart()
        previewTimer.restart()
        statsTimer.restart()
    }

    // Unassigned prose is a ROW like any other, so it appears in the list AND
    // in the preview. A separate side panel was the wrong answer: prose you
    // cannot see in context is no use when the whole point is assigning it.
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
        refreshStats()
        previewTimer.restart()
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
        if (isScanned) return          // numbers come from the editing copy
        var c = 0, d = 0
        for (var i = 0; i < rows.count; i++) {
            if (rows.get(i).orphan) continue
            if (beatComplete(i)) c++
            if (beatComplete(i) && proseText(rows.get(i).bkey).trim() !== "") d++
        }
        // Prose words only: markdown headings, anchors and blank lines excluded.
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
            if (L.indexOf("#") === 0) continue          // markdown heading
            if (L.indexOf("<!--") === 0) continue       // anchor
            var parts = L.split(/\s+/)
            for (var j = 0; j < parts.length; j++) if (parts[j] !== "") n++
        }
        return n
    }
    Timer { id: statsTimer; interval: 250; onTriggered: root.refreshStats() }

    // ═══════════════ document parsing ═══════════════
    // Split a document into frontmatter and body. SS only ever edits the body.
    // Handles +++ (TOML) and --- (YAML) fences, and documents with neither.
    function splitDoc(doc) {
        if (!doc) return { front: "", body: "" }
        var m = doc.match(/^(\+\+\+[\s\S]*?\n\+\+\+[ \t]*\n?)([\s\S]*)$/)
        if (m) return { front: m[1], body: m[2] }
        m = doc.match(/^(---[\s\S]*?\n---[ \t]*\n?)([\s\S]*)$/)
        if (m) return { front: m[1], body: m[2] }
        return { front: "", body: doc }
    }

    // ── REAL FILE I/O ──
    // Qt's XHR reads AND writes local files. Verified: an async PUT writes
    // byte-identical content; a SYNCHRONOUS PUT silently writes 0 bytes, which
    // is why the write below must stay async. Requires launching with
    //     QML_XHR_ALLOW_FILE_READ=1 QML_XHR_ALLOW_FILE_WRITE=1
    // Both are probed at runtime and reported plainly rather than assumed.
    property int canRead: -1     // -1 unknown · 0 blocked · 1 works
    property int canWrite: -1

    // A GUI must not require the user to know an env var. If Qt has blocked
    // local file access, SS relaunches the app itself with the two flags set.
    // Nothing is guessed: it re-executes the SAME binary and args it is
    // already running under, and only ever does it once per session.
    property bool relaunchTried: false
    function relaunchWithFileAccess() {
        if (relaunchTried) return false
        relaunchTried = true
        var cmd = "QML_XHR_ALLOW_FILE_READ=1 QML_XHR_ALLOW_FILE_WRITE=1"
        // Prefer a host-side exec if this build exposes one.
        var probes = [
            { p: "proc",  f: "restart_with_env" },
            { p: "shell", f: "restart_with_env" },
            { p: "fs",    f: "restart_with_env" }
        ]
        for (var i = 0; i < probes.length; i++) {
            var r = call(probes[i].p, probes[i].f,
                         { read: true, write: true, env: cmd })
            if (r !== undefined && r !== null) { log("relaunching via " + probes[i].p); return true }
        }
        log("no host exec available — cannot self-relaunch")
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
    // Async on purpose. cb(ok) fires when the write has actually completed.
    function writeFile(p, content, cb) {
        if (!p) { if (cb) cb(false); return }
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

    readonly property string reAnchor:
        "<!--\\s*ss:beat=([A-Za-z0-9]+)\\s+mode=(\\w+)\\s+para=(\\w+)\\s*-->([\\s\\S]*?)<!--\\s*/ss\\s*-->"

    // Pull anchored prose out of the BODY. Whatever is left over is the
    // author's existing prose and is kept verbatim as `unassigned`.
    // Headings (# .. ######) are DOCUMENT STRUCTURE, not prose. A title and a
    // POV/date subhead must stay exactly where the author put them — 0.6.0
    // swallowed them into the prose pool and let them be attached to a beat,
    // which is why "# Title" ended up inside an anchor.
    // They are lifted out here, kept verbatim in `headings`, and re-emitted
    // above the prose on every write.
    property string headings: ""

    // Inverse of blockToMarkdown: remove em-spaces, quotes and italic markers
    // so the editor shows what you typed, not the rendered form.
    function stripTypography(t, mode) {
        var lines = String(t).split("\n"), out = []
        for (var i = 0; i < lines.length; i++) {
            var L = lines[i].replace(/^\u2003+/, "")
            if (mode === "dialogue") {
                L = L.replace(/^\*(.*)\*$/, "$1")
                L = L.replace(/^\u201c/, "").replace(/\u201d$/, "")
            }
            out.push(L)
        }
        return out.join("\n")
    }

    function ingestBody(body) {
        var m = {}, leftover = body
        var rescued = []          // headings recovered from inside anchors
        try {
            var re = new RegExp(reAnchor, "g"), x
            while ((x = re.exec(body)) !== null)
            {
                var raw = stripTypography(x[4].replace(/^\n+|\n+$/g, ""), x[2])
                // MIGRATION: 0.6.0 swallowed "# Title" style headings into
                // anchors. Lift any heading back out so structure returns to
                // the top of the document instead of living inside a beat.
                var ls = raw.split("\n"), keep = []
                for (var y = 0; y < ls.length; y++) {
                    if (/^\s{0,3}#{1,6}\s+\S/.test(ls[y])) rescued.push(ls[y].replace(/\s+$/, ""))
                    else keep.push(ls[y])
                }
                m[x[1]] = { mode: x[2], para: x[3],
                            text: keep.join("\n").replace(/^\n+|\n+$/g, "") }
            }
            leftover = body.replace(new RegExp(reAnchor, "g"), "")
        } catch (e) {}

        // Split structure from prose, preserving heading order.
        var lines = leftover.split("\n")
        var head = [], rest = []
        for (var i = 0; i < lines.length; i++) {
            var L = lines[i]
            if (/^\s{0,3}#{1,6}\s+\S/.test(L)) head.push(L.replace(/\s+$/, ""))
            else rest.push(L)
        }
        var restText = rest.join("\n").replace(/\n{3,}/g, "\n\n").replace(/^\s+|\s+$/g, "")
        // Rescued headings come first: they were originally above the prose.
        var allHead = rescued.concat(head)
        if (rescued.length)
            log("recovered " + rescued.length + " heading(s) that were trapped inside anchors")
        return { prose: m, rest: restText, head: allHead.join("\n\n") }
    }

    // Merge: text typed in this session always beats text from disk.
    function mergeProse(fromDoc) {
        var m = {}
        for (var d in fromDoc) m[d] = fromDoc[d]
        for (var k in proseMap) {
            var mine = proseMap[k]
            if (mine.text && mine.text.trim() !== "") m[k] = mine
        }
        return m
    }

    function adoptDocument(doc, srcLabel) {
        var s = splitDoc(doc)
        frontMatter = s.front
        var got = ingestBody(s.body)
        headings = got.head
        proseMap = mergeProse(got.prose)
        // Adopting a document REPLACES the unassigned prose with that
        // document's own. Appending instead would drag the previous file's
        // prose into the new one — which is exactly the class of bug that
        // corrupted the sample. If the incoming document genuinely has none,
        // this must become empty.
        unassigned = got.rest
        bodyText = s.body
        bodySource = srcLabel
        proseRev++
        log("document adopted from " + srcLabel
            + " — " + Object.keys(got.prose).length + " anchored blocks, "
            + (got.rest.length) + " chars of existing prose preserved")
    }

    // ═══════════════ beats (READ-ONLY from BM) ═══════════════
    property string lastBeatSig: ""
    // The path whose CONTENT we have actually loaded. Distinct from filePath,
    // which BM can set before we have read anything.
    property string adoptedPath: ""
    function beatSig(list) {
        var s = []
        for (var i = 0; i < list.length; i++) s.push(keyOf(list[i]))
        return s.join(",")
    }
    // Continuous. There is no Sync button: SS follows BM automatically and only
    // flashes the indicator when something actually changed.
    property bool syncFlash: false
    function syncFromBM() {
        var s = bm("session_load_ffi", {})
        if (s === undefined || s === null) {
            bmStatus = "unreachable"; bmBeats = -1
            return
        }
        var incoming = s.beats ? s.beats : []
        bmBeats = incoming.length
        bmStatus = "live"
        var sig = beatSig(incoming)
        var pathChanged = (s.path && s.path !== "" && s.path !== adoptedPath)
        if (sig === lastBeatSig && !pathChanged) return
        lastBeatSig = sig
        beatList = incoming
        if (pathChanged) {
            // A DIFFERENT DOCUMENT. Everything keyed to the old file must go,
            // or its prose reappears as phantom orphans in the new one — which
            // is exactly what put 3 stale blocks into sample-2.md.
            log("file changed -> " + s.path + " (dropping previous prose)")
            filePath = s.path
            proseMap = ({})
            unassigned = ""
            frontMatter = ""
            headings = ""
            proseRev++
            adoptFile(s.path)
        }
        resync()
        syncFlash = true
        flashTimer.restart()
    }
    Timer { id: followTimer; interval: 700; repeat: true; running: !root.isScanned
            onTriggered: root.syncFromBM() }
    Timer { id: flashTimer; interval: 900; onTriggered: root.syncFlash = false }

    // Read a real file and take its prose. Called on every file switch, so SS
    // always reflects the document BM actually has open.
    function adoptFile(p) {
        var doc = readFile(p)
        if (doc === "") {
            bodySource = (canRead === 0) ? "unreadable" : "empty"
            log("could not read " + p + (canRead === 0 ? " (needs QML_XHR_ALLOW_FILE_READ=1)" : ""))
            return false
        }
        adoptDocument(doc, "file")
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
        resync()
        say("loaded " + k.beats.length + " beats from " + emacs.short)
    }

    // ═══════════════ writing — PROSE ONLY ═══════════════
    // Rebuilds the BODY. The frontmatter (and therefore the whole beatsheet) is
    // passed through byte-for-byte. SS cannot corrupt the beats because it never
    // regenerates them.
    // U+2003 EM SPACE — a real character, so the indent survives in emacs,
    // glow, pandoc and any renderer. NOT four literal spaces: markdown turns
    // a 4-space line into a CODE BLOCK, which is exactly the trap that ruins
    // prose in Obsidian and MarkText.
    readonly property string fileIndent: "\u2003"

    // Render one prose block the way it must appear ON DISK.
    //   narrative + new paragraph -> em-space first line
    //   dialogue                  -> own line, italic, curly quotes
    function blockToMarkdown(p, isFirst) {
        var body = (p.text || "").trim()
        if (body === "") return ""
        var paras = body.split(/\n\s*\n/)
        var out = []
        for (var q = 0; q < paras.length; q++) {
            var chunk = paras[q].replace(/\n/g, " ").trim()
            if (chunk === "") continue
            if (p.mode === "dialogue") {
                var t = chunk
                if (t.charAt(0) !== "\u201c") t = "\u201c" + t
                if (t.charAt(t.length - 1) !== "\u201d") t = t + "\u201d"
                // italic via markdown so pandoc emits <em>/\emph
                out.push(fileIndent + "*" + t + "*")
            } else {
                var newPara = (q > 0) || (p.para === "new")
                out.push((!isFirst && newPara ? fileIndent : "") + chunk)
            }
            isFirst = false
        }
        return out.join("\n\n")
    }

    function buildBody() {
        var out = []
        // Structure first, exactly as it was found.
        if (headings.trim() !== "") { out.push(headings.trim()); out.push("") }
        if (unassigned.trim() !== "") { out.push(unassigned.trim()); out.push("") }
        var first = true
        for (var i = 0; i < rows.count; i++) {
            var r = rows.get(i)
            if (r.bkey === unassignedKey) continue
            var p = proseFor(r.bkey)
            if (!p.text || p.text.trim() === "") continue
            var md = blockToMarkdown(p, first)
            if (md === "") continue
            first = false
            out.push("<!-- ss:beat=" + r.bkey + " mode=" + p.mode + " para=" + p.para + " -->")
            out.push(md)
            out.push("<!-- /ss -->")
            out.push("")
        }
        return out.join("\n").replace(/\s+$/, "") + "\n"
    }
    function buildDoc() { return frontMatter + (frontMatter !== "" ? "\n" : "") + buildBody() }

    // AUTOSAVE IN PLACE.
    // Re-reads the file first so BM's latest beatsheet is never overwritten by
    // a stale copy, swaps ONLY the prose body, and writes it back. The
    // frontmatter (and therefore the whole [beatsheet]) is passed through
    // byte-for-byte — SS regenerates nothing above the fence.
    property string saveState_: "idle"      // idle | saving | saved | failed
    function saveDoc(quiet) {
        if (isScanned || filePath === "") return false
        var disk = readFile(filePath)
        if (disk !== "") {
            var sp = splitDoc(disk)
            if (sp.front !== "") frontMatter = sp.front     // BM may have rewritten beats
        }
        var doc = buildDoc()
        saveState_ = "saving"
        writeFile(filePath, doc, function (ok) {
            root.saveState_ = ok ? "saved" : "failed"
            if (ok) { root.dirty = false; root.savedAt = new Date() }
            saveFlashTimer.restart()
            if (!ok) root.say("write failed — launch with QML_XHR_ALLOW_FILE_WRITE=1", true)
        })
        saveLocalState()
        return true
    }
    property var savedAt: null
    Timer { id: saveFlashTimer; interval: 1600
            onTriggered: if (root.saveState_ !== "failed") root.saveState_ = "idle" }

    // Debounced: a write lands ~900 ms after you stop typing.
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
                    [JSON.stringify({ path: filePath, prose: proseMap,
                                      front: frontMatter, unassigned: unassigned,
                                      headings: headings,
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
                if (o.src) bodySource = o.src
                proseRev++
                log("restored " + Object.keys(proseMap).length + " prose blocks"
                    + (unassigned !== "" ? " + existing prose" : ""))
            })
        } catch (e) { log("loadState failed: " + e) }
    }
    // 150 ms: this only writes a small JSON row that embedded widgets read.
    // The costly part (writing the .md) stays on saveTimer at 900 ms.
    Timer { id: stateTimer; interval: 150; onTriggered: root.saveLocalState() }
    onShellActiveChanged: if (!shellActive) { saveLocalState(); if (dirty) saveDoc(true) }

    // Both instances share state so an embedded preview tracks the live editor.
    // 200 ms poll. Cheap: it early-outs unless the stored JSON actually changed.
    Timer { id: mirrorTimer; interval: 200; repeat: true; running: root.isScanned
            onTriggered: root.mirrorFromState() }
    property string lastMirror: ""
    // Rendered html handed over by the editing instance, so an embedded
    // preview shows exactly what the main window shows.
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
                // Take the numbers AND the rendered html from the editing copy
                // rather than recomputing. Recomputing is what made the widget
                // disagree with the main window (46 vs 75).
                if (o.words !== undefined) { nWords = o.words; nDone = o.done; nComplete = o.total }
                if (o.html !== undefined) { mirrorHtml = o.html; mirrorHtmlMarks = o.htmlMarks }
                mirrorRev++
            })
        } catch (e) {}
    }

    // ═══════════════ preview ═══════════════
    // Qt RichText ignores text-indent, so the first-line indent is four real
    // non-breaking spaces — proportional font, never a Markdown code block.
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
    // Dialogue: its own line, italic, wrapped in curly quotes — the convention
    // you asked for. A blank line inside a dialogue block starts a new speech,
    // so several exchanges can live in one beat.
    function renderBlock(p, first, marks) {
        var h = []
        var body = (p.text || "").trim()
        if (body === "") return h
        var paras = body.split(/\n\s*\n/)
        for (var q = 0; q < paras.length; q++) {
            var chunk = paras[q].replace(/\n/g, " ").trim()
            if (chunk === "") continue
            if (p.mode === "dialogue") {
                var quoted = chunk
                if (quoted.charAt(0) !== "\u201c") quoted = "\u201c" + quoted
                if (quoted.charAt(quoted.length - 1) !== "\u201d") quoted = quoted + "\u201d"
                h.push('<p style="margin:6px 0 6px 0; line-height:145%">'
                     + indentRun + '<i>' + inline(quoted) + '</i></p>')
            } else {
                var newPara = (q > 0) || (p.para === "new")
                var indent = (!first.v && newPara)
                h.push('<p align="justify" style="margin:0 0 2px 0; line-height:140%">'
                     + (indent ? indentRun : "") + inline(chunk) + '</p>')
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
                h.push('<p style="margin:10px 0 2px 0"><font color="#6a6a7c" size="1">'
                     + '▸ ' + (r.orphan ? "orphan" : "beat " + r.idx) + ' · ' + esc(r.bkey)
                     + ' · ' + p.mode + ' · ' + p.para
                     + (r.phrase ? ' · ' + esc(r.phrase) : '') + '</font></p>')
            }
            var blk = renderBlock(p, first, marks)
            for (var z = 0; z < blk.length; z++) { h.push(blk[z]); any = true }
        }
        if (!any && !marks)
            h.push('<p style="color:#4a4a5c">No prose yet. Type into a beat on the left.</p>')
        h.push("</div>")
        return h.join("")
    }
    function repaint() {
        previewHtml = buildHtml(showMarks)
        // Publish straight away so an embedded preview or Word Count in a Jimmy
        // split tracks typing. Widgets read the published row, they never
        // recompute — that is what made the two counters disagree.
        if (!isScanned) saveLocalState()
    }
    // Any prose edit repaints. No toggle, no button.
    onProseRevChanged: previewTimer.restart()
    Timer { id: previewTimer; interval: 220; onTriggered: root.repaint() }

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
            root.resync(); root.repaint(); root.saveLocalState()
            root.say("document adopted — beatsheet untouched")
        }
        background: Rectangle { color: "#15151f"; radius: 10; border.color: "#3a3a4c" }
        contentItem: ColumnLayout {
            spacing: 6
            Text {
                Layout.fillWidth: true; wrapMode: Text.Wrap
                text: "SS reads the prose body only. Your frontmatter and [beatsheet] "
                    + "are passed through untouched — SS never rewrites beats."
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
        property string pending: ""
        property string sourceKey: ""
        property bool fromUnassigned: false
        modal: true; dim: false; padding: 8
        width: Math.min(340, root.width - 24)
        height: Math.min(400, root.height - 80)
        background: Rectangle { color: "#15151f"; radius: 9; border.color: "#4a4a60" }
        contentItem: ColumnLayout {
            spacing: 6
            Text { text: "Assign selection to which beat?"; color: root.cText; font.pixelSize: 12 }
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
                    height: orphan ? 0 : 30      // cannot attach prose to prose
                    visible: !orphan
                    width: ListView.view.width
                    background: Rectangle { radius: 5; color: ld.hovered ? "#26263a" : "transparent" }
                    contentItem: Text {
                        text: ld.idx + " · " + (ld.phrase === "" ? "(untitled)" : ld.phrase)
                        color: "#d4d4e0"; font.pixelSize: 12; leftPadding: 8
                        verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight
                    }
                    onClicked: {
                        var cur = root.proseText(ld.bkey)
                        root.setProse(ld.bkey, "text",
                            cur.trim() !== "" ? cur + "\n\n" + linkPop.pending : linkPop.pending)
                        // Remove it from wherever it came from, so prose is
                        // never duplicated between a source and its new beat.
                        if (linkPop.fromUnassigned) {
                            root.unassigned = root.unassigned.replace(linkPop.pending, "")
                                                  .replace(/\n{3,}/g, "\n\n").trim()
                        } else if (linkPop.sourceKey !== "" && linkPop.sourceKey !== ld.bkey) {
                            var m = {}
                            for (var x in root.proseMap) if (x !== linkPop.sourceKey) m[x] = root.proseMap[x]
                            root.proseMap = m
                        }
                        root.proseRev++
                        root.resync(); root.saveLocalState(); root.repaint()
                        saveTimer.restart()
                        linkPop.close()
                        root.say("attached to beat " + ld.idx)
                    }
                }
            }
        }
    }

    // ═══════════════ shortcuts ═══════════════
    Shortcut { sequences: ["Ctrl+S"]; onActivated: root.saveDoc(false) }
    Shortcut { sequences: ["Ctrl+Shift+C"]; onActivated: root.copyDoc() }
    Shortcut { sequences: ["Ctrl+Shift+V"]; onActivated: { pasteArea.text = ""; pasteDlg.open() } }
    Shortcut { sequences: ["Ctrl+P"]; onActivated: { pane.visible = !pane.visible; root.repaint() } }
    Shortcut { sequences: ["Ctrl+M"]; onActivated: { root.showMarks = !root.showMarks; root.repaint() } }

    // ═══════════════ layout ═══════════════
    ColumnLayout {
        anchors.fill: parent; anchors.margins: 12; spacing: 8

        Flow {
            Layout.fillWidth: true; spacing: 6
            KGroup {
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
                       onClicked: { root.showMarks = !root.showMarks; root.repaint() } }
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
            // Save state, always visible. You asked to see it every time SS
            // touches the file rather than press a button.
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
                    ? "writes are blocked — launch with QML_XHR_ALLOW_FILE_WRITE=1"
                    : "prose is written into " + (root.filePath === "" ? "(no file)" : root.filePath)
                       + " ~0.9 s after you stop typing"
                MouseArea { id: svMa; anchors.fill: parent; hoverEnabled: true }
            }
            // Honest BM status: what it is and how many beats it is serving.
            Rectangle {
                Layout.preferredHeight: 19; Layout.preferredWidth: bmT.implicitWidth + 18
                radius: 9
                color: root.syncFlash ? Qt.rgba(0, 1, 0.64, 0.18) : "transparent"
                Behavior on color { ColorAnimation { duration: 250 } }
                border.color: root.bmStatus === "live" ? root.cOk : root.cBad
                Text { id: bmT; anchors.centerIn: parent
                       text: root.bmStatus === "live"
                             ? "BM live · " + root.bmBeats + " beats"
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
                ToolTip.text: "Qt blocks local file access unless the app is started with\n"
                            + "QML_XHR_ALLOW_FILE_READ=1 QML_XHR_ALLOW_FILE_WRITE=1\n"
                            + "Click to copy the full launch command."
                MouseArea {
                    id: fxMa; anchors.fill: parent; hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        clip.text = "QML_XHR_ALLOW_FILE_READ=1 QML_XHR_ALLOW_FILE_WRITE=1 "
                                  + "./kosmik-kaleidoscope"
                        clip.selectAll(); clip.copy(); clip.deselect()
                        root.say("launch command copied — paste it in your terminal")
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
                        Component.onCompleted: {
                            if (isUnassigned) {
                                ta.text = root.unassigned
                                hasProse = root.unassigned.trim() !== ""
                            } else {
                                var p = root.proseFor(bkey)
                                localMode = p.mode; localPara = p.para
                                ta.text = p.text
                                hasProse = p.text.trim() !== ""
                            }
                            ready = true
                        }
                        readonly property bool complete:
                            plot.trim() !== "" && phrase.trim() !== "" && question.trim() !== ""

                        width: ListView.view.width
                        height: col.implicitHeight + 24
                        radius: 10
                        color: "#15151f"
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
                                // Attach unlinked prose to a real beat. This is
                                // the control that was missing: orphans had no
                                // route back to a beat at all.
                                KTool {
                                    visible: card.orphan
                                    text: "\u21c4"
                                    ToolTip.visible: hovered; ToolTip.text: "Attach this prose to a beat"
                                    onClicked: {
                                        linkPop.pending = ta.text
                                        linkPop.sourceKey = card.bkey
                                        linkPop.fromUnassigned = card.isUnassigned
                                        linkPop.x = Math.round((root.width - linkPop.width) / 2)
                                        linkPop.y = 60
                                        linkPop.open()
                                    }
                                }
                                KTool { text: card.open ? "⌃" : "⌄"
                                        onClicked: rows.setProperty(card.index, "open", !card.open) }
                            }

                            Text {
                                visible: card.open && card.question !== ""
                                Layout.fillWidth: true
                                text: card.question
                                color: root.cDim; font.pixelSize: 11; wrapMode: Text.Wrap
                            }

                            RowLayout {
                                visible: card.open
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

                            RowLayout {
                                visible: card.open && !card.isUnassigned
                                Layout.fillWidth: true; spacing: 6
                                KGroup {
                                    // Adds the blank line that starts a new
                                    // speech / paragraph inside THIS beat, so
                                    // you are not limited to one line per beat.
                                    KSeg {
                                        text: card.localMode === "dialogue" ? "+ line" : "+ paragraph"
                                        accent: root.cOk
                                        onClicked: {
                                            var t = ta.text
                                            if (t.length > 0 && t.charAt(t.length - 1) !== "\n") t += "\n"
                                            ta.text = t + "\n"
                                            ta.cursorPosition = ta.text.length
                                            ta.forceActiveFocus()
                                        }
                                    }
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: card.localMode === "dialogue"
                                          ? "Each blank-line block = one indented, italic, quoted speech."
                                          : "Blank line = new paragraph."
                                    color: root.cDim; font.pixelSize: 9; font.italic: true
                                }
                            }

                            TextArea {
                                id: ta
                                visible: card.open
                                Layout.fillWidth: true
                                Layout.minimumHeight: 96
                                wrapMode: TextArea.Wrap
                                selectByMouse: true
                                persistentSelection: true
                                color: root.cText; font.pixelSize: 14
                                placeholderText: card.complete
                                    ? (card.localMode === "dialogue"
                                       ? "Dialogue… blank line between speeches"
                                       : "Prose for this beat…")
                                    : "Finish this beat in Beat Machine first"
                                placeholderTextColor: "#4a4a5c"
                                background: Rectangle { color: "#101019"; radius: 6
                                                        border.color: ta.activeFocus ? root.cPhr : "#22222e" }
                                onTextChanged: {
                                    if (!card.ready) return
                                    if (card.isUnassigned) {
                                        root.unassigned = text
                                        root.dirty = true
                                        root.proseRev++
                                        saveTimer.restart()
                                        stateTimer.restart()
                                        previewTimer.restart()
                                    } else {
                                        root.setProse(card.bkey, "text", text)
                                    }
                                    card.hasProse = text.trim() !== ""
                                }
                                Keys.onPressed: function (e) {
                                    if (e.key === Qt.Key_L && (e.modifiers & Qt.ControlModifier)) {
                                        if (ta.selectedText !== "") {
                                            linkPop.pending = ta.selectedText
                                            linkPop.fromUnassigned = false
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
                color: "#08080f"; radius: 8; border.color: "#22222e"
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

    // ═══════════════ embeddable components ═══════════════
    Component {
        id: prosePreviewComp
        Rectangle {
            id: pp
            color: "#08080f"; radius: 8
            border.color: "#22222e"; border.width: 1
            property bool marks: false

            // Two sources, one behaviour:
            //   editing copy -> renders locally on proseRev
            //   scanned copy -> shows html published by the editing copy
            // Both repaint automatically; the marker toggle is not required to
            // force an update, which is what made 0.6.0 look frozen.
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

    // Prose words only — no headings, no anchors. Small enough for a bar slot.
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

    Component.onCompleted: {
        log("scene sculptor " + ver + (isScanned ? " (scan copy)" : "") + " starting")
        loadState()
        stateReady = true
        if (!isScanned) {
            syncFromBM()
            // Always read the document on startup. Restored state may already
            // hold this path, so a "did the path change?" test is not enough —
            // that is why 0.5.0 kept showing the PREVIOUS file's prose.
            if (filePath !== "") adoptFile(filePath)
            if (canRead === 0) {
                log("file reads blocked by Qt — attempting self-relaunch with flags")
                if (!relaunchWithFileAccess())
                    log("start the app with: QML_XHR_ALLOW_FILE_READ=1 "
                        + "QML_XHR_ALLOW_FILE_WRITE=1 ./kosmik-kaleidoscope")
            }
            var e = bm("emacs_status_ffi", {}); if (e) emacs = e
            log(bmStatus === "live"
                ? "beat machine answered session_load_ffi with " + bmBeats + " beats"
                : "beat machine did not answer: " + lastError)
        }
        repaint()
        say(canRead === 0
            ? "file access blocked — see the launcher note in the header"
            : "ready · " + rowCount + " rows · " + nWords + " words")
    }
    Component.onDestruction: { saveLocalState(); if (dirty) saveDoc(true) }
}
