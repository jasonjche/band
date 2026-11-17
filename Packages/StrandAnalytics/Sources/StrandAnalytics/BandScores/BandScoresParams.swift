import Foundation

extension BandScores {

    /// Fitted constants decoded from the bundled `params.json`.
    public struct Params: Sendable {
        public var loadIndex: BandLoadIndex.Params
        public var sleepLedger: BandSleepLedger.Params
        public var baselines: BandBaselines.Bundle
        public var consistency: BandConsistency.Params
        public var sleepPerformance: BandSleepPerformance.Params
        public var recovery: BandRecovery.Params
        public var recoveryV3: BandRecoveryV3.Params
        public var baselinesMinP: Int
        public var schemaVersion: Int
        /// Frozen local-level Kalman for HRV at a source change. Default EWMA is unchanged.
        public var hrvKalman: BandBaselines.KalmanParams
        /// Default `.ewma` (round-2 goldens). `.kalman` is switch_over.md policy (c).
        public var hrvBaselineMode: BandBaselines.HrvMode

        public static func bundled() throws -> Params {
            guard let url = Bundle.module.url(forResource: "params", withExtension: "json") else {
                throw ParamsError.missingResource
            }
            let data = try Data(contentsOf: url)
            return try decode(data)
        }

        public static func decode(_ data: Data) throws -> Params {
            let raw = try JSONDecoder().decode(File.self, from: data)
            let v3 = raw.recoveryV3
            guard v3.schemaVersion == BandRecoveryV3.expectedSchemaVersion else {
                throw ParamsError.unsupportedRecoveryV3Schema(v3.schemaVersion)
            }
            let recoveryV3 = BandRecoveryV3.Params(
                schemaVersion: v3.schemaVersion,
                variant: v3.variant,
                halfLifeDays: v3.halfLifeDays,
                zScale: v3.zScale,
                zFloor: v3.zFloor,
                warmupNights: v3.warmupNights,
                b0: v3.params.b0,
                wHrv: v3.params.wHrv,
                wSleep: v3.params.wSleep,
                sleepCenter: v3.sleepCenter,
                sleepScale: v3.sleepScale,
                zClip: v3.zClip,
                etaClip: v3.etaClip,
                recLo: v3.recClip[0],
                recHi: v3.recClip[1]
            )
            return Params(
                loadIndex: BandLoadIndex.Params(
                    intercept: raw.loadIndex.coef.intercept,
                    logEnergy: raw.loadIndex.coef.logEnergy,
                    logEdwards: raw.loadIndex.coef.logEdwards,
                    wZ45: raw.loadIndex.coef.wZ45,
                    logEnergyMedianTrain: raw.loadIndex.fills.logEnergyMedianTrain,
                    logEdwardsMissing: raw.loadIndex.fills.logEdwardsMissing,
                    wZ45Missing: raw.loadIndex.fills.wZ45Missing
                ),
                sleepLedger: BandSleepLedger.Params(
                    variant: raw.sleepLedger.primary.variant,
                    base: raw.sleepLedger.primary.params.base,
                    a: raw.sleepLedger.primary.params.a,
                    b: raw.sleepLedger.primary.params.b,
                    decay: raw.sleepLedger.primary.params.decay,
                    gain: raw.sleepLedger.primary.params.gain,
                    credit: raw.sleepLedger.primary.params.credit,
                    knap: raw.sleepLedger.primary.params.knap,
                    bias: raw.sleepLedger.primary.params.bias,
                    cap: raw.sleepLedger.primary.params.cap,
                    initDebt: raw.sleepLedger.primary.params.initDebt,
                    needLo: raw.sleepLedger.primary.needClip[0],
                    needHi: raw.sleepLedger.primary.needClip[1]
                ),
                baselines: BandBaselines.Bundle(
                    hrvLn: .from(raw.baselines.hrvLn),
                    rhr: .from(raw.baselines.rhr),
                    resp: .from(raw.baselines.resp),
                    temp: .from(raw.baselines.temp),
                    spo2: .from(raw.baselines.spo2)
                ),
                consistency: BandConsistency.Params(
                    nNights: raw.consistency.nNights,
                    mode: raw.consistency.mode,
                    recency: raw.consistency.recency,
                    intercept: raw.consistency.affine.intercept,
                    slope: raw.consistency.affine.slope,
                    clipLo: raw.consistency.clip[0],
                    clipHi: raw.consistency.clip[1]
                ),
                sleepPerformance: BandSleepPerformance.Params(
                    intercept: raw.sleepPerformance.params.intercept,
                    wHvn: raw.sleepPerformance.params.wHvn,
                    wCons: raw.sleepPerformance.params.wCons,
                    wEff: raw.sleepPerformance.params.wEff,
                    hvnPower: raw.sleepPerformance.params.hvnPower,
                    hvnCap: raw.sleepPerformance.params.hvnCap
                ),
                recovery: BandRecovery.Params(
                    b0: raw.recovery.params.b0,
                    wHrv: raw.recovery.params.wHrv,
                    wRhr: raw.recovery.params.wRhr,
                    wRr: raw.recovery.params.wRr,
                    wTemp: raw.recovery.params.wTemp,
                    wSpo2: raw.recovery.params.wSpo2,
                    wSleep: raw.recovery.params.wSleep,
                    tempDeadzone: raw.recovery.params.tempDeadzone,
                    spo2Deadzone: raw.recovery.params.spo2Deadzone
                ),
                recoveryV3: recoveryV3,
                baselinesMinP: raw.baselinesMinP,
                schemaVersion: raw.schemaVersion,
                hrvKalman: .bundled,
                hrvBaselineMode: .ewma
            )
        }

