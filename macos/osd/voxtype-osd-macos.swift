// voxtype-osd-macos -- the macOS renderer for voxtype's on-screen dictation
// display, in one file, built with Command Line Tools' swiftc alone.
//
// Upstream (peteonrails/voxtype v1.0.1) ships six OSD binaries, all Linux
// (gtk4-layer-shell, smithay-client-toolkit, quickshell). What macOS lacks is
// only the *window*: the daemon-side half of the OSD is platform-neutral and
// runs unconditionally --
//
//   * daemon.rs binds $XDG_RUNTIME_DIR/voxtype/audio.sock (default
//     /tmp/voxtype/audio.sock) regardless of [osd] enabled, and streams
//     16-byte AudioFrames at 100 Hz to any client that connects while a
//     recording is live: u32 seq, f32 min, f32 max, f32 peak_dbfs, native
//     (little-endian here) byte order -- src/audio/levels.rs.
//   * with state_file = "auto" the daemon writes idle/recording/transcribing
//     to /tmp/voxtype/state on every transition.
//
// Measured on this machine: ~100 frames/s while recording, stopping within
// ~0.1 s of the end; the state file lags each edge by ~0.2 s.
//
// This program ports the rendering math verbatim from src/osd/visual.rs
// (project_envelope, PeakHold, peak_meter_fraction) and the layout from
// src/bin/voxtype_osd_native/app.rs (draw_ui/draw_waveform/draw_meter), so
// the panel looks like the Linux one, plus a dimmed `transcribing` state the
// Linux OSD cannot show (it hides 0.15 s after "Recording stopped"; here the
// panel stays up until the state file says idle, covering the silent cleanup
// gap instead of papering over it with a progress notification).
//
// WHY `osd.enabled = false` IS IGNORED. This is the single most confusing
// thing about the design, so it is stated up front: upstream's frontends exit
// immediately when [osd] enabled = false. This binary deliberately does NOT
// read that key. On macOS `false` is exactly what keeps the daemon from
// trying to spawn a frontend it does not have (the sibling of the daemon
// executable is inside the sealed app bundle; the PATH fallback cannot see
// ~/.local/bin), and this renderer attaches through the socket the daemon
// binds unconditionally -- it is a LaunchAgent, not the daemon's child. Were
// it to honour `enabled`, one `voxtype config set osd.enabled true` would
// kill the panel AND make the daemon spam "Failed to spawn voxtype-osd".
//
// Attachment, in short (see com.tuantran.voxtype-osd.plist): standalone
// LaunchAgent; the binary is named voxtype-osd-macos so the daemon's
// supervisor (which looks for a sibling named exactly `voxtype-osd`) can
// never double-spawn it.
//
// Modes: --selftest (pure math, no GUI, no socket; CI/SSH-safe) and --probe
// [secs] (decoded frames as text, no window) exist so both halves of the
// contract can be verified without a display.

import AppKit
import Darwin
import Foundation

// MARK: - Small helpers

private let logFormatter: ISO8601DateFormatter = {
  let f = ISO8601DateFormatter()
  f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return f
}()

func log(_ message: @autoclosure () -> String) {
  print("[\(logFormatter.string(from: Date()))] \(message())")
}

extension Float {
  func clamped(_ lo: Float, _ hi: Float) -> Float {
    Swift.min(Swift.max(self, lo), hi)
  }
}

extension Double {
  func clamped(_ lo: Double, _ hi: Double) -> Double {
    Swift.min(Swift.max(self, lo), hi)
  }
}

// MARK: - AudioFrame: the 16-byte wire record
//
// Mirrors src/audio/levels.rs AudioFrame. Decoding is explicit
// little-endian byte assembly rather than a struct cast so the code says
// what the wire says (the daemon uses native order, which is LE on every
// Mac this can run on).

struct AudioFrame: Equatable {
  var seq: UInt32
  var min: Float
  var max: Float
  var peakDbfs: Float
}

private func u32le(_ b: [UInt8], _ i: Int) -> UInt32 {
  UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
}

/// Decode one frame from bytes[off..<off+16].
///
/// Sanitisation before the layout check, in this order: non-finite floats
/// become safe values (NaN min/max -> 0, non-finite peak -> -120 dBFS), then
/// |min| or |max| beyond 1.5 rejects the frame outright -- real samples live
/// in -1..=1, so anything past 1.5 means the daemon changed the 16-byte
/// layout, and the caller logs that once and goes quiet rather than drawing
/// garbage. Returns nil for a rejected frame.
func decodeFrame(_ bytes: [UInt8], at offset: Int) -> AudioFrame? {
  let rawMin = Float(bitPattern: u32le(bytes, offset + 4))
  let rawMax = Float(bitPattern: u32le(bytes, offset + 8))
  var mn: Float = 0
  var mx: Float = 0
  if rawMin.isFinite { mn = rawMin }
  if rawMax.isFinite { mx = rawMax }
  if abs(mn) > 1.5 || abs(mx) > 1.5 { return nil }
  mn = mn.clamped(-1, 1)
  mx = mx.clamped(-1, 1)
  let rawPeak = Float(bitPattern: u32le(bytes, offset + 12))
  let peak = rawPeak.isFinite ? rawPeak : -120
  return AudioFrame(
    seq: u32le(bytes, offset),
    min: mn,
    max: mx,
    peakDbfs: peak
  )
}

/// Encode a frame little-endian (selftest round-trip and --probe fixtures).
func encodeFrameLE(_ f: AudioFrame) -> [UInt8] {
  func put32(_ v: UInt32) -> [UInt8] {
    [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
  }
  return put32(f.seq)
    + put32(f.min.bitPattern)
    + put32(f.max.bitPattern)
    + put32(f.peakDbfs.bitPattern)
}

// MARK: - The ported visual math (src/osd/visual.rs)
//
// Kept as close to the Rust as Swift allows so the numbers cannot drift:
// identical constants, identical bucket arithmetic, identical clamp order.

struct EnvelopeColumn: Equatable {
  var min: Float
  var max: Float
  static let silent = EnvelopeColumn(min: 0, max: 0)
}

/// Port of project_envelope: project the newest frames onto n pixel columns
/// by aggregating min/max per proportional bucket, oldest on the left. With
/// fewer frames than columns, buckets go empty and sample-and-hold the
/// nearest frame so the waveform stretches across the full width instead of
/// leaving a dead zone on the left.
func projectEnvelope(_ frames: [AudioFrame], nColumns: Int) -> [EnvelopeColumn] {
  var out = [EnvelopeColumn](repeating: .silent, count: nColumns)
  let nFrames = frames.count
  if nFrames == 0 || nColumns == 0 { return out }

  for col in 0..<nColumns {
    let start = (col * nFrames) / nColumns
    let end = ((col + 1) * nFrames) / nColumns
    var mn: Float = 0
    var mx: Float = 0
    var any = false
    for f in frames[start..<end] {
      if !any {
        mn = f.min
        mx = f.max
        any = true
      } else {
        if f.min < mn { mn = f.min }
        if f.max > mx { mx = f.max }
      }
    }
    if any {
      out[col] = EnvelopeColumn(min: mn, max: mx)
    } else {
      let idx = Swift.min((col * nFrames) / nColumns, nFrames - 1)
      out[col] = EnvelopeColumn(min: frames[idx].min, max: frames[idx].max)
    }
  }
  return out
}

/// Port of update_peak_hold: held peak snaps up instantly to a louder peak,
/// decays linearly at decayDbPerSec otherwise, and floors at -120 dBFS.
func updatePeakHold(currentPeak: Float, held: inout Float, decayDbPerSec: Float, dtSecs: Float) {
  if currentPeak > held {
    held = currentPeak
  } else {
    held -= decayDbPerSec * dtSecs
    if held < -120 { held = -120 }
  }
}

struct PeakHold {
  var heldDbfs: Float = -120
  var decayDbPerSec: Float
  init(decayDbPerSec: Float) { self.decayDbPerSec = decayDbPerSec }
  mutating func update(currentPeakDbfs: Float, dtSecs: Float) {
    updatePeakHold(
      currentPeak: currentPeakDbfs, held: &heldDbfs, decayDbPerSec: decayDbPerSec, dtSecs: dtSecs)
  }
}

/// Port of peak_meter_fraction: map dBFS onto 0...1 against a floor (-60 by
/// convention here); 0 dBFS maps to 1.0, silence and non-finite map to 0.
func peakMeterFraction(_ peakDbfs: Float, floorDbfs: Float) -> Float {
  if !peakDbfs.isFinite || peakDbfs <= floorDbfs { return 0 }
  let clipped = Swift.min(peakDbfs, 0)
  let span = -floorDbfs
  if span <= 0 { return 0 }
  return ((clipped - floorDbfs) / span).clamped(0, 1)
}

enum MeterZone {
  case low, mid, high
  static func fromDbfs(_ peakDbfs: Float) -> MeterZone {
    if peakDbfs >= -3 { return .high }
    if peakDbfs >= -12 { return .mid }
    return .low
  }
}

/// RGBA 0...1, like visual.rs Color.
struct Color {
  var r: Float, g: Float, b: Float, a: Float
  static func rgba(_ r: Float, _ g: Float, _ b: Float, _ a: Float) -> Color {
    Color(r: r, g: g, b: b, a: a)
  }
  static func rgb(_ r: Float, _ g: Float, _ b: Float) -> Color {
    Color(r: r, g: g, b: b, a: 1)
  }
  func withAlpha(_ a: Float) -> Color { Color(r: r, g: g, b: b, a: a) }
  var cg: CGColor { CGColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a)) }
}

