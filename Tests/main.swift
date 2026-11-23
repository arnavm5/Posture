import Foundation

// Usage: PostureTests <path to Resources/Models>
let resources = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources/Models")

estimatorTests()
motionProcessingTests()
cleaningTests()
calibrationTests()
hunchTests()
hunchModelTests()
hunchDataQualityTests()
deskAndModelTests()
slouchTimerTests()
reviewFixTests()
relativePositionTests()
MainActor.assumeIsolated {
    modelTests(resources: resources)
    gridTests()
    feelTests(resources: resources)
    headPoseTests()
}
finish()
