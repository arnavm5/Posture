import Foundation

estimatorTests()
motionProcessingTests()
cleaningTests()
calibrationTests()
calibrationAccuracyTests()
calibrationSessionTests()
lookDownTests()
hunchTests()
bodyModelTests()
hunchStateTests()
hunchModelTests()
hunchDataQualityTests()
deskAndModelTests()
slouchTimerTests()
reviewFixTests()
relativePositionTests()
MainActor.assumeIsolated {
    dingTests()
}
finish()
