// swift-tools-version:5.9
// The onboarding "brain" (state machine, policy, prompts, LLM client) is plain Swift so it
// can be unit-tested and stress-tested on any machine (macOS or Linux CI) without Xcode.
// The iOS app compiles the same sources directly (PersonaOnboarding/Core).
import PackageDescription

let package = Package(
    name: "OnboardingCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "OnboardingCore", targets: ["OnboardingCore"]),
        .executable(name: "stress", targets: ["stress"]),
        .executable(name: "callsim", targets: ["callsim"]),
    ],
    targets: [
        .target(name: "OnboardingCore", path: "PersonaOnboarding/Core"),
        .executableTarget(name: "stress", dependencies: ["OnboardingCore"], path: "Tools/stress"),
        .executableTarget(name: "callsim", dependencies: ["OnboardingCore"], path: "Tools/callsim"),
        .testTarget(name: "OnboardingCoreTests", dependencies: ["OnboardingCore"], path: "Tests/OnboardingCoreTests"),
    ]
)
