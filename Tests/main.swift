import Foundation

// Deterministic output regardless of the machine's locale.
setenv("LC_ALL", "en_US.UTF-8", 1)

print("Multi AI Usage Monitor — test suite")

runResetScheduleTests()
runAccountTests()
runParsingTests()
runBehaviourTests()
runPresentationTests()

exit(TestRunner.shared.summary())
