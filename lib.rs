use serde::{Deserialize, Serialize};
use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};

// ═══════════════════════════ vocab ═══════════════════════════

const PLOTS: &[&str] = &[
    "INCITING INCIDENT", "PROGRESSIVE COMPLICATION", "TURNING POINT", "CRISIS",
    "CLIMAX", "RESOLUTION", "DESCRIPTIVE / DIALOGUE", "SETUP", "REVERSAL",
    "REVELATION", "DECISION", "ESCALATION", "MIDPOINT", "DARK NIGHT",
];

const OPS: &[&str] = &[
    "THIS HAPPENS", "BUT", "THEREFORE", "BECAUSE",
    "UNTIL", "MEANWHILE", "INSTEAD", "AND", "SO", "FINALLY",
];

// ═══════════════════════════ model ═══════════════════════════

#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
pub struct Line {
    #[serde(default)] pub op: String,
    #[serde(default)] pub text: String,
}

#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
pub struct Beat {
    #[serde(default)] pub plot: String,
    #[serde(default)] pub phrase: String,
    #[serde(default)] pub question: String,
    #[serde(default)] pub lines: Vec<Line>,
    #[serde(default)] pub notes: Vec<String>,
}

// ═══════════════════════════ paths ═══════════════════════════

fn home_dir() -> Result<PathBuf, String> {
    std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from)
        .ok_or_else(|| "no HOME / USERPROFILE".to_string())
}

fn state_dir() -> Result<PathBuf, String> {
    let d = home_dir()?.join(".studio").join("state");
    std::fs::create_dir_all(&d).map_err(|e| format!("mkdir {}: {e}", d.display()))?;
    Ok(d)
}

fn session_file() -> Result<PathBuf, String> {
    Ok(state_dir()?.join("kosmik-beat-machine.session.json"))
}

// ═══════════════════════════ parse ═══════════════════════════

fn shouty(s: &str) -> bool {
    let t = s.trim();
    !t.is_empty()
        && t.chars().count() <= 48
        && t.chars().any(|c| c.is_alphabetic())
        && !t.chars().any(|c| c.is_lowercase())
}

fn split_line(s: &str) -> Line {
    if let Some(i) = s.find(':') {
        let (l, r) = s.split_at(i);
        if shouty(l) {
            return Line { op: l.trim().into(), text: r[1..].trim().into() };
        }
    }
    Line { op: String::new(), text: s.trim().into() }
}

/// 3+ slots -> positional [plot, phrase, question] (V3, authoritative)
/// 2  slots -> disambiguated by PLOTS
/// 1  slot  -> fused "LABEL: question" (V1/V2)
fn parse_header(items: &[String]) -> (String, String, String) {
    let v: Vec<&str> = items.iter().map(|s| s.trim()).collect();
    match v.len() {
        0 => (String::new(), String::new(), String::new()),
        1 => {
            let s = v[0];
            if let Some(i) = s.find(':') {
                let (l, r) = s.split_at(i);
                let (lab, q) = (l.trim(), r[1..].trim());
                if shouty(lab) && !q.is_empty() {
                    return if PLOTS.contains(&lab) {
                        (lab.into(), String::new(), q.into())
                    } else {
                        (String::new(), lab.into(), q.into())
                    };
                }
            }
            (String::new(), String::new(), s.into())
        }
        2 => {
            if PLOTS.contains(&v[0]) { (v[0].into(), String::new(), v[1].into()) }
            else { (String::new(), v[0].into(), v[1].into()) }
        }
        _ => (v[0].into(), v[1].into(), v[2..].join(" ").trim().into()),
    }
}

/// Net bracket depth for one line, ignoring brackets inside quoted strings and
/// after `#`. Your beats contain "[SECOND TRIGGER WORD]" — those must not count.
fn bracket_delta(line: &str) -> i32 {
    let mut d = 0i32;
    let (mut in_str, mut esc) = (false, false);
    for c in line.chars() {
        if in_str {
            if esc { esc = false; }
            else if c == '\\' { esc = true; }
            else if c == '"' { in_str = false; }
            continue;
        }
        match c {
            '"' => in_str = true,
            '#' => break,
            '[' => d += 1,
            ']' => d -= 1,
            _ => {}
        }
    }
    d
}

