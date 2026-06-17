import Foundation

public enum PlanAction: String, Equatable {
    case up
    case down
}

public struct PlanOptions: Equatable {
    public var action: PlanAction
    public var compatibilityMode: CompatibilityMode
    public var containerBinary: String
    public var removeVolumes: Bool
    public var serviceNames: [String]
    public var includeDependencies: Bool

    public init(
        action: PlanAction,
        compatibilityMode: CompatibilityMode = .strict,
        containerBinary: String = "container",
        removeVolumes: Bool = false,
        serviceNames: [String] = [],
        includeDependencies: Bool = true
    ) {
        self.action = action
        self.compatibilityMode = compatibilityMode
        self.containerBinary = containerBinary
        self.removeVolumes = removeVolumes
        self.serviceNames = serviceNames
        self.includeDependencies = includeDependencies
    }
}

public struct RuntimeCommand: Equatable {
    public var executable: String
    public var arguments: [String]
    public var allowFailure: Bool
    public var note: String?

    public init(_ executable: String, _ arguments: [String], allowFailure: Bool = false, note: String? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.allowFailure = allowFailure
        self.note = note
    }

    public var display: String {
        ([executable] + arguments).map(shellQuote).joined(separator: " ")
    }
}

public struct FileArtifact: Equatable {
    public var path: URL
    public var contents: Data
    public var mode: Int
    public var sensitive: Bool

    public init(path: URL, contents: String, mode: Int, sensitive: Bool) {
        self.path = path
        self.contents = Data(contents.utf8)
        self.mode = mode
        self.sensitive = sensitive
    }

    public init(path: URL, data: Data, mode: Int, sensitive: Bool) {
        self.path = path
        self.contents = data
        self.mode = mode
        self.sensitive = sensitive
    }
}

public struct ComposePlan: Equatable {
    public var project: ComposeProject
    public var action: PlanAction
    public var commands: [RuntimeCommand]
    public var artifacts: [FileArtifact]
    public var issues: [CompatibilityIssue]
}

public struct ComposePlanner {
    public init() {}

    public func plan(project: ComposeProject, options: PlanOptions) throws -> ComposePlan {
        let services = try selectedOrderedServices(project, requested: options.serviceNames, includeDependencies: options.includeDependencies)
        try validateResourceReferences(project: project, services: services)
        let issues = CompatibilityAnalyzer().analyze(project, services: services)
        let fatal = CompatibilityAnalyzer().fatalIssues(issues, mode: options.compatibilityMode)
        if !fatal.isEmpty {
            throw ComposeError.unsupported(fatal)
        }

        let commands: [RuntimeCommand]
        let artifacts: [FileArtifact]
        switch options.action {
        case .up:
            commands = try planUp(project, services: services, containerBinary: options.containerBinary)
            artifacts = try fileArtifacts(for: project, services: activeManagedReplicaServices(services))
        case .down:
            commands = planDown(project, services: services, containerBinary: options.containerBinary, removeVolumes: options.removeVolumes, removeProjectResources: options.serviceNames.isEmpty)
            artifacts = []
        }

        return ComposePlan(project: project, action: options.action, commands: commands, artifacts: artifacts, issues: issues)
    }

    public func preview(
        project: ComposeProject,
        action: PlanAction,
        containerBinary: String = "container",
        removeVolumes: Bool = false,
        serviceNames: [String] = [],
        includeDependencies: Bool = true
    ) throws -> ComposePlan {
        let services = try selectedOrderedServices(project, requested: serviceNames, includeDependencies: includeDependencies)
        try validateResourceReferences(project: project, services: services)
        let issues = CompatibilityAnalyzer().analyze(project, services: services)
        let commands: [RuntimeCommand]
        let artifacts: [FileArtifact]
        switch action {
        case .up:
            commands = try planUp(project, services: services, containerBinary: containerBinary)
            artifacts = try fileArtifacts(for: project, services: activeManagedReplicaServices(services))
        case .down:
            commands = planDown(project, services: services, containerBinary: containerBinary, removeVolumes: removeVolumes, removeProjectResources: serviceNames.isEmpty)
            artifacts = []
        }
        return ComposePlan(project: project, action: action, commands: commands, artifacts: artifacts, issues: issues)
    }

    public func selectedServices(
        project: ComposeProject,
        serviceNames: [String] = [],
        includeDependencies: Bool = true,
        allowEmpty: Bool = false,
        missingOptionalDependenciesAreErrors: Bool = false
    ) throws -> [ComposeService] {
        let services = try selectedOrderedServices(
            project,
            requested: serviceNames,
            includeDependencies: includeDependencies,
            allowEmpty: allowEmpty,
            missingOptionalDependenciesAreErrors: missingOptionalDependenciesAreErrors
        )
        try validateResourceReferences(project: project, services: services)
        return services
    }

    public func validateResourceReferences(
        project: ComposeProject,
        services: [ComposeService],
        includeSkippedBuildSecrets: Bool = false
    ) throws {
        try validateServiceResourceReferences(
            project: project,
            services: services,
            includeSkippedBuildSecrets: includeSkippedBuildSecrets
        )
    }