/// The fallback palette from visual.rs Palette::fallback(). No Omarchy
/// theme file exists on this machine, so the fallback IS the palette.
struct Palette {
  var background = Color.rgba(0.10, 0.10, 0.12, 0.85)
  var accent = Color.rgb(0.40, 0.78, 1.00)
  var meterLow = Color.rgb(0.30, 0.85, 0.45)
  var meterMid = Color.rgb(0.95, 0.80, 0.30)
  var meterHigh = Color.rgb(0.95, 0.35, 0.30)
  var foreground = Color.rgb(0.92, 0.92, 0.95)
  func zoneColor(_ z: MeterZone) -> Color {
    switch z {
    case .low: return meterLow
    case .mid: return meterMid
    case .high: return meterHigh
    }
  }
}

// MARK: - FrameRing (src/osd/ipc.rs FrameRing)
//
/// Fixed-capacity ring, newest overwriting oldest, iterated oldest-first.
/// 300 slots = 3.0 s at the daemon's 100 Hz. Internally locked: pushed by
/// the reader thread, snapshotted by the main thread at redraw time.

final class FrameRing {
  private let capacity: Int
  private var slots: [AudioFrame]
  private var head = 0
  private var len = 0
  private let lock = NSLock()
  private var lastFrameUptime: Double?
  private var lastSeq: UInt32?

  init(capacity: Int) {
    precondition(capacity > 0)
    self.capacity = capacity
    self.slots = [AudioFrame](repeating: AudioFrame(seq: 0, min: 0, max: 0, peakDbfs: -120), count: capacity)
  }

  func push(_ frame: AudioFrame) {
    lock.lock()
    slots[head] = frame
    head = (head + 1) % capacity
    if len < capacity { len += 1 }
    lastFrameUptime = ProcessInfo.processInfo.systemUptime
    lastSeq = frame.seq
    lock.unlock()
  }

  /// Seconds since the last pushed frame; nil when no frame ever arrived.
  func sinceLastFrame() -> Double? {
    lock.lock()
    defer { lock.unlock() }
    guard let t = lastFrameUptime else { return nil }
    return ProcessInfo.processInfo.systemUptime - t
  }

  var latestSeq: UInt32? {
    lock.lock()
    defer { lock.unlock() }
    return lastSeq
  }

  /// Oldest-first snapshot of the buffered frames.
  func snapshot() -> [AudioFrame] {
    lock.lock()
    defer { lock.unlock() }
    let start = (len < capacity) ? 0 : head
    var out = [AudioFrame]()
    out.reserveCapacity(len)
    for i in 0..<len { out.append(slots[(start + i) % capacity]) }
    return out
  }
}

/// PeakHold boxed for cross-thread access; updated per frame by the reader
/// thread (dt = 1/100 s, exactly like the native frontend's IPC thread).
final class LockedPeakHold {
  private let lock = NSLock()
  private var ph: PeakHold
  init(decayDbPerSec: Float) { ph = PeakHold(decayDbPerSec: decayDbPerSec) }
  func update(peakDbfs: Float) {
    lock.lock()
    ph.update(currentPeakDbfs: peakDbfs, dtSecs: 1.0 / 100.0)
    lock.unlock()
  }
  var heldDbfs: Float {
    lock.lock()
    defer { lock.unlock() }
    return ph.heldDbfs
  }
}

// MARK: - Config
//
// Layering mirrors upstream's frontends: defaults (src/osd/config.rs
// OsdConfig::default, except `enabled`, which is deliberately not modelled
// at all -- see the header) < config.toml [osd] scalars < VOXTYPE_OSD_* env
// < flags. There is no TOML library without SwiftPM, so the scanner is a
// ~30-line key = value reader over scalar keys; everything it does not
// understand is ignored, which is also how it treats sections upstream added
// since.

struct Config {
  var socketPath = ""
  var reconnectSecs = 1.0
  var widthPx = 400.0
  var heightPx = 48.0
  var topMargin = 0.85
  var opacity = 0.95
  var waveformWindowSecs = 3.0
  var peakDecayDbPerSec = 6.0
  var waveformGain = 10.0
  var logEvery = 0
  var configPath = ""
  // Top-level state_file setting: "auto" (default), a literal path, or
  // "disabled". The daemon honours the same spellings; "auto" resolves to
  // runtimeDir()/state. Defaulting to auto when the key is absent is a
  // deliberate choice: absent means the daemon writes no state file, which
  // merely degrades this renderer to upstream's plain 0.5 s teardown.
  var stateFileSetting = "auto"

  /// $XDG_RUNTIME_DIR/voxtype or /tmp/voxtype -- daemon.rs's runtime_dir().
  static func runtimeDir() -> String {
    let env = ProcessInfo.processInfo.environment
    let base = env["XDG_RUNTIME_DIR"] ?? "/tmp"
    return (base as NSString).appendingPathComponent("voxtype")
  }

  static func defaultSocketPath() -> String {
    (runtimeDir() as NSString).appendingPathComponent("audio.sock")
  }

  static func defaultConfigPath() -> String {
    let env = ProcessInfo.processInfo.environment
    if let cfgHome = env["XDG_CONFIG_HOME"], !cfgHome.isEmpty {
      return (cfgHome as NSString).appendingPathComponent("voxtype/config.toml")
    }
    let home = env["HOME"] ?? NSHomeDirectory()
    return (home as NSString).appendingPathComponent(".config/voxtype/config.toml")
  }

  /// Resolved state-file path; nil when disabled.
  func resolvedStateFile() -> String? {
    switch stateFileSetting.trimmingCharacters(in: .whitespaces).lowercased() {
    case "disabled", "none", "off", "false":
      return nil
    case "", "auto":
      return (Config.runtimeDir() as NSString).appendingPathComponent("state")
    default:
      return (stateFileSetting as NSString).expandingTildeInPath
    }
  }
}

struct ParsedToml {
  var top = [String: String]()
  var osd = [String: String]()
}

/// Cut at the first # that is not inside a double-quoted string.
private func stripTomlComment(_ line: String) -> String {
  var inQuote = false
  for (offset, ch) in line.unicodeScalars.enumerated() {
    if ch == "\"" { inQuote.toggle() }
    else if ch == "#" && !inQuote {
      return String(line.prefix(offset))
    }
  }
  return line
}

func parseTomlScalars(_ text: String) -> ParsedToml {
  var out = ParsedToml()
  var section = ""
  for rawLine in text.components(separatedBy: .newlines) {
    let line = stripTomlComment(rawLine)
      .trimmingCharacters(in: .whitespaces)
    if line.isEmpty { continue }
    if line.hasPrefix("[[") && line.hasSuffix("]]") {
      // Array-of-tables ([[osd.visual.layers]]): its keys belong to the
      // array elements, not to [osd] -- skip them until the next header.
      section = "\u{0}array"
      continue
    }
    if line.hasPrefix("[") && line.hasSuffix("]") {
      let inner = line.dropFirst().dropLast()
      section = inner.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        .lowercased()
      continue
    }
    guard let eq = line.firstIndex(of: "=") else { continue }
    let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces).lowercased()
    var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
    if value.count >= 2 {
      let first = value.first!, last = value.last!
      if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
        value = String(value.dropFirst().dropLast())
      }
    }
    if key.isEmpty { continue }
    if section == "osd" {
      out.osd[key] = value
    } else if section.isEmpty {
      out.top[key] = value
    }
    // Every other section ([whisper], [hotkey], ...) is not ours to read.
  }
  return out
}

