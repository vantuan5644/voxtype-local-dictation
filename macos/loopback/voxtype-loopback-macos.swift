// voxtype-loopback-macos -- the macOS stand-in for the two PulseAudio CLIs
// voxtype's meeting mode shells out to, in one file, built with Command Line
// Tools' swiftc alone. See docs/install-macos.md ("Meeting mode:
// the loopback shim").
//
// WHY THIS BINARY EXISTS. Upstream v1.0.1's src/audio/dual_capture.rs captures
// the remote side of a call by spawning two PulseAudio CLIs:
//
//   pactl list short sources                     (discover a *.monitor source)
//   parec --device <src> --format=float32le \
//         --channels=1 --rate=16000 --raw         (read raw f32 mono 16 kHz)
//
// with zero target_os conditionals. Neither binary exists on macOS, so
// loopback_device = "auto" logs "No monitor source found, using mic only" and
// records half the call. This program impersonates both: it is installed once
// as ~/.local/bin/voxtype-loopback-macos plus two symlinks in the private shim
// directory ~/.local/libexec/voxtype-shims/{pactl,parec}, and dispatches on
// argv[0]:
//
//   pactl list short sources     one hard-coded line naming a monitor source
//                                that "runs" at exactly the contract format
//   parec --device system-audio.monitor --format=float32le --channels=1 \
//        --rate=16000 --raw      a CoreAudio PROCESS TAP (macOS 14.2+):
//                                CATapDescription(mono global) ->
//                                AudioHardwareCreateProcessTap -> private
//                                aggregate (TapList + TapAutoStart) -> IOProc
//                                via AudioDeviceCreateIOProcIDWithBlock,
//                                converted to f32 mono 16 kHz and written raw
//                                to stdout until stdout closes or SIGTERM
//   parec --device <other name>  the same output contract from the named
//                                CoreAudio INPUT device, captured with an
//                                IOProc registered directly on the device
//                                (the BlackHole fallback route; needs only
//                                the Microphone grant the daemon already
//                                holds)
//   voxtype-loopback-macos --self-test [--device NAME] [--seconds N]
//                                capture N seconds (default 3), print RMS and
//                                sample count, exit non-zero on silence
//
// Anything that does not match the contract exactly fails LOUDLY (exit 1 for
// unknown pactl calls, exit 2 for a parec format other than the one triple),
// so a future upstream argument change produces an error instead of garbage.
//
// THE SILENT-ZEROS TRAP, which is why --self-test exists: a process tap
// created without NSAudioCaptureUsageDescription on the *responsible* app
// (for a daemon child, Voxtype.app) returns noErr everywhere and is then
// starved silently -- observed on macOS 26 either as IOProc callbacks that
// never arrive at all, or as callbacks carrying exact zeros. tccd logs the
// query against kTCCServiceAudioCapture ("System Audio Recording") and
// never reports the denial to the caller. install.sh patches the usage key
// into the bundle's Info.plist and verifies with --self-test.
//
// Device changes: the aggregate/tap pair goes SILENT after the default output
// device changes (AirPods connecting mid-call is the realistic trigger), and
// restarting only the IOProc does not recover it. A
// kAudioHardwarePropertyDefaultOutputDevice listener plus an all-zero watchdog
// (5 s of exact zeros after audio has been seen) both request a full rebuild:
// IOProc, aggregate device and tap are torn down and recreated.
//
// Behavioural rules: log to stderr only (the daemon nulls it); exit 0 on
// EPIPE (the reader went away -- that is a normal stop); never buffer more
// than a couple of seconds (the daemon reads continuously; the FIFO drops
// oldest and counts if a stalled reader ever fills it). SIGTERM/SIGINT tear
// everything down and exit 0; SIGKILL is also safe because process taps and
// private aggregates are owned by the process and die with it.
//
// Built with `-swift-version 5`: the realtime IOProc block captures mutable
// state, which Swift 6 mode rejects.

import AVFoundation
import CoreAudio
import Darwin
import Foundation

// MARK: - Constants

let outputSampleRate = 16000.0
let monitorSourceName = "system-audio.monitor"
// What `pactl list short sources` prints: index, name, driver, sample spec,
// state -- the fields upstream's find_monitor_source() parses. It prefers a
// RUNNING *.monitor source, which this line claims to be.
let pactlSourcesLine =
  "0\tsystem-audio.monitor\tvoxtype-loopback-macos\tfloat32le 1ch 16000Hz\tRUNNING"

// MARK: - stderr logging (stdout carries raw samples in parec mode)

private let logFormatter: ISO8601DateFormatter = {
  let f = ISO8601DateFormatter()
  f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return f
}()

func logErr(_ message: @autoclosure () -> String) {
  FileHandle.standardError.write(
    ("[\(logFormatter.string(from: Date()))] \(message())\n").data(using: .utf8)!)
}

// MARK: - Shutdown registry

protocol Stoppable: AnyObject {
  func stop()
}

/// Every engine registers itself so SIGTERM/SIGINT/EPIPE can tear down the
/// tap, aggregate and IOProc before exiting. Teardown is best-effort: an
/// error inside shutdown is logged and ignored -- the process is leaving.
final class CaptureRuntime {
  static let shared = CaptureRuntime()
  private let lock = NSLock()
  private var engines: [Stoppable] = []
  private var exitCode: Int32? = nil

  func register(_ engine: Stoppable) {
    lock.lock(); defer { lock.unlock() }
    engines.append(engine)
  }

