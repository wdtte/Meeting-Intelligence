import Foundation
import Darwin

let result = MeetingCLI.run(Array(CommandLine.arguments.dropFirst()))
FileHandle.standardOutput.write(result.stdout)
if !result.stderr.isEmpty { FileHandle.standardError.write(Data(result.stderr.utf8)) }
exit(result.exitCode)
