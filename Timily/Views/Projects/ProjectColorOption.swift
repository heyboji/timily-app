struct ProjectColorOption: Identifiable {
    let name: String
    let hex: String

    var id: String { hex }

    static let `default` = ProjectColorOption(name: "Indigo", hex: "#5E5CE6")

    static let all = [
        ProjectColorOption(name: "Red", hex: "#FF453A"),
        ProjectColorOption(name: "Orange", hex: "#FF9F0A"),
        ProjectColorOption(name: "Yellow", hex: "#FFD60A"),
        ProjectColorOption(name: "Green", hex: "#30D158"),
        ProjectColorOption(name: "Mint", hex: "#63E6E2"),
        ProjectColorOption(name: "Blue", hex: "#0A84FF"),
        ProjectColorOption.default,
        ProjectColorOption(name: "Purple", hex: "#BF5AF2"),
        ProjectColorOption(name: "Pink", hex: "#FF375F"),
    ]
}