extension Config {
  /// defaults < config.toml < env < flags
  static func load(flagOverrides: [String: String]) -> Config {
    var c = Config()
    c.socketPath = Config.defaultSocketPath()
    c.configPath = Config.defaultConfigPath()

    // 1. config.toml (missing/unreadable -> defaults, like upstream).
    if let text = try? String(contentsOfFile: c.configPath, encoding: .utf8) {
      let p = parseTomlScalars(text)
      if let v = p.top["state_file"] { c.stateFileSetting = v }
      func d(_ s: String?) -> Double? { s.flatMap { Double($0) } }
      if let v = d(p.osd["width_px"]) { c.widthPx = v }
      if let v = d(p.osd["height_px"]) { c.heightPx = v }
      if let v = d(p.osd["top_margin"]) { c.topMargin = v }
      if let v = d(p.osd["opacity"]) { c.opacity = v }
      if let v = d(p.osd["waveform_window_secs"]) { c.waveformWindowSecs = v }
      if let v = d(p.osd["peak_decay_db_per_sec"]) { c.peakDecayDbPerSec = v }
      if let v = d(p.osd["waveform_gain"]) { c.waveformGain = v }
      // NOTE: `enabled` is deliberately not read. See the file header.
      // `frontend`, `style`, `layout`, `palette`, `frame`, `visual` are
      // Linux-frontend knobs with no meaning here.
    }

    // 2. env (upstream's own names: VOXTYPE_OSD_WIDTH, VOXTYPE_OSD_GAIN, ...).
    let env = ProcessInfo.processInfo.environment
    if let v = env["VOXTYPE_CONFIG"] { c.configPath = v }
    if let v = env["VOXTYPE_OSD_SOCKET"] { c.socketPath = v }
    if let v = Double(env["VOXTYPE_OSD_RECONNECT_SECS"] ?? "") { c.reconnectSecs = v }
    if let v = Double(env["VOXTYPE_OSD_WIDTH"] ?? "") { c.widthPx = v }
    if let v = Double(env["VOXTYPE_OSD_HEIGHT"] ?? "") { c.heightPx = v }
    if let v = Double(env["VOXTYPE_OSD_TOP_MARGIN"] ?? "") { c.topMargin = v }
    if let v = Double(env["VOXTYPE_OSD_OPACITY"] ?? "") { c.opacity = v }
    if let v = Double(env["VOXTYPE_OSD_GAIN"] ?? "") { c.waveformGain = v }
    if let v = Int(env["VOXTYPE_OSD_LOG_EVERY"] ?? "") { c.logEvery = v }

    // 3. flags.
    if let v = flagOverrides["config"] { c.configPath = v }
    if let v = flagOverrides["socket"] { c.socketPath = v }
    if let v = Double(flagOverrides["reconnect-secs"] ?? "") { c.reconnectSecs = v }
    if let v = Double(flagOverrides["width-px"] ?? "") { c.widthPx = v }
    if let v = Double(flagOverrides["height-px"] ?? "") { c.heightPx = v }
    if let v = Double(flagOverrides["top-margin"] ?? "") { c.topMargin = v }
    if let v = Double(flagOverrides["opacity"] ?? "") { c.opacity = v }
    if let v = Double(flagOverrides["waveform-gain"] ?? "") { c.waveformGain = v }
    if let v = Int(flagOverrides["log-every"] ?? "") { c.logEvery = v }

    // Sanitise ranges the same way upstream's frontends do.
    c.reconnectSecs = c.reconnectSecs.clamped(0.05, 3600)
    c.widthPx = c.widthPx.clamped(64, 4096)
    c.heightPx = c.heightPx.clamped(16, 1024)
    c.topMargin = c.topMargin.clamped(0.0, 1.0)
    c.opacity = c.opacity.clamped(0.0, 1.0)
    c.waveformWindowSecs = c.waveformWindowSecs.clamped(0.1, 30)
    c.peakDecayDbPerSec = c.peakDecayDbPerSec.clamped(0.1, 120)
    c.waveformGain = c.waveformGain.clamped(0.1, 100)
    if c.logEvery < 0 { c.logEvery = 0 }
    c.configPath = (c.configPath as NSString).expandingTildeInPath
    c.socketPath = (c.socketPath as NSString).expandingTildeInPath
    return c
  }
}

// MARK: - LevelReader (the daemon IPC half of src/osd/ipc.rs)
//
// A dedicated thread doing blocking connect(2)/read(2) on AF_UNIX/SOCK_STREAM,
// accumulating into a 16-byte staging buffer (short reads are normal) and
// handing decoded frames to a callback on that thread. On EOF or error it
// sleeps --reconnect-secs and reconnects BY PATH forever: daemon restarts
// replace the socket inode, so re-connect() is the only correct recovery.
// This loop NEVER exits on transient conditions -- the process is meant to
// outlive any number of daemon restarts (and under KeepAlive a non-zero exit
// would respawn every 10 s forever).

final class LevelReader {
  let cfg: Config
  var onFrame: ((AudioFrame) -> Void)?
  var onStatus: ((String) -> Void)?

  init(cfg: Config) { self.cfg = cfg }

  func start() {
    let thread = Thread { [self] in self.runLoop() }
    thread.name = "voxtype-osd-ipc"
    thread.start()
  }

  private func runLoop() {
    let delay = max(0.05, cfg.reconnectSecs)
    var layoutWarned = false
    while true {
      let fd = LevelReader.connectUnixSocket(cfg.socketPath)
      if fd < 0 {
        onStatus?("cannot connect to \(cfg.socketPath); retrying every \(delay) s")
        Thread.sleep(forTimeInterval: delay)
        continue
      }
      onStatus?("connected to daemon at \(cfg.socketPath)")
      layoutWarned = false
      readFrames(fd, layoutWarned: &layoutWarned)
      close(fd)
      onStatus?("audio socket closed; reconnecting in \(delay) s")
      Thread.sleep(forTimeInterval: delay)
    }
  }

  /// One connection's read loop; returns when the connection ends.
  private func readFrames(_ fd: Int32, layoutWarned: inout Bool) {
    var staging = [UInt8]()
    staging.reserveCapacity(64)
    var buf = [UInt8](repeating: 0, count: 4096)
    var frames: UInt64 = 0
    let started = DispatchTime.now()
    let logEvery = cfg.logEvery

    while true {
      let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
        read(fd, ptr.baseAddress, ptr.count)
      }
      if n == 0 {
        onStatus?("daemon closed the socket (EOF)")
        return
      }
      if n < 0 {
        if errno == EINTR { continue }
        onStatus?("read error on audio socket: \(String(cString: strerror(errno)))")
        return
      }
      staging.append(contentsOf: buf[0..<n])
      while staging.count >= 16 {
        if let frame = decodeFrame(staging, at: 0) {
          onFrame?(frame)
          frames += 1
          if logEvery > 0 && frames % UInt64(logEvery) == 0 {
            let secs = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e9
            onStatus?("\(frames) frames in \(String(format: "%.1f", secs)) s (\(String(format: "%.0f", Double(frames) / Swift.max(secs, 0.001))) fps)")
          }
        } else if !layoutWarned {
          layoutWarned = true
          onStatus?("frame rejected: |min| or |max| beyond 1.5 -- has the daemon's 16-byte frame layout changed? Going quiet about it.")
        }
        staging.removeFirst(16)
      }
    }
  }

  /// Blocking connect to a Unix domain socket by path. -1 on failure.
  static func connectUnixSocket(_ path: String) -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return -1 }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    guard pathBytes.count < 104 else {
      close(fd)
      return -1
    }
    withUnsafeMutableBytes(of: &addr.sun_path) { dst in
      dst.copyBytes(from: pathBytes)
    }
    // sockaddr_un zero-initialises, so sun_path is NUL-terminated already.
    let ok = withUnsafePointer(to: &addr) { ptr -> Int32 in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard ok == 0 else {
      close(fd)
      return -1
    }
    return fd
  }
}

// MARK: - StateWatcher
//
// kqueue (via DispatchSource) on TWO descriptors:
//
//   * the state FILE for content changes (.write/.extend) -- measured on
//     this machine, a directory watch alone is NOT enough: macOS fires a
//     directory's NOTE_WRITE when entries come and go, but an in-place
//     fs::write to an existing file does not reliably re-fire it (the
//     recording->recording edge fired; recording->idle did not), which left
//     the panel pinned until the frozen-watchdog tore it down.
//   * the DIRECTORY for entry lifecycle (.write/.delete/.rename) -- covers
//     the file being replaced atomically, removed, or recreated, and lets
//     the file watch re-attach when that happens.
//
// The handler re-reads the file on every event and reports only actual
// changes. No polling anywhere.

final class StateWatcher {
  private let dirPath: String
  private let filePath: String
  private var dirSource: DispatchSourceFileSystemObject?
  private var fileSource: DispatchSourceFileSystemObject?
  private var reopenItem: DispatchWorkItem?
  private(set) var current: String?
  var onChange: ((String?) -> Void)?

  /// Path of the state file to watch; nil disables the watcher entirely.
  init?(stateFilePath: String?) {
    guard let p = stateFilePath else { return nil }
    filePath = p
    dirPath = (p as NSString).deletingLastPathComponent
  }

  func start() {
    readState()
    openDirSource()
    openFileSource()
  }

  // --- the file: content changes ------------------------------------------

  private func openFileSource() {
    let fd = open(filePath, O_EVTONLY)
    guard fd >= 0 else {
      scheduleReopen()
      return
    }
    let src = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
    src.setEventHandler { [weak self] in
      guard let self else { return }
      let ev = self.fileSource?.data ?? []
      if ev.contains(.delete) || ev.contains(.rename) {
        // The inode we hold is gone; re-attach by path once the replacement
        // lands (the dir watch meanwhile reports the change itself).
        self.closeFileSource()
        self.readState()
        self.scheduleReopen()
        return
      }
      self.readState()
    }
    src.setCancelHandler { close(fd) }
    fileSource = src
    src.resume()
  }

  private func closeFileSource() {
    fileSource?.cancel()
    fileSource = nil
  }

  // --- the directory: entry lifecycle ---------------------------------------