  /// Stops every registered engine, exactly once, then exits.
  func shutdown(_ code: Int32) -> Never {
    lock.lock()
    if exitCode != nil {
      lock.unlock()
      Thread.sleep(forTimeInterval: 5)
      exit(code)
    }
    exitCode = code
    let toStop = engines
    lock.unlock()
    for e in toStop { e.stop() }
    exit(code)
  }
}

// MARK: - Sample FIFO (IOProc -> writer thread)

/// A mutex-and-condition FIFO of converted Float32 samples. The IOProc pushes
/// (never blocks: a full FIFO drops oldest and counts -- a stalled reader must
/// not wedge the audio thread), a dedicated writer thread pops and writes to
/// stdout. Capacity is 4 s of 16 kHz audio; in steady state the queue holds
/// one IOProc callback (~10 ms), never more.
final class SamplePipe {
  private let cond = NSCondition()
  private var buffer: [Float32] = []
  private var closed = false
  private(set) var droppedSamples = 0

  static let capacity = 16000 * 4

  func push(_ samples: ArraySlice<Float32>) {
    cond.lock(); defer { cond.unlock() }
    buffer.append(contentsOf: samples)
    if buffer.count > SamplePipe.capacity {
      let excess = buffer.count - SamplePipe.capacity
      buffer.removeFirst(excess)
      droppedSamples += excess
      if droppedSamples % 16000 == 0 || excess >= 16000 {
        logErr("warning: reader stalled; dropped \(droppedSamples) samples total")
      }
    }
    cond.broadcast()
  }

  /// Blocks until at least one sample is available or the pipe closes.
  func pop() -> [Float32]? {
    cond.lock(); defer { cond.unlock() }
    while buffer.isEmpty && !closed { cond.wait() }
    if buffer.isEmpty && closed { return nil }
    let out = buffer
    buffer = []
    return out
  }

  func close() {
    cond.lock(); defer { cond.unlock() }
    closed = true
    cond.broadcast()
  }
}

// MARK: - Stdout writer

/// Drains the pipe and writes raw little-endian f32 to fd 1. EPIPE is a
/// NORMAL exit -- the reader (the daemon) went away -- and exits 0, per the
/// contract. SIGPIPE is ignored up front so the error surfaces here instead
/// of killing the process with the default signal disposition.
final class StdoutWriter {
  private let pipe: SamplePipe
  private var thread: Thread?

  init(pipe: SamplePipe) { self.pipe = pipe }

  func start() {
    let t = Thread { [weak self] in
      guard let self = self else { return }
      while let chunk = self.pipe.pop() {
        if !self.writeSamples(chunk) { return }
      }
      // Pipe closed with everything drained: nothing left to do.
      CaptureRuntime.shared.shutdown(0)
    }
    t.name = "voxtype-loopback-writer"
    t.start()
    thread = t
  }

  /// Returns false when stdout is gone (caller should stop).
  private func writeSamples(_ samples: [Float32]) -> Bool {
    var written = 0
    let totalBytes = samples.count * MemoryLayout<Float32>.size
    return samples.withUnsafeBufferPointer { buf -> Bool in
      let base = UnsafeRawPointer(buf.baseAddress!)
      while written < totalBytes {
        let n = write(1, base + written, totalBytes - written)
        if n > 0 { written += n; continue }
        if n < 0 && errno == EINTR { continue }
        if n < 0 && errno == EPIPE {
          logErr("stdout closed (EPIPE); exiting cleanly")
          CaptureRuntime.shared.shutdown(0)
        }
        logErr("write(2) failed: errno \(errno); exiting")
        CaptureRuntime.shared.shutdown(1)
      }
      return true
    }
  }
}

// MARK: - Format conversion (device rate -> 16 kHz mono)

/// Wraps AVAudioConverter for one input format. The tap reports Float32 at
/// the output device's rate (48 kHz here); the daemon wants Float32 mono
/// 16 kHz. Input is normalized to mono first: for a multi-channel tap the
/// channels are averaged, which is inaudible for this purpose and cannot
/// happen with the mono tap description we request.
final class FormatConverter {
  private let converter: AVAudioConverter
  private let inputFormat: AVAudioFormat
  private let outputFormat: AVAudioFormat
  private let inputChannels: Int
  private let lock = NSLock()

  init?(inputRate: Double, channels: Int) {
    guard
      let inF = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: inputRate,
        channels: 1, interleaved: false),
      let outF = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: outputSampleRate,
        channels: 1, interleaved: false)
    else { return nil }
    self.inputFormat = inF
    self.outputFormat = outF
    self.inputChannels = max(1, channels)
    guard let converter = AVAudioConverter(from: inF, to: outF) else { return nil }
    self.converter = converter
  }

  /// Converts interleaved input floats at the device rate to mono 16 kHz.
  func convert(_ input: UnsafePointer<Float32>, frameCount: Int) -> [Float32] {
    guard frameCount > 0 else { return [] }
    lock.lock(); defer { lock.unlock() }

    var mono = [Float32](repeating: 0, count: frameCount)
    if inputChannels == 1 {
      mono.withUnsafeMutableBufferPointer { dst in
        dst.baseAddress!.update(from: input, count: frameCount)
      }
    } else {
      // Average interleaved channels down to mono.
      for f in 0..<frameCount {
        var acc: Float = 0
        for c in 0..<inputChannels { acc += input[f * inputChannels + c] }
        mono[f] = acc / Float(inputChannels)
      }
    }

    guard let inBuf = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frameCount))
    else { return mono }
    inBuf.frameLength = AVAudioFrameCount(frameCount)
    mono.withUnsafeBufferPointer { src in
      inBuf.floatChannelData![0].update(from: src.baseAddress!, count: frameCount)
    }

    // Capacity for the rate ratio plus converter slack; rate conversion holds
    // a few samples back for priming across calls, which is fine for a
    // continuous stream.
    let ratio = outputSampleRate / inputFormat.sampleRate
    let capacity = AVAudioFrameCount(Double(frameCount) * ratio) + 64
    guard let outBuf = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)
    else { return mono }

    var fedInput = false
    var convError: NSError?
    let status = converter.convert(to: outBuf, error: &convError) { _, inputStatus in
      if fedInput {
        inputStatus.pointee = .noDataNow
        return nil
      }
      fedInput = true
      inputStatus.pointee = .haveData
      return inBuf
    }
    if status == .error {
      logErr("converter error: \(convError?.localizedDescription ?? "unknown")")
      return mono
    }

    let n = Int(outBuf.frameLength)
    guard n > 0, let outData = outBuf.floatChannelData?[0] else { return [] }
    return [Float32](UnsafeBufferPointer(start: outData, count: n))
  }
}

