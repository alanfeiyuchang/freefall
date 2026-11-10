import AVFoundation
import os

/// 跳伞的声音，全部程序合成，不用素材。
///
/// 持续的：
/// - 发动机：螺旋桨叶片通过频率（四台略微失谐，嗡嗡地拍）+ 低频轰鸣，出舱后随距离变小
/// - 自由落体的风：低沉的呼啸（棕噪声）+ 嘶嘶声（带通，速度越快越高）+ 阵风的冲击 + 跳伞服被扯的啪啪声
/// - 伞下：轻风 + 伞布抖动
/// - 近地和落地后：海浪拍礁、海鸥（左右随机）
/// - 高度表报警：三声一组（可以开伞），急促连响（低于决断高度）
/// 一次性的：抓扶杆、绿灯「叮」、拉手撕开、开伞（呼——、布抖、张满时「嘭」）、落地、摔、落水、赢/输
final class JumpAudio: @unchecked Sendable {
    struct Params: Sendable {
        var speed: Float = 0
        var gain: Float = 0
        var engine: Float = 0
        var alarm = 0
        /// 伞下的程度 0…1（风变轻、多了伞布声）
        var canopy: Float = 0
        /// 海浪和海鸥 0…1
        var ambience: Float = 0
        /// 转弯的快慢 0…1（风声大一点）
        var turn: Float = 0
        // 一次性的事件：计数加一就触发一次（渲染线程只管加，音频线程看到变化就播）
        var dings = 0, grabs = 0, rips = 0, deploys = 0, thuds = 0, crashes = 0, splashes = 0, wins = 0, fails = 0
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
    private let dt: Float
    private var rng: UInt32 = 0x9E37_79B9

    // 平滑后的参数
    private var speed: Float = 0, gain: Float = 0, engineLevel: Float = 0
    private var canopy: Float = 0, ambience: Float = 0, turn: Float = 0

    // 风
    private var brown: [Float] = [0, 0], low: [Float] = [0, 0], band: [Float] = [0, 0]
    private var gust: Float = 0.5, gustTarget: Float = 0.5, gustCountdown = 0
    private var buffet: Float = 0, buffetTarget: Float = 0, buffetCountdown = 0
    private var flapPhase: Float = 0
    // 发动机
    private var phases: [Float] = [0, 0, 0, 0, 0, 0]
    private var rumble: Float = 0
    // 伞布
    private var fabricLow: Float = 0, fabricPhase: Float = 0
    // 海浪
    private var surfLow: [Float] = [0, 0], surfPhase: Float = 0, surfPeriod: Float = 7, hissBand: Float = 0, hissLow: Float = 0
    // 海鸥
    private var gullCountdown: Float = 2, gullTime: Float = -1, gullCalls = 0, gullPitch: Float = 1300
    private var gullPan: Float = 0, gullPhase: [Float] = [0, 0, 0], gullRasp: Float = 0
    // 报警
    private var alarmTime: Float = 0, alarmPhase: Float = 0
    // 一次性事件
    private var counters = [Int](repeating: 0, count: 9)
    private var eventTime = [Float](repeating: -1, count: 9)
    private var deployLow: Float = 0, deployBand: Float = 0
    private var splashLow: Float = 0

    private enum Event: Int { case ding, grab, rip, deploy, thud, crash, splash, win, fail }

    init(sampleRate: Float) {
        self.sampleRate = sampleRate
        dt = 1 / sampleRate
    }

    private func white() -> Float {
        rng ^= rng << 13
        rng ^= rng >> 17
        rng ^= rng << 5
        return Float(rng) / Float(UInt32.max) * 2 - 1
    }

    private func unit() -> Float { white() * 0.5 + 0.5 }

