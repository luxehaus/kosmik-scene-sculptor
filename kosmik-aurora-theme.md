# Kosmik Kaleidoscope — Theme Authoring Guide

### Learning the whole theme API by reading one real theme: **Aurora**

This document explains the Kaleidoscope theming system using the Aurora theme
as a worked example. Every snippet below is real code from
`kosmik-theme-aurora.qml` — nothing here is pseudocode.

---

## Contents

1. [What a theme actually is](#1-what-a-theme-actually-is)
2. [The contract — two things, that's all](#2-the-contract)
3. [Aurora, section by section](#3-aurora-section-by-section)
4. [State: themes own their own settings](#4-state)
5. [The backdrop: replacing the entire background](#5-backdrop)
6. [Settings integration](#6-settings-integration)
7. [The theme page](#7-the-theme-page)
8. [Widgets: themes publish components too](#8-widgets)
9. [Complete theme API reference](#9-complete-api-reference)
10. [The global bridges — how composability works](#10-global-bridges)

---

## 1 · What a theme actually is

A theme is an ordinary QML plugin. It lives in `~/.studio/plugins/` next to
every other plugin. It is not special-cased anywhere in the shell.

Two things make the shell treat it as a theme rather than an app:

- Its `id` or `name` contains `theme` — the shell keeps it **off the nav rail**
  so it never consumes a slot, and lists it under **Home → THEMES** and in
  **Settings**.
- It calls `shell.applyTheme(obj)` — which is what actually restyles the app.

Everything else is a normal plugin: it can publish widgets, host a page, and
persist its own state.

---

## 2 · The contract

A theme needs exactly two things.

```qml
import QtQuick

Item {
    id: theme

    // 1 · the shell injects itself here on load
    property var shell: null
    property var kosmikTheme: null
    property bool shellActive: false

    // 2 · one call, whenever you want the look applied
    function apply() { if (shell) shell.applyTheme(def) }
    Component.onCompleted: apply()
    onShellChanged: apply()          // shell may arrive after construction
}
```

Every field in the theme object is **optional**. Anything you omit keeps the
shipped default, so a five-line theme is perfectly valid.
`shell.clearTheme()` reverts everything.

> **Why `onShellChanged` matters.** The shell assigns `shell` after your
> component is constructed. If you only apply in `Component.onCompleted`, you
> race the injection and sometimes apply nothing.

---

## 3 · Aurora, section by section

Aurora builds one object, `def`, and hands it to `shell.applyTheme()`.

### 3.1 A computed palette

Aurora doesn't hardcode colours. It derives them from a hue wheel so a single
`hueShift` property recolours the entire application:

```qml
property int hueShift: 0

function hs(c) { return Qt.hsla((c + hueShift / 360.0 + 1.0) % 1.0, 0.72, 0.62, 1.0) }

readonly property color cGreen:  hs(0.42)   // classic aurora green
readonly property color cTeal:   hs(0.50)
readonly property color cViolet: hs(0.78)
readonly property color cRose:   hs(0.92)
readonly property color cGold:   hs(0.12)
readonly property color cIce:    hs(0.58)
```

Change `hueShift` to 220 and every panel border, every accent, the kanji, the
title, the aurora curtains and the meteors all shift together.

### 3.2 `palette` — the six semantic accents

Plugins address colours **by name**, never by literal. That is what makes a
theme reach into plugins it has never heard of.

```qml
palette: {
    pink:   theme.cRose,     // rail accent, primary highlight, toast border
    violet: theme.cViolet,   // aside B, float dock, widget slots
    cyan:   theme.cIce,      // aside A, tool hover, info chips
    mint:   theme.cGreen,    // success, widget rail, "installed" badges
    amber:  theme.cGold,     // warnings, corner controls
    orange: theme.cTeal,     // BITCLOCK
    dot:    theme.cGreen     // rail status pips
}
```

### 3.3 `surface` — per-panel backgrounds

Each surface has its own key and falls back to `panel`/`rail` when omitted.
Aurora gives every panel a different character:

```qml
surface: {
    panel:     "#b3070b14",
    rail:      "#cc05080f",
    railBg:    "#cc05080f",
    wrailBg:   "#b3061020",
    barBg:     "#cc04070d",
    stage:     "#8c060a12",   // most transparent: the sky shows through
    asideA:    "#a6061423",   // cool green cast
    asideB:    "#a60d0a24",   // violet cast
    dockBg:    "#e6081026",
    popupBg:   "#f2060912",
    toastBg:   "#f2081426",
    toastText: "#e8fbff",     // see note below
    slotBg:    "#14ffffff",
    tileBg:    "#0dffffff",
    fieldBg:   "#40000814",
    kanji:     theme.cGreen,  // the vertical 万華鏡 wordmark
    title:     theme.cIce,    // the "Kaleidoscope" rail title
    tint:      theme.cGreen,  // hue of the tint layer
    edge:      "#1d2e3a",
    text:      "#e6f4f8",
    soft:      "#8fb3c4",
    dim:       "#5b7f92"
}
```

> **`toastText` exists for a reason.** A theme that sets a near-white `text`
> would otherwise render white-on-white toasts in light mode. Toast text is
> its own token so that can't happen.

**Alpha matters.** Use `#cc…`/`#b3…` prefixes rather than solid colours — the
window is translucent and solid panels destroy the effect.

### 3.4 `fills` — hover states app-wide

Buttons, chips, list rows and tool buttons all read these:

```qml
fills: {
    rest:     "#0affffff",
    hover:    Qt.rgba(theme.cGreen.r, theme.cGreen.g, theme.cGreen.b, 0.16),
    press:    Qt.rgba(theme.cGreen.r, theme.cGreen.g, theme.cGreen.b, 0.26),
    selected: Qt.rgba(theme.cIce.r,   theme.cIce.g,   theme.cIce.b,   0.18)
}
```

### 3.5 `rules` — how loud the styling reads

```qml
rules: {
    glow:        0.85 * theme.intensity,  // glow-ring strength 0..1
    borderAlpha: 0.16,                    // resting border opacity
    hoverAlpha:  0.95,                    // border opacity on hover
    radius:      14,
    borderWidth: 1,
    panelMode:   theme.ghostPanels ? "ghost" : "solid"
}
```

`panelMode` is the most dramatic switch in the API:

| Value | Behaviour |
|---|---|
| `"solid"` | default — panels always painted |
| `"ghost"` | **transparent until hover** — the backdrop shows through |
| `"none"` | never painted |

Borders are always computed from the accent of the thing they surround:
`Qt.rgba(accent.r, accent.g, accent.b, borderAlpha)` at rest, `hoverAlpha` on
hover. You never set a border colour directly.

### 3.6 `borders` — remove them selectively

```qml
borders: { all: true, stage: false, toast: false }
```

Aurora frames everything except the stage, letting the centre content float on
the sky. Keys: `panel, stage, asideA, asideB, rail, wrail, bar, dock, popup,
toast`. `all: false` removes every border; individual keys override it.

### 3.7 `fonts`

```qml
fonts: { ui: "", display: "", mono: "Monospace", scale: 1.0 }
```

`scale` multiplies every font size in the shell. Plugins that adopted the API
(like Jimmy Bento) honour it too.

### 3.8 `title` — animate the wordmark

```qml
title: { glow: true, glowAmount: theme.intensity, pulseMs: 3200, kanjiPulse: true }
```

`glow` blooms the rail title, `pulseMs` breathes it, `kanjiPulse` breathes 万華鏡.

### 3.9 `gradient` — retune the builtin background

Used only when no `backdrop` is supplied:

```qml
gradient: {
    colors: [theme.cGreen, theme.cTeal, theme.cViolet, theme.cIce, theme.cRose],
    speed: 0.8, blobs: 5, opacity: 0.5, animate: true, spread: 0.45
}
```

Omit `colors` entirely and the shell uses a clock-driven hue that drifts through
the day.

---

## 4 · State

**This is the rule that governs the whole system:**

> The shell restores **which** theme is active.
> A theme restores **its own settings**.
> A plugin restores **its own state**.

Nobody needs a shutdown API. Every component owns its lifecycle, which means it
survives a crash, a `kill -9`, or an OOM kill — none of which fire an exit hook.

The shell persists `activeThemeId` and re-runs your plugin on launch. It
**cannot** persist your settings, because a theme object contains live
`Component` references (`backdrop`, `settings`) that cannot be serialised to
JSON. So you persist them.

### Aurora's state manager

```qml
import QtQuick.LocalStorage

property bool stateReady: false     // true once a load has been attempted

function stateDb() {
    try { return LocalStorage.openDatabaseSync("KosmikThemeAurora", "1.0",
                                               "Aurora Theme State", 100000) }
    catch (e) { return null }
}

function saveState() {
    if (!stateReady) return          // never write before the first read
    var db = stateDb(); if (!db) return
    var data = {
        intensity: intensity, curtains: curtains, meteors: meteors,
        snow: snow, ghostPanels: ghostPanels, hueShift: hueShift
    }
    try {
        db.transaction(function (tx) {
            tx.executeSql("CREATE TABLE IF NOT EXISTS state(k TEXT UNIQUE, v TEXT)")
            tx.executeSql("INSERT OR REPLACE INTO state(k,v) VALUES('aurora', ?)",
                          [JSON.stringify(data)])
        })
    } catch (e) {}
}

function loadState() {
    var db = stateDb()
    if (!db) { stateReady = true; return }
    try {
        db.transaction(function (tx) {
            tx.executeSql("CREATE TABLE IF NOT EXISTS state(k TEXT UNIQUE, v TEXT)")
            var rs = tx.executeSql("SELECT v FROM state WHERE k='aurora'")
            if (rs.rows.length > 0) {
                var o = JSON.parse(rs.rows.item(0).v)
                if (o.hueShift !== undefined) hueShift = o.hueShift
                // … one line per property …
                console.log("AURORA: state restored (hue " + hueShift + ")")
            }
        })
    } catch (e) { console.log("AURORA: state load failed -", e) }
    stateReady = true
}
```

### Wiring it up — three rules that matter

```qml
// 1 · LOAD BEFORE THE FIRST APPLY, or the shell briefly sees defaults
Component.onCompleted: { loadState(); apply() }

// 2 · debounce writes — a slider drag must not hammer the database
Timer { id: stateTimer; interval: 400; onTriggered: theme.saveState() }
function queueState() { if (stateReady) stateTimer.restart() }

// 3 · every tunable re-applies AND persists
onHueShiftChanged:    { apply(); queueState() }
onIntensityChanged:   { apply(); queueState() }
onCurtainsChanged:    { apply(); queueState() }
onGhostPanelsChanged: { apply(); queueState() }
onMeteorsChanged:     queueState()
onSnowChanged:        queueState()

// flush immediately on hide/destroy so an unload never loses work
onShellActiveChanged: if (!shellActive && stateReady) saveState()
Component.onDestruction: if (stateReady) saveState()
```

The `stateReady` guard is essential. Without it, the property-changed handlers
fire during construction and overwrite your saved state with defaults before
`loadState()` ever runs.

Verified round-trip:

```
run 1:  AURORA: no saved state, using defaults
        set hue=220 intensity=1.6 curtains=9
run 2:  AURORA: state restored (hue 220, intensity 1.6, curtains 9)
```

---

## 5 · Backdrop

The layer is called **`backdrop`**. Supply a `Component` and it takes over the
whole background — the builtin blob field steps aside completely. Particles,
shaders, `Canvas`, animated `Image`, video: anything QML can draw.

Your backdrop receives `kosmikTheme` if it declares the property, so it can read
the live palette.

Aurora's sky layers four independent systems:

```qml
property Component auroraSky: Component {
    Item {
        id: sky
        property var kosmikTheme: null

        // 1 · deep polar gradient
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                GradientStop { position: 0.0;  color: "#01030a" }
                GradientStop { position: 0.45; color: "#041020" }
                GradientStop { position: 1.0;  color: "#020610" }
            }
        }

        // 2 · starfield — 90 stars, deterministic pseudo-random placement
        Repeater {
            model: 90
            delegate: Rectangle {
                required property int index
                readonly property real sd: (index * 9301 + 49297) % 233280 / 233280
                // … twinkle animation …
            }
        }

        // 3 · aurora curtains — soft bands, heavily blurred
        Item {
            anchors.fill: parent
            layer.enabled: true
            // Blur at quarter resolution: on a 2K screen this is 16x less work
            // per frame (3.69 MP -> 0.23 MP) and visually identical for soft light.
            layer.textureSize: Qt.size(Math.max(160, width / 4),
                                       Math.max(160, height / 4))
            layer.smooth: true
            layer.effect: MultiEffect {
                blurEnabled: true; blur: 1.0; blurMax: 40; blurMultiplier: 1.6
            }
            Repeater { model: theme.curtains; /* … shearing bands … */ }
        }

        // 4 · meteors on randomised unique paths
    }
}
// then:  backdrop: auroraSky
```

### Performance: the one thing that actually matters

`layer.textureSize` is the difference between comfortable and pegging a
low-power GPU. A full-resolution blur on a 2560×1440 display is **3.69
megapixels every frame** — roughly 221 MP/s at 60fps. At quarter resolution
that's 0.23 MP, **16× less work**, and for soft light you cannot see the
difference.

If your backdrop blurs anything full-screen, downscale it.

### Meteors: randomness that doesn't repeat

```qml
function fire() {
    ang  = -20 - Math.random() * 45            // unique angle
    len  = 130 + Math.random() * 220           // unique length
    tint = [cIce, cGreen, cRose, cGold][Math.floor(Math.random() * 4)]
    var fromLeft = Math.random() > 0.35        // unique entry side
    px = fromLeft ? -len : sky.width * (0.25 + Math.random() * 0.7)
    py = sky.height * (Math.random() * 0.45)
    shoot.restart()
}

Timer {
    running: theme.meteors
    repeat: true
    interval: 4200 + Math.round(Math.random() * 9000)   // random gap
    onTriggered: {
        var burst = 1 + Math.floor(Math.random() * 3)   // random burst size
        for (var i = 0; i < burst; i++)
            stagger.fireAt(i, i * (140 + Math.random() * 220))
        interval = 4200 + Math.round(Math.random() * 9000)   // re-randomise
    }
}
```

Re-randomising `interval` inside `onTriggered` is what stops showers falling
into a visible rhythm.

---

## 6 · Settings integration

Supply `settings: myComponent` and `icon:` and the shell embeds your panel
inside its Settings page, under your theme's own name. You receive `shell`
(full API) and `kosmikTheme`.

```qml
property Component auroraSettings: Component {
    Column {
        property var shell: null
        property var kosmikTheme: null
        height: childrenRect.height      // NOTE: Column.implicitHeight is read-only
        spacing: 8

        Row {
            spacing: 5
            Text { text: "Intensity"; color: theme.def.surface.soft; width: 74 }
            Repeater {
                model: [["Soft", 0.55], ["Normal", 1.0], ["Blazing", 1.6]]
                delegate: Rectangle {
                    required property var modelData
                    readonly property bool sel: Math.abs(theme.intensity - modelData[1]) < 0.01
                    // … chip styling …
                    MouseArea {
                        anchors.fill: parent
                        onClicked: theme.intensity = modelData[1]   // triggers apply + save
                    }
                }
            }
        }
    }
}
// then:  settings: auroraSettings,  icon: "\u2726"
```

Note the panel only ever **sets a property**. Applying and persisting happen
automatically through the change handlers in §4. That is the whole pattern.

Any plugin (not only themes) can also contribute a section:

```qml
shell.addSettings("my-id", "MY SECTION", myComponent)
shell.removeSettings("my-id")
```

---

## 7 · The theme page

A theme is still a plugin, so its root item is a normal page. The shell shows it
when you click the theme on Home — **without giving it a rail slot**.

```qml
Item {
    anchors.fill: parent
    ColumnLayout {
        anchors.centerIn: parent
        Text {
            text: "AURORA"
            color: theme.cIce
            font.pixelSize: 30; font.bold: true; font.letterSpacing: 10
            layer.enabled: true
            layer.effect: MultiEffect { blurEnabled: true; blur: 0.6; brightness: 0.35 }
        }
        // swatches, Apply / Ghost panels / Meteor now / Reset buttons …
    }
}
```

---

## 8 · Widgets

Themes publish reusable components exactly like any other plugin. Declaring
`widgets` gives them proper names and icons instead of auto-generated ones:

```qml
property var widgets: [
    { id: "aurora",    title: "Aurora Control", icon: "\u25c8", component: auroraCtl },
    { id: "intensity", title: "Aurora Dial",    icon: "\u25c9", component: dialCtl },
    { id: "meteor",    title: "Meteor Toggle",  icon: "\u2604", component: meteorCtl },
    { id: "palette",   title: "Aurora Palette", icon: "\u25a4", component: paletteCtl }
]
```

They then appear in **every** widget slot in the app — `nav-widget-sq`,
`nav-widget-golden`, the widget rail, the top/bottom bars, the asides, and
inside Jimmy Bento's tiles — grouped under **AURORA THEME COMPONENTS**.

A widget is just an `Item`. Keep it small and let it size to its slot:

```qml
property Component meteorCtl: Component {
    Item {
        Text {
            anchors.centerIn: parent
            text: "\u2604"
            color: theme.meteors ? theme.cGold : "#33ffffff"
            font.pixelSize: Math.max(12, Math.min(24, parent.height - 10))
        }
        MouseArea {
            anchors.fill: parent
            onClicked: theme.meteors = !theme.meteors    // persists automatically
        }
    }
}
```

Because these widgets mutate the same properties the settings panel does, a
Meteor Toggle dropped in the bottom bar and the Settings switch stay in sync
for free — and both persist.

---

## 9 · Complete API reference

### The theme object

| Key | Type | Purpose |
|---|---|---|
| `name` | string | shown in Settings and in `tm.themeName` |
| `icon` | string | glyph for the Settings heading |
| `palette` | object | `pink violet cyan mint amber orange dot` |
| `surface` | object | see table below |
| `fills` | object | `rest hover press selected` |
| `rules` | object | `glow borderAlpha hoverAlpha radius borderWidth panelMode` |
| `borders` | object | `all` plus per-surface booleans |
| `fonts` | object | `ui display mono scale` |
| `title` | object | `glow glowAmount pulseMs kanjiPulse` |
| `gradient` | object | `colors speed blobs opacity animate spread` |
| `backdrop` | Component | replaces the background entirely |
| `settings` | Component | embedded in the Settings page |

### `surface` keys

`panel` · `rail` · `railBg` · `wrailBg` · `barBg` · `stage` · `asideA` ·
`asideB` · `dockBg` · `popupBg` · `toastBg` · `toastText` · `slotBg` ·
`tileBg` · `fieldBg` · `kanji` · `title` · `tint` · `edge` · `text` ·
`soft` · `dim`

### Shell API available to themes

```qml
shell.applyTheme(obj)          // apply
shell.clearTheme()             // revert to defaults
shell.setMode(0|1|2)           // auto / dark / light
shell.setPalette(0|1|2|3)      // 2117 / vivid / mono / mono-inverted
shell.setShade(v, style)       // v 0–1; style 0 translucent · 1 tinted
                               //              2 image · 3 solid
shell.toast(msg)
shell.addSettings(id, title, component)
shell.removeSettings(id)
shell.saveConfig(name) / loadConfig(name) / configs()
```

`mode`, `palette` and `shade` are independent of any theme and combine freely
with it.

### Layer order

Bottom to top, each independent:

1. **window base** — transparent, coloured, or solid (`shadeStyle 0/1/3`)
2. **image** — `shadeImage`, its own layer so tint still affects it
3. **tint** — accent wash, strength follows `shade`, hue from `surface.tint`
4. **gradient or backdrop** — the animated field
5. **UI**

---

## 10 · Global bridges

Three mechanisms make Kaleidoscope composable. Understanding them is what turns
a collection of plugins into one instrument.

### 10.1 The widget bridge — components go global

On startup the shell mounts every installed plugin once, off-screen and
staggered, purely to harvest what it publishes. Three tiers, tried in order:

1. **`widgets`** — the declared contract. Proper names and icons.
2. **`widgetExports`** — an array of property names to expose.
3. **Automatic** — every `Component` a plugin declares lands in `item.data`,
   so the shell can harvest them even from a plugin that exports nothing and
   whose ids are file-private. Those appear as `plugin · part N`.

Harvested components are kept alive for the session (a `QQmlComponent` dies with
the object that declared it) and are then available **everywhere**:

```qml
shell.widgets()          // every published component id
shell.widget(id)         // { id, title, icon, component, owner }
shell.widgetsOf(owner)   // just one plugin's components
shell.rescanWidgets()    // re-scan on demand
shell.publish(id, title, icon, component)   // publish directly
```

Unloading a plugin removes its widgets from every surface automatically.

### 10.2 The universal loader — one catalog, everywhere

Every "what can I load here?" surface renders the **same** catalog, so a new
plugin appears everywhere at once with no per-surface code:

```qml
shell.catalog(context, localItems)
// -> [ { group, groupLabel, items: [ { kind, key, title, icon, accent, enabled } ] } ]
//
// context : "aside" | "bento" | "pane" | "widget" | ""
// kind    : "empty" | "builtin" | "plugin" | "widget"

shell.apply(item, slot)   // one apply path for every kind
```

Group order is fixed: **empty → local → builtin → installed plugins → widgets
grouped by owning app**. Context matters — a small widget slot passes
`"widget"` and receives components only, never whole apps.

### 10.3 FFI — native plugins in the same catalog

The host loads native `.so` plugins through a single C ABI
(`*const c_char` in, `*mut c_char` out, panics caught at the boundary) and
reports them alongside QML-only plugins. Any plugin can call into any native
plugin:

```qml
shell.execute(pluginId, functionName, jsonPayload)
```

A plugin may be `.so` + `.qml`, or QML-only — both appear in the catalog. This
is why a Rust-backed component can be dropped into a QML plugin's tile and just
work.

### 10.4 Composability in practice — Jimmy Bento

Jimmy Bento is a spatial dashboard: a 3×3 Bagua of stages, each splittable into
panes, with a configurable Bento matrix of 4–11 tiles.

It publishes its own components:

```qml
property var widgets: [
    { id: "dpad",    title: "Bagua D-Pad",      icon: "\u2756", component: baguaDpadGridComp },
    { id: "manager", title: "Bagua Manager",    icon: "\u25f1", component: baguaManagerComp },
    { id: "slots",   title: "Bento Slots",      icon: "\u25a6", component: bentoSlotsManagerComp },
    { id: "matrix",  title: "Bento Matrix",     icon: "\u229e", component: bentoStageSurfaceComp }
]
```

…and consumes everyone else's, so **any** component from **any** plugin can be
loaded into **any** Bento tile:

```qml
shell.widgets()      // what else exists?
shell.widget(id)     // give me that component
```

The result is genuinely bidirectional. Jimmy's D-Pad can sit in the shell's nav
rail. Aurora's Meteor Toggle can sit inside a Bento tile. A Rust-backed beat
machine can sit next to a prose note. Nothing in the shell knows about any
specific plugin — it just brokers the catalog.

That is the whole idea: **the shell owns layout and theming, plugins own their
content and their state, and every component is available to every surface.**

---

*Reference implementation: `kosmik-theme-aurora.qml`.*
*Shell: `main.qml`. Composability example: `kosmik-jimmy-panel-v7.x.qml`.*