    private func planUp(_ project: ComposeProject, services: [ComposeService], containerBinary: String) throws -> [RuntimeCommand] {
        var commands: [RuntimeCommand] = []
        let activeServices = activeManagedReplicaServices(services)
        let usedNetworks = collectUsedNetworks(project, services: activeServices)
        let usedVolumes = collectUsedVolumes(project, services: activeServices)

        for key in usedNetworks.sorted() {
            let network = project.networks[key] ?? ComposeNetwork(key: key, name: nil, external: false, driver: nil, driverOptions: [:], labels: [:], internalNetwork: false, ipamSubnets: [], enableIPv4: nil, enableIPv6: nil)
            if network.external {
                commands.append(RuntimeCommand(containerBinary, ["network", "inspect", actualNetworkName(network, project: project)], note: "Verify external Compose network exists before use."))
                continue
            }
            var args = ["network", "create"]
            if network.internalNetwork {
                args.append("--internal")
            }
            if let plugin = networkPluginArgument(for: network) {
                args += ["--plugin", plugin]
            }
            args += ["--label", "com.docker.compose.project=\(project.name)"]
            args += ["--label", "com.docker.compose.network=\(key)"]
            for (label, value) in network.labels.sorted(by: { $0.key < $1.key }) where !label.isEmpty {
                args += ["--label", "\(label)=\(value)"]
            }
            for (option, value) in network.driverOptions.sorted(by: { $0.key < $1.key }) {
                args += ["--option", "\(option)=\(value)"]
            }
            if let subnet = network.ipamSubnets.first(where: { !$0.contains(":") }) {
                args += ["--subnet", subnet]
            }
            if let subnetV6 = network.ipamSubnets.first(where: { $0.contains(":") }) {
                args += ["--subnet-v6", subnetV6]
            }
            args.append(actualNetworkName(network, project: project))
            commands.append(RuntimeCommand(containerBinary, args, allowFailure: true, note: "Network create is idempotent when the named network already exists."))
        }

        for key in usedVolumes.keys.sorted() {
            let volume = usedVolumes[key] ?? ComposeVolume(key: key, name: nil, external: false, driver: nil, driverOptions: [:], labels: [:])
            if volume.external {
                commands.append(RuntimeCommand(containerBinary, ["volume", "inspect", actualVolumeName(volume, project: project)], note: "Verify external Compose volume exists before use."))
                continue
            }
            var args = ["volume", "create"]
            args += ["--label", "com.docker.compose.project=\(project.name)"]
            args += ["--label", "com.docker.compose.volume=\(key)"]
            for (label, value) in volume.labels.sorted(by: { $0.key < $1.key }) where !label.isEmpty {
                args += ["--label", "\(label)=\(value)"]
            }
            if let size = volume.driverOptions["size"], !size.isEmpty {
                args += ["-s", size]
            }
            for (option, value) in volume.driverOptions.sorted(by: { $0.key < $1.key }) where option != "size" {
                args += ["--opt", "\(option)=\(value)"]
            }
            args.append(actualVolumeName(volume, project: project))
            commands.append(RuntimeCommand(containerBinary, args, allowFailure: true, note: "Volume create is idempotent when the named volume already exists."))
        }

        commands += bindHostPathCommands(project: project, services: activeServices)

        for service in activeServices where shouldBuild(service) {
            if shouldBuildWithPullFallback(service) {
                commands.append(try buildFallbackCommand(for: service, project: project, containerBinary: containerBinary))
            } else {
                commands.append(try buildCommand(for: service, project: project, containerBinary: containerBinary))
                commands += buildTagCommands(for: service, project: project, containerBinary: containerBinary)
            }
        }

        for service in activeServices where shouldPull(service) {
            commands.append(pullCommand(for: service, project: project, containerBinary: containerBinary))
        }
        for service in activeServices where shouldPullIfMissing(service) {
            commands.append(missingPullCommand(for: service, project: project, containerBinary: containerBinary))
        }
        let timeBasedPullServices = activeServices.filter { shouldPullTimeBased($0) }
        if !timeBasedPullServices.isEmpty {
            commands.append(RuntimeCommand("/bin/mkdir", ["-p", pullStateDirectory(project: project).path], note: "Create apple-compose pull policy timestamp directory."))
        }
        for service in timeBasedPullServices {
            commands.append(timeBasedPullCommand(for: service, project: project, containerBinary: containerBinary))
        }

        for service in activeServices where shouldRequireLocalImage(service) {
            commands.append(imageInspectCommand(for: service, project: project, containerBinary: containerBinary))
        }

        for service in managedContainerServices(services) {
            for replica in replicaNumbers(for: service) {
                let name = containerName(for: service, project: project, replica: replica)
                commands += execHookCommands(service.preStop, service: service, project: project, containerName: name, containerBinary: containerBinary, allowFailure: true, lifecycleName: "pre_stop")
                commands.append(stopCommand(for: service, name: name, containerBinary: containerBinary, allowFailure: true))
                commands.append(RuntimeCommand(containerBinary, ["delete", "--force", name], allowFailure: true, note: "Remove stale container before recreation."))
                commands.append(try runCommand(for: service, project: project, replica: replica, containerBinary: containerBinary))
                commands += execHookCommands(service.postStart, service: service, project: project, containerName: name, containerBinary: containerBinary, allowFailure: false, lifecycleName: "post_start")
            }
        }

        return commands
    }

    private func planDown(
        _ project: ComposeProject,
        services: [ComposeService],
        containerBinary: String,
        removeVolumes: Bool,
        removeProjectResources: Bool
    ) -> [RuntimeCommand] {
        var commands: [RuntimeCommand] = []
        let managedServices = managedContainerServices(services)
        for service in managedServices.reversed() {
            for replica in replicaNumbers(for: service).reversed() {
                let name = containerName(for: service, project: project, replica: replica)
                commands += execHookCommands(service.preStop, service: service, project: project, containerName: name, containerBinary: containerBinary, allowFailure: true, lifecycleName: "pre_stop")
                commands.append(stopCommand(for: service, name: name, containerBinary: containerBinary, allowFailure: true))
                commands.append(RuntimeCommand(containerBinary, ["delete", "--force", name], allowFailure: true))
            }
        }

        guard removeProjectResources else {
            return commands
        }

        for key in collectUsedNetworks(project, services: managedServices).sorted().reversed() {
            let network = project.networks[key] ?? ComposeNetwork(key: key, name: nil, external: false, driver: nil, driverOptions: [:], labels: [:], internalNetwork: false, ipamSubnets: [], enableIPv4: nil, enableIPv6: nil)
            if !network.external {
                commands.append(RuntimeCommand(containerBinary, ["network", "delete", actualNetworkName(network, project: project)], allowFailure: true))
            }
        }

        if removeVolumes {
            let usedVolumes = collectUsedVolumes(project, services: managedServices)
            for key in usedVolumes.keys.sorted().reversed() {
                let volume = usedVolumes[key] ?? ComposeVolume(key: key, name: nil, external: false, driver: nil, driverOptions: [:], labels: [:])
                if !volume.external {
                    commands.append(RuntimeCommand(containerBinary, ["volume", "delete", actualVolumeName(volume, project: project)], allowFailure: true))
                }
            }
        }

        return commands
    }

    private func buildCommand(for service: ComposeService, project: ComposeProject, containerBinary: String) throws -> RuntimeCommand {
        RuntimeCommand(containerBinary, try buildArguments(for: service, project: project))
    }

    private func buildFallbackCommand(for service: ComposeService, project: ComposeProject, containerBinary: String) throws -> RuntimeCommand {
        let image = imageName(for: service, project: project)
        let tags = service.build?.tags.filter { !$0.isEmpty && $0 != image } ?? []
        let script = """
        image=$1
        container_bin=$2
        platform=$3
        pull_latest=$4
        tag_count=$5
        shift 5
        tags=
        while [ "$tag_count" -gt 0 ]; do
          tags="${tags}${tags:+
        }$1"
          shift
          tag_count=$((tag_count - 1))
        done
        pull_image() {
          if [ -n "$platform" ]; then
            case "$platform" in
              */*) "$container_bin" image pull --platform "$platform" "$image" ;;
              *) "$container_bin" image pull --os "$platform" "$image" ;;
            esac
          else
            "$container_bin" image pull "$image"
          fi
        }
        should_build=0
        if [ "$pull_latest" = "1" ]; then
          pull_image || should_build=1
        elif "$container_bin" image inspect "$image" >/dev/null 2>&1; then
          exit 0
        elif ! pull_image; then
          should_build=1
        fi
        if [ "$should_build" -eq 1 ]; then
          "$@"
          if [ -n "$tags" ]; then
            printf '%s\\n' "$tags" | while IFS= read -r tag; do
              "$container_bin" image tag "$image" "$tag"
            done
          fi
        fi
        """
        let args = [
            "-c",
            script,
            "apple-compose-build-fallback",
            image,
            containerBinary,
            service.platform ?? "",
            imageUsesLatestTag(image) ? "1" : "0",
            String(tags.count)
        ] + tags + [containerBinary] + (try buildArguments(for: service, project: project))
        return RuntimeCommand("/bin/sh", args, note: "Apply Compose image+build fallback by pulling first and building only when the image is unavailable.")
    }