  private func openDirSource() {
    let fd = open(dirPath, O_EVTONLY)
    guard fd >= 0 else {
      scheduleReopen()
      return
    }
    let src = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
    src.setEventHandler { [weak self] in
      guard let self else { return }
      let ev = self.dirSource?.data ?? []
      if ev.contains(.delete) || ev.contains(.rename) {
        self.closeDirSource()
        self.readState()
        // Both descriptors may be gone with the directory; the shared retry
        // re-attaches each one that is still nil.
        self.scheduleReopen()
        return
      }
      // Entry-level churn: the state file may have been (re)created.
      if self.fileSource == nil {
        self.openFileSource()
      }
      self.readState()
    }
    src.setCancelHandler { close(fd) }
    dirSource = src
    src.resume()
  }

  private func closeDirSource() {
    dirSource?.cancel()
    dirSource = nil
  }

  // --- shared reopen backoff ------------------------------------------------

  private func scheduleReopen() {
    // One shared retry every 2 s is enough: it re-opens whichever source is
    // still nil, and the daemon rewrites state (and recreates /tmp/voxtype)
    // on its next transition either way.
    guard reopenItem == nil else { return }
    let item = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.reopenItem = nil
      if self.dirSource == nil { self.openDirSource() }
      if self.fileSource == nil { self.openFileSource() }
    }
    reopenItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: item)
  }

  private func readState() {
    let value = (try? String(contentsOfFile: filePath, encoding: .utf8))?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let next = (value?.isEmpty == false) ? value : nil
    if next != current {
      current = next
      onChange?(next)
    }
  }
}

// MARK: - Panel geometry
//
/// Pure function so the maths is testable: horizontally centred in the
/// visible frame; top edge at topMargin of the FULL screen height (gtk4
/// frontend parity: `top_margin x monitor_height`), then clamped into the
/// visible frame. Upstream's numbers are physical pixels on a 1x output;
/// treating them as points reads identically on a Retina display and lets
/// AppKit handle the backing scale.
func panelFrame(screenFrame: CGRect, visibleFrame: CGRect, width: Double, height: Double,
                topMargin: Double) -> CGRect {
  let w = CGFloat(width), h = CGFloat(height)
  var x = visibleFrame.midX - w / 2
  if x + w > visibleFrame.maxX { x = visibleFrame.maxX - w }
  if x < visibleFrame.minX { x = visibleFrame.minX }
  var y = screenFrame.minY + screenFrame.height * CGFloat(topMargin) - h
  y = Swift.min(y, visibleFrame.maxY - h)
  y = Swift.max(y, visibleFrame.minY)
  return CGRect(x: x, y: y, width: w, height: h)
}

// MARK: - OSDView
//
/// Everything is plain CoreGraphics in draw(_:) -- no Metal, no layer tree.
/// The controller publishes a RenderState on the main thread before setting
/// needsDisplay; draw() only reads it.

enum DrawMode {
  case live  // frames flowing: full-rate redraws
  case frozen  // no frames, state still says recording: keep the last picture
  case transcribing  // no frames, state says transcribing: dimmed + label, 10 Hz
}

struct RenderState {
  var columns: [EnvelopeColumn]
  var peakDbfs: Float
  var heldDbfs: Float
  var mode: DrawMode
  var gain: Float
  var opacity: Float  // multiplies the palette background alpha
}

final class OSDView: NSView {
  var render: RenderState?
  var palette = Palette()

  override func draw(_ dirtyRect: NSRect) {
    guard let ctx = NSGraphicsContext.current?.cgContext, let r = render else { return }
    let w = bounds.width, h = bounds.height
    guard w > 0, h > 0 else { return }

    // Background. Upstream clears with palette.background (alpha 0.85);
    // `opacity` is parsed-but-unused in BOTH shipped frontends -- here it
    // scales the background alpha, reducing to upstream's behaviour at 1.0.
    let bg = palette.background
    ctx.setFillColor(
      CGColor(
        red: CGFloat(bg.r), green: CGFloat(bg.g), blue: CGFloat(bg.b),
        alpha: CGFloat(bg.a * r.opacity)))
    ctx.fill(bounds)

    // Layout, verbatim from voxtype_osd_native draw_ui: meter on the right
    // max(width*0.05, 8), waveform gets the rest minus a 4 pt gap.
    let meterW = Swift.max(w * 0.05, 8)
    let waveformW = w - meterW - 4

    drawWaveform(ctx, w: waveformW, h: h, r: r)
    drawMeter(ctx, x0: w - meterW, w: meterW, h: h, r: r)

    if r.mode == .transcribing {
      drawTranscribingLabel(ctx, w: waveformW, h: h)
    }
  }

  private func drawWaveform(_ ctx: CGContext, w: CGFloat, h: CGFloat, r: RenderState) {
    guard w >= 1, !r.columns.isEmpty else { return }
    let n = r.columns.count
    let colW = w / CGFloat(n)
    let midY = h / 2
    let halfH = h * 0.45

    // One closed polygon: top boundary left-to-right, bottom right-to-left.
    // CG here is bottom-left origin (non-flipped view), so positive max
    // draws upward from the centreline -- the mirror of egui's y-down math,
    // same picture. Gain, then clamp to +-1, then map to +-45% of height.
    let path = CGMutablePath()
    for i in 0..<n {
      let x = (CGFloat(i) + 0.5) * colW
      let y = midY + CGFloat((r.columns[i].max * r.gain).clamped(-1, 1)) * halfH
      if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    for i in stride(from: n - 1, through: 0, by: -1) {
      let x = (CGFloat(i) + 0.5) * colW
      let y = midY + CGFloat((r.columns[i].min * r.gain).clamped(-1, 1)) * halfH
      path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()

    let fillAlpha: Float = (r.mode == .transcribing) ? 0.35 : 1.0
    ctx.addPath(path)
    ctx.setFillColor(palette.accent.withAlpha(fillAlpha).cg)
    ctx.fillPath()

    // Centreline tick for visual reference at low levels: 1 pt at 25% alpha.
    ctx.setStrokeColor(palette.foreground.withAlpha(0.25).cg)
    ctx.setLineWidth(1)
    ctx.move(to: CGPoint(x: 0, y: midY))
    ctx.addLine(to: CGPoint(x: w, y: midY))
    ctx.strokePath()
  }

  private func drawMeter(_ ctx: CGContext, x0: CGFloat, w: CGFloat, h: CGFloat, r: RenderState) {
    let segments = 10
    let floorDbfs: Float = -60
    let segH = h / CGFloat(segments)
    let gap = Swift.min(Swift.max(segH * 0.15, 1), 3)
    let innerW = w - 4
    let litFraction = peakMeterFraction(r.peakDbfs, floorDbfs: floorDbfs)
    let litSegments = Int((litFraction * Float(segments)).rounded())

    for i in 0..<segments {
      // Segment 0 is the BOTTOM of the bar (low dB == bottom).
      let y0 = CGFloat(i) * segH + gap / 2
      let y1 = CGFloat(i + 1) * segH - gap / 2
      let rect = CGRect(x: x0 + 2, y: y0, width: innerW, height: Swift.max(y1 - y0, 0))
      // egui's rect_filled uses 1 px rounding on these segments.
      let path = CGPath(
        roundedRect: rect, cornerWidth: Swift.min(1, rect.width / 2),
        cornerHeight: Swift.min(1, rect.height / 2), transform: nil)
      let segmentPeakDbfs = floorDbfs * (1 - Float(i) / Float(segments))
      let base = palette.zoneColor(MeterZone.fromDbfs(segmentPeakDbfs))
      ctx.addPath(path)
      ctx.setFillColor((i < litSegments ? base : base.withAlpha(0.18)).cg)
      ctx.fillPath()
    }

    // Held-peak tick: a thin 2 pt bar in the foreground colour.
    let heldFraction = peakMeterFraction(r.heldDbfs, floorDbfs: floorDbfs)
    if heldFraction > 0 {
      let y = CGFloat(heldFraction) * h
      ctx.setFillColor(palette.foreground.cg)
      ctx.fill(CGRect(x: x0 + 2, y: CGFloat(y) - 1, width: innerW, height: 2))
    }
  }

  private func drawTranscribingLabel(_ ctx: CGContext, w: CGFloat, h: CGFloat) {
    let text = NSAttributedString(
      string: "transcribing…",
      attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
        .foregroundColor: NSColor(cgColor: palette.foreground.withAlpha(0.8).cg)!,
      ])
    let size = text.size()
    text.draw(at: CGPoint(x: (w - size.width) / 2, y: h / 2 - size.height / 2))
  }
}

// MARK: - NonKeyPanel

/// An NSPanel that structurally cannot take keyboard focus.
///
/// `canBecomeKey` and `canBecomeMain` are computed from the style mask, and
/// for `[.borderless, .nonactivatingPanel]` AppKit already answers false to
/// both. Overriding them pins that answer to the class instead of to the
/// mask, so a later edit to the mask cannot quietly send a dictation into
/// the OSD instead of the text field the user is looking at.
final class NonKeyPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

// MARK: - OSDController
//
/// Visibility policy, panel lifecycle, and the redraw timer.
///
///   first frame after idle  -> build/position panel, orderFrontRegardless,
///                              start the 16 ms redraw timer
///   frames flowing          -> redraw at ~60 fps (only on new seq)
///   0.5 s no frame, state
///   `transcribing`          -> freeze last envelope at 35% alpha, label,
///                              10 Hz timer
///   0.5 s no frame, state
///   `idle`/absent           -> orderOut, stop the timer: zero timers, zero
///                              CPU until the next frame arrives
///
/// The 0.5 s figure is upstream's IDLE_TEARDOWN_SECS. Two additions the
/// state file buys: the transcribing arm, and a frozen arm for the ~0.2 s
/// the state file lags behind the stopped frames at the end of a recording
/// (0.5 s grace would otherwise flicker the panel away and back). A 2 s
/// watchdog bounds the frozen arm so a daemon killed with SIGKILL -- which
/// leaves a stale `recording` behind -- cannot pin the panel on screen
/// forever.

final class OSDController {
  let cfg: Config
  let palette = Palette()
  let ring = FrameRing(capacity: 300)  // 3.0 s at 100 Hz (DEFAULT_RING_DEPTH)
  let peakHold: LockedPeakHold
  private var stateWatcher: StateWatcher?

