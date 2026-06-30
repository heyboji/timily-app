import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class TimerViewModel {
    var projectID: UUID?
    var entryDescription = ""
    var activeTimer: TimeEntry?
    var presets: [TimerPreset] = []
    var errorMessage = ""
    var isShowingError = false
    var isShowingStopConflict = false

    private let service: TimerService
    private var heartbeatTask: Task<Void, Never>?

    init(service: TimerService = TimerService()) {
        self.service = service
    }

    func refresh(in context: ModelContext) {
        do {
            let activeTimer = try service.activeTimer(in: context)
            let presets = try service.presets(in: context)
            self.activeTimer = activeTimer
            self.presets = presets

            if activeTimer == nil {
                cancelHeartbeat()
            } else {
                startHeartbeat(in: context)
            }
        } catch {
            show(error)
        }
    }

    func start(projects: [Project], in context: ModelContext) {
        let project = projectID.flatMap { selectedID in
            projects.first { $0.id == selectedID && !$0.isArchived }
        }

        do {
            activeTimer = try service.start(
                project: project,
                description: normalizedDescription,
                in: context
            )
            startHeartbeat(in: context)
            presets = try service.presets(in: context)
        } catch {
            show(error)
        }
    }

    func stop(in context: ModelContext) {
        do {
            _ = try service.stop(in: context)
            finishStop(in: context)
        } catch TimerError.stopConflictsWithExistingEntries {
            isShowingStopConflict = true
        } catch {
            show(error)
        }
    }

    func resolveStop(using resolution: TimerStopResolution, in context: ModelContext) {
        isShowingStopConflict = false

        do {
            _ = try service.stop(resolving: resolution, in: context)
            finishStop(in: context)
        } catch {
            refresh(in: context)
            show(error)
        }
    }

    func dismissStopConflict() {
        isShowingStopConflict = false
    }

    func applyPreset(_ preset: TimerPreset) {
        let values = service.fill(from: preset)
        projectID = values.project?.id
        entryDescription = values.description ?? ""
    }

    private var normalizedDescription: String? {
        let value = entryDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func finishStop(in context: ModelContext) {
        activeTimer = nil
        cancelHeartbeat()
        isShowingStopConflict = false

        do {
            presets = try service.presets(in: context)
        } catch {
            show(error)
        }
    }

    private func startHeartbeat(in context: ModelContext) {
        guard heartbeatTask == nil else { return }

        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    return
                }

                guard let self, !Task.isCancelled else { return }

                do {
                    activeTimer = try service.heartbeat(in: context)
                    if activeTimer == nil {
                        cancelHeartbeat()
                        return
                    }
                } catch {
                    show(error)
                    cancelHeartbeat()
                    return
                }
            }
        }
    }

    private func cancelHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    private func show(_ error: Error) {
        errorMessage = error.localizedDescription
        isShowingError = true
    }
}
