import Accelerate
import AVFoundation
import MediaToolbox
import os

/// Спектр того, что сейчас играет AVPlayer: audio tap (MTAudioProcessingTap) → FFT (vDSP) → 48 полос
/// в логарифмической шкале 40 Гц–16 кГц, значения 0…1. Считается в аудиопотоке, читается из интерфейса.
final class AudioAnalyzer: @unchecked Sendable {
    static let shared = AudioAnalyzer()
    static let bandCount = 48

    private let fftSize = 1024
    private let log2n: vDSP_Length = 10
    private let setup: FFTSetup
    private var window: [Float]
    private var ring: [Float]           // последние fftSize сэмплов (моно)
    private var work: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var mags: [Float]
    private var sampleRate: Double = 44100
    private var isFloat = true

    private var lock = os_unfair_lock()
    private var bands = [Float](repeating: 0, count: AudioAnalyzer.bandCount)
    private var lastUpdate: CFTimeInterval = 0

    private init() {
        setup = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: 1024)
        vDSP_hann_window(&window, vDSP_Length(1024), Int32(vDSP_HANN_NORM))
        ring = [Float](repeating: 0, count: 1024)
        work = [Float](repeating: 0, count: 1024)
        real = [Float](repeating: 0, count: 512)
        imag = [Float](repeating: 0, count: 512)
        mags = [Float](repeating: 0, count: 512)
    }

    /// Текущие полосы; если звук давно не приходил (пауза) — плавно гаснут.
    func snapshot() -> [Float] {
        os_unfair_lock_lock(&lock)
        let b = bands
        let age = CACurrentMediaTime() - lastUpdate
        os_unfair_lock_unlock(&lock)
        return age > 0.25 ? b.map { $0 * Float(max(0, 1 - (age - 0.25) * 3)) } : b
    }

    // MARK: Подключение к плееру

    /// AudioMix с «прослушкой» для звуковой дорожки трека.
    func makeAudioMix(for track: AVAssetTrack) -> AVAudioMix? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passUnretained(self).toOpaque(),
            init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
            finalize: { _ in },
            prepare: { tap, _, format in
                AudioAnalyzer.from(tap).prepare(format.pointee)
            },
            unprepare: { _ in },
            process: { tap, numberFrames, _, bufferList, numberFramesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferList, flagsOut, nil, numberFramesOut) == noErr
                else { return }
                AudioAnalyzer.from(tap).process(bufferList, frames: Int(numberFramesOut.pointee))
            }
        )
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                         kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr,
              let tap else { return nil }
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }

    private static func from(_ tap: MTAudioProcessingTap) -> AudioAnalyzer {
        Unmanaged<AudioAnalyzer>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    }

    // MARK: Аудиопоток

    private func prepare(_ asbd: AudioStreamBasicDescription) {
        sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 44100
        isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 && asbd.mBitsPerChannel == 32
        for i in ring.indices { ring[i] = 0 }
    }

    private func process(_ abl: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        guard isFloat, frames > 0 else { return }
        let list = UnsafeMutableAudioBufferListPointer(abl)
        guard let d0 = list.first?.mData else { return }
        let ch0 = d0.assumingMemoryBound(to: Float.self)
        let ch1 = list.count > 1 ? list[1].mData?.assumingMemoryBound(to: Float.self) : nil

        // Дописываем новые сэмплы (моно = среднее двух каналов) в конец «кольца».
        let n = min(frames, fftSize)
        let start = frames - n
        if n < fftSize {
            _ = ring.withUnsafeMutableBufferPointer { r in
                memmove(r.baseAddress!, r.baseAddress! + n, (fftSize - n) * MemoryLayout<Float>.size)
            }
        }
        for i in 0..<n {
            let s = ch0[start + i]
            ring[fftSize - n + i] = ch1.map { (s + $0[start + i]) * 0.5 } ?? s
        }

        // Окно Ханна → FFT → квадраты модулей.
        vDSP_vmul(ring, 1, window, 1, &work, 1, vDSP_Length(fftSize))
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                work.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(fftSize / 2))
            }
        }

        // Полосы в логарифмической шкале 40 Гц … 16 кГц → дБ → 0…1.
        let count = Self.bandCount
        let binHz = sampleRate / Double(fftSize)
        var out = [Float](repeating: 0, count: count)
        let lo = 40.0, hi = min(16000.0, sampleRate / 2 - binHz)
        for b in 0..<count {
            let f0 = lo * pow(hi / lo, Double(b) / Double(count))
            let f1 = lo * pow(hi / lo, Double(b + 1) / Double(count))
            let i0 = max(1, Int(f0 / binHz))
            let i1 = max(i0 + 1, min(fftSize / 2, Int(f1 / binHz) + 1))
            var peak: Float = 0
            for i in i0..<i1 { peak = max(peak, mags[i]) }
            let amp = sqrt(peak) / Float(fftSize)               // ≈ амплитуда, 0…~0.5
            let db = 20 * log10(amp + 1e-9)
            // Небольшой подъём верхов: в музыке они тише, иначе правая часть всегда пустая.
            let tilt = Float(b) / Float(count) * 12
            out[b] = min(max((db + tilt + 72) / 58, 0), 1)
        }

        os_unfair_lock_lock(&lock)
        bands = out
        lastUpdate = CACurrentMediaTime()
        os_unfair_lock_unlock(&lock)
    }
}