  private var panel: NSPanel?
  private var view: OSDView?
  private var visible = false
  private var mode: DrawMode = .live
  private var lastDrawnSeq: UInt64 = 0
  private var needsForcedRedraw = false
  private var timer: DispatchSourceTimer?
  private var frameSignal: DispatchSourceUserDataAdd?
  private var reader: LevelReader?

  init(cfg: Config) {
    self.cfg = cfg
    self.peakHold = LockedPeakHold(decayDbPerSec: Float(cfg.peakDecayDbPerSec))
  }

  func start() {
    if NSScreen.main == nil && NSScreen.screens.isEmpty {
      // Not fatal (see the failure-mode table): with no screen the panel
      // simply never shows, and didChangeScreenParameters picks it up when
      // one appears. Exiting non-zero here would crash-loop under
      // KeepAlive -- the llama-server-run trap.
      log("no screens visible right now; the panel will wait for one")
    }

    // Screen plugged/unplugged: re-resolve and reposition (or hide).
    NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.screenParametersChanged()
    }

    // Frame arrival wakes the main thread; add() coalesces, so calling it
    // 100x/s from the reader thread is fine (calloop ping upstream).
    let signal = DispatchSource.makeUserDataAddSource(queue: .main)
    signal.setEventHandler { [weak self] in self?.framesAvailable() }
    signal.resume()
    frameSignal = signal

    if let watcher = StateWatcher(stateFilePath: cfg.resolvedStateFile()) {
      watcher.onChange = { state in
        log("daemon state: \(state ?? "(none)")")
      }
      watcher.start()
      stateWatcher = watcher
    } else {
      log("state_file disabled; no transcribing state, plain 0.5 s teardown")
    }

    let r = LevelReader(cfg: cfg)
    r.onFrame = { [weak self] frame in
      guard let self else { return }
      self.ring.push(frame)
      self.peakHold.update(peakDbfs: frame.peakDbfs)
      self.frameSignal?.add(data: 1)
    }
    r.onStatus = { message in log(message) }
    r.start()
    reader = r
  }

  // --- show/hide ------------------------------------------------------------

  private func framesAvailable() {
    if !visible { show() }
  }

  private func show() {
    let p = ensurePanel()
    guard positionPanel() else {
      // No screen to draw on right now; stay hidden, retry on next frame.
      return
    }
    visible = true
    mode = .live
    // NEVER makeKeyAndOrderFront -- see the panel construction below.
    p.orderFrontRegardless()
    setTimerInterval(16)
    needsForcedRedraw = true
    renderNow()
  }

  private func hide() {
    panel?.orderOut(nil)
    stopTimer()
    visible = false
  }

  private func screenParametersChanged() {
    guard visible else { return }
    _ = positionPanel()
    needsForcedRedraw = true
  }

  /// Resolve the screen at show time and clamp the frame into its visible
  /// area. Returns false when there is no screen at all.
  private func positionPanel() -> Bool {
    guard let screen = NSScreen.main ?? NSScreen.screens.first, let p = panel else { return false }
    p.setFrame(
      panelFrame(
        screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
        width: cfg.widthPx, height: cfg.heightPx, topMargin: cfg.topMargin),
      display: false)
    return true
  }

  // --- the one safety-critical construction ----------------------------------
  //
  // The daemon types the transcription into whatever holds focus. An OSD
  // that activates sends dictated text to the wrong window, so every
  // property below is required, not stylistic:
  //   * .accessory app policy: no Dock icon, no menu bar to steal focus.
  //   * .nonactivatingPanel + borderless: the panel can never become key.
  //   * orderFrontRegardless(): shows WITHOUT activating the app.
  //   * ignoresMouseEvents: clicks pass through to whatever is underneath.
  // The binary-level guarantee this buys is checked by hand: click into a
  // text field, keep typing while a recording runs -- every character must
  // land in the field.
  //
  // NonKeyPanel makes the first of those structural rather than incidental.
  // Measured: a bare NSPanel([.borderless, .nonactivatingPanel]) already
  // reports canBecomeKey=false, canBecomeMain=false -- so these overrides
  // change nothing today. They exist because that answer is a property of
  // the style mask, and the day someone adds .titled or .resizable to get a
  // drag handle, AppKit's default flips back to true and the dictation lands
  // in the wrong window. The override cannot flip.
  private func ensurePanel() -> NSPanel {
    if let p = panel { return p }
    let rect = NSRect(x: 0, y: 0, width: cfg.widthPx, height: cfg.heightPx)
    let p = NonKeyPanel(
      contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    p.isFloatingPanel = true
    p.level = .statusBar
    p.collectionBehavior = [
      .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
    ]
    p.ignoresMouseEvents = true
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = false
    p.hidesOnDeactivate = false
    p.title = "voxtype-osd"
    let v = OSDView(frame: rect)
    v.palette = palette
    p.contentView = v
    view = v
    panel = p
    return p
  }

  // --- redraw ------------------------------------------------------------------

  private func setTimerInterval(_ ms: Int) {
    stopTimer()
    let t = DispatchSource.makeTimerSource(queue: .main)
    t.schedule(
      deadline: .now() + .milliseconds(ms), repeating: .milliseconds(ms),
      leeway: .milliseconds(2))
    t.setEventHandler { [weak self] in self?.tick() }
    t.resume()
    timer = t
  }

  private func stopTimer() {
    timer?.cancel()
    timer = nil
  }

  private func tick() {
    guard visible else { stopTimer(); return }
    let age = ring.sinceLastFrame() ?? .infinity
    let state = stateWatcher?.current

    let next: DrawMode
    if age < 0.5 {
      next = .live
    } else if state == "transcribing" {
      next = .transcribing
    } else if (state == "recording" || state == "streaming") && age < 2.0 {
      next = .frozen
    } else {
      // idle, stopped, unknown, or a `recording` state whose feed died
      // (a SIGKILLed daemon leaves a stale state file behind).
      hide()
      return
    }

    if next != mode {
      mode = next
      setTimerInterval(next == .transcribing ? 100 : 16)
      needsForcedRedraw = true
    }

    // Redraw only when a new frame actually arrived (or a mode change
    // forces it) -- the timer itself is nearly free.
    let seq = UInt64(ring.latestSeq ?? 0)
    if seq != lastDrawnSeq || needsForcedRedraw {
      lastDrawnSeq = seq
      needsForcedRedraw = false
      renderNow()
    }
  }

  private func renderNow() {
    guard let view else { return }
    var frames = ring.snapshot()
    let windowN = min(frames.count, Int((cfg.waveformWindowSecs * 100).rounded()))
    if frames.count > windowN {
      frames = Array(frames[(frames.count - windowN)...])
    }
    // Column count: the native frontend's n_columns = max(waveform_w, 32).
    let meterW = max(cfg.widthPx * 0.05, 8)
    let waveformW = cfg.widthPx - meterW - 4
    let nColumns = max(Int(waveformW.rounded()), 32)

    view.render = RenderState(
      columns: projectEnvelope(frames, nColumns: nColumns),
      peakDbfs: frames.last?.peakDbfs ?? -120,
      heldDbfs: peakHold.heldDbfs,
      mode: mode,
      gain: Float(cfg.waveformGain),
      opacity: Float(cfg.opacity))
    view.needsDisplay = true
  }
}

// MARK: - Selftest
//
// The ported math, the frame codec, and the geometry clamp, against the
// same cases upstream's own unit tests pin (visual.rs tests, ipc.rs ring
// tests) plus the macOS-specific additions. No GUI, no socket; safe over
// SSH or in CI.

struct Selftest {
  private static var failures = 0

  private static func check(_ name: String, _ cond: Bool) {
    print("\(cond ? "PASS" : "FAIL")  \(name)")
    if !cond { failures += 1 }
  }

  private static func approxEq(_ a: Float, _ b: Float, tol: Float = 1e-6) -> Bool {
    abs(a - b) <= tol
  }

