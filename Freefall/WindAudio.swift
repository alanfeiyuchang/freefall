import AVFoundation
import os

/// 风声：程序合成，不用素材。
/// 低沉的棕噪声（呼呼声）+ 带通的白噪声（嘶嘶声，速度越快中心频率越高），整体响度跟速度走，再叠慢慢起伏的阵风。
final class WindAudio: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let params = OSAllocatedUnfairLock(initialState: WindDSP.Params())

    init?() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)

        let outputRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let sampleRate = outputRate > 0 ? outputRate : 48000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return nil }
        let dsp = WindDSP(sampleRate: Float(sampleRate))
        let params = self.params
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let p = params.withLock { $0 }
            dsp.render(frameCount: Int(frameCount), into: audioBufferList, params: p)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            return nil
        }
    }

    /// - Parameters:
    ///   - speed: 下落速度（m/s）
    ///   - gain: 整体音量（跟画面一起淡入淡出）
    func update(speed: Float, gain: Float) {
        params.withLock { $0 = WindDSP.Params(speed: speed, gain: gain) }
    }

    func stop() {
        engine.stop()
    }
}

/// 只在音频线程上用
final class WindDSP: @unchecked Sendable {
    struct Params: Sendable {
        var speed: Float = 0
        var gain: Float = 0
    }

    private let sampleRate: Float
    private var rng: UInt32 = 0x9E37_79B9
    private var brown: [Float] = [0, 0]
    private var low: [Float] = [0, 0]
    private var band: [Float] = [0, 0]
    private var gust: Float = 0.5
    private var gustTarget: Float = 0.5
    private var gustCountdown = 0
    private var speed: Float = 0
    private var gain: Float = 0

    init(sampleRate: Float) {
        self.sampleRate = sampleRate
    }

    private func white() -> Float {
        rng ^= rng << 13
        rng ^= rng >> 17
        rng ^= rng << 5
        return Float(rng) / Float(UInt32.max) * 2 - 1
    }

    func render(frameCount: Int, into list: UnsafeMutablePointer<AudioBufferList>, params: Params) {
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let smoothing = 1 - exp(-1 / (0.05 * sampleRate))      // 参数 50 ms 平滑，避免拉链声
        let gustSmoothing = 1 - exp(-1 / (0.9 * sampleRate))
        for i in 0..<frameCount {
            speed += (params.speed - speed) * smoothing
            gain += (params.gain - gain) * smoothing
            gustCountdown -= 1
            if gustCountdown <= 0 {
                gustTarget = 0.25 + 0.75 * (white() * 0.5 + 0.5)
                gustCountdown = Int(sampleRate * (0.4 + 0.8 * (white() * 0.5 + 0.5)))
            }
            gust += (gustTarget - gust) * gustSmoothing

            let intensity = min(speed / 90, 1.2)
            let amplitude = gain * pow(intensity, 1.5) * (0.55 + 0.45 * gust) * 0.35
            let center = 180 + speed * 5 + gust * 160
            let f = 2 * sin(Float.pi * min(center, 4000) / sampleRate)
            for channel in 0..<min(buffers.count, 2) {
                let w = white()
                brown[channel] = brown[channel] * 0.996 + w * 0.05
                // Chamberlin 状态变量滤波器，取带通
                let high = w - low[channel] - 1.2 * band[channel]
                band[channel] += f * high
                low[channel] += f * band[channel]
                let sample = (brown[channel] * 0.9 + band[channel] * 0.6) * amplitude
                buffers[channel].mData?.assumingMemoryBound(to: Float.self)[i] = sample
            }
        }
    }
}