// MARK: - CoreAudio helpers

enum CoreAudioHelpers {
  /// The default output device's AudioObjectID.
  static func defaultOutputDevice() -> AudioObjectID? {
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var id = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr
    else { return nil }
    return id
  }

  /// A device's nominal sample rate.
  static func nominalSampleRate(_ id: AudioObjectID) -> Double? {
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyNominalSampleRate,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var rate = Double(0)
    var size = UInt32(MemoryLayout<Double>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate) == noErr, rate > 0
    else { return nil }
    return rate
  }

  static func deviceName(_ id: AudioObjectID) -> String? {
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioObjectPropertyName,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<CFString>.size)
    // The HAL writes a CFStringRef into the slot; routing through raw bytes
    // says so explicitly instead of letting &cfString warn about it.
    var name: CFString = "" as CFString
    let ok = withUnsafeMutableBytes(of: &name) { raw -> Bool in
      guard let base = raw.baseAddress else { return false }
      return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, base) == noErr
    }
    guard ok else { return nil }
    return name as String
  }

  /// Total input channels a device exposes. Used to prove a process tap was
  /// actually accepted into its aggregate: a device with no input channels
  /// can never deliver a sample, whatever the creation calls returned.
  static func inputChannelCount(_ id: AudioObjectID) -> Int {
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamConfiguration,
      mScope: kAudioDevicePropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(0)
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0
    else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(
      raw.assumingMemoryBound(to: AudioBufferList.self))
    var total = 0
    for buffer in list { total += Int(buffer.mNumberChannels) }
    return total
  }

  static func hasInputStreams(_ id: AudioObjectID) -> Bool {
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreams,
      mScope: kAudioDevicePropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(0)
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0
    else { return false }
    return true
  }

  /// All devices, for name-based lookup on the input route.
  static func allDevices() -> [AudioObjectID] {
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(0)
    guard
      AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
      size > 0
    else { return [] }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: 0, count: count)
    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
    else { return [] }
    return ids
  }

  /// Finds an input device by name: exact (case-insensitive) match first,
  /// then substring, matching the way a human names "BlackHole 2ch".
  static func findInputDevice(named name: String) -> AudioObjectID? {
    let lower = name.lowercased()
    var substringHit: AudioObjectID?
    for id in allDevices() where hasInputStreams(id) {
      guard let nm = deviceName(id)?.lowercased() else { continue }
      if nm == lower { return id }
      if substringHit == nil && nm.contains(lower) { substringHit = id }
    }
    return substringHit
  }
}

// MARK: - Process tap engine

/// Owns the tap -> aggregate -> IOProc stack and its full-rebuild lifecycle.
///
/// The rebuild is the load-bearing part. After the default output device
/// changes, the existing pair goes silent: IOProc callbacks keep arriving but
/// carry only zeros, and restarting the IOProc or the aggregate alone does
/// not recover it -- all three objects must be destroyed and recreated. Two
/// independent triggers request a rebuild:
///   * the kAudioHardwarePropertyDefaultOutputDevice listener, and
///   * the watchdog: >= 5 s of exact-zero input AFTER real audio was seen.
/// The second is armed only after audio because a meeting whose remote side
/// is muted delivers legitimate zeros; rebuilding then costs nothing the ear
/// can hear, but there is no reason to start before audio ever flowed.
final class ProcessTapEngine: Stoppable {
  private let sink: ([Float32]) -> Void
  private let control = DispatchQueue(label: "voxtype-loopback.control")

  private var tapID = AudioObjectID(0)
  private var aggregateID = AudioObjectID(0)
  private var ioProcID: AudioDeviceIOProcID?
  private var converterRef: FormatConverter?
  private var inputRate: Double = 48000

  // State shared between the IO thread and the control queue. Touched only
  // under stateLock; every critical section is a handful of instructions.
  private let stateLock = NSLock()
  private var rebuildRequested = false
  private var sawAudio = false
  private var lastAudioAt = Date.distantPast
  private var startedAt = Date.distantPast
  private var lastRebuild = Date.distantPast
  private var coldRebuilds = 0
  private var warnedColdGiveUp = false
  private(set) var rebuildCount = 0

  // Property addresses must outlive the calls that use them; kept here so
  // the pointers passed to CoreAudio remain valid.
  private var defaultOutputAddr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
  private var listenerBlock: AudioObjectPropertyListenerBlock?
  private var watchdogTimer: DispatchSourceTimer?