    private func buildArguments(for service: ComposeService, project: ComposeProject) throws -> [String] {
        guard let build = service.build else {
            throw ComposeError.invalidCompose("Service '\(service.name)' has no build section")
        }

        var args = ["build"]
        args += ["--tag", imageName(for: service, project: project)]
        if build.dockerfileInline != nil {
            args += ["--file", generatedBuildDockerfilePath(service: service, project: project).path]
        } else if let dockerfile = build.dockerfile {
            args += ["--file", buildDockerfileArgument(dockerfile, build: build, project: project)]
        }
        for (key, value) in build.args.sorted(by: { $0.key < $1.key }) where !key.isEmpty {
            if let value {
                args += ["--build-arg", "\(key)=\(value)"]
            } else if let resolved = project.environment[key] {
                args += ["--build-arg", "\(key)=\(resolved)"]
            }
        }
        for (key, value) in build.labels.sorted(by: { $0.key < $1.key }) where !key.isEmpty {
            args += ["--label", "\(key)=\(value)"]
        }
        if let target = build.target {
            args += ["--target", target]
        }
        if let platform = selectedBuildPlatform(for: service) {
            args += platformArguments(for: platform)
        }
        if build.noCache {
            args.append("--no-cache")
        }
        if build.pull {
            args.append("--pull")
        }
        for secret in build.secrets {
            args += ["--secret", try buildSecretSpec(secret, project: project)]
        }
        args.append(buildContextArgument(build.context, project: project))
        return args
    }

    private func buildTagCommands(for service: ComposeService, project: ComposeProject, containerBinary: String) -> [RuntimeCommand] {
        (service.build?.tags ?? [])
            .filter { !$0.isEmpty && $0 != imageName(for: service, project: project) }
            .map { RuntimeCommand(containerBinary, ["image", "tag", imageName(for: service, project: project), $0]) }
    }

    private func buildContextArgument(_ context: String, project: ComposeProject) -> String {
        looksLikeRemoteBuildContext(context) ? context : resolvePath(context, relativeTo: project.workingDirectory).path
    }

    private func buildDockerfileArgument(_ dockerfile: String, build: BuildSpec, project: ComposeProject) -> String {
        if looksLikeRemoteBuildContext(build.context) {
            return dockerfile
        }
        let context = resolvePath(build.context, relativeTo: project.workingDirectory)
        return resolvePath(dockerfile, relativeTo: context).path
    }

    private func buildSecretSpec(_ grant: ServiceFileGrant, project: ComposeProject) throws -> String {
        let id = grant.target ?? grant.source
        guard let secret = project.secrets[grant.source] else {
            return "id=\(id)"
        }
        if let file = secret.file {
            return "id=\(id),src=\(resolvePath(file, relativeTo: project.workingDirectory).path)"
        }
        if let environment = secret.environment {
            return "id=\(id),env=\(environment)"
        }
        return "id=\(id)"
    }

    private func selectedBuildPlatform(for service: ComposeService) -> String? {
        guard let build = service.build else {
            return service.platform
        }
        if let servicePlatform = service.platform, build.platforms.isEmpty || build.platforms.contains(servicePlatform) {
            return servicePlatform
        }
        return build.platforms.first
    }

    private func runtimePlatform(for service: ComposeService) -> String? {
        if let platform = service.platform {
            return platform
        }
        guard shouldBuild(service) else {
            return nil
        }
        return selectedBuildPlatform(for: service)
    }

    private func platformRequiresRosetta(_ platform: String) -> Bool {
        let parts = platform.lowercased().split(separator: "/").map(String.init)
        let arch = parts.count >= 2 ? parts[1] : parts.first
        return arch == "amd64" || arch == "x86_64"
    }

    private func platformArguments(for platform: String) -> [String] {
        let parts = platform.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 1 {
            return ["--os", platform]
        }
        return ["--platform", platform]
    }

    private func pullCommand(for service: ComposeService, project: ComposeProject, containerBinary: String) -> RuntimeCommand {
        RuntimeCommand(containerBinary, pullArguments(for: service, project: project))
    }

    private func missingPullCommand(for service: ComposeService, project: ComposeProject, containerBinary: String) -> RuntimeCommand {
        let image = imageName(for: service, project: project)
        let script = """
        image=$1
        container_bin=$2
        shift 2
        if ! "$container_bin" image inspect "$image" >/dev/null 2>&1; then
          "$@"
        fi
        """
        let args = ["-c", script, "apple-compose-missing-pull", image, containerBinary, containerBinary] + pullArguments(for: service, project: project)
        return RuntimeCommand("/bin/sh", args, note: "Enforce pull_policy=missing by pulling only when the image is absent locally.")
    }

    private func pullArguments(for service: ComposeService, project: ComposeProject) -> [String] {
        var args = ["image", "pull"]
        if let platform = service.platform {
            args += platformArguments(for: platform)
        }
        args.append(imageName(for: service, project: project))
        return args
    }

    private func timeBasedPullCommand(for service: ComposeService, project: ComposeProject, containerBinary: String) -> RuntimeCommand {
        let interval = pullPolicyIntervalSeconds(for: service) ?? 0
        let image = imageName(for: service, project: project)
        let script = """
        state=$1
        interval=$2
        image=$3
        shift 3
        now=$(date +%s)
        saved_image=
        last=0
        if [ -r "$state" ]; then
          {
            IFS= read -r saved_image
            IFS= read -r last
          } < "$state"
        fi
        case "$last" in ''|*[!0-9]*) last=0 ;; esac
        if [ "$saved_image" != "$image" ] || [ $((now - last)) -ge "$interval" ]; then
          "$@" && mkdir -p "$(dirname "$state")" && printf '%s\\n%s\\n' "$image" "$now" > "$state"
        fi
        """
        let args = ["-c", script, "apple-compose-time-pull", pullStatePath(for: service, project: project).path, String(interval), image, containerBinary] + pullArguments(for: service, project: project)
        return RuntimeCommand("/bin/sh", args, note: "Enforce pull_policy=\(service.pullPolicy ?? "") with apple-compose timestamp state.")
    }

    private func imageInspectCommand(for service: ComposeService, project: ComposeProject, containerBinary: String) -> RuntimeCommand {
        RuntimeCommand(
            containerBinary,
            ["image", "inspect", imageName(for: service, project: project)],
            note: "Enforce pull_policy=never by requiring the image to exist locally before run."
        )
    }

    private func stopCommand(for service: ComposeService, name: String, containerBinary: String, allowFailure: Bool) -> RuntimeCommand {
        var args = ["stop"]
        if let signal = service.stopSignal {
            args += ["--signal", signal]
        }
        let seconds = service.stopGracePeriod == nil ? 10 : composeDurationSeconds(service.stopGracePeriod)
        if let seconds {
            args += ["--time", String(seconds)]
        }
        args.append(name)
        return RuntimeCommand(containerBinary, args, allowFailure: allowFailure)
    }

