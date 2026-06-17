import Foundation

public struct CommandRunner {
    public var dryRun: Bool
    public var standardOutput: (String) -> Void
    public var standardError: (String) -> Void

    public init(
        dryRun: Bool = false,
        standardOutput: @escaping (String) -> Void = { print($0) },
        standardError: @escaping (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) {
        self.dryRun = dryRun
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public func run(_ plan: ComposePlan) throws {
        if dryRun {
            for artifact in plan.artifacts {
                let descriptor = artifact.sensitive ? "sensitive file" : "file"
                standardOutput("# would write \(descriptor) \(artifact.path.path) mode \(String(artifact.mode, radix: 8))")
            }
            try run(plan.commands)
            return
        }

        for artifact in plan.artifacts {
            try write(artifact)
        }
        try run(plan.commands)
    }

    public func run(_ commands: [RuntimeCommand]) throws {
        for command in commands {
            if dryRun {
                standardOutput(command.display)
                continue
            }

            if let note = command.note {
                standardError("# \(note)")
            }
            standardError("+ \(command.display)")

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command.executable] + command.arguments
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus != 0 && !command.allowFailure {
                throw ComposeError.commandFailed(command.display, process.terminationStatus)
            }
        }
    }

    private func write(_ artifact: FileArtifact) throws {
        let directory = artifact.path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try artifact.contents.write(to: artifact.path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: artifact.mode], ofItemAtPath: artifact.path.path)
    }
}