  static let zeroWatchdogSeconds = 5.0
  static let rebuildCooldownSeconds = 10.0
  // The cold case: audio has NEVER arrived. That is what a first meeting
  // looks like, because the System Audio Recording grant is created at
  // AudioDeviceStart -- the tap is already running when the user clicks
  // Allow, and it does not begin flowing on its own afterwards. Measured
  // here: the first meeting after the grant recorded 0 chunks, and the very
  // next one recorded 4. A rebuild once the grant exists picks the audio up,
  // so the cold watchdog exists to turn "the first meeting is silently lost"
  // into "the first meeting recovers itself". Longer than the warm window
  // (a click takes a moment) and bounded, because a genuinely denied grant
  // must not rebuild forever.
  static let coldWatchdogSeconds = 12.0
  static let maxColdRebuilds = 3

  // The channel count the converter was built with, so the IO callback can
  // divide interleaved input into frames. Set at build time; read on the IO
  // thread only after start() returns.
  private(set) var converterInputChannels = 1

  init(sink: @escaping ([Float32]) -> Void) {
    self.sink = sink
  }

  func start() throws {
    try buildAndStart()
    installDefaultDeviceListener()
    startWatchdog()
    CaptureRuntime.shared.register(self)
    logErr(
      "process tap running: global mono tap, \(Int(inputRate)) Hz -> \(Int(outputSampleRate)) Hz")
  }

