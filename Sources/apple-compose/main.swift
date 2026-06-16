import AppleComposeCore
import ArgumentParser
import Foundation
import Yams

@main
struct AppleCompose: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apple-compose",
        abstract: "Run modern Docker Compose projects on Apple's container CLI.",
        subcommands: [Up.self, Down.self, Plan.self, Config.self],
        defaultSubcommand: Plan.self
    )
}

struct CommonOptions: ParsableArguments {
    @Option(name: [.customShort("f"), .customLong("file")], parsing: .upToNextOption, help: "Compose file path. Can be passed multiple times.")
    var files: [String] = []

    @Option(name: [.customShort("p"), .long], help: "Project name. Defaults to top-level name or directory name.")
    var projectName: String?

    @Option(name: .long, parsing: .upToNextOption, help: "Active Compose profile.")
    var profile: [String] = []

    @Option(name: .long, parsing: .upToNextOption, help: "Environment file used for Compose interpolation.")
    var envFile: [String] = []

    @Option(name: .long, help: "Path/name of the Apple container CLI binary.")
    var containerBin: String = "container"

    func loadProject() throws -> ComposeProject {
        try ComposeLoader().load(options: ComposeLoadOptions(
            files: files,
            projectName: projectName,
            profiles: profile,
            envFiles: envFile,
            workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        ))
    }
}

extension CompatibilityMode: ExpressibleByArgument {
    public init?(argument: String) {
        self.init(rawValue: argument)
    }
}

struct Up: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create networks/volumes, build images, and run services.")

    @OptionGroup var common: CommonOptions

    @Option(name: .long, help: "Unsupported-feature handling: strict, best-effort, or ignore.")
    var compatibilityMode: CompatibilityMode = .strict

    @Flag(name: .long, help: "Print commands instead of running them.")
    var dryRun = false

    @Flag(name: .long, help: "Do not include dependent services when specific services are selected.")
    var noDeps = false

    @Argument(help: "Optional service names to create/recreate.")
    var services: [String] = []

    func run() throws {
        let project = try common.loadProject()
        let plan = try ComposePlanner().plan(project: project, options: PlanOptions(
            action: .up,
            compatibilityMode: compatibilityMode,
            containerBinary: common.containerBin,
            serviceNames: services,
            includeDependencies: !noDeps
        ))
        printIssues(plan.issues, mode: compatibilityMode)
        try CommandRunner(dryRun: dryRun).run(plan)
    }
}

struct Down: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop/delete project containers and project networks.")

    @OptionGroup var common: CommonOptions

    @Option(name: .long, help: "Unsupported-feature handling: strict, best-effort, or ignore.")
    var compatibilityMode: CompatibilityMode = .bestEffort

    @Flag(name: .long, help: "Remove named project volumes as well.")
    var volumes = false

    @Flag(name: .long, help: "Print commands instead of running them.")
    var dryRun = false

    func run() throws {
        let project = try common.loadProject()
        let plan = try ComposePlanner().plan(project: project, options: PlanOptions(action: .down, compatibilityMode: compatibilityMode, containerBinary: common.containerBin, removeVolumes: volumes))
        printIssues(plan.issues, mode: compatibilityMode)
        try CommandRunner(dryRun: dryRun).run(plan)
    }
}

struct Plan: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show compatibility findings and generated Apple container commands.")

    @OptionGroup var common: CommonOptions

    @Option(name: .long, help: "Action to plan: up or down.")
    var action: PlanActionArgument = .up

    @Flag(name: .long, help: "Include volume delete commands when planning down.")
    var volumes = false

    @Flag(name: .long, help: "Do not include dependent services when specific services are selected.")
    var noDeps = false

    @Argument(help: "Optional service names to include in the plan.")
    var services: [String] = []

    func run() throws {
        let project = try common.loadProject()
        let plan = try ComposePlanner().preview(
            project: project,
            action: action.value,
            containerBinary: common.containerBin,
            removeVolumes: volumes,
            serviceNames: services,
            includeDependencies: !noDeps
        )
        print("Project: \(project.name)")
        printIssues(plan.issues, mode: .bestEffort)
        if !plan.issues.isEmpty {
            print("")
        }
        for artifact in plan.artifacts {
            let descriptor = artifact.sensitive ? "sensitive file" : "file"
            print("# write \(descriptor) \(artifact.path.path) mode \(String(artifact.mode, radix: 8))")
        }
        for command in plan.commands {
            if let note = command.note {
                print("# \(note)")
            }
            print(command.display)
        }
    }
}

enum PlanActionArgument: String, ExpressibleByArgument {
    case up
    case down

    var value: PlanAction {
        switch self {
        case .up: .up
        case .down: .down
        }
    }
}

struct Config: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print the merged, interpolated Compose YAML.")

    @OptionGroup var common: CommonOptions

    @Argument(help: "Optional service names to include in the config output.")
    var services: [String] = []

    func run() throws {
        let project = try common.loadProject()
        let planner = ComposePlanner()
        let selectedServices = try planner.selectedServices(
            project: project,
            serviceNames: services,
            includeDependencies: true,
            allowEmpty: true,
            missingOptionalDependenciesAreErrors: true
        )
        try planner.validateResourceReferences(
            project: project,
            services: selectedServices,
            includeSkippedBuildSecrets: true
        )
        let selectedNames = Set(selectedServices.map(\.name))
        let raw = filteredConfigRaw(project: project, selectedServiceNames: selectedNames, explicitServiceSelection: !services.isEmpty)
        print(try Yams.dump(object: raw.toAny(), sortKeys: true))
    }
}