/// Byte range of the `[beatsheet]` section. Ends right after the last complete
/// `beat_N = [...]`, so trailing prose can never be inside the range.
fn find_section(src: &str) -> Option<(usize, usize)> {
    let mut start: Option<usize> = None;
    let (mut off, mut end, mut depth) = (0usize, 0usize, 0i32);
    let mut fenced = false;

    for line in src.split_inclusive('\n') {
        let t = line.trim();

        if start.is_none() {
            if t.starts_with("```") || t.starts_with("~~~") {
                fenced = !fenced;                       // ignore code blocks
            } else if !fenced && t == "[beatsheet]" {
                start = Some(off);
                end = off + line.len();
            }
            off += line.len();
            continue;
        }

        if depth == 0 {
            if t.is_empty() || t.starts_with('#') { off += line.len(); continue; }
            if !(t.starts_with("beat_") && t.contains('=')) { break; }
        }

        depth += bracket_delta(line);
        off += line.len();
        if depth <= 0 { depth = 0; end = off; }         // entry closed = safe boundary
    }
    start.map(|s| (s, end))
}

fn parse_beats(src: &str) -> Result<Vec<Beat>, String> {
    let region = match find_section(src) { Some((s, e)) => &src[s..e], None => src };
    let root: toml::Value = region.parse().map_err(|e| format!("TOML parse error: {e}"))?;

    // [beatsheet] is a TABLE, not an array — calling .as_array() here is the
    // original bug that made the first plugin return "" forever.
    let table = root.get("beatsheet").and_then(|v| v.as_table())
        .or_else(|| root.as_table())
        .ok_or("no [beatsheet] table found")?;

    let mut keys: Vec<&String> = table.keys().filter(|k| k.starts_with("beat_")).collect();
    keys.sort_by_key(|k| k.trim_start_matches("beat_").parse::<i64>().unwrap_or(i64::MAX));

    let mut out = Vec::new();
    for key in keys {
        let Some(blocks) = table.get(key).and_then(|v| v.as_array()) else { continue };
        let mut b = Beat::default();
        for (i, blk) in blocks.iter().enumerate() {
            let items: Vec<String> = blk.as_array()
                .map(|a| a.iter().filter_map(|x| x.as_str()).map(str::to_string).collect())
                .unwrap_or_default();
            if items.is_empty() { continue; }

            if i == 0 {
                let (p, ph, q) = parse_header(&items);
                b.plot = p; b.phrase = ph; b.question = q;
            } else if items[0].trim().eq_ignore_ascii_case("NOTES") {
                b.notes.extend(items[1..].iter().map(|s| s.trim().to_string()));
            } else {
                b.lines.extend(items.iter().map(|s| split_line(s)));
            }
        }
        out.push(b);
    }
    Ok(out)
}

fn has_beatsheet(src: &str) -> bool {
    find_section(src).is_some()
}

// ═══════════════════════════ emit ═══════════════════════════

/// TOML basic-string escaping. Never hand-roll format!("\"{}\"").
fn q(s: &str) -> String {
    let mut o = String::with_capacity(s.len() + 2);
    o.push('"');
    for c in s.chars() {
        match c {
            '"'  => o.push_str("\\\""),
            '\\' => o.push_str("\\\\"),
            '\n' => o.push_str("\\n"),
            '\r' => o.push_str("\\r"),
            '\t' => o.push_str("\\t"),
            c if (c as u32) < 0x20 => o.push_str(&format!("\\u{:04X}", c as u32)),
            c => o.push(c),
        }
    }
    o.push('"');
    o
}