  func stop() {
    watchdogTimer?.cancel()
    watchdogTimer = nil
    if listenerBlock != nil {
      AudioObjectRemovePropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject), &defaultOutputAddr, control,
        listenerBlock!)
      listenerBlock = nil
    }
    teardown()
  }

  // MARK: build / teardown

  private func buildAndStart() throws {
    // 1. The process tap: mono, global (every process), private.
    let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
    description.isPrivate = true

    var newTap = AudioObjectID(0)
    var err = AudioHardwareCreateProcessTap(description, &newTap)
    guard err == noErr else {
      throw ShimmerError.coreAudio("AudioHardwareCreateProcessTap: \(err)")
    }
    tapID = newTap

    // 2. The tap's format: Float32 at the output device's rate. Query the
    // tap itself; fall back to the default output device's nominal rate.
    var channels = 1
    var rate: Double? = nil
    var asbd = AudioStreamBasicDescription()
    var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    var fmtAddr = AudioObjectPropertyAddress(
      mSelector: kAudioTapPropertyFormat,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    if AudioObjectGetPropertyData(tapID, &fmtAddr, 0, nil, &asbdSize, &asbd) == noErr,
      asbd.mSampleRate > 0
    {
      rate = asbd.mSampleRate
      channels = max(1, Int(asbd.mChannelsPerFrame))
    }
    if rate == nil {
      rate = CoreAudioHelpers.defaultOutputDevice().flatMap { CoreAudioHelpers.nominalSampleRate($0) }
    }
    guard let inputRateFound = rate else {
      AudioHardwareDestroyProcessTap(tapID)
      tapID = 0
      throw ShimmerError.coreAudio("could not determine the tap sample rate")
    }
    inputRate = inputRateFound
    guard let converter = FormatConverter(inputRate: inputRate, channels: channels) else {
      AudioHardwareDestroyProcessTap(tapID)
      tapID = 0
      throw ShimmerError.coreAudio("AVAudioConverter init failed")
    }
    converterRef = converter
    converterInputChannels = channels

    // 3. A private aggregate holding the tap, auto-starting it. TapAutoStart
    // is what makes the tap flow as soon as the aggregate's IO runs, and it
    // REQUIRES the private key (AudioHardware.h:1641-1643).
    //
    // The tap list is "a CFArray of CFDictionaries that describe each tap",
    // each keyed by kAudioSubTapUIDKey holding "a CFString that contains the
    // UID for the AudioSubTap" (AudioHardware.h:1628-1630, 1861-1866) -- the
    // CATapDescription's UUID string, NOT the AudioObjectID the tap was
    // created as. Passing the object ID is the trap this comment exists for:
    // AudioHardwareCreateAggregateDevice returns noErr, the aggregate is
    // created, and the tap is silently DROPPED -- measured here, the stored
    // kAudioAggregateDevicePropertyTapList reads back empty and the device
    // reports zero input channels, so the IOProc never sees a sample. That
    // is indistinguishable at the call site from the silent TCC refusal
    // described at the top of this file, and would be misdiagnosed as one.
    // The aggregate needs no sub-device: the tap is its only input, and it
    // supplies the clock.
    let aggregateDict: [String: Any] = [
      kAudioAggregateDeviceNameKey as String: "Voxtype Loopback",
      kAudioAggregateDeviceUIDKey as String: "voxtype.loopback.aggregate",
      kAudioAggregateDeviceIsPrivateKey as String: true,
      kAudioAggregateDeviceTapListKey as String: [
        [kAudioSubTapUIDKey as String: description.uuid.uuidString]
      ],
      kAudioAggregateDeviceTapAutoStartKey as String: true,
    ]
    var newAggregate = AudioObjectID(0)
    err = AudioHardwareCreateAggregateDevice(
      aggregateDict as CFDictionary, &newAggregate)
    guard err == noErr else {
      AudioHardwareDestroyProcessTap(tapID)
      tapID = 0
      throw ShimmerError.coreAudio("AudioHardwareCreateAggregateDevice: \(err)")
    }
    aggregateID = newAggregate

    // 3b. Prove the tap landed. A malformed tap list is accepted with noErr
    // and silently produces an aggregate with no input at all, so the only
    // way to tell a live tap from a dropped one is to ask the device how
    // many input channels it ended up with. Checked on every build and
    // rebuild: this is the difference between a loud error here and a
    // meeting that records half the call.
    let aggInputChannels = CoreAudioHelpers.inputChannelCount(aggregateID)
    guard aggInputChannels > 0 else {
      AudioHardwareDestroyAggregateDevice(aggregateID)
      aggregateID = 0
      AudioHardwareDestroyProcessTap(tapID)
      tapID = 0
      throw ShimmerError.coreAudio(
        "the aggregate device reports \(aggInputChannels) input channels: the tap was "
          + "not accepted into it (a malformed tap list is accepted with noErr and "
          + "silently dropped). This is a bug in this shim, not a permissions problem.")
    }

    // 4. The IOProc. Input buffers (the tapped audio) arrive on the input
    // side. This is where the System Audio Recording TCC check happens --
    // and where a refusal is silent: buffers arrive all-zero, noErr.
    var newProc: AudioDeviceIOProcID?
    err = AudioDeviceCreateIOProcIDWithBlock(&newProc, aggregateID, nil) {
      [weak self] _, inputData, _, _, _ in
      self?.ioCallback(inputData)
    }
    guard err == noErr, let proc = newProc else {
      AudioHardwareDestroyAggregateDevice(aggregateID)
      aggregateID = 0
      AudioHardwareDestroyProcessTap(tapID)
      tapID = 0
      throw ShimmerError.coreAudio("AudioDeviceCreateIOProcIDWithBlock: \(err)")
    }
    ioProcID = proc

    err = AudioDeviceStart(aggregateID, proc)
    guard err == noErr else {
      AudioDeviceDestroyIOProcID(aggregateID, proc)
      ioProcID = nil
      AudioHardwareDestroyAggregateDevice(aggregateID)
      aggregateID = 0
      AudioHardwareDestroyProcessTap(tapID)
      tapID = 0
      throw ShimmerError.coreAudio("AudioDeviceStart: \(err)")
    }

    // A fresh build restarts both watchdog clocks so the pre-rebuild silence
    // does not immediately re-trigger.
    stateLock.lock()
    startedAt = Date()
    lastAudioAt = Date()
    stateLock.unlock()
  }

  /// IOProc -> aggregate -> tap, in that order (the reverse of creation).
  private func teardown() {
    if let proc = ioProcID {
      AudioDeviceStop(aggregateID, proc)
      AudioDeviceDestroyIOProcID(aggregateID, proc)
      ioProcID = nil
    }
    if aggregateID != 0 {
      AudioHardwareDestroyAggregateDevice(aggregateID)
      aggregateID = 0
    }
    if tapID != 0 {
      AudioHardwareDestroyProcessTap(tapID)
      tapID = 0
    }
    converterRef = nil
  }

  // MARK: the IO callback

  private func ioCallback(_ inputData: UnsafePointer<AudioBufferList>?) {
    guard let inputData = inputData else { return }
    guard let converter = converterRef else { return }
    for buffer in UnsafeMutableAudioBufferListPointer(
      UnsafeMutablePointer(mutating: inputData))
    {
      guard let data = buffer.mData, buffer.mDataByteSize > 0 else { continue }
      let floatCount = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size
      guard floatCount > 0 else { continue }
      let floats = data.assumingMemoryBound(to: Float32.self)

      // Watchdog bookkeeping on the RAW input, before conversion: any
      // nonzero sample is proof the tap is delivering. The DECISION is not
      // made here -- it is made by the 1 Hz timer, because the failure this
      // has to catch includes "no callbacks at all", and a watchdog that
      // lives inside the callback cannot see that. Measured: a tap with no
      // System Audio Recording grant produced zero callbacks for 55 s, and
      // an in-callback watchdog never evaluated once.
      var sawNonZero = false
      for f in 0..<floatCount where floats[f] != 0 { sawNonZero = true; break }
      if sawNonZero {
        stateLock.lock()
        sawAudio = true
        lastAudioAt = Date()
        stateLock.unlock()
      }

      let frames = floatCount / max(1, converterInputChannels)
      let converted = converter.convert(floats, frameCount: frames)
      if !converted.isEmpty { sink(converted) }
    }
  }

  // MARK: rebuild triggers

  private func installDefaultDeviceListener() {
    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      logErr("default output device changed; requesting rebuild")
      self?.requestRebuild()
    }
    listenerBlock = block
    let err = AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &defaultOutputAddr, control, block)
    if err != noErr {
      logErr("warning: could not install default-device listener: \(err)")
      listenerBlock = nil
    }
  }

  /// The default-output-device listener's trigger. The timer performs it.
  private func requestRebuild() {
    stateLock.lock()
    rebuildRequested = true
    stateLock.unlock()
  }

  private func startWatchdog() {
    let timer = DispatchSource.makeTimerSource(queue: control)
    timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
    timer.setEventHandler { [weak self] in self?.serviceRebuild() }
    timer.resume()
    watchdogTimer = timer
  }

  /// Runs on the control queue once a second. It both DECIDES whether a
  /// rebuild is due and performs it, because the two conditions worth
  /// catching are "the tap went silent" and "the tap never started", and the
  /// second produces no callbacks to notice it from.
  ///
  ///   warm  audio flowed, then stopped for zeroWatchdogSeconds
  ///   cold  audio has never flowed, startup grace elapsed, budget remains
  ///
  /// A failed rebuild is logged and re-requested on the next tick.
  private func serviceRebuild() {
    let now = Date()
    stateLock.lock()
    let cold = !sawAudio
    var due = rebuildRequested          // the device-change listener asked
    var reason = "default output device changed"
    if cold {
      if now.timeIntervalSince(startedAt) >= ProcessTapEngine.coldWatchdogSeconds
        && coldRebuilds < ProcessTapEngine.maxColdRebuilds
      {
        due = true
        reason =
          "\(Int(ProcessTapEngine.coldWatchdogSeconds))s and the tap has never delivered a "
          + "sample"
      }
    } else if now.timeIntervalSince(lastAudioAt) >= ProcessTapEngine.zeroWatchdogSeconds {
      due = true
      reason = "\(Int(ProcessTapEngine.zeroWatchdogSeconds))s of silence while running"
    }
    let cooled = now.timeIntervalSince(lastRebuild) >= ProcessTapEngine.rebuildCooldownSeconds
    let giveUp = cold && coldRebuilds >= ProcessTapEngine.maxColdRebuilds && !warnedColdGiveUp
    if giveUp { warnedColdGiveUp = true }
    if due && cooled {
      rebuildRequested = false
      lastRebuild = now
      startedAt = now
      lastAudioAt = now
      if cold { coldRebuilds += 1 }
    }
    stateLock.unlock()

    if giveUp {
      logErr(
        "watchdog: no audio after \(ProcessTapEngine.maxColdRebuilds) rebuilds; the capture "
          + "is running but the system is withholding audio from it. The System Audio "
          + "Recording grant is missing or denied for the app RESPONSIBLE for this process "
          + "(Voxtype.app when the daemon spawns it; your terminal when you run it by hand): "
          + "System Settings > Privacy & Security > Screen & System Audio Recording. "
          + "This meeting is recording the microphone only.")
    }
    guard due, cooled else { return }
    logErr("watchdog: \(reason); rebuilding")

    rebuildCount += 1
    logErr("rebuild #\(rebuildCount): tearing down IOProc, aggregate, tap")
    teardown()
    do {
      try buildAndStart()
      logErr("rebuild #\(rebuildCount): complete")
    } catch {
      logErr("rebuild #\(rebuildCount) failed: \(error)")
    }
  }
}

