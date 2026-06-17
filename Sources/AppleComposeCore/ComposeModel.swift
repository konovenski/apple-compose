import Foundation

public struct ComposeProject: Equatable {
    public var name: String
    public var workingDirectory: URL
    public var environment: [String: String]
    public var activeProfiles: Set<String>
    public var raw: YAMLValue
    public var includeConflicts: [ComposeIncludeConflict]
    public var services: [String: ComposeService]
    public var networks: [String: ComposeNetwork]
    public var volumes: [String: ComposeVolume]
    public var secrets: [String: ComposeSecret]
    public var configs: [String: ComposeConfig]
}

public struct ComposeIncludeConflict: Equatable, Sendable {
    public var location: String
    public var message: String
}

public struct ComposeService: Equatable {
    public var name: String
    public var raw: YAMLValue
    public var image: String?
    public var build: BuildSpec?
    public var pullPolicy: String?
    public var pullRefreshAfter: String?
    public var containerName: String?
    public var profiles: [String]
    public var dependsOn: [String: ServiceDependency]
    public var links: [ServiceLink]
    public var environment: [String: String?]
    public var envFiles: [EnvFileSpec]
    public var labels: [String: String]
    public var annotations: [String: String]
    public var attach: Bool
    public var ports: [PortSpec]
    public var volumes: [ServiceVolume]
    public var volumesFrom: [VolumesFromSpec]
    public var tmpfs: [TmpfsSpec]
    public var networks: [String: NetworkAttachment]?
    public var networkMode: String?
    public var command: CommandSpec?
    public var entrypoint: CommandSpec?
    public var workingDir: String?
    public var user: String?
    public var platform: String?
    public var runtime: String?
    public var macAddress: String?
    public var cpus: String?
    public var memory: String?
    public var shmSize: String?
    public var initProcess: Bool
    public var readOnly: Bool
    public var tty: Bool
    public var stdinOpen: Bool
    public var capAdd: [String]
    public var capDrop: [String]
    public var dns: [String]
    public var dnsSearch: [String]
    public var domainName: String?
    public var dnsOptions: [String]
    public var extraHosts: [ExtraHostEntry]
    public var ulimits: [UlimitSpec]
    public var secrets: [ServiceFileGrant]
    public var configs: [ServiceFileGrant]
    public var postStart: [LifecycleHook]
    public var preStop: [LifecycleHook]
    public var stopSignal: String?
    public var stopGracePeriod: String?
    public var replicas: Int
}

public extension ComposeService {
    var modelReferences: Set<String> {
        guard let models = raw.map?["models"] else {
            return []
        }
        if let array = models.array {
            return Set(array.compactMap(\.string))
        }
        if let map = models.map {
            return Set(map.keys)
        }
        return []
    }
}

public struct BuildSpec: Equatable {
    public var context: String
    public var dockerfile: String?
    public var dockerfileInline: String?
    public var args: [String: String?]
    public var labels: [String: String]
    public var target: String?
    public var platforms: [String]
    public var noCache: Bool
    public var pull: Bool
    public var shmSize: String?
    public var ulimits: [UlimitSpec]
    public var secrets: [ServiceFileGrant]
    public var tags: [String]
}

public struct ComposeNetwork: Equatable {
    public var key: String
    public var name: String?
    public var external: Bool
    public var driver: String?
    public var driverOptions: [String: String]
    public var labels: [String: String]
    public var internalNetwork: Bool
    public var ipamSubnets: [String]
    public var enableIPv4: Bool?
    public var enableIPv6: Bool?
}

public struct ComposeVolume: Equatable {
    public var key: String
    public var name: String?
    public var external: Bool
    public var driver: String?
    public var driverOptions: [String: String]
    public var labels: [String: String]
}

public struct ComposeSecret: Equatable {
    public var key: String
    public var name: String?
    public var file: String?
    public var environment: String?
    public var external: Bool
}

public struct ComposeConfig: Equatable {
    public var key: String
    public var name: String?
    public var file: String?
    public var content: String?
    public var environment: String?
    public var external: Bool
}

public struct ServiceDependency: Equatable {
    public var condition: String?
    public var restart: Bool
    public var required: Bool
}

public struct ServiceLink: Equatable {
    public var source: String
    public var alias: String?
}

public struct EnvFileSpec: Equatable {
    public var path: String
    public var required: Bool
    public var format: String?
}

public enum CommandSpec: Equatable {
    case string(String)
    case list([String])

    public var arguments: [String] {
        switch self {
        case .string(let value):
            return ShellWords.split(value)
        case .list(let values):
            return values
        }
    }

    public var isEmptyOverride: Bool {
        arguments.isEmpty
    }
}

public struct PortSpec: Equatable {
    public var raw: String?
    public var target: String?
    public var published: String?
    public var hostIP: String?
    public var protocolName: String?
    public var appProtocol: String?
    public var name: String?
}

public struct ServiceVolume: Equatable {
    public var type: String?
    public var source: String?
    public var target: String
    public var readOnly: Bool
    public var consistency: String?
    public var shortOptions: [String]
    public var createHostPath: Bool
    public var bind: YAMLValue?
    public var volume: YAMLValue?
    public var volumeLabels: [String: String]
    public var tmpfs: YAMLValue?
}

public struct VolumesFromSpec: Equatable {
    public var source: String
    public var containerReference: Bool
    public var readOnly: Bool?
}

public struct TmpfsSpec: Equatable {
    public var target: String
    public var options: String?
}

public struct NetworkAttachment: Equatable {
    public var key: String
    public var aliases: [String]
    public var ipv4Address: String?
    public var ipv6Address: String?
    public var macAddress: String?
    public var driverOptions: [String: String]
    public var priority: Int?
    public var interfaceName: String?
    public var gwPriority: Int?
    public var linkLocalIPs: [String]
}

public struct UlimitSpec: Equatable {
    public var name: String
    public var soft: String
    public var hard: String?
}

public struct ExtraHostEntry: Equatable {
    public var host: String
    public var address: String
}

public struct ServiceFileGrant: Equatable {
    public var source: String
    public var target: String?
    public var uid: String?
    public var gid: String?
    public var mode: String?
}

public struct LifecycleHook: Equatable {
    public var command: CommandSpec
    public var user: String?
    public var privileged: Bool
    public var workingDir: String?
    public var environment: [String: String?]
}

public enum ShellWords {
    public static func split(_ input: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false

        for char in input {
            if escaped {
                current.append(char)
                escaped = false
                continue
            }
            if char == "\\" {
                escaped = true
                continue
            }
            if let activeQuote = quote {
                if char == activeQuote {
                    quote = nil
                } else {
                    current.append(char)
                }
                continue
            }
            if char == "\"" || char == "'" {
                quote = char
                continue
            }
            if char.isWhitespace {
                if !current.isEmpty {
                    result.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }
        if escaped {
            current.append("\\")
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }
}