    private func execHookCommands(
        _ hooks: [LifecycleHook],
        service: ComposeService,
        project: ComposeProject,
        containerName: String,
        containerBinary: String,
        allowFailure: Bool,
        lifecycleName: String
    ) -> [RuntimeCommand] {
        hooks.map { hook in
            var args = ["exec"]
            for (key, value) in hook.environment.sorted(by: { $0.key < $1.key }) where !key.isEmpty {
                if let value {
                    args += ["--env", "\(key)=\(value)"]
                } else if let resolved = project.environment[key] {
                    args += ["--env", "\(key)=\(resolved)"]
                }
            }
            if let user = hook.user ?? service.user {
                args += ["--user", user]
            }
            if let workingDir = hook.workingDir ?? service.workingDir {
                args += ["--workdir", workingDir]
            }
            args.append(containerName)
            args += lifecycleArguments(hook.command)
            return RuntimeCommand(containerBinary, args, allowFailure: allowFailure, note: "\(lifecycleName) hook for service \(service.name)")
        }
    }

    private func lifecycleArguments(_ command: CommandSpec) -> [String] {
        switch command {
        case .string(let value):
            return ["/bin/sh", "-c", value]
        case .list(let values):
            return values
        }
    }

    private func runCommand(for service: ComposeService, project: ComposeProject, replica: Int, containerBinary: String) throws -> RuntimeCommand {
        var args = ["run", "--detach", "--name", containerName(for: service, project: project, replica: replica)]

        args += ["--label", "com.docker.compose.project=\(project.name)"]
        args += ["--label", "com.docker.compose.service=\(service.name)"]
        args += ["--label", "com.docker.compose.container-number=\(replica)"]
        for (key, value) in service.labels.sorted(by: { $0.key < $1.key }) where !key.isEmpty {
            args += ["--label", "\(key)=\(value)"]
        }

        let envFileValues = try effectiveEnvFileValues(for: service, project: project)
        if envFileValuesContainNewline(envFileValues) {
            for (key, value) in envFileValues.sorted(by: { $0.key < $1.key }) {
                if let value {
                    args += ["--env", "\(key)=\(value)"]
                }
            }
        } else if envFileValues.contains(where: { $0.value != nil }) {
            args += ["--env-file", generatedEnvFilePath(service: service, project: project).path]
        }
        for (key, value) in service.environment.sorted(by: { $0.key < $1.key }) where !key.isEmpty {
            if let value {
                args += ["--env", "\(key)=\(value)"]
            } else if let resolved = project.environment[key] {
                args += ["--env", "\(key)=\(resolved)"]
            }
        }

        if let workingDir = service.workingDir {
            args += ["--workdir", workingDir]
        }
        if let user = service.user {
            args += ["--user", user]
        }
        if let platform = runtimePlatform(for: service) {
            args += platformArguments(for: platform)
            if platformRequiresRosetta(platform) {
                args.append("--rosetta")
            }
        }
        if let runtime = service.runtime {
            args += ["--runtime", runtime]
        }
        if let cpus = service.cpus {
            args += ["--cpus", cpus]
        }
        if let memory = service.memory {
            args += ["--memory", memory]
        }
        if let shmSize = service.shmSize {
            args += ["--shm-size", shmSize]
        }
        if service.initProcess {
            args.append("--init")
        }
        if service.readOnly {
            args.append("--read-only")
        }
        if service.tty {
            args.append("--tty")
        }
        if service.stdinOpen {
            args.append("--interactive")
        }
        for capability in service.capAdd {
            args += ["--cap-add", capability]
        }
        for capability in service.capDrop {
            args += ["--cap-drop", capability]
        }
        if !networkModeIsNone(service) {
            for dns in service.dns {
                args += ["--dns", dns]
            }
            for dnsSearch in service.dnsSearch {
                args += ["--dns-search", dnsSearch]
            }
            if let domainName = service.domainName {
                args += ["--dns-domain", domainName]
            }
            for dnsOption in service.dnsOptions {
                args += ["--dns-option", dnsOption]
            }
        }
        for ulimit in service.ulimits {
            if let hard = ulimit.hard {
                args += ["--ulimit", "\(ulimit.name)=\(ulimit.soft):\(hard)"]
            } else {
                args += ["--ulimit", "\(ulimit.name)=\(ulimit.soft)"]
            }
        }

        if let entrypoint = service.entrypoint {
            let entrypointArgs = entrypoint.arguments
            if let first = entrypointArgs.first {
                args += ["--entrypoint", first]
            }
        }

        for port in service.ports {
            for spec in publishSpecs(port) {
                args += ["--publish", spec]
            }
        }

        if networkModeIsNone(service) {
            args.append("--no-dns")
        } else {
            for network in orderedNetworkAttachments(for: service) {
                let networkSpec = runtimeNetworkSpec(network, service: service, project: project)
                args += ["--network", networkSpec]
            }
        }

        for mount in try mountSpecs(for: service, project: project) {
            switch mount.kind {
            case .mount:
                args += ["--mount", mount.value]
            case .tmpfs:
                args += ["--tmpfs", mount.value]
            }
        }

        args.append(imageName(for: service, project: project))
        var commandArguments = service.command?.arguments ?? []
        if let entrypoint = service.entrypoint {
            let entrypointArgs = entrypoint.arguments
            if entrypointArgs.count > 1 {
                commandArguments = Array(entrypointArgs.dropFirst()) + commandArguments
            }
        }
        args += commandArguments
        return RuntimeCommand(containerBinary, args)
    }

    private enum MountKind {
        case mount
        case tmpfs
    }

    private struct MountSpec {
        var kind: MountKind
        var value: String
    }

    private func mountSpecs(for service: ComposeService, project: ComposeProject) throws -> [MountSpec] {
        var mounts: [MountSpec] = []
        for volume in service.volumes {
            let type = resolvedVolumeType(volume)
            if type == "tmpfs" {
                mounts.append(MountSpec(kind: .tmpfs, value: volume.target))
                continue
            }

            var pieces: [String] = ["type=\(type)"]
            if let source = resolvedVolumeSource(volume, service: service, project: project, type: type) {
                pieces.append("source=\(source)")
            }
            pieces.append("target=\(volume.target)")
            if volume.readOnly {
                pieces.append("readonly")
            }
            mounts.append(MountSpec(kind: .mount, value: pieces.joined(separator: ",")))
        }

        for tmpfs in service.tmpfs {
            mounts.append(MountSpec(kind: .tmpfs, value: tmpfs.target))
        }

        if !service.extraHosts.isEmpty {
            mounts.append(MountSpec(kind: .mount, value: "type=bind,source=\(generatedExtraHostsPath(service: service, project: project).path),target=/etc/hosts,readonly"))
        }

        for grant in service.secrets {
            guard let source = try secretSourcePath(grant.source, project: project) else { continue }
            let target = grant.target ?? "/run/secrets/\(grant.source)"
            mounts.append(MountSpec(kind: .mount, value: "type=bind,source=\(source),target=\(target),readonly"))
        }

        for grant in service.configs {
            guard let source = try configSourcePath(grant, project: project) else { continue }
            let target = grant.target ?? "/\(grant.source)"
            mounts.append(MountSpec(kind: .mount, value: "type=bind,source=\(source),target=\(target),readonly"))
        }

        return mounts
    }

