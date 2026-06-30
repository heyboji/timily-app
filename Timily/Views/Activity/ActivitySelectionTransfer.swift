import CoreTransferable
import Foundation
import UniformTypeIdentifiers

nonisolated struct ActivitySelectionTransfer: Codable, Equatable, Sendable, Transferable {
    let entryIDs: [UUID]
    let segmentIDs: [UUID]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .timilyActivitySelection)
    }
}

extension UTType {
    nonisolated static let timilyActivitySelection = UTType(
        exportedAs: "com.yauhenin.timily.activity-selection"
    )
}
