# Kosmik Kaleidoscope — State Ownership & Plugin API

**Version:** main.qml (4115 lines) · Jimmy v7.4 · Aurora theme
**Audience:** anyone writing a Kosmik plugin or theme.

---

## 1 · The ownership rule

There are exactly three owners of persistent state. Nothing else persists anything.

| Owner | Owns | Storage | Restored by |
|---|---|---|---|
| **main.qml** (shell) | Window chrome: rail, asides, widget bars, widget rail, **float dock**, zen, theme selection, `slotMap`, current tab | LocalStorage `KosmikShell` — `prefs` row + named `configs` (incl. `__last__`) | Itself, in `Component.onCompleted` |
| **Theme** (e.g. Aurora) | Its own knobs — hue, intensity, curtains, meteors | Its own DB, e.g. `KosmikThemeAurora` | Itself, on load |
| **Plugin** (e.g. Jimmy) | Its own interior — stages, bento cells, drawers, notes, workspaces | Its own DB, e.g. `KosmikJimmyObentoV3` | Itself, on load |

**The dividing line is not "who displays it" — it is "who declares the property."**

That is the whole answer to *"why did main.qml change if Jimmy owns its own state?"* — see §2.

---

## 2 · Why Aurora needed no shell change but Jimmy did

This is a real structural difference, not an inconsistency.

### Aurora touches nothing the shell owns

```
grep -c "setPanel|setFloat|showPanel"  kosmik-theme-aurora.qml   →  0
```

Aurora only calls `applyTheme()` and writes its own DB. Every property it
persists is one **it declares itself**. So it is self-contained by construction,
and the shell never had to change for it.

Aurora is also **never scanned** — `scanAllPlugins()` skips themes:

```qml
if (... && !isTheme(p)) pending.push(p)
```

So exactly one Aurora instance exists, and single-instance state "just works."

### Jimmy drives shell-owned surfaces

```
grep -c "shell.setPanel|shell.setFloat|shell.showPanel"  jimmy-v7.4.qml   →  11
```

Jimmy's `handshake()` pushes its managers into **asides** and its D-Pad into the
**float dock**. Those are `main.qml` properties (`panelAOn`, `panelBOn`,
`floatOpen`), not Jimmy's. Jimmy *cannot* persist them — it does not own them,
and a second plugin doing the same thing would fight it.

The bugs were therefore genuinely on the shell side:

- `assignPanel()` did `panelAOn = true` **unconditionally**. Supplying *content*
  force-opened the *container*, overwriting the visibility that had just been
  restored — so a closed aside reopened every launch, and that wrong value was
  saved back.
- `setFloat()` did the same to `floatOpen`.
- `floatOpen` / `dockCollapsed` were **never in the persistence lists at all**.

Fix: the shell now separates **content** from **visibility**. Once prefs are
restored (`panelStateRestored`), `setPanel()`/`setFloat()` may change *what* is
in a container but never *whether it is open*.

### And Jimmy is scanned — twice

Unlike a theme, Jimmy is mounted **twice**: once headless by the widget scanner,
once on the stage. Both ran `initStorage()` and an autosave timer against the
same DB, so the hidden copy periodically wrote its pristine startup state over
the user's live workspace. That needed a shell-side signal to fix:

```qml
scanShell.isScanShell === true     // inert copy
shell.isScanShell     === false    // live copy
```

**Rule for plugin authors:** if you own persistent state, check `isScanShell`
and stay read-only when it is `true`. Themes do not need this (never scanned).

---

## 3 · What each layer persists

### 3.1 Shell (`main.qml`)

Saved on **every change** (450 ms debounce → `prefs`) *and* on exit (`__last__`):

```
railSide railScale railOn
wbarOn wbarScale wbarSwapped
topBarOn bottomBarOn barScale
panelAOn panelBOn panelsSwapped panelASpec panelBSpec
floatOpen dockCollapsed dockSide          ← added in this round
zenPad zenMode titleBarPref
unloadedIds slotMap launchFocus currentTab
activeThemeId openThemeId + theme tokens
```

