import AppKit
import ControlCenterCore

@main
enum ControlCenterMain {
  @MainActor
  static func main() {
    let arguments = CommandLine.arguments
    let environment = ProcessInfo.processInfo.environment
    let home = FileManager.default.homeDirectoryForCurrentUser

    // Helper invocations answer and exit before any window machinery starts.
    // `bin/model-router-tray` and CI call these on the packaged binary, so
    // they must never wait on AppKit, the bridge, or a display.
    if arguments.contains(LifecycleState.queryArgument) {
      let query = LifecycleState.query(file: LifecycleState.path(environment: environment, home: home))
      FileHandle.standardOutput.write(Data((query.json + "\n").utf8))
      exit(0)
    }

    if arguments.contains("--quit-for-update") {
      SingleInstance.terminateOtherInstances()
      exit(0)
    }

    // A second launch of this bundle through LaunchServices never gets here;
    // LaunchServices reactivates the first. Only a direct binary launch can
    // find another instance running, and it leaves that instance in charge.
    if SingleInstance.anotherInstanceIsRunning() {
      exit(0)
    }

    let application = NSApplication.shared
    let delegate = AppDelegate(launchArguments: arguments, environment: environment, home: home)
    application.delegate = delegate
    withExtendedLifetime(delegate) {
      application.run()
    }
  }
}