enum ShimmerError: Error, CustomStringConvertible {
  case coreAudio(String)
  case notFound(String)
  case contract(String)

  var description: String {
    switch self {
    case .coreAudio(let m): return m
    case .notFound(let m): return m
    case .contract(let m): return m
    }
  }
}


// MARK: - Input device engine (the non-monitor route)

/// Opens a named CoreAudio INPUT device and feeds the same converted 16 kHz
/// mono sink. This is the BlackHole fallback: point
/// meeting.audio.loopback_device at a real input device name (or install
/// BlackHole 2ch and name it) and the daemon needs only the Microphone grant
/// it already holds -- no System Audio Recording prompt.
///
/// Implementation note: an IOProc is registered DIRECTLY on the input device
/// (AudioDeviceCreateIOProcIDWithBlock + AudioDeviceStart), the same public
/// API the tap route uses one level up. AVAudioEngine was considered and
/// rejected for this route: it has no public input-device selector on macOS
/// (the underlying AudioUnit is not reachable from Swift), so a named device
/// cannot be chosen through it. The buffers arrive in the device's input
/// stream format; AVAudioConverter handles the rate change.
final class InputDeviceEngine: Stoppable {
  private let sink: ([Float32]) -> Void
  private var deviceID = AudioObjectID(0)
  private var ioProcID: AudioDeviceIOProcID?
  private var converterRef: FormatConverter?
  private var converterInputChannels = 1
  private(set) var inputRate: Double = 0

  init(deviceName: String, sink: @escaping ([Float32]) -> Void) throws {
    self.sink = sink
    guard let id = CoreAudioHelpers.findInputDevice(named: deviceName) else {
      throw ShimmerError.notFound(
        "no CoreAudio input device named \"\(deviceName)\"")
    }
    deviceID = id

    // The device's input stream format tells the converter what arrives.
    var asbd = AudioStreamBasicDescription()
    var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    var fmtAddr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreamFormat,
      mScope: kAudioDevicePropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain)
    guard
      AudioObjectGetPropertyData(deviceID, &fmtAddr, 0, nil, &asbdSize, &asbd) == noErr,
      asbd.mSampleRate > 0
    else {
      throw ShimmerError.coreAudio(
        "could not read the input format of \"\(deviceName)\"")
    }
    inputRate = asbd.mSampleRate
    let channels = max(1, Int(asbd.mChannelsPerFrame))
    guard let converter = FormatConverter(inputRate: inputRate, channels: channels) else {
      throw ShimmerError.coreAudio("AVAudioConverter init failed")
    }
    converterRef = converter
    converterInputChannels = channels

    var newProc: AudioDeviceIOProcID?
    let err = AudioDeviceCreateIOProcIDWithBlock(&newProc, deviceID, nil) {
      [weak self] _, inputData, _, _, _ in
      self?.ioCallback(inputData)
    }
    guard err == noErr, let proc = newProc else {
      throw ShimmerError.coreAudio("AudioDeviceCreateIOProcIDWithBlock: \(err)")
    }
    ioProcID = proc

    let startErr = AudioDeviceStart(deviceID, proc)
    guard startErr == noErr else {
      AudioDeviceDestroyIOProcID(deviceID, proc)
      ioProcID = nil
      throw ShimmerError.coreAudio("AudioDeviceStart: \(startErr)")
    }

