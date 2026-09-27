import Foundation

let result = PortalCLI.run(
    arguments: Array(CommandLine.arguments.dropFirst()),
    store: PortalStore()
)
if !result.stdout.isEmpty {
    FileHandle.standardOutput.write(Data(result.stdout.utf8))
}
if !result.stderr.isEmpty {
    FileHandle.standardError.write(Data(result.stderr.utf8))
}
exit(result.code)
