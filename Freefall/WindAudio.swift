import AVFoundation
import os

/// 跳伞的声音，全部程序合成，不用素材：
/// - 风：低沉的棕噪声（呼呼声）+ 带通的白噪声（嘶嘶声，速度越快中心频率越高），响度跟速度走，叠慢慢起伏的阵风
/// - 发动机：螺旋桨的叶片通过频率（四台发动机略微失谐，听起来是「嗡嗡」地拍）加低频轰鸣，出舱后随距离变小
/// - 绿灯亮：一声「叮」
/// - 开伞：一阵扫频的「呼——」，接着伞衣抖动的「啪啪」声慢慢停下
final class JumpAudio: @unchecked Sendable {
    struct Params: Sendable {
        var speed: Float = 0
        var gain: Float = 0
        var engine: Float = 0
        /// 计数加一就触发一次（渲染线程只管加，音频线程看到变化就播）
        var dings = 0
        var deploys = 0
    }

    private let engine = AVAudioEngine()
    private let params = OSAllocatedUnfairLock(initialState: Params())

    init?() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)

        let outputRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let sampleRate = outputRate > 0 ? outputRate : 48000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return nil }
        let dsp = JumpDSP(sampleRate: Float(sampleRate))
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

    func update(_ newParams: Params) {
        params.withLock { $0 = newParams }
    }

    func stop() {
        engine.stop()
    }
}

/// 只在音频线程上用
final class JumpDSP: @unchecked Sendable {
    private let sampleRate: Float
    private var rng: UInt32 = 0x9E37_79B9
    private var brown: [Float] = [0, 0]
    private var low: [Float] = [0, 0]
    private var band: [Float] = [0, 0]
    private var rumble: Float = 0
    private var gust: Float = 0.5
    private var gustTarget: Float = 0.5
    private var gustCountdown = 0
    private var speed: Float = 0
    private var gain: Float = 0
    private var engineLevel: Float = 0
    private var phases: [Float] = [0, 0, 0, 0, 0, 0]
    private var dings = 0, deploys = 0
    private var dingTime: Float = -1
    private var deployTime: Float = -1
    private var deployLow: Float = 0, deployBand: Float = 0

    init(sampleRate: Float) {
        self.sampleRate = sampleRate
    }

    private func white() -> Float {
        rng ^= rng << 13
        rng ^= rng >> 17
        rng ^= rng << 5
        return Float(rng) / Float(UInt32.max) * 2 - 1
    }

    func render(frameCount: Int, into list: UnsafeMutablePointer<AudioBufferList>, params: JumpAudio.Params) {
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        if params.dings != dings { dings = params.dings; dingTime = 0 }
        if params.deploys != deploys { deploys = params.deploys; deployTime = 0 }
        let dt = 1 / sampleRate
        let smoothing = 1 - exp(-1 / (0.05 * sampleRate))      // 参数 50 ms 平滑，避免拉链声
        let gustSmoothing = 1 - exp(-1 / (0.9 * sampleRate))
        // 四台发动机的叶片通过频率（约 68 Hz），略微失谐
        let engineFrequencies: [Float] = [67.6, 68.3, 69.1, 136.4, 204.9, 272.3]
        let engineAmplitudes: [Float] = [0.22, 0.2, 0.18, 0.12, 0.06, 0.03]

        for i in 0..<frameCount {
            speed += (params.speed - speed) * smoothing
            gain += (params.gain - gain) * smoothing
            engineLevel += (params.engine - engineLevel) * smoothing
            gustCountdown -= 1
            if gustCountdown <= 0 {
                gustTarget = 0.25 + 0.75 * (white() * 0.5 + 0.5)
                gustCountdown = Int(sampleRate * (0.4 + 0.8 * (white() * 0.5 + 0.5)))
            }
            gust += (gustTarget - gust) * gustSmoothing

            // 发动机（两个声道一样）
            var engineSample: Float = 0
            if engineLevel > 0.001 {
                for k in 0..<engineFrequencies.count {
                    phases[k] += 2 * .pi * engineFrequencies[k] * dt
                    if phases[k] > 2 * .pi { phases[k] -= 2 * .pi }
                    engineSample += sin(phases[k]) * engineAmplitudes[k]
                }
                rumble = rumble * 0.995 + white() * 0.06
                engineSample = (engineSample + rumble * 1.6) * engineLevel * 0.5
            }

            // 叮：两个泛音，0.8 秒衰减
            var ding: Float = 0
            if dingTime >= 0 {
                let env = exp(-dingTime * 5)
                ding = (sin(2 * .pi * 880 * dingTime) + 0.5 * sin(2 * .pi * 1320 * dingTime)) * env * 0.12
                dingTime += dt
                if dingTime > 1.2 { dingTime = -1 }
            }

            // 开伞：0.5 秒的扫频呼声 + 1.5 秒越来越慢的布抖动
            var deploy: Float = 0
            if deployTime >= 0 {
                let w = white()
                let sweep = 2200 * exp(-deployTime * 5) + 250
                let f = 2 * sin(Float.pi * min(sweep, 4000) / sampleRate)
                let high = w - deployLow - 0.9 * deployBand
                deployBand += f * high
                deployLow += f * deployBand
                let whoosh = deployBand * exp(-deployTime * 3.2) * 0.9
                let flapRate = 11 * exp(-deployTime * 0.8) + 3
                let flap = max(0, sin(2 * .pi * flapRate * deployTime)) * exp(-deployTime * 1.6) * w * 0.5
                deploy = whoosh + flap
                deployTime += dt
                if deployTime > 2.5 { deployTime = -1 }
            }

            let intensity = min(speed / 90, 1.2)
            let amplitude = pow(intensity, 1.5) * (0.55 + 0.45 * gust) * 0.35
            let center = 180 + speed * 5 + gust * 160
            let f = 2 * sin(Float.pi * min(center, 4000) / sampleRate)
            for channel in 0..<min(buffers.count, 2) {
                let w = white()
                brown[channel] = brown[channel] * 0.996 + w * 0.05
                // Chamberlin 状态变量滤波器，取带通
                let high = w - low[channel] - 1.2 * band[channel]
                band[channel] += f * high
                low[channel] += f * band[channel]
                let wind = (brown[channel] * 0.9 + band[channel] * 0.6) * amplitude
                let sample = (wind + engineSample + ding + deploy) * gain
                buffers[channel].mData?.assumingMemoryBound(to: Float.self)[i] = sample
            }
        }
    }
}