    CaptureRuntime.shared.register(self)
    logErr(
      "input device running: \"\(deviceName)\" \(Int(inputRate)) Hz -> "
        + "\(Int(outputSampleRate)) Hz")
  }

  func stop() {
    if let proc = ioProcID {
      AudioDeviceStop(deviceID, proc)
      AudioDeviceDestroyIOProcID(deviceID, proc)
      ioProcID = nil
    }
    converterRef = nil
  }

  private func ioCallback(_ inputData: UnsafePointer<AudioBufferList>?) {
    guard let inputData = inputData else { return }
    guard let converter = converterRef else { return }
    for buffer in UnsafeMutableAudioBufferListPointer(
      UnsafeMutablePointer(mutating: inputData))
    {
      guard let data = buffer.mData, buffer.mDataByteSize > 0 else { continue }
      let floatCount = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size
      guard floatCount > 0 else { continue }
      let floats = data.assumingMemoryBound(to: Float32.self)
      let frames = floatCount / max(1, converterInputChannels)
      let converted = converter.convert(floats, frameCount: frames)
      if !converted.isEmpty { sink(converted) }
    }
  }
}

// MARK: - pactl mode

func runPactl(_ args: [String]) -> Int32 {
  guard args == ["list", "short", "sources"] else {
    FileHandle.standardError.write(
      ("pactl shim: only `pactl list short sources' is implemented\n")
        .data(using: .utf8)!)
    return 1
  }
  print(pactlSourcesLine)
  return 0
}

// MARK: - parec mode

func runParec(_ args: [String]) -> Int32 {
  var device: String?
  var format: String?
  var channels: String?
  var rate: String?
  var raw = false

  var i = 0
  while i < args.count {
    let arg = args[i]
    func valueFor(_ flag: String) -> String? {
      if arg == flag, i + 1 < args.count { return args[i + 1] }
      return nil
    }
    if arg.hasPrefix("--") {
      let (flag, inlineValue): (String, String?) = {
        if let eq = arg.firstIndex(of: "=") {
          return (String(arg[arg.startIndex..<eq]), String(arg[arg.index(after: eq)...]))
        }
        return (arg, nil)
      }()
      switch flag {
      case "--device":
        device = inlineValue ?? valueFor("--device")
        if inlineValue == nil { i += 1 }
      case "--format":
        format = inlineValue ?? valueFor("--format")
        if inlineValue == nil { i += 1 }
      case "--channels":
        channels = inlineValue ?? valueFor("--channels")
        if inlineValue == nil { i += 1 }
      case "--rate":
        rate = inlineValue ?? valueFor("--rate")
        if inlineValue == nil { i += 1 }
      case "--raw":
        raw = true
      default:
        FileHandle.standardError.write(
          ("parec shim: unknown argument `\(arg)'\n").data(using: .utf8)!)
        return 2
      }
    } else {
      FileHandle.standardError.write(
        ("parec shim: unexpected argument `\(arg)'\n").data(using: .utf8)!)
      return 2
    }
    i += 1
  }

  // Exactly one format triple is accepted. A future upstream that changes
  // its arguments gets a loud failure here, not garbage on stdout.
  guard
    let dev = device,
    format == "float32le",
    channels == "1",
    rate == "16000",
    raw
  else {
    FileHandle.standardError.write(
      """
      parec shim: this build speaks exactly one contract:
        parec --device <name> --format=float32le --channels=1 --rate=16000 --raw
      got: --device=\(device ?? "<missing>") --format=\(format ?? "<missing>") \
      --channels=\(channels ?? "<missing>") --rate=\(rate ?? "<missing>") \
      --raw=\(raw)

      """.data(using: .utf8)!)
    return 2
  }

  signal(SIGPIPE, SIG_IGN)

  do {
    if dev == monitorSourceName {
      let pipe = SamplePipe()
      let writer = StdoutWriter(pipe: pipe)
      let engine = ProcessTapEngine { samples in pipe.push(samples[...]) }
      writer.start()
      try engine.start()
    } else {
      let pipe = SamplePipe()
      let writer = StdoutWriter(pipe: pipe)
      let engine = try InputDeviceEngine(deviceName: dev) { samples in
        pipe.push(samples[...])
      }
      _ = engine
      writer.start()
    }
  } catch {
    FileHandle.standardError.write(
      ("parec shim: \(error)\n").data(using: .utf8)!)
    return 2
  }

  // Park the main thread; everything else runs on IO/control/writer threads.
  dispatchMain()
}

// MARK: - self-test

// The explanation both self-test failure modes need. The tap's TCC refusal
// is SILENT: no CoreAudio error exists to print, so this text is the only
// diagnostic the tool has.
func printTapTCCGuidance() {
  print("""
  The responsible app is what tccd checks for NSAudioCaptureUsageDescription
  and the System Audio Recording grant (kTCCServiceAudioCapture in tccd's
  own log; no error is ever returned to the caller):
    - run by hand from a terminal: the TERMINAL's own app -- and if it does
      not declare the usage key (Ghostty does not), the refusal is silent
      and structural: no prompt can ever appear. This failure is then
      EXPECTED and says nothing about the daemon route.
    - spawned by the voxtype daemon: Voxtype.app, which install.sh
      --with-meeting patches with the usage key. The grant prompt appears
      at the FIRST meeting start (it fires at AudioDeviceStart), not here.
  The end-to-end test is a real meeting: voxtype-meeting start while audio
  is playing, then check the export for You AND Remote segments. After a
  bundle re-sign, reset the grant with:
    tccutil reset AudioCapture io.voxtype.daemon
  See docs/install-macos.md, "Meeting mode: the loopback shim".

  """)
}