`slotMap` is the widget-placement map: **slot name → widget id**. This is what
makes "I put BTC in the top bar" survive a restart.

**Verified:**
```
RUN1  slotMap {'top-widget-0':'builtin:btc','wrail-widget-1':'kosmik-jimmy-panel-v7:dpad'}
RUN2  slotMap {'top-widget-0':'builtin:btc','wrail-widget-1':'kosmik-jimmy-panel-v7:dpad'}   PASS
      topBarOn True · bottomBarOn True · wbarOn True · barScale 2                            PASS
      dock closed by user → stayed closed                                                    PASS
```

#### Named widget slots

| Slot name | Where |
|---|---|
| `nav-widget-golden`, `nav-widget-sq` | nav rail |
| `wr-golden`, `wr-sq`, `wr-sq-2` | widget rail (Alt+G) |
| `top-widget-bar-1 … -N` | top bar (Alt+T) |
| `bottom-widget-bar-1 … -N` | bottom bar (Alt+B) |
| `aside-a-widget`, `aside-b-widget` | shelf under each aside |

Slot count follows `barScale` (1×/2×/3×).

**Not persisted (by design):** `floatComp`, `panelA.comp` — a live
`QQmlComponent` cannot be serialised. The *container* state is saved; the
plugin re-supplies the content via `handshake()` on next launch.

### 3.2 Theme (Aurora pattern — recommended)

```qml
property bool stateReady: false
Timer { id: stateTimer; interval: 400; onTriggered: theme.saveState() }
function queueState() { if (stateReady) stateTimer.restart() }
onShellActiveChanged: if (!shellActive && stateReady) saveState()
Component.onDestruction: if (stateReady) saveState()
```

### 3.3 Plugin (Jimmy v7.4)

Per named workspace, in `configs`; `meta.last_active` records which to reopen:

```
colX rowY bentoCount bentoFocus chaosPatternIndex hoverExpandDelta
bentoCells[]          kind + key/src + text + font + fontSize + pad + style + calmed
stageMap{}            panes, paneKinds, paneKeys, paneTexts, paneBentoCells
tokonomaOpen nagashiOpen        ← drawers
soloNotes{}                     ← Prose Notes outside a Jimmy cell
```

---

## 4 · Save-timing: debounce, never poll

**This is the single most important lesson from this round.**

❌ **Wrong — periodic poll.** Structurally loses data: change something, quit
before the next tick, the write never happened. Shortening the interval only
narrows the window; it never closes it.

```qml
Timer { interval: 60000; repeat: true; running: true
        onTriggered: if (dirty) save() }
```

✅ **Right — debounce on change.** A write always follows the last edit by a
fixed small delay; bursts collapse into one.

```qml
function markDirty() {
    if (!autoSave || !storageOwner || !storageStarted) return
    autoDirty = true
    autoSaveTimer.restart()          // ← restart, not poll
}
Timer { id: autoSaveTimer; interval: 600; repeat: false
        onTriggered: { autoDirty = false; saveConfig(activeWorkspaceName) } }

onShellActiveChanged: if (!shellActive && autoDirty) flush()
Component.onDestruction: if (autoDirty) flush()      // last chance on quit
```

**Verified** — drawer opened, app quit **2.5 s** later:
```
JTOGGLE tok=true dirty=true owner=true started=true
JSAVE   tok=true count=9          ← wrote before quit
--- restart ---
JLOAD   tok=true count=9 ok=true  ← restored
```

Also: **cancel the timer after a restore** (`autoSaveTimer.stop()`), or loading a
config immediately re-saves what it just read.

---

## 5 · Shell API reference

### Panels / containers
```
setPanel(slot, component, title)      slot: "a" | "b"
setPanelUrl(slot, url, title)
setPanelBuiltin(slot, key, title)     key: doc | info | btc | plugins
setPanelWidget(slot, widgetId, title)
clearPanel(slot)
showPanel(slot, on)        ← the ONLY way to change aside visibility
setFloat(component, title) / clearFloat() / setDockSide("tl|tr|bl|br")
```
`setPanel*`/`setFloat` set **content only** once prefs are restored. Use
`showPanel()` for visibility.