func filteredConfigRaw(project: ComposeProject, selectedServiceNames: Set<String>, explicitServiceSelection: Bool) -> YAMLValue {
    guard var root = project.raw.map else {
        return project.raw
    }
    guard let services = root["services"]?.map else {
        return project.raw
    }

    var filteredServices: [String: YAMLValue] = [:]
    for name in selectedServiceNames.sorted() {
        guard let service = services[name] else {
            continue
        }
        filteredServices[name] = explicitServiceSelection
            ? pruneUnselectedOptionalDependencies(serviceName: name, service: service, project: project, selectedServiceNames: selectedServiceNames)
            : service
    }
    root["services"] = .map(filteredServices)
    root = filterConfigResources(root, project: project, selectedServiceNames: selectedServiceNames)
    return .map(root)
}

func filterConfigResources(
    _ root: [String: YAMLValue],
    project: ComposeProject,
    selectedServiceNames: Set<String>
) -> [String: YAMLValue] {
    var root = root
    let usage = configResourceUsage(project: project, selectedServiceNames: selectedServiceNames)
    root = filterConfigNetworkSection(root, includedKeys: usage.networks)
    root = filterConfigResourceSection(root, section: "volumes", includedKeys: usage.volumes)
    root = filterConfigResourceSection(root, section: "secrets", includedKeys: usage.secrets)
    root = filterConfigResourceSection(root, section: "configs", includedKeys: usage.configs)
    root = filterConfigResourceSection(root, section: "models", includedKeys: usage.models)
    return root
}

func filterConfigNetworkSection(
    _ root: [String: YAMLValue],
    includedKeys: Set<String>
) -> [String: YAMLValue] {
    var networks = root["networks"]?.map ?? [:]
    if includedKeys.contains("default"), networks["default"] == nil {
        networks["default"] = .map([:])
    }

    let filtered = networks.filter { includedKeys.contains($0.key) }
    var root = root
    if filtered.isEmpty {
        root.removeValue(forKey: "networks")
    } else {
        root["networks"] = .map(filtered)
    }
    return root
}

func filterConfigResourceSection(
    _ root: [String: YAMLValue],
    section: String,
    includedKeys: Set<String>
) -> [String: YAMLValue] {
    guard let resources = root[section]?.map else {
        return root
    }
    let filtered = resources.filter { includedKeys.contains($0.key) }
    var root = root
    if filtered.isEmpty {
        root.removeValue(forKey: section)
    } else {
        root[section] = .map(filtered)
    }
    return root
}

func configResourceUsage(project: ComposeProject, selectedServiceNames: Set<String>) -> (
    networks: Set<String>,
    volumes: Set<String>,
    secrets: Set<String>,
    configs: Set<String>,
    models: Set<String>
) {
    var networks: Set<String> = []
    var volumes: Set<String> = []
    var secrets: Set<String> = []
    var configs: Set<String> = []
    var models: Set<String> = []

    for serviceName in selectedServiceNames {
        guard let service = project.services[serviceName] else {
            continue
        }
        if service.networkMode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "none" {
            if let serviceNetworks = service.networks, !serviceNetworks.isEmpty {
                networks.formUnion(serviceNetworks.keys)
            } else {
                networks.insert("default")
            }
        }

        for volume in service.volumes {
            guard configVolumeIsNamed(volume), let source = volume.source else {
                continue
            }
            volumes.insert(source)
        }

        secrets.formUnion(service.secrets.map(\.source))
        if service.build != nil {
            secrets.formUnion(service.build?.secrets.map(\.source) ?? [])
        }
        configs.formUnion(service.configs.map(\.source))
        models.formUnion(service.modelReferences)
    }

    return (networks, volumes, secrets, configs, models)
}

func configVolumeIsNamed(_ volume: ServiceVolume) -> Bool {
    if let type = volume.type {
        return type == "volume"
    }
    guard let source = volume.source else {
        return false
    }
    return !configVolumeSourceLooksLikeHostPath(source)
}

func configVolumeSourceLooksLikeHostPath(_ source: String) -> Bool {
    source.hasPrefix(".") || source.hasPrefix("/") || source.hasPrefix("~")
}

func pruneUnselectedOptionalDependencies(
    serviceName: String,
    service: YAMLValue,
    project: ComposeProject,
    selectedServiceNames: Set<String>
) -> YAMLValue {
    guard var serviceMap = service.map,
          var dependsOn = serviceMap["depends_on"]?.map,
          let parsedService = project.services[serviceName] else {
        return service
    }

    for (dependency, spec) in parsedService.dependsOn where !spec.required && !selectedServiceNames.contains(dependency) {
        dependsOn.removeValue(forKey: dependency)
    }
    if dependsOn.isEmpty {
        serviceMap.removeValue(forKey: "depends_on")
    } else {
        serviceMap["depends_on"] = .map(dependsOn)
    }
    return .map(serviceMap)
}

func printIssues(_ issues: [CompatibilityIssue], mode: CompatibilityMode) {
    guard mode != .ignore, !issues.isEmpty else { return }
    let warnings = issues.filter { $0.severity == .warning }
    let errors = issues.filter { $0.severity == .error }
    if !errors.isEmpty {
        print("Unsupported Compose features:")
        for issue in errors {
            print("- \(issue.rendered)")
        }
    }
    if !warnings.isEmpty {
        print("Compatibility warnings:")
        for issue in warnings {
            print("- \(issue.rendered)")
        }
    }
}