fn emit(beats: &[Beat]) -> String {
    let mut o = String::from("[beatsheet]\n\n");
    for (i, b) in beats.iter().enumerate() {
        let (p, ph, qu) = (b.plot.trim(), b.phrase.trim(), b.question.trim());

        // plot + phrase both set -> always 3 slots, so reparsing is positional
        // and a lowercase phrase can't be mistaken for prose.
        let head: Vec<&str> = if !p.is_empty() && !ph.is_empty() {
            vec![p, ph, qu]
        } else {
            [p, ph, qu].iter().filter(|s| !s.is_empty()).cloned().collect()
        };

        o.push_str(&format!("beat_{} = [\n    [\n", i + 1));
        for s in head { o.push_str(&format!("        {},\n", q(s))); }
        o.push_str("    ],\n    [\n");
        for l in &b.lines {
            let (op, tx) = (l.op.trim(), l.text.trim());
            let s = if op.is_empty() { tx.to_string() }
                    else if tx.is_empty() { format!("{op}:") }
                    else { format!("{op}: {tx}") };
            if !s.is_empty() { o.push_str(&format!("        {},\n", q(&s))); }
        }
        o.push_str("    ],\n");

        let notes: Vec<&String> = b.notes.iter().filter(|n| !n.trim().is_empty()).collect();
        if !notes.is_empty() {
            o.push_str("    [\n        \"NOTES\",\n");
            for n in notes { o.push_str(&format!("        {},\n", q(n.trim()))); }
            o.push_str("    ],\n");
        }
        o.push_str("]\n\n");
    }
    o
}

/// Swap the [beatsheet] region only. Preserves the file's line endings.
fn splice(src: &str, block: &str) -> String {
    let block = if src.contains("\r\n") { block.replace('\n', "\r\n") } else { block.to_string() };
    if let Some((s, e)) = find_section(src) {
        return format!("{}{}{}", &src[..s], block, &src[e..]);
    }
    let mut out = src.to_string();
    if !out.is_empty() && !out.ends_with('\n') { out.push('\n'); }
    out.push('\n');
    out.push_str(&block);
    out
}

// ═══════════════════════════ time ═══════════════════════════

fn stamp() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0) as i64;
    let (days, sod) = (secs.div_euclid(86400), secs.rem_euclid(86400));
    let z = days + 719468;
    let era = (if z >= 0 { z } else { z - 146096 }) / 146097;
    let doe = (z - era * 146097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!("{y:04}{m:02}{d:02}-{:02}{:02}{:02}", sod / 3600, (sod % 3600) / 60, sod % 60)
}

// ═══════════════════════════ emacs ═══════════════════════════

#[derive(Serialize, Clone, Default)]
struct EmacsStatus {
    running: bool,
    server: bool,
    usable: bool,
    file: String,
    short: String,
    beats: usize,
}

#[cfg(windows)]
fn hide_console(cmd: &mut std::process::Command) {
    use std::os::windows::process::CommandExt;
    cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
}
#[cfg(not(windows))]
fn hide_console(_: &mut std::process::Command) {}

/// Bounded external call. Runs on a worker thread; never blocks the caller
/// past `ms`, because a stale emacsclient socket can hang forever.
fn run_timeout(prog: &str, args: &[&str], ms: u64) -> Option<String> {
    let prog = prog.to_string();
    let args: Vec<String> = args.iter().map(|s| s.to_string()).collect();
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut c = std::process::Command::new(&prog);
        c.args(&args);
        hide_console(&mut c);
        let _ = tx.send(c.output());
    });
    match rx.recv_timeout(std::time::Duration::from_millis(ms)) {
        Ok(Ok(o)) if o.status.success() => Some(String::from_utf8_lossy(&o.stdout).into_owned()),
        _ => None,
    }
}