  static func run() -> Int32 {
    // project_envelope: partial input stretches to fill (no silent left
    // edge), newest frame lands in the last column, oldest in the first.
    do {
      let frames = [
        AudioFrame(seq: 0, min: -0.1, max: 0.1, peakDbfs: -20),
        AudioFrame(seq: 1, min: -0.2, max: 0.2, peakDbfs: -14),
      ]
      let cols = projectEnvelope(frames, nColumns: 5)
      check("envelope-partial-stretches", cols.count == 5 && cols.allSatisfy { $0 != .silent })
      check("envelope-partial-first-is-oldest", cols[0] == EnvelopeColumn(min: -0.1, max: 0.1))
      check("envelope-partial-last-is-newest", cols[4] == EnvelopeColumn(min: -0.2, max: 0.2))
    }

    // project_envelope: full input aggregates per bucket.
    do {
      let frames = (0..<10).map {
        AudioFrame(seq: UInt32($0), min: -Float($0) * 0.1, max: Float($0) * 0.1, peakDbfs: -20)
      }
      let cols = projectEnvelope(frames, nColumns: 5)
      check("envelope-aggregates-first", approxEq(cols[0].min, -0.1) && approxEq(cols[0].max, 0.1))
      check("envelope-aggregates-last", approxEq(cols[4].min, -0.9) && approxEq(cols[4].max, 0.9))
    }

    // project_envelope: empty input yields silence everywhere.
    do {
      let cols = projectEnvelope([], nColumns: 4)
      check("envelope-empty-yields-silence", cols.count == 4 && cols.allSatisfy { $0 == .silent })
    }

    // PeakHold: snaps up instantly, decays linearly, floors at -120.
    do {
      var hold = PeakHold(decayDbPerSec: 6)
      hold.update(currentPeakDbfs: -10, dtSecs: 0.01)
      check("peak-hold-snaps-up", approxEq(hold.heldDbfs, -10))
      hold.update(currentPeakDbfs: -3, dtSecs: 0.01)
      check("peak-hold-snaps-up-again", approxEq(hold.heldDbfs, -3))
      hold.update(currentPeakDbfs: -30, dtSecs: 1.0)
      check("peak-hold-decays-linearly", approxEq(hold.heldDbfs, -9, tol: 1e-3))
      var held: Float = -10
      updatePeakHold(currentPeak: -100, held: &held, decayDbPerSec: 6, dtSecs: 1000)
      check("peak-hold-floor-at-minus-120", held == -120)
    }

    // peak_meter_fraction: floor maps to 0, 0 dBFS to 1, midpoint to ~0.5,
    // silence and -inf clamp to 0.
    check("meter-fraction-floor", peakMeterFraction(-60, floorDbfs: -60) == 0)
    check("meter-fraction-full", peakMeterFraction(0, floorDbfs: -60) == 1)
    check("meter-fraction-mid", approxEq(peakMeterFraction(-30, floorDbfs: -60), 0.5, tol: 1e-3))
    check("meter-fraction-silence", peakMeterFraction(-120, floorDbfs: -60) == 0)
    check(
      "meter-fraction-neg-inf", peakMeterFraction(-Float.infinity, floorDbfs: -60) == 0)

    // Meter zones: >= -3 high, >= -12 mid, else low (boundary values in the
    // upper class, exactly as upstream's test pins them).
    check("meter-zone-low", MeterZone.fromDbfs(-30) == .low)
    check("meter-zone-mid-boundary", MeterZone.fromDbfs(-12) == .mid)
    check("meter-zone-mid", MeterZone.fromDbfs(-6) == .mid)
    check("meter-zone-high-boundary", MeterZone.fromDbfs(-3) == .high)
    check("meter-zone-high", MeterZone.fromDbfs(0) == .high)

    // Frame codec: little-endian round trip.
    do {
      let f = AudioFrame(seq: 42, min: -0.25, max: 0.75, peakDbfs: -12.5)
      let bytes = encodeFrameLE(f)
      let back = decodeFrame(bytes, at: 0)
      check("frame-roundtrip", back == f)
    }

    // Frame codec: partial bytes accumulate correctly -- the same
    // append-then-drain staging loop the reader thread runs.
    do {
      let f = AudioFrame(seq: 7, min: -0.5, max: 0.5, peakDbfs: -6)
      var staging = [UInt8]()
      var decoded: AudioFrame?
      for b in encodeFrameLE(f) {
        staging.append(b)
        while staging.count >= 16 {
          decoded = decodeFrame(staging, at: 0)
          staging.removeFirst(16)
        }
      }
      check("frame-partial-bytes", decoded == f)
    }

    // Frame codec: |min| or |max| beyond 1.5 rejects (layout change).
    do {
      let bad = AudioFrame(seq: 1, min: -3.5, max: 0.1, peakDbfs: -20)
      check("frame-rejects-layout-garbage", decodeFrame(encodeFrameLE(bad), at: 0) == nil)
    }

    // Frame codec: NaN/inf sanitised, not rejected.
    do {
      let nan = AudioFrame(seq: 2, min: Float.nan, max: Float.infinity, peakDbfs: Float.nan)
      let out = decodeFrame(encodeFrameLE(nan), at: 0)
      check(
        "frame-sanitizes-non-finite",
        out != nil && out!.min == 0 && out!.max == 0 && out!.peakDbfs == -120)
    }

    // Ring: 6 pushes into 4 slots keep the newest 4, oldest-first, and
    // latest() reports the last seq.
    do {
      let ring = FrameRing(capacity: 4)
      for i in 0..<6 { ring.push(AudioFrame(seq: UInt32(i), min: -0.1, max: 0.1, peakDbfs: -20)) }
      let seqs = ring.snapshot().map { $0.seq }
      check("ring-oldest-first-when-full", seqs == [2, 3, 4, 5])
      check("ring-latest", ring.latestSeq == 5)
      check("ring-partial", { () -> Bool in
        let r = FrameRing(capacity: 8)
        r.push(AudioFrame(seq: 7, min: 0, max: 0, peakDbfs: -120))
        r.push(AudioFrame(seq: 8, min: 0, max: 0, peakDbfs: -120))
        return r.snapshot().map { $0.seq } == [7, 8]
      }())
    }

    // Config scanner: [osd] scalars, top-level state_file, quoted values,
    // comments, unknown sections ignored, `enabled` never surfaced.
    do {
      let text = """
        # voxtype config
        state_file = "auto"   # top-level

        [whisper]
        language = "en"

        [osd]
        enabled = false
        frontend = "gtk4"
        width_px = 512
        height_px = 64
        top_margin = 0.9
        opacity = 0.5
        waveform_gain = 12.5

        [[osd.visual.layers]]
        type = "bars"
        """
      let p = parseTomlScalars(text)
      check("toml-top-level", p.top["state_file"] == "auto")
      check("toml-osd-scalars", p.osd["width_px"] == "512" && p.osd["top_margin"] == "0.9"
        && p.osd["opacity"] == "0.5" && p.osd["waveform_gain"] == "12.5")
      check("toml-ignores-other-sections", p.top["language"] == nil)
      check(
        "toml-ignores-array-sections", p.osd["type"] == nil && p.osd["bars"] == nil)
    }

    // Geometry: centred horizontally, top edge at topMargin of the screen
    // height, clamped into the visible frame.
    do {
      let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
      let visible = CGRect(x: 0, y: 38, width: 1512, height: 982 - 38 - 21)
      let f = panelFrame(
        screenFrame: screen, visibleFrame: visible, width: 400, height: 48, topMargin: 0.85)
      check(
        "geometry-top-margin",
        abs(f.maxY - screen.height * 0.85) < 0.001 && abs(f.midX - visible.midX) < 0.001)
      // A clamping case: topMargin 1.0 would push the panel into the menu
      // bar; it must be pulled down to the visible frame's top edge.
      let g = panelFrame(
        screenFrame: screen, visibleFrame: visible, width: 400, height: 48, topMargin: 1.0)
      check("geometry-clamps-into-visible", g.maxY <= visible.maxY && g.minY >= visible.minY)
      // A panel wider than the visible frame cannot fit; it must left-align
      // at the visible frame's edge rather than spill off a negative origin.
      let wide = panelFrame(
        screenFrame: screen, visibleFrame: visible, width: 4096, height: 48, topMargin: 0.85)
      check(
        "geometry-clamps-width", wide.minX == visible.minX)
    }

    print(failures == 0 ? "selftest: all cases passed" : "selftest: \(failures) case(s) FAILED")
    return failures == 0 ? 0 : 1
  }
}

// MARK: - Probe
//
// Connect and print decoded frames as text so the socket half can be proven
// live without a window. No GUI, no NSApplication -- safe over SSH.

enum Probe {
  static func run(secs: Double, cfg: Config) -> Int32 {
    setvbuf(stdout, nil, _IONBF, 0)
    let reader = LevelReader(cfg: cfg)
    let sem = DispatchSemaphore(value: 0)
    var count = 0
    reader.onFrame = { frame in
      count += 1
      print(
        "seq=\(frame.seq) min=\(String(format: "%.4f", frame.min)) "
          + "max=\(String(format: "%.4f", frame.max)) "
          + "peak=\(String(format: "%.1f", frame.peakDbfs)) dBFS")
    }
    reader.onStatus = { message in log(message) }
    reader.start()
    _ = sem.wait(timeout: .now() + secs)
    print("probe: \(count) frames in \(secs) s")
    return 0
  }
}

// MARK: - Render
//
// Write one panel frame to a PNG through the same OSDView.draw() the live
// panel uses, so a picture in the docs cannot quietly drift from what the
// renderer actually paints.
//
// No window, no socket, and no NSApplication: an NSBitmapImageRep is the
// only drawing surface, which is what lets this run beside --selftest on a
// terminal-less CI runner. The panel is drawn at its configured point size
// and scaled up by --render-scale, the same way a Retina display samples it.
//
// The frames are synthetic and DETERMINISTIC, for two reasons. A capture of
// real dictation would carry whatever the microphone happened to hear into a
// public repository; and a fixed seed means regenerating the images produces
// byte-identical files rather than a diff on every run.

enum Render {
  /// The two states worth a picture. `idle` is not one of them: the live
  /// panel is ordered out entirely when the daemon goes idle, so its honest
  /// screenshot is an empty desktop.
  static let states = ["recording", "transcribing"]