    private func bindHostPathCommands(project: ComposeProject, services: [ComposeService]) -> [RuntimeCommand] {
        var paths: Set<String> = []
        for service in services {
            for volume in service.volumes where volume.createHostPath && resolvedVolumeType(volume) == "bind" {
                if let source = resolvedVolumeSource(volume, service: service, project: project, type: "bind") {
                    paths.insert(source)
                }
            }
        }
        return paths.sorted().map {
            RuntimeCommand("/bin/mkdir", ["-p", $0], note: "Create bind host path requested by Compose volume syntax.")
        }
    }

    private func fileArtifacts(for project: ComposeProject, services: [ComposeService]) throws -> [FileArtifact] {
        var artifacts: [String: FileArtifact] = [:]
        for service in services {
            if shouldBuild(service), let dockerfileInline = service.build?.dockerfileInline {
                let path = generatedBuildDockerfilePath(service: service, project: project)
                artifacts[path.path] = FileArtifact(path: path, contents: dockerfileInline, mode: 0o644, sensitive: false)
            }
            if let envArtifact = try generatedEnvFileArtifactIfNeeded(for: service, project: project) {
                artifacts[envArtifact.path.path] = envArtifact
            }
            if let hostsArtifact = generatedExtraHostsArtifactIfNeeded(for: service, project: project) {
                artifacts[hostsArtifact.path.path] = hostsArtifact
            }
            for grant in service.secrets {
                guard let secret = project.secrets[grant.source], !secret.external, secret.file == nil else { continue }
                let path = generatedArtifactPath(kind: "secrets", key: grant.source, project: project)
                let contents = try generatedSecretContents(secret, project: project)
                let mode = permissionMode(grant.mode, defaultMode: 0o400)
                artifacts[path.path] = FileArtifact(path: path, contents: contents, mode: mode, sensitive: true)
            }
            for grant in service.configs {
                let mode = permissionMode(grant.mode, defaultMode: 0o444)
                guard let config = project.configs[grant.source], !config.external else { continue }
                let path = generatedConfigArtifactPath(grant, project: project)
                if let file = config.file {
                    guard grant.mode != nil else { continue }
                    let source = resolvePath(file, relativeTo: project.workingDirectory)
                    let data = try Data(contentsOf: source)
                    artifacts[path.path] = FileArtifact(path: path, data: data, mode: mode, sensitive: false)
                } else {
                    let contents = try generatedConfigContents(config, project: project)
                    artifacts[path.path] = FileArtifact(path: path, contents: contents, mode: mode, sensitive: false)
                }
            }
        }
        return artifacts.values.sorted(by: { $0.path.path < $1.path.path })
    }

    private func generatedEnvFileArtifactIfNeeded(for service: ComposeService, project: ComposeProject) throws -> FileArtifact? {
        let values = try effectiveEnvFileValues(for: service, project: project)
        guard !envFileValuesContainNewline(values) else {
            return nil
        }
        let lines = values
            .compactMap { key, value -> String? in
                guard let value else { return nil }
                return "\(key)=\(value)"
            }
            .sorted()
        guard !lines.isEmpty else {
            return nil
        }
        let path = generatedEnvFilePath(service: service, project: project)
        return FileArtifact(path: path, contents: lines.joined(separator: "\n") + "\n", mode: 0o600, sensitive: true)
    }

    private func generatedExtraHostsArtifactIfNeeded(for service: ComposeService, project: ComposeProject) -> FileArtifact? {
        guard !service.extraHosts.isEmpty else {
            return nil
        }
        let lines = [
            "127.0.0.1 localhost",
            "::1 localhost ip6-localhost ip6-loopback"
        ] + service.extraHosts
            .map { "\($0.address) \($0.host)" }
            .sorted()
        return FileArtifact(
            path: generatedExtraHostsPath(service: service, project: project),
            contents: lines.joined(separator: "\n") + "\n",
            mode: 0o444,
            sensitive: false
        )
    }

    private func effectiveEnvFileValues(for service: ComposeService, project: ComposeProject) throws -> [String: String?] {
        var values = try mergedEnvFileValues(for: service, project: project)
        for key in service.environment.keys {
            values.removeValue(forKey: key)
        }
        return values
    }

    private func mergedEnvFileValues(for service: ComposeService, project: ComposeProject) throws -> [String: String?] {
        var values: [String: String?] = [:]
        for envFile in service.envFiles {
            let path = resolvePath(envFile.path, relativeTo: project.workingDirectory)
            guard FileManager.default.fileExists(atPath: path.path) else {
                if envFile.required {
                    throw ComposeError.invalidCompose("Service '\(service.name)' env_file '\(envFile.path)' does not exist")
                }
                continue
            }
            let text = try String(contentsOf: path, encoding: .utf8)
            let parser = ComposeEnvFileParser(environment: project.environment, format: envFileFormat(envFile.format))
            for (key, value) in try parser.parse(text) {
                values.updateValue(value, forKey: key)
            }
        }
        return values
    }

    private func envFileValuesContainNewline(_ values: [String: String?]) -> Bool {
        values.values.contains { value in
            guard let value else { return false }
            return value.contains("\n") || value.contains("\r")
        }
    }

    private func envFileFormat(_ value: String?) -> ComposeEnvFileFormat {
        value?.lowercased() == "raw" ? .raw : .compose
    }

    private func secretSourcePath(_ key: String, project: ComposeProject) throws -> String? {
        guard let secret = project.secrets[key] else { return nil }
        if let file = secret.file {
            return resolvePath(file, relativeTo: project.workingDirectory).path
        }
        if secret.external {
            return nil
        }
        _ = try generatedSecretContents(secret, project: project)
        return generatedArtifactPath(kind: "secrets", key: key, project: project).path
    }

    private func configSourcePath(_ grant: ServiceFileGrant, project: ComposeProject) throws -> String? {
        guard let config = project.configs[grant.source] else { return nil }
        if let file = config.file {
            if grant.mode != nil {
                return generatedConfigArtifactPath(grant, project: project).path
            }
            return resolvePath(file, relativeTo: project.workingDirectory).path
        }
        if config.external {
            return nil
        }
        _ = try generatedConfigContents(config, project: project)
        return generatedConfigArtifactPath(grant, project: project).path
    }

    private func generatedSecretContents(_ secret: ComposeSecret, project: ComposeProject) throws -> String {
        if let environment = secret.environment {
            guard let value = project.environment[environment] else {
                throw ComposeError.invalidCompose("Secret '\(secret.key)' references missing environment variable '\(environment)'")
            }
            return value
        }
        throw ComposeError.invalidCompose("Secret '\(secret.key)' must define file, environment, or external")
    }

    private func generatedConfigContents(_ config: ComposeConfig, project: ComposeProject) throws -> String {
        if let content = config.content {
            return content
        }
        if let environment = config.environment {
            guard let value = project.environment[environment] else {
                throw ComposeError.invalidCompose("Config '\(config.key)' references missing environment variable '\(environment)'")
            }
            return value
        }
        throw ComposeError.invalidCompose("Config '\(config.key)' must define file, content, environment, or external")
    }

