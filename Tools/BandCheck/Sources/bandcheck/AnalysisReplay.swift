import Foundation
import StrandAnalytics
import WhoopProtocol

/// Extra analysis-pass replay used only when BAND_PERF=1. Not a gate: scores are counted,
/// never compared, so agreement output stays byte-identical to a run without this path.
func replayAnalysisPass(hrByDay: [String: [HRSample]],
                        gravByDay: [String: [GravitySample]],
                        stepsByDay: [String: [StepSample]],
                        rrByDay: [String: [RRInterval]],
                        skinByDay: [String: [SkinTempSample]],
                        cfg: CheckConfig) {
    var analyzeDays = 0
    var sleepSessions = 0
    var workouts = 0
    let days = hrByDay.keys.sorted()
    for day in days {
        let hr = hrByDay[day] ?? []
        let grav = gravByDay[day] ?? []
        let steps = stepsByDay[day] ?? []
        let rr = rrByDay[day] ?? []
        let skin = skinByDay[day] ?? []
        guard !hr.isEmpty else { continue }

        Perf.measureDay("AnalyticsEngine.analyzeDay", day: day) {
            let result = AnalyticsEngine.analyzeDay(
                day: day, hr: hr, rr: rr, gravity: grav, steps: steps,
                dayHr: hr, daySteps: steps, dayGravity: grav,
                skinTemp: skin, profile: cfg.profile,
                tzOffsetSeconds: cfg.calendar.timeZone.secondsFromGMT(),
                useSleepStagerV2: true, useSleepStageLearned: true,
                useBandStrain: true)
            analyzeDays += 1
            sleepSessions += result.sleepSessions.count
            workouts += result.workouts.count
        }
    }
    fputs("BAND_PERF analysis replay  days \(analyzeDays)  sleepSessions \(sleepSessions)  workouts \(workouts)\n",
          stderr)
}