### Layout
```
setRailSide(s) getRailSide() setRailMode(m) getRailMode() showRail(on)
setBarScale(which, n)   which: "rail"|"widgets"|"bars",  n: 1..3
showBar(which, on)
setZen(on, pad) zenAll(pad) zenOff()
resetLayout() setLaunchFocus(id)
```

### Universal loader
```
catalog(ctx, localItems, callerId) → [{ group, groupLabel, items:[…] }]
    ctx : "aside" | "bento" | "pane" | "widget" | ""
    item: { kind, key, title, icon, accent, enabled }
    kind: "empty" | "builtin" | "plugin" | "widget"
apply(item, slot)      catalogVersion()
```
Group order: **empty → caller's own → builtin → installed plugins → other apps**.

> A plugin must **not** pass its own components as `localItems` — the widget
> bridge already publishes them. Doing so lists them twice. Pass `callerId` and
> the shell hoists yours to the top.

### Builtins
```
builtinTitle(key) builtinWidgetId(key) builtinComponent(key) builtinIsCompact(key)
```
Builtins are real registry components under owner `builtin`. **Never
re-implement one** — instantiate `builtinComponent(key)` so every surface shows
the identical live object. Only `btc` is `compact: true` (bar-eligible).

### Widgets
```
publish(id, title, icon, component)   widgets()   widget(id)
widgetsOf(owner)                      rescanWidgets()
```
Or declare: `property var widgets: [{ id, title, icon, component }]`.

### Misc
```
execute(pluginId, fn, payload)   toast(m)   docFor(pluginId)
saveConfig(name) loadConfig(name) configs()
addSettings(id, title, comp) removeSettings(id) openSettings()
applyTheme(obj) clearTheme() setMode(m) setPalette(p) setShade(v, style)
```

### Read-only
```
theme  neon  dark  hostInfo  railDouble  railBottom  isScanShell
```

---

## 6 · Edge cases

| Case | Behaviour |
|---|---|
| **Plugin scanned twice** | Check `shell.isScanShell`; stay read-only if `true`. Themes exempt. |
| **`shell` arrives late** | Assigned *after* `Component.onCompleted`. Decide ownership in `onShellChanged`, not at construction. |
| **Shallow-copy mutation** | `arr.slice()` copies references. Mutating `a[n].x` leaves identity unchanged → **QML `var` bindings never fire**. Always replace the object. |
| **Orphaned widget id** | Slot pointing at an uninstalled plugin shows *"widget unavailable"*. No crash; repopulates on reinstall. |
| **Unloaded plugin** | Widgets filtered from every catalog; slots cleared. |
| **Restore re-saving itself** | Clear the dirty flag **and** `stop()` the debounce timer at the end of load. |
| **Duplicate `onXChanged`** | Two handlers for one signal is a fatal QML error. Merge them. |
| **`Window.flags` not NOTIFYable** | Sample once at startup. |
| **Theme docs** | `docFor(id)` works for themes too, though they have no rail tab. |
| **XHR file-read warning** | One harmless boot warning unless `QML_XHR_ALLOW_FILE_READ=1`. Probed once. |

### Known limitation

**Zen mode container toggles.** The layout holding asides/rails/bars is
`visible: !zenMode`, so toggling `panelAOn` in zen flips a property on
unrendered items. Only Settings and Exit work. A real fix requires zen to render
its own aside instances. **Deferred by agreement.**

---

## 7 · Checklist for a stateful plugin

1. Own only properties you declare. Container visibility belongs to the shell.
2. Guard with `isScanShell` → set `storageOwner` in `onShellChanged`.
3. `initStorage()` exactly once, only when `storageOwner`.
4. **Debounce** saves (~400–600 ms); never poll.
5. Flush on `onShellActiveChanged` **and** `Component.onDestruction`.
6. Clear dirty flag *and* stop the timer after a restore.
7. Replace objects, never mutate in place.
8. Don't pass your own components as `localItems`.
9. Never re-implement a builtin.
10. Degrade gracefully on an older shell — wrap optional APIs in `try/catch`.