    private func generatedArtifactPath(kind: String, key: String, project: ComposeProject) -> URL {
        project.workingDirectory
            .appendingPathComponent(".apple-compose")
            .appendingPathComponent(project.name)
            .appendingPathComponent(kind)
            .appendingPathComponent(safeArtifactName(key))
    }

    private func generatedConfigArtifactPath(_ grant: ServiceFileGrant, project: ComposeProject) -> URL {
        let key: String
        if let mode = grant.mode, !mode.isEmpty {
            key = "\(grant.source).\(String(permissionMode(mode, defaultMode: 0o444), radix: 8))"
        } else {
            key = grant.source
        }
        return generatedArtifactPath(kind: "configs", key: key, project: project)
    }

    private func generatedBuildDockerfilePath(service: ComposeService, project: ComposeProject) -> URL {
        project.workingDirectory
            .appendingPathComponent(".apple-compose")
            .appendingPathComponent(project.name)
            .appendingPathComponent("build")
            .appendingPathComponent("\(safeArtifactName(service.name)).Dockerfile")
    }

    private func generatedEnvFilePath(service: ComposeService, project: ComposeProject) -> URL {
        project.workingDirectory
            .appendingPathComponent(".apple-compose")
            .appendingPathComponent(project.name)
            .appendingPathComponent("env")
            .appendingPathComponent("\(safeArtifactName(service.name)).env")
    }

    private func generatedExtraHostsPath(service: ComposeService, project: ComposeProject) -> URL {
        project.workingDirectory
            .appendingPathComponent(".apple-compose")
            .appendingPathComponent(project.name)
            .appendingPathComponent("hosts")
            .appendingPathComponent("\(safeArtifactName(service.name)).hosts")
    }

    private func pullStateDirectory(project: ComposeProject) -> URL {
        project.workingDirectory
            .appendingPathComponent(".apple-compose")
            .appendingPathComponent(project.name)
            .appendingPathComponent("pull-state")
    }

    private func pullStatePath(for service: ComposeService, project: ComposeProject) -> URL {
        pullStateDirectory(project: project)
            .appendingPathComponent("\(safeArtifactName(service.name)).state")
    }