#[cfg(target_os = "linux")]
fn emacs_running() -> bool {
    let Ok(rd) = std::fs::read_dir("/proc") else { return false };
    for e in rd.flatten() {
        if let Ok(s) = std::fs::read_to_string(e.path().join("comm")) {
            let n = s.trim();
            if n == "emacs" || n.starts_with("emacs-") { return true; }
        }
    }
    false
}
#[cfg(target_os = "macos")]
fn emacs_running() -> bool {
    run_timeout("pgrep", &["-x", "Emacs"], 500).is_some()
        || run_timeout("pgrep", &["-x", "emacs"], 500).is_some()
}
#[cfg(target_os = "windows")]
fn emacs_running() -> bool {
    run_timeout("tasklist", &["/FI", "IMAGENAME eq emacs.exe", "/NH"], 900)
        .map(|s| s.to_lowercase().contains("emacs.exe")).unwrap_or(false)
}
#[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "windows")))]
fn emacs_running() -> bool { false }

fn unquote_elisp(s: &str) -> String {
    let s = s.trim();
    if s.len() >= 2 && s.starts_with('"') && s.ends_with('"') {
        let mut o = String::new();
        let mut esc = false;
        for c in s[1..s.len() - 1].chars() {
            if esc { o.push(c); esc = false; }
            else if c == '\\' { esc = true; }
            else { o.push(c); }
        }
        o
    } else { s.to_string() }
}

fn shorten(p: &str, n: usize) -> String {
    let base = Path::new(p).file_name().and_then(|s| s.to_str()).unwrap_or(p);
    if base.chars().count() <= n { base.to_string() }
    else { format!("{}…", base.chars().take(n - 1).collect::<String>()) }
}

fn emacs_probe() -> EmacsStatus {
    let mut s = EmacsStatus { running: emacs_running(), ..Default::default() };
    if !s.running { return s; }

    let Some(out) = run_timeout(
        "emacsclient",
        &["-e", "(buffer-file-name (window-buffer (selected-window)))"],
        1200,
    ) else { return s };
    s.server = true;

    let t = out.trim();
    if t.is_empty() || t == "nil" { return s; }
    let path = unquote_elisp(t);
    if path.is_empty() { return s; }

    s.short = shorten(&path, 33);
    s.file = path.clone();

    if let Ok(src) = std::fs::read_to_string(&path) {
        if has_beatsheet(&src) {
            if let Ok(b) = parse_beats(&src) { s.beats = b.len(); s.usable = true; }
        }
    }
    s
}

/// Returns instantly from cache; refreshes in the background. The probe spawns
/// processes, so it must never run on the QML thread.
fn emacs_status() -> EmacsStatus {
    static CACHE: OnceLock<Mutex<EmacsStatus>> = OnceLock::new();
    static BUSY: AtomicBool = AtomicBool::new(false);
    let cell = CACHE.get_or_init(|| Mutex::new(EmacsStatus::default()));

    if !BUSY.swap(true, Ordering::SeqCst) {
        std::thread::spawn(move || {
            let fresh = emacs_probe();
            if let Some(c) = CACHE.get() {
                if let Ok(mut g) = c.lock() { *g = fresh; }
            }
            BUSY.store(false, Ordering::SeqCst);
        });
    }
    cell.lock().map(|g| g.clone()).unwrap_or_default()
}

// ═══════════════════════════ requests ═══════════════════════════

#[derive(Deserialize)] struct ParseReq { #[serde(default)] path: String, #[serde(default)] text: String }
#[derive(Serialize)]   struct BeatsResp { beats: Vec<Beat>, path: String }
#[derive(Deserialize)] struct BuildReq { beats: Vec<Beat> }
#[derive(Serialize)]   struct BuildResp { toml: String }
#[derive(Deserialize)] struct SaveReq { beats: Vec<Beat>, #[serde(default)] path: String, #[serde(default)] mode: String }
#[derive(Serialize)]   struct SaveResp { path: String, action: String }
#[derive(Serialize)]   struct VocabResp { ops: Vec<String>, plots: Vec<String> }

#[derive(Serialize, Deserialize, Default)]
struct Session {
    #[serde(default)] path: String,
    #[serde(default)] beats: Vec<Beat>,
    #[serde(default)] open: Vec<bool>,
    #[serde(default)] dirty: bool,
    #[serde(default)] stamp: String,
}