    func render(frameCount: Int, into list: UnsafeMutablePointer<AudioBufferList>, params: JumpAudio.Params) {
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let counts = [params.dings, params.grabs, params.rips, params.deploys, params.thuds, params.crashes,
                      params.splashes, params.wins, params.fails]
        for i in 0..<counts.count where counts[i] != counters[i] {
            counters[i] = counts[i]
            eventTime[i] = 0
        }
        let smoothing = 1 - exp(-1 / (0.05 * sampleRate))      // 参数 50 ms 平滑，避免拉链声
        let slow = 1 - exp(-1 / (0.8 * sampleRate))
        let engineFrequencies: [Float] = [67.6, 68.3, 69.1, 136.4, 204.9, 272.3]
        let engineAmplitudes: [Float] = [0.22, 0.2, 0.18, 0.12, 0.06, 0.03]
        let left = buffers.count > 0 ? buffers[0].mData?.assumingMemoryBound(to: Float.self) : nil
        let right = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : left

        for i in 0..<frameCount {
            speed += (params.speed - speed) * smoothing
            gain += (params.gain - gain) * smoothing
            engineLevel += (params.engine - engineLevel) * smoothing
            canopy += (params.canopy - canopy) * slow
            ambience += (params.ambience - ambience) * slow
            turn += (params.turn - turn) * smoothing

            var outL: Float = 0, outR: Float = 0

            // ---- 风 ----
            gustCountdown -= 1
            if gustCountdown <= 0 {
                gustTarget = 0.25 + 0.75 * unit()
                gustCountdown = Int(sampleRate * (0.4 + 0.8 * unit()))
            }
            gust += (gustTarget - gust) * (1 - exp(-1 / (0.6 * sampleRate)))
            buffetCountdown -= 1
            if buffetCountdown <= 0 {
                buffetTarget = unit()
                buffetCountdown = Int(sampleRate * (0.05 + 0.15 * unit()))
            }
            buffet += (buffetTarget - buffet) * (1 - exp(-1 / (0.04 * sampleRate)))
            let freefall = 1 - canopy
            let intensity = min(speed / 90, 1.2)
            var windAmp = pow(intensity, 1.5) * (0.5 + 0.5 * gust) * 0.33
            windAmp *= 1 + freefall * intensity * 0.6 * (buffet - 0.5)          // 阵风的冲击
            windAmp *= 1 - 0.55 * canopy                                       // 伞下风轻多了
            windAmp *= 1 + turn * 0.6
            // 跳伞服被扯：20 Hz 上下的啪啪声，速度越快越明显
            flapPhase += (17 + 9 * gust) * dt
            if flapPhase > 1 { flapPhase -= 1 }
            let flap = freefall * min(speed / 80, 1) * max(0, sin(2 * .pi * flapPhase)) * 0.35
            let center = 180 + speed * 5 + gust * 160
            let f = 2 * sin(Float.pi * min(center, 4000) / sampleRate)
            for c in 0..<2 {
                let w = white()
                brown[c] = brown[c] * 0.996 + w * 0.05
                let high = w - low[c] - 1.2 * band[c]
                band[c] += f * high
                low[c] += f * band[c]
                let s = (brown[c] * 0.9 + band[c] * 0.6) * windAmp + band[c] * flap * windAmp * 2
                if c == 0 { outL += s } else { outR += s }
            }

            // ---- 伞布：轻轻抖（5~9 Hz 一阵阵）----
            if canopy > 0.01 {
                fabricPhase += (5.5 + 3.5 * gust) * dt
                if fabricPhase > 1 { fabricPhase -= 1 }
                fabricLow = fabricLow * 0.97 + white() * 0.03
                let rustle = fabricLow * (0.4 + 0.6 * max(0, sin(2 * .pi * fabricPhase))) * canopy * (0.5 + turn) * 0.9
                outL += rustle; outR += rustle * 0.85
            }

            // ---- 发动机 ----
            if engineLevel > 0.001 {
                var e: Float = 0
                for k in 0..<engineFrequencies.count {
                    phases[k] += 2 * .pi * engineFrequencies[k] * dt
                    if phases[k] > 2 * .pi { phases[k] -= 2 * .pi }
                    e += sin(phases[k]) * engineAmplitudes[k]
                }
                rumble = rumble * 0.995 + white() * 0.06
                e = (e + rumble * 1.6) * engineLevel * 0.5
                outL += e; outR += e
            }

            // ---- 海浪和海鸥 ----
            if ambience > 0.01 {
                surfPhase += dt / surfPeriod
                if surfPhase > 1 { surfPhase -= 1; surfPeriod = 6 + 4 * unit() }
                let swell = pow(max(0, sin(.pi * surfPhase)), 3)
                let crash = pow(max(0, sin(.pi * min(surfPhase * 1.4, 1))), 8)
                for c in 0..<2 {
                    surfLow[c] = surfLow[c] * 0.985 + white() * 0.04
                    let s = surfLow[c] * (0.25 + 0.75 * swell) * ambience * 1.1
                    if c == 0 { outL += s } else { outR += s }
                }
                // 碎浪的嘶嘶声
                let w = white()
                let fh = 2 * sin(Float.pi * 3200 / sampleRate)
                let h = w - hissLow - 0.8 * hissBand
                hissBand += fh * h
                hissLow += fh * hissBand
                let hiss = hissBand * crash * ambience * 0.06
                outL += hiss; outR += hiss

                gullCountdown -= dt
                if gullCountdown <= 0 && gullTime < 0 {
                    gullTime = 0
                    gullCalls = 1 + Int(unit() * 3)
                    gullPitch = 1100 + 500 * unit()
                    gullPan = white() * 0.8
                    gullCountdown = 3 + 6 * unit()
                }
                if gullTime >= 0 {
                    let callLength: Float = 0.42, gap: Float = 0.12
                    let local = fmod(gullTime, callLength + gap)
                    if local < callLength {
                        let x = local / callLength
                        // 「kee-ow」：音高先往上冲再往下掉，带三个泛音和一点沙哑
                        let pitch = gullPitch * (1 + 0.45 * sin(.pi * pow(x, 0.6))) * (1 - 0.25 * x)
                        for k in 0..<3 {
                            gullPhase[k] += 2 * .pi * pitch * Float(k + 1) * dt
                            if gullPhase[k] > 2 * .pi { gullPhase[k] -= 2 * .pi }
                        }
                        gullRasp = gullRasp * 0.6 + white() * 0.4
                        let env = min(x / 0.08, 1) * pow(1 - x, 1.5)
                        let voice = (sin(gullPhase[0]) + 0.5 * sin(gullPhase[1]) + 0.25 * sin(gullPhase[2]))
                            * (0.75 + 0.25 * gullRasp) * env * 0.05 * ambience
                        outL += voice * (1 - gullPan) * 0.7
                        outR += voice * (1 + gullPan) * 0.7
                    }
                    gullTime += dt
                    if gullTime > Float(gullCalls) * (callLength + gap) { gullTime = -1 }
                }
            }

            // ---- 高度表报警 ----
            if params.alarm > 0 {
                alarmTime += dt
                let on: Bool
                if params.alarm >= 2 {
                    on = fmod(alarmTime, 0.12) < 0.06
                } else {
                    let t = fmod(alarmTime, 1.2)
                    on = t < 0.45 && fmod(t, 0.15) < 0.08
                }
                alarmPhase += 2 * .pi * 2900 * dt
                if alarmPhase > 2 * .pi { alarmPhase -= 2 * .pi }
                if on {
                    let beep = (sin(alarmPhase) + 0.3 * sin(alarmPhase * 3)) * 0.07
                    outL += beep; outR += beep
                }
            } else {
                alarmTime = 0
            }

            // ---- 一次性事件 ----
            let e = oneShots()
            outL += e
            outR += e

            left?[i] = outL * gain
            right?[i] = outR * gain
        }
    }

