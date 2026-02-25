// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pixe",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "pixe", targets: ["Pixe"])
    ],
    targets: [
        .executableTarget(
            name: "Pixe",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "PixeTests",
            dependencies: ["Pixe"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