  /// A 64-bit LCG (Numerical Recipes constants). Not for anything that
  /// matters -- it exists so the waveform is reproducible across machines,
  /// which SystemRandomNumberGenerator explicitly is not.
  private struct LCG {
    var state: UInt64
    /// Next value in 0..<1, taken from the high bits: the low bits of an LCG
    /// have short periods, and the lowest bit of this one simply alternates.
    mutating func unit() -> Float {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Float(state >> 40) / Float(1 << 24)
    }
  }

  /// `count` frames of plausible speech: a syllabic envelope filled with
  /// noise, at the amplitudes a real microphone produces -- loudest peaks
  /// near 0.10 linear, about -20 dBFS, which lands the meter in its green
  /// zone rather than pinned and leaves the waveform just short of the
  /// clamp. The waveform is drawn with gain 10 by default, which is why
  /// these numbers look small next to a full-scale +-1.
  static func syntheticFrames(count: Int, seed: UInt64) -> [AudioFrame] {
    var rng = LCG(state: seed &* 2_862_933_555_777_941_757 &+ 3_037_000_493)
    var out = [AudioFrame]()
    out.reserveCapacity(count)
    for i in 0..<count {
      let t = Float(i) / 100.0  // the daemon's frame rate, 100 Hz
      // Two detuned syllable rates beating against each other, so the
      // envelope does not repeat visibly across a 3 s window.
      let syllable = (sinf(t * 2 * .pi * 3.1) * 0.5 + 0.5) * (sinf(t * 2 * .pi * 0.7) * 0.35 + 0.65)
      // A breath: one gap in the middle, where a speaker would pause.
      let gap: Float = (t > 1.32 && t < 1.55) ? 0.05 : 1.0
      let envelope = syllable * gap
      let amp = (0.010 + envelope * 0.072) * (0.75 + rng.unit() * 0.5)
      // min/max are not symmetric in real speech; skew them slightly.
      let mx = amp * (0.85 + rng.unit() * 0.3)
      let mn = -amp * (0.85 + rng.unit() * 0.3)
      let linear = Swift.max(abs(mn), abs(mx))
      let peak = linear > 0 ? 20 * log10f(linear) : -120
      out.append(AudioFrame(seq: UInt32(i), min: mn, max: mx, peakDbfs: peak))
    }
    return out
  }

  /// Parse `#rrggbb` / `rrggbb` into a CGColor. Returns nil for "none".
  static func parseBackdrop(_ spec: String) -> CGColor?? {
    let s = spec.trimmingCharacters(in: .whitespaces).lowercased()
    if s == "none" || s.isEmpty { return .some(nil) }
    let hex = s.hasPrefix("#") ? String(s.dropFirst()) : s
    guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
    return CGColor(
      red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
      blue: CGFloat(v & 0xFF) / 255, alpha: 1)
  }

  /// Load a PNG back as the same RGBA8 bitmap the renderer wrote.
  private static func loadRep(_ path: String) -> NSBitmapImageRep? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return NSBitmapImageRep(data: data)
  }

  /// The region the `transcribing` label occupies, in pixels, generously
  /// oversized: the centre 60% x 60% of the waveform area.
  ///
  /// Deliberately a fixed fraction rather than the text's measured bounds.
  /// The whole reason this rect exists is that font metrics are NOT stable
  /// across macOS versions, so a box derived from `text.size()` would be a
  /// different box on the machine it is meant to reconcile with. The label is
  /// ~94 x 14 pt inside a 376 x 48 pt waveform area; this rect is more than
  /// twice that in each direction.
  static func labelRect(cfg: Config, scale: Double, pad: Double) -> (
    x0: Int, y0: Int, x1: Int, y1: Int
  ) {
    let meterW = Swift.max(cfg.widthPx * 0.05, 8)
    let waveformW = cfg.widthPx - meterW - 4
    let bw = waveformW * 0.6, bh = cfg.heightPx * 0.6
    let x0 = pad + (waveformW - bw) / 2, y0 = pad + (cfg.heightPx - bh) / 2
    return (
      Int((x0 * scale).rounded(.down)), Int((y0 * scale).rounded(.down)),
      Int(((x0 + bw) * scale).rounded(.up)), Int(((y0 + bh) * scale).rounded(.up))
    )
  }

  /// Percentage of pixels that differ between two rendered PNGs, or nil when
  /// they are not even the same shape.
  ///
  /// `ignore` masks out a rectangle. It exists for exactly one reason: the
  /// `transcribing` frame draws a label with the system monospaced font, and
  /// glyph rasterisation is not stable across macOS versions, so CI on
  /// macos-15 and a developer on a newer release disagree on that text while
  /// drawing the same picture. Everything outside the rect still compares
  /// EXACTLY, which is what keeps the check worth running: a global
  /// percentage threshold would have to be set so loose to absorb the font
  /// that an entirely different waveform slips under it (measured: a new seed
  /// moves only 6.8% of this frame, less than the label can).
  static func diffPercent(
    _ pathA: String, _ pathB: String,
    ignore: (x0: Int, y0: Int, x1: Int, y1: Int)? = nil
  ) -> Double? {
    guard let a = loadRep(pathA), let b = loadRep(pathB),
      a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh,
      a.samplesPerPixel == b.samplesPerPixel,
      let da = a.bitmapData, let db = b.bitmapData
    else { return nil }

    let spp = a.samplesPerPixel
    let w = a.pixelsWide, h = a.pixelsHigh
    var differing = 0
    var compared = 0
    for y in 0..<h {
      let rowA = da + y * a.bytesPerRow
      let rowB = db + y * b.bytesPerRow
      for x in 0..<w {
        if let r = ignore, x >= r.x0, x < r.x1, y >= r.y0, y < r.y1 { continue }
        compared += 1
        let off = x * spp
        for c in 0..<spp where rowA[off + c] != rowB[off + c] {
          differing += 1
          break
        }
      }
    }
    guard compared > 0 else { return nil }
    return 100.0 * Double(differing) / Double(compared)
  }

  static func run(
    path: String, state: String, scale: Double, pad: Double, backdrop: String, seed: UInt64,
    compareTo: String?, maxDiffPct: Double, ignoreLabel: Bool, cfg: Config
  ) -> Int32 {
    let mode: DrawMode
    switch state {
    case "recording": mode = .live
    case "transcribing": mode = .transcribing
    default:
      FileHandle.standardError.write(
        "voxtype-osd-macos: unknown --render-state \(state); expected one of \(states.joined(separator: ", "))\n"
          .data(using: .utf8)!)
      return 2
    }
    guard let maybeBackdrop = parseBackdrop(backdrop) else {
      FileHandle.standardError.write(
        "voxtype-osd-macos: --render-bg wants #rrggbb or none, got \(backdrop)\n".data(using: .utf8)!
      )
      return 2
    }

    // Exactly the numbers OSDController.renderNow() computes, so the picture
    // is the live panel's and not an approximation of it.
    let frames = syntheticFrames(count: Int((cfg.waveformWindowSecs * 100).rounded()), seed: seed)
    var hold = PeakHold(decayDbPerSec: Float(cfg.peakDecayDbPerSec))
    for f in frames { hold.update(currentPeakDbfs: f.peakDbfs, dtSecs: 0.01) }
    let meterW = Swift.max(cfg.widthPx * 0.05, 8)
    let waveformW = cfg.widthPx - meterW - 4
    let nColumns = Swift.max(Int(waveformW.rounded()), 32)

    let view = OSDView(frame: NSRect(x: 0, y: 0, width: cfg.widthPx, height: cfg.heightPx))
    view.render = RenderState(
      columns: projectEnvelope(frames, nColumns: nColumns),
      peakDbfs: frames.last?.peakDbfs ?? -120,
      heldDbfs: hold.heldDbfs,
      mode: mode,
      gain: Float(cfg.waveformGain),
      opacity: Float(cfg.opacity))

    let ptW = cfg.widthPx + pad * 2
    let ptH = cfg.heightPx + pad * 2
    let pxW = Int((ptW * scale).rounded())
    let pxH = Int((ptH * scale).rounded())
    guard pxW > 0, pxH > 0,
      let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pxW, pixelsHigh: pxH, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)
    else {
      FileHandle.standardError.write(
        "voxtype-osd-macos: cannot allocate a \(pxW)x\(pxH) bitmap\n".data(using: .utf8)!)
      return 1
    }
    // Point size on a larger pixel grid: NSGraphicsContext derives the scale
    // transform from the ratio, so every coordinate below stays in points.
    rep.size = NSSize(width: ptW, height: ptH)
    guard let gctx = NSGraphicsContext(bitmapImageRep: rep) else {
      FileHandle.standardError.write(
        "voxtype-osd-macos: cannot make a drawing context\n".data(using: .utf8)!)
      return 1
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gctx
    let ctx = gctx.cgContext
    if let bg = maybeBackdrop {
      ctx.setFillColor(bg)
      ctx.fill(CGRect(x: 0, y: 0, width: ptW, height: ptH))
    }
    // The panel is translucent by design; drawing it onto the padded canvas
    // rather than into its own bitmap is what lets the backdrop show through
    // it the way a desktop does.
    ctx.saveGState()
    ctx.translateBy(x: pad, y: pad)
    view.draw(view.bounds)
    ctx.restoreGState()
    gctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
      FileHandle.standardError.write("voxtype-osd-macos: PNG encoding failed\n".data(using: .utf8)!)
      return 1
    }
    do {
      try png.write(to: URL(fileURLWithPath: path))
    } catch {
      FileHandle.standardError.write(
        "voxtype-osd-macos: cannot write \(path): \(error.localizedDescription)\n".data(
          using: .utf8)!)
      return 1
    }
    print("render: \(state) -> \(path) (\(pxW)x\(pxH) px, \(Int(scale))x)")