#[derive(Deserialize)]
struct SessionSaveReq {
    #[serde(default)] path: String,
    #[serde(default)] beats: Vec<Beat>,
    #[serde(default)] open: Vec<bool>,
    #[serde(default)] dirty: bool,
    #[serde(default)] backup: bool,
}
#[derive(Serialize)] struct SessionSaveResp { saved: bool, backup: String }

fn default_beat() -> Beat {
    Beat {
        plot: "INCITING INCIDENT".into(),
        phrase: String::new(),
        question: String::new(),
        lines: vec![
            Line { op: "THIS HAPPENS".into(), text: String::new() },
            Line { op: "BUT".into(),          text: String::new() },
            Line { op: "THEREFORE".into(),    text: String::new() },
        ],
        notes: vec![],
    }
}

fn do_parse(r: ParseReq) -> Result<BeatsResp, String> {
    let (src, path) = if !r.path.is_empty() {
        (std::fs::read_to_string(&r.path).map_err(|e| format!("{}: {e}", r.path))?, r.path)
    } else { (r.text, String::new()) };
    Ok(BeatsResp { beats: parse_beats(&src)?, path })
}

fn do_save(r: SaveReq) -> Result<SaveResp, String> {
    let block = emit(&r.beats);
    if r.mode == "replace" {
        if r.path.is_empty() { return Err("no file open — use Save copy".into()); }
        let src = std::fs::read_to_string(&r.path).map_err(|e| format!("{}: {e}", r.path))?;
        std::fs::write(&r.path, splice(&src, &block)).map_err(|e| format!("write: {e}"))?;
        return Ok(SaveResp { path: r.path, action: "replaced".into() });
    }
    let out = if r.path.is_empty() {
        home_dir()?.join(format!("{}.beatsheet.toml", stamp()))
    } else {
        let p = Path::new(&r.path);
        let s = p.file_stem().and_then(|s| s.to_str()).unwrap_or("scene");
        p.with_file_name(format!("{s}.{}.beatsheet.toml", stamp()))
    };
    std::fs::write(&out, &block).map_err(|e| format!("write: {e}"))?;
    Ok(SaveResp { path: out.display().to_string(), action: "created".into() })
}

fn prune(dir: &Path, keep: usize) {
    let Ok(rd) = std::fs::read_dir(dir) else { return };
    let mut v: Vec<PathBuf> = rd.flatten().map(|e| e.path())
        .filter(|p| p.is_file()).collect();
    if v.len() <= keep { return; }
    v.sort();
    for p in &v[..v.len() - keep] { let _ = std::fs::remove_file(p); }
}

fn do_session_save(r: SessionSaveReq) -> Result<SessionSaveResp, String> {
    let s = Session { path: r.path.clone(), beats: r.beats.clone(),
                      open: r.open, dirty: r.dirty, stamp: stamp() };
    let json = serde_json::to_string(&s).map_err(|e| e.to_string())?;
    std::fs::write(session_file()?, json).map_err(|e| format!("session write: {e}"))?;

    let mut backup = String::new();
    if r.backup && !r.beats.is_empty() {
        let dir = state_dir()?.join("autosave");
        std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
        let stem = if r.path.is_empty() { "untitled".to_string() } else {
            Path::new(&r.path).file_stem().and_then(|s| s.to_str()).unwrap_or("scene").to_string()
        };
        let out = dir.join(format!("{stem}.{}.beatsheet.toml", stamp()));
        std::fs::write(&out, emit(&r.beats)).map_err(|e| e.to_string())?;
        prune(&dir, 25);
        backup = out.display().to_string();
    }
    Ok(SessionSaveResp { saved: true, backup })
}

fn do_session_load(_: serde_json::Value) -> Result<Session, String> {
    let f = session_file()?;
    if !f.exists() { return Ok(Session::default()); }
    let s = std::fs::read_to_string(&f).map_err(|e| e.to_string())?;
    Ok(serde_json::from_str(&s).unwrap_or_default())
}

// ═══════════════════════════ ABI ═══════════════════════════