func runSelfTest(device: String?, seconds: Double) -> Int32 {
  let dev = device ?? monitorSourceName
  print("self-test: \(seconds) s from \(dev)" + (dev == monitorSourceName ? " (process tap)" : " (input device)"))
  FileHandle.standardError.write(
    ("self-test: capturing \(seconds) s from \(dev)\n").data(using: .utf8)!)

  let lock = NSLock()
  var collected: [Float32] = []

  signal(SIGPIPE, SIG_IGN)
  var engine: Stoppable?
  var inputRate = 0.0
  do {
    if dev == monitorSourceName {
      let tap = ProcessTapEngine { samples in
        lock.lock()
        collected.append(contentsOf: samples)
        lock.unlock()
      }
      inputRate = tap.inputRateForDiagnostics
      engine = tap
      try tap.start()
    } else {
      let inp = try InputDeviceEngine(deviceName: dev) { samples in
        lock.lock()
        collected.append(contentsOf: samples)
        lock.unlock()
      }
      engine = inp
    }
  } catch {
    print("self-test: FAILED -- \(error)")
    FileHandle.standardError.write(("self-test: \(error)\n").data(using: .utf8)!)
    return 1
  }

  Thread.sleep(forTimeInterval: seconds)
  engine?.stop()

  lock.lock()
  let samples = collected
  lock.unlock()

  var peak: Float = 0
  var sumSquares: Double = 0
  for s in samples {
    let a = Swift.abs(s)
    if a > peak { peak = a }
    sumSquares += Double(s) * Double(s)
  }
  // RMS is sqrt(mean of squares). Dividing the root by n instead of rooting
  // the mean reports a number that shrinks with capture length, which makes
  // a longer --seconds look quieter.
  let rms = samples.isEmpty ? 0 : (sumSquares / Double(samples.count)).squareRoot()
  let rateNote = inputRate > 0 ? String(format: ", %.0f Hz -> %.0f Hz", inputRate, outputSampleRate) : ""

  print(String(format: "self-test: %d samples in %.1f s%@", samples.count, seconds, rateNote))
  print(String(format: "self-test: peak %.6f, rms %.6f", peak, rms))

  if samples.isEmpty {
    print("self-test: FAILED -- the tap produced no callbacks at all (no error returned)")
    printTapTCCGuidance()
    FileHandle.standardError.write(
      ("self-test: no callbacks; audio withheld (silent TCC refusal?)\n").data(using: .utf8)!)
    return 1
  }
  if peak <= 1e-6 {
    print("self-test: FAILED -- all-zero capture with no CoreAudio error")
    printTapTCCGuidance()
    FileHandle.standardError.write(
      ("self-test: all zeros (silent TCC refusal?)\n").data(using: .utf8)!)
    return 1
  }
  print("self-test: audio present")
  return 0
}

// MARK: - usage / main

func usage() -> String {
  """
  voxtype-loopback-macos -- pactl/parec shim for voxtype meeting mode on macOS

  Dispatches on argv[0]:
    pactl   (symlink)  `list short sources` prints one monitor source line
    parec   (symlink)  --device <name> --format=float32le --channels=1
                       --rate=16000 --raw streams f32 mono 16 kHz on stdout;
                       --device system-audio.monitor uses a CoreAudio process
                       tap, any other name a CoreAudio input device

  Direct invocation:
    --self-test [--device NAME] [--seconds N]   capture and verify (3 s)
    -h | --help                                 this text
  """
}

extension ProcessTapEngine {
  var inputRateForDiagnostics: Double {
    // The rate is set during start(); expose it read-only for self-test
    // output. Reads happen after start() returns, so no locking is needed.
    return inputRate
  }
}

var argv0Base = ""

func main() -> Int32 {
  let args = CommandLine.arguments
  argv0Base = (args.first as NSString?)?.lastPathComponent ?? "voxtype-loopback-macos"

  if argv0Base == "pactl" {
    return runPactl(Array(args.dropFirst()))
  }
  if argv0Base == "parec" {
    return runParec(Array(args.dropFirst()))
  }

  var device: String?
  var seconds = 3.0
  var rest = Array(args.dropFirst())
  while !rest.isEmpty {
    let arg = rest.removeFirst()
    switch arg {
    case "--self-test": break
    case "--device":
      if !rest.isEmpty { device = rest.removeFirst() }
    case "--seconds":
      if !rest.isEmpty { seconds = Double(rest.removeFirst()) ?? 3.0 }
    case "-h", "--help":
      print(usage())
      return 0
    default:
      FileHandle.standardError.write(
        ("unknown argument: \(arg)\n").data(using: .utf8)!)
      print(usage())
      return 2
    }
  }
  return runSelfTest(device: device, seconds: seconds)
}

// Install signal handlers, then run. SIGPIPE is ignored so write(2) reports
// EPIPE instead of killing the process; SIGTERM/SIGINT tear down the engines
// (destroying the tap and aggregate) and exit 0 -- the daemon's normal stop.
signal(SIGPIPE, SIG_IGN)
for sig in [SIGTERM, SIGINT] {
  signal(sig, SIG_IGN)
  let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
  source.setEventHandler { CaptureRuntime.shared.shutdown(0) }
  source.resume()
}

exit(main())