        public enum ParamsError: Error {
            case missingResource
            case unsupportedRecoveryV3Schema(Int)
        }
    }
}

private struct File: Decodable {
    var schemaVersion: Int
    var loadIndex: LoadIndex
    var sleepLedger: SleepLedger
    var baselines: Baselines
    var consistency: Consistency
    var sleepPerformance: SleepPerf
    var recovery: Recovery
    var recoveryV3: RecoveryV3
    var baselinesMinP: Int

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case loadIndex = "load_index"
        case sleepLedger = "sleep_ledger"
        case baselines, consistency
        case sleepPerformance = "sleep_performance"
        case recovery
        case recoveryV3 = "recovery_v3"
        case baselinesMinP = "baselines_min_p"
    }

    struct LoadIndex: Decodable {
        var coef: Coef
        var fills: Fills
        struct Coef: Decodable {
            var intercept: Double
            var logEnergy: Double
            var logEdwards: Double
            var wZ45: Double
            enum CodingKeys: String, CodingKey {
                case intercept
                case logEnergy = "log_energy"
                case logEdwards = "log_edwards"
                case wZ45 = "w_z45"
            }
        }
        struct Fills: Decodable {
            var logEnergyMedianTrain: Double
            var logEdwardsMissing: Double
            var wZ45Missing: Double
            enum CodingKeys: String, CodingKey {
                case logEnergyMedianTrain = "log_energy_median_train"
                case logEdwardsMissing = "log_edwards_missing"
                case wZ45Missing = "w_z45_missing"
            }
        }
    }

    struct SleepLedger: Decodable {
        var primary: Primary
        struct Primary: Decodable {
            var variant: String
            var params: P
            var needClip: [Double]
            enum CodingKeys: String, CodingKey {
                case variant, params
                case needClip = "need_clip"
            }
            struct P: Decodable {
                var base, a, b, decay, gain, credit, knap, bias, cap: Double
                var initDebt: Double
                enum CodingKeys: String, CodingKey {
                    case base, a, b, decay, gain, credit, knap, bias, cap
                    case initDebt = "init_debt"
                }
            }
        }
    }

    struct Signal: Decodable {
        var method: String
        var halfLife: Double?
        var window: Double
        var outlierK: Double
        var zScale: Double
        var floor: Double
        enum CodingKeys: String, CodingKey {
            case method, window, floor
            case halfLife = "half_life"
            case outlierK = "outlier_k"
            case zScale = "z_scale"
        }
    }

    struct Baselines: Decodable {
        var hrvLn: Signal
        var rhr: Signal
        var resp: Signal
        var temp: Signal
        var spo2: Signal
        enum CodingKeys: String, CodingKey {
            case hrvLn = "hrv_ln"
            case rhr, resp, temp, spo2
        }
    }

    struct Consistency: Decodable {
        var nNights: Int
        var mode: String
        var recency: Double
        var affine: Affine
        var clip: [Double]
        enum CodingKeys: String, CodingKey {
            case mode, recency, affine, clip
            case nNights = "n_nights"
        }
        struct Affine: Decodable { var intercept: Double; var slope: Double }
    }

    struct SleepPerf: Decodable {
        var params: P
        struct P: Decodable {
            var intercept, wHvn, wCons, wEff, hvnPower, hvnCap: Double
            enum CodingKeys: String, CodingKey {
                case intercept
                case wHvn = "w_hvn"
                case wCons = "w_cons"
                case wEff = "w_eff"
                case hvnPower = "hvn_power"
                case hvnCap = "hvn_cap"
            }
        }
    }

    struct Recovery: Decodable {
        var params: P
        struct P: Decodable {
            var b0, wHrv, wRhr, wRr, wTemp, wSpo2, wSleep, tempDeadzone, spo2Deadzone: Double
            enum CodingKeys: String, CodingKey {
                case b0
                case wHrv = "w_hrv"
                case wRhr = "w_rhr"
                case wRr = "w_rr"
                case wTemp = "w_temp"
                case wSpo2 = "w_spo2"
                case wSleep = "w_sleep"
                case tempDeadzone = "temp_deadzone"
                case spo2Deadzone = "spo2_deadzone"
            }
        }
    }

    struct RecoveryV3: Decodable {
        var schemaVersion: Int
        var variant: String
        var halfLifeDays: Double
        var zScale: Double
        var zFloor: Double
        var warmupNights: Int
        var sleepCenter: Double
        var sleepScale: Double
        var zClip: Double
        var etaClip: Double
        var recClip: [Double]
        var params: P
        enum CodingKeys: String, CodingKey {
            case variant, params
            case schemaVersion = "schema_version"
            case halfLifeDays = "half_life_days"
            case zScale = "z_scale"
            case zFloor = "z_floor"
            case warmupNights = "warmup_nights"
            case sleepCenter = "sleep_center"
            case sleepScale = "sleep_scale"
            case zClip = "z_clip"
            case etaClip = "eta_clip"
            case recClip = "rec_clip"
        }
        struct P: Decodable {
            var b0, wHrv, wSleep: Double
            enum CodingKeys: String, CodingKey {
                case b0
                case wHrv = "w_hrv"
                case wSleep = "w_sleep"
            }
        }
    }
}

extension BandBaselines.Config {
    fileprivate static func from(_ s: File.Signal) -> BandBaselines.Config {
        BandBaselines.Config(
            method: BandBaselines.Method(rawValue: s.method) ?? .ewma,
            halfLife: s.halfLife ?? 14,
            window: s.window,
            outlierK: s.outlierK,
            zScale: s.zScale,
            floor: s.floor
        )
    }
}