    private func safeArtifactName(_ value: String) -> String {
        let scalars = value.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-" || scalar == "_" ? Character(scalar) : "_"
        }
        let name = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return name.isEmpty ? "artifact" : name
    }

    private func permissionMode(_ value: String?, defaultMode: Int) -> Int {
        guard let value, !value.isEmpty else { return defaultMode }
        let normalized = value.hasPrefix("0o") ? String(value.dropFirst(2)) : value
        return Int(normalized, radix: 8) ?? defaultMode
    }

    private func resolvedVolumeType(_ volume: ServiceVolume) -> String {
        if let type = volume.type {
            return type
        }
        guard let source = volume.source else {
            return "volume"
        }
        return looksLikeHostPath(source) ? "bind" : "volume"
    }

    private func resolvedVolumeSource(_ volume: ServiceVolume, service: ComposeService, project: ComposeProject, type: String) -> String? {
        switch type {
        case "bind":
            guard let source = volume.source else { return nil }
            return resolvePath(source, relativeTo: project.workingDirectory).path
        case "volume":
            let key = volume.source ?? anonymousVolumeKey(service: service, target: volume.target)
            let topLevel = project.volumes[key] ?? ComposeVolume(key: key, name: nil, external: false, driver: nil, driverOptions: [:], labels: [:])
            return actualVolumeName(topLevel, project: project)
        default:
            return volume.source
        }
    }

    private func collectUsedNetworks(_ project: ComposeProject, services: [ComposeService]) -> Set<String> {
        var keys: Set<String> = []
        for service in services {
            if networkModeIsNone(service) {
                continue
            }
            if let networks = service.networks, !networks.isEmpty {
                keys.formUnion(networks.keys)
            } else {
                keys.insert("default")
            }
        }
        return keys
    }

    private func collectUsedVolumes(_ project: ComposeProject, services: [ComposeService]) -> [String: ComposeVolume] {
        var volumes: [String: ComposeVolume] = [:]
        for service in services {
            for volume in service.volumes where resolvedVolumeType(volume) == "volume" {
                let key = volume.source ?? anonymousVolumeKey(service: service, target: volume.target)
                var definition = volumes[key] ?? project.volumes[key] ?? ComposeVolume(key: key, name: nil, external: false, driver: nil, driverOptions: [:], labels: [:])
                definition.labels.merge(volume.volumeLabels) { _, serviceLabel in serviceLabel }
                volumes[key] = definition
            }
        }
        return volumes
    }

    private func runtimeNetworkSpec(_ attachment: NetworkAttachment, service: ComposeService, project: ComposeProject) -> String {
        let network = project.networks[attachment.key] ?? ComposeNetwork(key: attachment.key, name: nil, external: false, driver: nil, driverOptions: [:], labels: [:], internalNetwork: false, ipamSubnets: [], enableIPv4: nil, enableIPv6: nil)
        var spec = actualNetworkName(network, project: project)
        if let mac = attachment.macAddress ?? serviceMacAddress(for: attachment, service: service) {
            spec += ",mac=\(mac)"
        }
        if let mtu = attachment.driverOptions["mtu"] {
            spec += ",mtu=\(mtu)"
        }
        return spec
    }

    private func orderedNetworkAttachments(for service: ComposeService) -> [NetworkAttachment] {
        if networkModeIsNone(service) {
            return []
        }
        return (service.networks ?? ["default": .empty(key: "default")])
            .values
            .sorted {
                let leftPriority = $0.priority ?? 0
                let rightPriority = $1.priority ?? 0
                if leftPriority != rightPriority {
                    return leftPriority > rightPriority
                }
                return $0.key < $1.key
            }
    }

    private func serviceMacAddress(for attachment: NetworkAttachment, service: ComposeService) -> String? {
        guard let macAddress = service.macAddress else {
            return nil
        }
        guard orderedNetworkAttachments(for: service).first?.key == attachment.key else {
            return nil
        }
        return macAddress
    }

    private func networkModeIsNone(_ service: ComposeService) -> Bool {
        service.networkMode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "none"
    }

    private func publishSpecs(_ port: PortSpec) -> [String] {
        guard port.published != nil else {
            return []
        }
        if let published = port.published,
           let target = port.target,
           let publishedRange = portRangeValues(published),
           let targetRange = portRangeValues(target),
           publishedRange.count == targetRange.count {
            return zip(publishedRange, targetRange).map { published, target in
                publishSpec(hostIP: port.hostIP, published: String(published), target: String(target), protocolName: port.protocolName)
            }
        }
        if let raw = port.raw,
           port.hostIP == nil,
           !rawPortHasEmptyProtocol(raw),
           !isPortRange(port.published),
           !isPortRange(port.target) {
            return [raw]
        }
        return [publishSpec(hostIP: port.hostIP, published: port.published, target: port.target ?? "", protocolName: port.protocolName)]
    }

    private func rawPortHasEmptyProtocol(_ raw: String) -> Bool {
        raw.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).last == ""
    }

    private func publishSpec(hostIP: String?, published: String?, target: String, protocolName: String?) -> String {
        var spec = ""
        if let hostIP, let published {
            spec += "\(publishHostIP(hostIP)):\(published):"
        } else if let published {
            spec += "\(published):"
        }
        spec += target
        if let proto = protocolName, proto.lowercased() != "tcp" {
            spec += "/\(proto)"
        }
        return spec
    }

    private func publishHostIP(_ hostIP: String) -> String {
        if hostIP.contains(":"), !hostIP.hasPrefix("[") {
            return "[\(hostIP)]"
        }
        return hostIP
    }

    private func isPortRange(_ value: String?) -> Bool {
        value?.contains("-") ?? false
    }

    private func portRangeValues(_ value: String) -> [Int]? {
        let bounds = value.split(separator: "-", maxSplits: 1).compactMap { Int($0) }
        guard bounds.count == 2, bounds[0] <= bounds[1] else {
            return nil
        }
        return Array(bounds[0]...bounds[1])
    }

    private func imageName(for service: ComposeService, project: ComposeProject) -> String {
        service.image ?? "\(project.name)-\(service.name):latest"
    }

    private func shouldBuild(_ service: ComposeService) -> Bool {
        guard service.build != nil else {
            return false
        }
        guard service.image != nil else {
            return true
        }
        switch service.pullPolicy?.lowercased() {
        case "always", "never":
            return false
        case .some(_) where pullPolicyIntervalSeconds(for: service) != nil:
            return false
        default:
            return true
        }
    }

    private func shouldBuildWithPullFallback(_ service: ComposeService) -> Bool {
        guard service.image != nil && service.build != nil else {
            return false
        }
        switch service.pullPolicy?.lowercased() {
        case nil, "", "missing", "if_not_present":
            return true
        default:
            return false
        }
    }

    private func shouldPull(_ service: ComposeService) -> Bool {
        guard let image = service.image else { return false }
        guard !shouldBuild(service) else { return false }
        switch service.pullPolicy?.lowercased() {
        case "always":
            return true
        case "build":
            return false
        case "never":
            return false
        case "missing", "if_not_present":
            return imageUsesLatestTag(image)
        case .some(_) where pullPolicyIntervalSeconds(for: service) != nil:
            return false
        default:
            return imageUsesLatestTag(image)
        }
    }

    private func shouldPullIfMissing(_ service: ComposeService) -> Bool {
        guard let image = service.image else { return false }
        guard !shouldBuild(service) else { return false }
        guard !imageUsesLatestTag(image) else { return false }
        switch service.pullPolicy?.lowercased() {
        case nil, "", "missing", "if_not_present":
            return true
        default:
            return false
        }
    }

    private func shouldPullTimeBased(_ service: ComposeService) -> Bool {
        service.image != nil && !shouldBuild(service) && pullPolicyIntervalSeconds(for: service) != nil
    }

    private func pullPolicyIntervalSeconds(for service: ComposeService) -> Int? {
        let policy = service.pullPolicy?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if policy == "refresh" {
            return composePullPolicyRefreshAfterSeconds(service.pullRefreshAfter) ?? 0
        }
        return composePullPolicyIntervalSeconds(policy)
    }

    private func shouldRequireLocalImage(_ service: ComposeService) -> Bool {
        service.image != nil && !shouldBuild(service) && service.pullPolicy?.lowercased() == "never"
    }

    private func imageUsesLatestTag(_ image: String) -> Bool {
        if image.contains("@") {
            return false
        }
        let lastPathComponent = image.split(separator: "/").last.map(String.init) ?? image
        guard let colon = lastPathComponent.lastIndex(of: ":") else {
            return true
        }
        return String(lastPathComponent[lastPathComponent.index(after: colon)...]) == "latest"
    }

    private func containerName(for service: ComposeService, project: ComposeProject, replica: Int) -> String {
        if let containerName = service.containerName {
            return containerName
        }
        return "\(project.name)-\(service.name)-\(replica)"
    }

    private func replicaNumbers(for service: ComposeService) -> [Int] {
        guard service.replicas > 0 else {
            return []
        }
        return Array(1...service.replicas)
    }

    private func activeReplicaServices(_ services: [ComposeService]) -> [ComposeService] {
        services.filter { $0.replicas > 0 }
    }

    private func activeManagedReplicaServices(_ services: [ComposeService]) -> [ComposeService] {
        activeReplicaServices(managedContainerServices(services))
    }

    private func managedContainerServices(_ services: [ComposeService]) -> [ComposeService] {
        services.filter { !hasActiveProvider($0) }
    }

    private func hasActiveProvider(_ service: ComposeService) -> Bool {
        guard let map = service.raw.map, let provider = map["provider"] else {
            return false
        }
        return !isEmptyNoopValue(provider) && !isProviderNoopValue(provider)
    }

    private func isProviderNoopValue(_ value: YAMLValue) -> Bool {
        switch value {
        case .map(let map):
            guard let type = map["type"], isEmptyStringValue(type) else {
                return false
            }
            return map.allSatisfy { key, value in
                switch key {
                case "type":
                    return isEmptyStringValue(value)
                case "options":
                    return isEmptyNoopValue(value)
                default:
                    return key.hasPrefix("x-")
                }
            }
        case .reset(let value), .overrideValue(let value):
            return isProviderNoopValue(value)
        default:
            return false
        }
    }

    private func isEmptyStringValue(_ value: YAMLValue) -> Bool {
        switch value {
        case .string(let string):
            return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .reset(let value), .overrideValue(let value):
            return isEmptyStringValue(value)
        default:
            return false
        }
    }

    private func isEmptyNoopValue(_ value: YAMLValue) -> Bool {
        switch value {
        case .null:
            return true
        case .array(let values):
            return values.isEmpty
        case .map(let values):
            return values.isEmpty
        case .reset(let value), .overrideValue(let value):
            return isEmptyNoopValue(value)
        case .string, .bool, .int, .double:
            return false
        }
    }

    private func actualNetworkName(_ network: ComposeNetwork, project: ComposeProject) -> String {
        network.name ?? (network.external ? network.key : "\(project.name)_\(network.key)")
    }

    private func networkPluginArgument(for network: ComposeNetwork) -> String? {
        guard let driver = network.driver else {
            return nil
        }
        switch driver.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "bridge", "default":
            return nil
        default:
            return driver
        }
    }

    private func actualVolumeName(_ volume: ComposeVolume, project: ComposeProject) -> String {
        volume.name ?? (volume.external ? volume.key : "\(project.name)_\(volume.key)")
    }

    private func anonymousVolumeKey(service: ComposeService, target: String) -> String {
        "\(service.name)_\(target.replacingOccurrences(of: "/", with: "_").trimmingCharacters(in: CharacterSet(charactersIn: "_")))"
    }

    private func looksLikeHostPath(_ value: String) -> Bool {
        value.hasPrefix(".") || value.hasPrefix("/") || value.hasPrefix("~")
    }

    private func validateServiceResourceReferences(
        project: ComposeProject,
        services: [ComposeService],
        includeSkippedBuildSecrets: Bool
    ) throws {
        for service in services.sorted(by: { $0.name < $1.name }) {
            if let serviceNetworks = service.networks {
                for network in serviceNetworks.keys.sorted() where network != "default" && project.networks[network] == nil {
                    throw ComposeError.invalidCompose("Service '\(service.name)' refers to undefined network '\(network)'")
                }
            }

            for volume in service.volumes {
                guard serviceVolumeReferenceRequiresTopLevelDefinition(volume),
                      let source = volume.source,
                      project.volumes[source] == nil else {
                    continue
                }
                throw ComposeError.invalidCompose("Service '\(service.name)' refers to undefined volume '\(source)'")
            }

            for grant in service.secrets where project.secrets[grant.source] == nil {
                throw ComposeError.invalidCompose("Service '\(service.name)' refers to undefined secret '\(grant.source)'")
            }
            for grant in service.configs where project.configs[grant.source] == nil {
                throw ComposeError.invalidCompose("Service '\(service.name)' refers to undefined config '\(grant.source)'")
            }
            for (dependency, key) in namespaceServiceReferences(for: service).sorted(by: { $0.key < $1.key }) where project.services[dependency] == nil {
                throw ComposeError.invalidCompose("Service '\(service.name)' \(key) refers to undefined service '\(dependency)'")
            }
            if let build = service.build, includeSkippedBuildSecrets || shouldBuild(service) {
                for grant in build.secrets where project.secrets[grant.source] == nil {
                    throw ComposeError.invalidCompose("Service '\(service.name)' build refers to undefined secret '\(grant.source)'")
                }
            }
        }
    }

    private func serviceVolumeReferenceRequiresTopLevelDefinition(_ volume: ServiceVolume) -> Bool {
        if let type = volume.type {
            return type == "volume" && volume.source != nil
        }
        guard let source = volume.source else {
            return false
        }
        return !looksLikeHostPath(source)
    }

    private func orderedServices(_ project: ComposeProject, only includedNames: Set<String>? = nil) throws -> [ComposeService] {
        var temporary: Set<String> = []
        var permanent: Set<String> = []
        var ordered: [ComposeService] = []

        func visit(_ name: String) throws {
            if let includedNames, !includedNames.contains(name) {
                return
            }
            if permanent.contains(name) {
                return
            }
            if temporary.contains(name) {
                throw ComposeError.invalidCompose("Circular depends_on relationship involving service '\(name)'")
            }
            guard let service = project.services[name] else {
                throw ComposeError.invalidCompose("Service '\(name)' is referenced but not defined or not active")
            }
            temporary.insert(name)
            for (dependency, required) in dependencyRequirements(for: service).sorted(by: { $0.key < $1.key }) {
                if let includedNames, !includedNames.contains(dependency) {
                    continue
                } else if project.services[dependency] != nil {
                    try visit(dependency)
                } else if required {
                    throw ComposeError.invalidCompose("Service '\(name)' depends on service '\(dependency)' which is not defined or not active")
                }
            }
            temporary.remove(name)
            permanent.insert(name)
            ordered.append(service)
        }

        for name in (includedNames ?? Set(project.services.keys)).sorted() {
            try visit(name)
        }
        return ordered
    }

    private func selectedOrderedServices(
        _ project: ComposeProject,
        requested: [String],
        includeDependencies: Bool,
        allowEmpty: Bool = false,
        missingOptionalDependenciesAreErrors: Bool = false
    ) throws -> [ComposeService] {
        let requested = requested.filter { !$0.isEmpty }
        let requestedNames = Set(requested)
        let activeNames = Set(project.services.values.filter { isProfileActive($0, project: project) }.map(\.name))
        for name in requested {
            guard project.services[name] != nil else {
                throw ComposeError.invalidCompose("Service '\(name)' is not defined")
            }
        }

        let enabledNames = requestedNames.isEmpty ? activeNames : activeNames.union(requestedNames)
        var selected = requestedNames.isEmpty ? activeNames : requestedNames

        if selected.isEmpty && allowEmpty {
            return []
        }
        if selected.isEmpty {
            throw ComposeError.invalidCompose("no service selected")
        }

        var visited: Set<String> = []
        func select(_ name: String) throws {
            guard let service = project.services[name] else {
                throw ComposeError.invalidCompose("Service '\(name)' is not defined")
            }
            guard visited.insert(name).inserted else {
                return
            }
            selected.insert(name)
            guard includeDependencies else {
                return
            }
            for (dependency, required) in dependencyRequirements(for: service).sorted(by: { $0.key < $1.key }) {
                guard project.services[dependency] != nil else {
                    if required || missingOptionalDependenciesAreErrors {
                        throw ComposeError.invalidCompose("Service '\(name)' depends on service '\(dependency)' which is not defined")
                    }
                    continue
                }
                guard enabledNames.contains(dependency) else {
                    if required {
                        throw ComposeError.invalidCompose("Service '\(name)' depends on service '\(dependency)' which is not defined or not active")
                    }
                    continue
                }
                try select(dependency)
            }
        }

        for name in selected.sorted() {
            try select(name)
        }
        return try orderedServices(project, only: selected)
    }

    private func isProfileActive(_ service: ComposeService, project: ComposeProject) -> Bool {
        let gatingProfiles = service.profiles.filter { !$0.isEmpty }
        return gatingProfiles.isEmpty
            || project.activeProfiles.contains("*")
            || !project.activeProfiles.isDisjoint(with: Set(gatingProfiles))
    }

    private func dependencyRequirements(for service: ComposeService) -> [String: Bool] {
        var dependencies = service.dependsOn.mapValues(\.required)
        for link in service.links {
            dependencies[link.source] = true
        }
        for dependency in namespaceServiceReferences(for: service).keys {
            dependencies[dependency] = true
        }
        return dependencies
    }

    private func namespaceServiceReferences(for service: ComposeService) -> [String: String] {
        var references: [String: String] = [:]
        if let dependency = serviceReferenceTarget(service.networkMode) {
            references[dependency] = "network_mode"
        }
        guard let map = service.raw.map else {
            return references
        }
        for key in ["ipc", "pid"] {
            if let dependency = serviceReferenceTarget(rawString(map[key])) {
                references[dependency] = key
            }
        }
        return references
    }

    private func serviceReferenceTarget(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("service:") else {
            return nil
        }
        let target = trimmed.dropFirst("service:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        return target.isEmpty ? nil : String(target)
    }

    private func rawString(_ value: YAMLValue?) -> String? {
        guard let value else {
            return nil
        }
        switch value {
        case .string(let string):
            return string
        case .reset(let value), .overrideValue(let value):
            return rawString(value)
        default:
            return nil
        }
    }
}

public func shellQuote(_ value: String) -> String {
    if value.isEmpty {
        return "''"
    }
    if value.range(of: #"[^A-Za-z0-9_\-./:=,+@%]"#, options: .regularExpression) == nil {
        return value
    }
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