    /// 一次性的声音（单声道），每个事件自己的时间从 0 开始走
    private func oneShots() -> Float {
        var out: Float = 0
        func advance(_ event: Event, _ length: Float) -> Float? {
            let k = event.rawValue
            guard eventTime[k] >= 0 else { return nil }
            let t = eventTime[k]
            eventTime[k] += dt
            if eventTime[k] > length { eventTime[k] = -1 }
            return t
        }
        if let t = advance(.ding, 1.2) {
            out += (sin(2 * .pi * 880 * t) + 0.5 * sin(2 * .pi * 1320 * t)) * exp(-t * 5) * 0.12
        }
        if let t = advance(.grab, 0.25) {          // 金属扶杆、拉环：短促的「叮」
            out += (sin(2 * .pi * 1850 * t) + 0.6 * sin(2 * .pi * 2770 * t)) * exp(-t * 28) * 0.08
        }
        if let t = advance(.rip, 0.4) {            // 魔术贴撕开：一串密集的噼啪
            let crackle = unit() > 0.7 ? white() : 0
            out += crackle * exp(-t * 6) * 0.35
        }
        if let t = advance(.deploy, 3.2) {         // 呼——（扫频）+ 布抖（越来越慢）+ 张满时「嘭」
            let w = white()
            let sweep = 2200 * exp(-t * 4) + 250
            let f = 2 * sin(Float.pi * min(sweep, 4000) / sampleRate)
            let high = w - deployLow - 0.9 * deployBand
            deployBand += f * high
            deployLow += f * deployBand
            out += deployBand * exp(-t * 2.2) * 0.8
            let flapRate = 12 * exp(-t * 0.7) + 3
            out += max(0, sin(2 * .pi * flapRate * t)) * exp(-t * 1.2) * w * 0.45
            let pop = t - 2.5
            if pop > 0 { out += (sin(2 * .pi * 70 * pop) * 0.6 + w * 0.25) * exp(-pop * 14) * 0.9 }
        }
        if let t = advance(.thud, 0.5) {           // 落地：沙地上的一声闷响
            out += (sin(2 * .pi * 58 * t) * 0.7 + white() * 0.25) * exp(-t * 11) * 0.7
        }
        if let t = advance(.crash, 1.4) {          // 摔：沉重的撞击
            out += (sin(2 * .pi * 42 * t) * 0.9 + white() * 0.6) * exp(-t * 4) * 0.9
        }
        if let t = advance(.splash, 1.8) {         // 落水：「噗通」一声闷响，然后哗啦的水花
            splashLow = splashLow * 0.9 + white() * 0.1
            out += sin(2 * .pi * 90 * t * exp(-t * 3)) * exp(-t * 9) * 0.6
            out += (white() * 0.5 + splashLow * 1.5) * exp(-t * 2.5) * min(t / 0.05, 1) * 0.5
        }
        if let t = advance(.win, 1.6) {            // 赢：三个上行音
            let notes: [Float] = [523.3, 659.3, 784.0]
            for (k, freq) in notes.enumerated() {
                let start = Float(k) * 0.16
                if t > start { out += sin(2 * .pi * freq * (t - start)) * exp(-(t - start) * 3) * 0.09 }
            }
        }
        if let t = advance(.fail, 1.2) {           // 输：两个下行音
            let notes: [Float] = [392.0, 311.1]
            for (k, freq) in notes.enumerated() {
                let start = Float(k) * 0.25
                if t > start { out += sin(2 * .pi * freq * (t - start)) * exp(-(t - start) * 3) * 0.09 }
            }
        }
        return out
    }
}