    guard let reference = compareTo else { return 0 }
    let ignore = ignoreLabel ? labelRect(cfg: cfg, scale: scale, pad: pad) : nil
    guard let pct = diffPercent(path, reference, ignore: ignore) else {
      FileHandle.standardError.write(
        "voxtype-osd-macos: cannot compare \(path) with \(reference) (missing, unreadable, or a different size)\n"
          .data(using: .utf8)!)
      return 1
    }
    let verdict = pct <= maxDiffPct ? "ok" : "STALE"
    let scope = ignore == nil ? "whole frame" : "label region excluded"
    print(
      String(
        format: "compare: %@ %.4f%% of pixels differ from %@ (%@, allowed %.4f%%)", verdict, pct,
        reference, scope, maxDiffPct))
    return pct <= maxDiffPct ? 0 : 1
  }
}

// MARK: - Argument parsing and main

enum RunMode {
  case run, selftest, probe(secs: Double), help
  /// Draw one frame into a PNG and exit; see the Render section.
  case render(path: String)
}

func parseArgs(_ args: [String]) -> (mode: RunMode, flags: [String: String], error: String?) {
  var mode = RunMode.run
  var flags = [String: String]()
  let valued = [
    "config", "socket", "reconnect-secs", "width-px", "height-px", "opacity", "waveform-gain",
    "top-margin", "log-every",
    // --render takes its output path the same way, but also selects a
    // mode, so it is handled separately below.
    "render-state", "render-scale", "render-pad", "render-bg", "render-seed",
    "render-compare", "render-max-diff",
  ]
  var i = 0
  while i < args.count {
    let arg = args[i]
    if arg == "--selftest" {
      mode = .selftest
    } else if arg == "--render" {
      guard i + 1 < args.count else { return (mode, flags, "missing value for --render") }
      mode = .render(path: args[i + 1])
      i += 1
    } else if arg == "--render-ignore-label" {
      flags["render-ignore-label"] = "1"
    } else if arg == "--probe" {
      // Optional value: `--probe 3` or bare `--probe`.
      var secs = 10.0
      if i + 1 < args.count, let v = Double(args[i + 1]), v > 0 {
        secs = v
        i += 1
      }
      mode = .probe(secs: secs)
    } else if arg == "-h" || arg == "--help" {
      mode = .help
    } else if arg.hasPrefix("--"), valued.contains(String(arg.dropFirst(2))) {
      let name = String(arg.dropFirst(2))
      guard i + 1 < args.count else {
        return (mode, flags, "missing value for \(arg)")
      }
      flags[name] = args[i + 1]
      i += 1
    } else {
      return (mode, flags, "unknown flag: \(arg)")
    }
    i += 1
  }
  return (mode, flags, nil)
}

let usage = """
  voxtype-osd-macos -- macOS renderer for the voxtype dictation OSD

  Usage: voxtype-osd-macos [flags]

  Modes:
    (no flags)        draw the OSD panel (run as a LaunchAgent)
    --selftest        run the ported-math unit checks; no GUI, no socket
    --probe [secs]    print decoded audio frames as text; no window
                      (default 10 s)
    --render <png>    draw one frame to a PNG from synthetic, deterministic
                      audio and exit; no window, no socket (docs images)

  Flags (defaults come from ~/.config/voxtype/config.toml [osd], then
  VOXTYPE_OSD_* env vars, then these):
    --config <path>            config file to read [VOXTYPE_CONFIG]
    --socket <path>            audio-frame socket
                                [VOXTYPE_OSD_SOCKET; default /tmp/voxtype/audio.sock]
    --reconnect-secs <f>       daemon-reconnect interval [VOXTYPE_OSD_RECONNECT_SECS]
    --width-px <n>             panel width  [VOXTYPE_OSD_WIDTH]
    --height-px <n>            panel height [VOXTYPE_OSD_HEIGHT]
    --top-margin <f>           top edge as a fraction of screen height [VOXTYPE_OSD_TOP_MARGIN]
    --opacity <f>              background opacity 0..1 [VOXTYPE_OSD_OPACITY]
    --waveform-gain <f>        waveform visual gain  [VOXTYPE_OSD_GAIN]
    --log-every <n>            log frame rate every N frames (0 = quiet)

  Flags for --render only:
    --render-state <s>         recording | transcribing   [recording]
    --render-scale <n>         pixels per point, as a Retina display samples
                               the panel [2]
    --render-pad <pt>          transparent/backdrop margin around the panel [0]
    --render-bg <#rrggbb|none> fill behind the translucent panel [none]
    --render-seed <n>          waveform seed; same seed, same pixels [1]
    --render-compare <png>     after rendering, compare against this file and
                               exit non-zero if they differ by more than
                               --render-max-diff
    --render-max-diff <pct>    percentage of compared pixels allowed to
                               differ [0]
    --render-ignore-label      exclude the transcribing label's region from
                               the comparison. System font rasterisation is
                               not stable across macOS versions; the rest of
                               the panel is, and still compares exactly

  NOTE: [osd] enabled is deliberately ignored by this binary -- on macOS
  `false` is what keeps the daemon from spawning a (nonexistent) frontend
  while this renderer runs as its own LaunchAgent. See the source header.
  """

func main() -> Int32 {
  // Line-buffered stdout: launchd redirects this to a log file, where full
  // buffering would swallow every line if the process is ever SIGKILLed.
  setvbuf(stdout, nil, _IOLBF, 0)
  let (mode, flags, error) = parseArgs(Array(CommandLine.arguments.dropFirst()))
  if let error {
    FileHandle.standardError.write("voxtype-osd-macos: \(error)\n".data(using: .utf8)!)
    FileHandle.standardError.write(usage.data(using: .utf8)!)
    return 2
  }
  switch mode {
  case .help:
    print(usage)
    return 0
  case .selftest:
    return Selftest.run()
  case .probe(let secs):
    return Probe.run(secs: secs, cfg: Config.load(flagOverrides: flags))
  case .render(let path):
    return Render.run(
      path: path,
      state: flags["render-state"] ?? "recording",
      scale: Double(flags["render-scale"] ?? "") ?? 2,
      pad: Double(flags["render-pad"] ?? "") ?? 0,
      backdrop: flags["render-bg"] ?? "none",
      seed: UInt64(flags["render-seed"] ?? "") ?? 1,
      compareTo: flags["render-compare"],
      maxDiffPct: Double(flags["render-max-diff"] ?? "") ?? 0,
      ignoreLabel: flags["render-ignore-label"] == "1",
      cfg: Config.load(flagOverrides: flags))
  case .run:
    let cfg = Config.load(flagOverrides: flags)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let controller = OSDController(cfg: cfg)
    controller.start()
    log(
      "voxtype-osd-macos starting; socket=\(cfg.socketPath), \(Int(cfg.widthPx))x\(Int(cfg.heightPx))"
    )
    // withExtendedLifetime: app.delegate is a weak reference; the local
    // must outlive run(), which never returns.
    let delegate = RunDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) {
      withExtendedLifetime(controller) {
        app.run()
      }
    }
    return 0
  }
}

/// Minimal delegate: nothing to customise, but NSApplication wants one to
/// reach a proper run loop.
final class RunDelegate: NSObject, NSApplicationDelegate {}

exit(main())