fn json_call<Q, R>(raw: &str, f: fn(Q) -> Result<R, String>) -> Result<String, String>
where Q: serde::de::DeserializeOwned, R: Serialize {
    let req: Q = serde_json::from_str(raw).map_err(|e| format!("bad request json: {e}"))?;
    serde_json::to_string(&f(req)?).map_err(|e| e.to_string())
}

/// null-check + utf8 + JSON envelope + catch_unwind.
/// A panic crossing extern "C" is UB, so this wrapper is mandatory.
fn dispatch(ptr: *const c_char, f: fn(&str) -> Result<String, String>) -> *mut c_char {
    let res = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        if ptr.is_null() { return Err("null input".to_string()); }
        let s = unsafe { CStr::from_ptr(ptr) }.to_str().map_err(|e| format!("utf8: {e}"))?;
        f(s)
    }));
    let json = match res {
        Ok(Ok(p))  => format!(r#"{{"ok":{p}}}"#),
        Ok(Err(e)) => serde_json::json!({ "error": e }).to_string(),
        Err(_)     => serde_json::json!({ "error": "plugin panicked" }).to_string(),
    };
    CString::new(json.replace('\0', ""))
        .unwrap_or_else(|_| CString::new(r#"{"error":"encode failed"}"#).unwrap())
        .into_raw()
}

macro_rules! export {
    ($($sym:ident => $h:expr),* $(,)?) => {
        $(#[no_mangle] pub extern "C" fn $sym(p: *const c_char) -> *mut c_char { dispatch(p, $h) })*
    };
}

export! {
    ping_ffi          => |s: &str| Ok(serde_json::json!(s).to_string()),
    vocab_ffi         => |_: &str| serde_json::to_string(&VocabResp {
                              ops: OPS.iter().map(|s| s.to_string()).collect(),
                              plots: PLOTS.iter().map(|s| s.to_string()).collect(),
                          }).map_err(|e| e.to_string()),
    new_beats_ffi     => |_: &str| serde_json::to_string(&BeatsResp {
                              beats: vec![default_beat()], path: String::new()
                          }).map_err(|e| e.to_string()),
    parse_beats_ffi   => |s: &str| json_call(s, do_parse),
    build_beats_ffi   => |s: &str| json_call(s, |r: BuildReq| Ok::<_, String>(BuildResp { toml: emit(&r.beats) })),
    save_beats_ffi    => |s: &str| json_call(s, do_save),
    session_save_ffi  => |s: &str| json_call(s, do_session_save),
    session_load_ffi  => |s: &str| json_call(s, do_session_load),
    session_clear_ffi => |_: &str| { let _ = session_file().map(std::fs::remove_file);
                                     Ok("{\"cleared\":true}".to_string()) },
    emacs_status_ffi  => |_: &str| serde_json::to_string(&emacs_status()).map_err(|e| e.to_string()),
}

#[no_mangle]
pub extern "C" fn free_string_ffi(p: *mut c_char) {
    if !p.is_null() { unsafe { let _ = CString::from_raw(p); } }
}

#[no_mangle]
pub extern "C" fn init_plugin() { println!("SUCCESS: kosmik-beat-machine v0.3 loaded."); }

// ═══════════════════════════ tests ═══════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn v3_three_slots_positional() {
        let src = r#"[beatsheet]
beat_1 = [
    ["INCITING INCIDENT","SECOND TRIGGER","What private word does the goddess use?"],
    ["THIS HAPPENS: It begins.","BUT: The word is forbidden."],
    ["NOTES","note 1"]
]"#;
        let b = &parse_beats(src).unwrap()[0];
        assert_eq!(b.plot, "INCITING INCIDENT");
        assert_eq!(b.phrase, "SECOND TRIGGER");
        assert_eq!(b.lines[1].op, "BUT");
        assert_eq!(b.notes, ["note 1"]);
    }

    #[test]
    fn lowercase_phrase_survives_round_trip() {
        let src = r#"[beatsheet]
beat_1 = [["INCITING INCIDENT","Siren Caged","What causes her to get captured?"],
          ["THIS HAPPENS: kosmik girl walks into the hivemind, alone"]]"#;
        let a = parse_beats(src).unwrap();
        assert_eq!(a[0].phrase, "Siren Caged");
        assert_eq!(a, parse_beats(&emit(&a)).unwrap());
    }

    #[test]
    fn two_slot_legacy_and_fused_label() {
        let a = parse_beats("[beatsheet]\nbeat_1=[[\"TRUE NAME\",\"What identity?\"],[\"THIS HAPPENS: x\"]]").unwrap();
        assert_eq!(a[0].phrase, "TRUE NAME");
        assert_eq!(a[0].plot, "");
        let b = parse_beats("[beatsheet]\nbeat_1=[[\"SECOND TRIGGER: What word?\"],[\"THIS HAPPENS: x\"]]").unwrap();
        assert_eq!(b[0].phrase, "SECOND TRIGGER");
        assert_eq!(b[0].question, "What word?");
    }

    #[test]
    fn quotes_survive() {
        let src = "[beatsheet]\nbeat_1 = [[\"CRISIS\",\"key\",\"q?\"],[\"BUT: She said \\\"no\\\".\"]]";
        let a = parse_beats(src).unwrap();
        assert_eq!(a, parse_beats(&emit(&a)).unwrap());
    }

    /// The data-loss bug: no terminator after the beatsheet.
    #[test]
    fn prose_after_beatsheet_survives() {
        let doc = "[beatsheet]\nbeat_1 = [[\"CRISIS\"],[\"BUT: x\"]]\n\n## Prose\n\nShe walked in.\n";
        let out = splice(doc, &emit(&parse_beats(doc).unwrap()));
        assert!(out.contains("## Prose"));
        assert!(out.contains("She walked in."));
        assert_eq!(out.matches("[beatsheet]").count(), 1);
    }

    #[test]
    fn brackets_inside_strings_do_not_end_section() {
        let doc = "[beatsheet]\n\nbeat_1 = [\n    [\n        \"CRISIS\",\n    ],\n    [\n        \"THIS HAPPENS: she uses [SECOND TRIGGER WORD].\",\n        \"BUT: connects to [STELLAR MEMORY, IDENTITY].\",\n    ],\n]\n\n[characters]\nname = \"Emma\"\n";
        let out = splice(doc, &emit(&parse_beats(doc).unwrap()));
        assert!(out.contains("[characters]"));
        assert!(out.contains("name = \"Emma\""));
        assert!(out.contains("[SECOND TRIGGER WORD]"));
    }

    #[test]
    fn multiple_toml_sections_only_beatsheet_replaced() {
        let doc = "+++\n[scene]\ntitle = \"Chambers\"\nchapter = 1\n\n[beatsheet]\nbeat_1 = [[\"CRISIS\"],[\"BUT: x\"]]\n\n[meta]\nwords = 2400\n+++\n\nProse here.\n";
        let out = splice(doc, &emit(&parse_beats(doc).unwrap()));
        assert!(out.contains("chapter = 1"));
        assert!(out.contains("words = 2400"));
        assert!(out.contains("Prose here."));
    }

    #[test]
    fn crlf_preserved() {
        let doc = "[beatsheet]\r\nbeat_1 = [[\"CRISIS\"],[\"BUT: x\"]]\r\n\r\n## P\r\n";
        let out = splice(doc, &emit(&parse_beats(doc).unwrap()));
        assert!(out.contains("\r\n"));
        assert!(out.contains("## P"));
    }

    #[test]
    fn beatsheet_in_code_fence_ignored() {
        let doc = "```\n[beatsheet]\nbeat_1 = [[\"X\"],[\"Y\"]]\n```\n\n[beatsheet]\nbeat_1 = [[\"CRISIS\"],[\"BUT: real\"]]\n";
        let (s, _) = find_section(doc).unwrap();
        assert!(doc[s..].contains("BUT: real"));
    }
}
