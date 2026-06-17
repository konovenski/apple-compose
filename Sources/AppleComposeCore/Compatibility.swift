import Foundation

public enum CompatibilitySeverity: String, Equatable, Sendable {
    case warning
    case error
}

public struct CompatibilityIssue: Equatable, Sendable {
    public var severity: CompatibilitySeverity
    public var location: String
    public var feature: String
    public var message: String

    public init(_ severity: CompatibilitySeverity, _ location: String, _ feature: String, _ message: String) {
        self.severity = severity
        self.location = location
        self.feature = feature
        self.message = message
    }

    public var rendered: String {
        "[\(severity.rawValue)] \(location): \(feature) - \(message)"
    }
}

public enum CompatibilityMode: String, CaseIterable, Equatable, Sendable {
    case strict
    case bestEffort = "best-effort"
    case ignore
}

public struct CompatibilityAnalyzer {
    private struct ResourceUsage {
        var networks: Set<String>
        var volumes: Set<String>
        var secrets: Set<String>
        var configs: Set<String>
        var models: Set<String>
    }

    public init() {}

    public func analyze(_ project: ComposeProject, services plannedServices: [ComposeService]? = nil) -> [CompatibilityIssue] {
        let servicesToAnalyze = plannedServices ?? project.services.values.sorted(by: { $0.name < $1.name })
        let plannedServiceNames = plannedServices.map { Set($0.map(\.name)) }
        let resourceUsage = plannedServices.map { collectResourceUsage(for: $0) }
        var issues: [CompatibilityIssue] = []
        issues += analyzeTopLevel(project, resourceUsage: resourceUsage)
        for network in project.networks.values.sorted(by: { $0.key < $1.key }) where resourceUsage?.networks.contains(network.key) ?? true {
            issues += analyze(network)
        }
        for volume in project.volumes.values.sorted(by: { $0.key < $1.key }) where resourceUsage?.volumes.contains(volume.key) ?? true {
            issues += analyze(volume)
        }
        for service in servicesToAnalyze.sorted(by: { $0.name < $1.name }) {
            issues += analyze(service, project: project, plannedServiceNames: plannedServiceNames)
        }
        return issues
    }

    public func fatalIssues(_ issues: [CompatibilityIssue], mode: CompatibilityMode) -> [CompatibilityIssue] {
        switch mode {
        case .strict:
            return issues.filter { $0.severity == .error }
        case .bestEffort, .ignore:
            return []
        }
    }

    private func collectResourceUsage(for services: [ComposeService]) -> ResourceUsage {
        var networks: Set<String> = []
        var volumes: Set<String> = []
        var secrets: Set<String> = []
        var configs: Set<String> = []
        var models: Set<String> = []

        for service in services {
            if hasActiveProvider(service.raw.map?["provider"]) {
                continue
            }
            if networkModeIsNone(service.networkMode) {
                continue
            }
            if let serviceNetworks = service.networks, !serviceNetworks.isEmpty {
                networks.formUnion(serviceNetworks.keys)
            } else {
                networks.insert("default")
            }

            for volume in service.volumes where resolvedVolumeType(volume) == "volume" {
                if let source = volume.source {
                    volumes.insert(source)
                }
            }

            secrets.formUnion(service.secrets.map(\.source))
            if buildIsActive(service) {
                secrets.formUnion(service.build?.secrets.map(\.source) ?? [])
            }
            configs.formUnion(service.configs.map(\.source))
            models.formUnion(service.modelReferences)
        }

        return ResourceUsage(networks: networks, volumes: volumes, secrets: secrets, configs: configs, models: models)
    }

    private func analyzeTopLevel(_ project: ComposeProject, resourceUsage: ResourceUsage?) -> [CompatibilityIssue] {
        guard let map = project.raw.map else { return [] }
        var issues: [CompatibilityIssue] = []
        issues += project.includeConflicts.map { conflict in
            CompatibilityIssue(.warning, conflict.location, "include", conflict.message)
        }
        for key in map.keys.sorted() where !knownTopLevelKeys.contains(key) && !key.hasPrefix("x-") {
            issues.append(.init(.error, "compose", key, "This top-level Compose attribute is not implemented by apple-compose and would otherwise be ignored."))
        }
        if map["version"] != nil {
            issues.append(.init(.warning, "compose", "version", "The Compose specification treats version as obsolete and informational; apple-compose always parses the modern schema."))
        }
        if let models = map["models"], !topLevelModelsAreUnusedOrEmpty(models, resourceUsage: resourceUsage) {
            issues.append(.init(.error, "compose", "models", "Apple containers do not provide Compose model runner semantics."))
        }
        issues += analyzeNetworkDefinitions(map["networks"], only: resourceUsage?.networks)
        issues += analyzeVolumeDefinitions(map["volumes"], only: resourceUsage?.volumes)
        issues += analyzeSecretDefinitions(map["secrets"], only: resourceUsage?.secrets)
        issues += analyzeConfigDefinitions(map["configs"], only: resourceUsage?.configs)
        return issues
    }

    private func topLevelModelsAreUnusedOrEmpty(_ node: YAMLValue, resourceUsage: ResourceUsage?) -> Bool {
        guard let map = node.map else {
            return isEmptyNoopValue(node)
        }
        guard !map.isEmpty else {
            return true
        }
        guard let resourceUsage else {
            return false
        }
        return map.keys.allSatisfy { !resourceUsage.models.contains($0) }
    }

    private func analyzeNetworkDefinitions(_ node: YAMLValue?, only includedKeys: Set<String>?) -> [CompatibilityIssue] {
        guard let networks = node?.map else { return [] }
        var issues: [CompatibilityIssue] = []
        for (name, value) in networks.sorted(by: { $0.key < $1.key }) {
            if let includedKeys, !includedKeys.contains(name) { continue }
            guard let map = value.map else { continue }
            let location = "networks.\(name)"
            issues += unknownKeys(in: map, known: knownNetworkKeys, location: location, kind: "network")
            issues += externalResourceIssues(in: map, location: location, kind: "network")
            if exactBool(map["attachable"]) == true {
                issues.append(.init(.error, location, "attachable", "Apple container network create does not expose Docker's manually attachable network flag."))
            }
            if let ipam = map["ipam"]?.map {
                issues += unknownKeys(in: ipam, known: knownIPAMKeys, location: "\(location).ipam", kind: "network IPAM")
                if let driver = ipam["driver"],
                   !isEmptyStringValue(driver),
                   exactString(driver)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "default" {
                    issues.append(.init(.error, "\(location).ipam", "driver", "Custom IPAM drivers are not exposed by Apple container CLI."))
                }
                if let options = ipam["options"], !isEmptyNoopValue(options) {
                    issues.append(.init(.error, "\(location).ipam", "options", "Custom IPAM options are not exposed by Apple container CLI."))
                }
                for (index, config) in (ipam["config"]?.array ?? []).enumerated() {
                    guard let configMap = config.map else { continue }
                    for key in configMap.keys.sorted() where key != "subnet" && !key.hasPrefix("x-") {
                        issues.append(.init(.error, "\(location).ipam.config[\(index)]", key, "Apple container network create accepts subnet values but not Docker IPAM \(key)."))
                    }
                }
            }
        }
        return issues
    }

    private func analyzeVolumeDefinitions(_ node: YAMLValue?, only includedKeys: Set<String>?) -> [CompatibilityIssue] {
        guard let volumes = node?.map else { return [] }
        var issues: [CompatibilityIssue] = []
        for (name, value) in volumes.sorted(by: { $0.key < $1.key }) {
            if let includedKeys, !includedKeys.contains(name) { continue }
            guard let map = value.map else { continue }
            let location = "volumes.\(name)"
            issues += unknownKeys(in: map, known: knownVolumeKeys, location: location, kind: "volume")
            issues += externalResourceIssues(in: map, location: location, kind: "volume")
        }
        return issues
    }

    private func analyzeSecretDefinitions(_ node: YAMLValue?, only includedKeys: Set<String>?) -> [CompatibilityIssue] {
        guard let secrets = node?.map else { return [] }
        var issues: [CompatibilityIssue] = []
        for (name, value) in secrets.sorted(by: { $0.key < $1.key }) {
            if let includedKeys, !includedKeys.contains(name) { continue }
            guard let map = value.map else { continue }
            let location = "secrets.\(name)"
            issues += unknownKeys(in: map, known: knownSecretKeys, location: location, kind: "secret")
            issues += externalResourceIssues(in: map, location: location, kind: "secret")
            if let labels = map["labels"], !isEmptyNoopValue(labels) {
                issues.append(.init(.error, location, "labels", "Apple container CLI has no secret resource label API; apple-compose materializes secrets as files or bind mounts."))
            }
            if let driver = map["driver"], !isEmptyNoopValue(driver), !isEmptyStringValue(driver) {
                issues.append(.init(.error, location, "driver", "Secret drivers are not exposed by Apple container CLI; apple-compose can materialize file or environment-backed secrets as bind mounts."))
            }
            if let driverOptions = map["driver_opts"], !isEmptyNoopValue(driverOptions) {
                issues.append(.init(.error, location, "driver_opts", "Secret driver options require a secret driver API, which Apple container CLI does not expose."))
            }
            if let templateDriver = map["template_driver"], !isEmptyNoopValue(templateDriver), !isEmptyStringValue(templateDriver) {
                issues.append(.init(.error, location, "template_driver", "Secret template drivers are not exposed by Apple container CLI."))
            }
            if !resourceIsExternal(map) {
                let sourceKeys = ["file", "environment"].filter { map[$0] != nil }
                if sourceKeys.isEmpty {
                    issues.append(.init(.error, location, "source", "Compose secrets must define file, environment, or external."))
                } else if sourceKeys.count > 1 {
                    issues.append(.init(.error, location, "source", "Compose secrets can only define one source type: \(sourceKeys.joined(separator: ", "))."))
                }
            }
        }
        return issues
    }

    private func analyzeConfigDefinitions(_ node: YAMLValue?, only includedKeys: Set<String>?) -> [CompatibilityIssue] {
        guard let configs = node?.map else { return [] }
        var issues: [CompatibilityIssue] = []
        for (name, value) in configs.sorted(by: { $0.key < $1.key }) {
            if let includedKeys, !includedKeys.contains(name) { continue }
            guard let map = value.map else { continue }
            let location = "configs.\(name)"
            issues += unknownKeys(in: map, known: knownConfigKeys, location: location, kind: "config")
            issues += externalResourceIssues(in: map, location: location, kind: "config")
            if let labels = map["labels"], !isEmptyNoopValue(labels) {
                issues.append(.init(.error, location, "labels", "Apple container CLI has no config resource label API; apple-compose materializes configs as files or bind mounts."))
            }
            if let templateDriver = map["template_driver"], !isEmptyNoopValue(templateDriver), !isEmptyStringValue(templateDriver) {
                issues.append(.init(.error, location, "template_driver", "Config template drivers are not exposed by Apple container CLI; apple-compose materializes file, content, or environment-backed configs."))
            }
            if !resourceIsExternal(map) {
                let sourceKeys = ["file", "content", "environment"].filter { map[$0] != nil }
                if sourceKeys.isEmpty {
                    issues.append(.init(.error, location, "source", "Compose configs must define file, content, environment, or external."))
                } else if sourceKeys.count > 1 {
                    issues.append(.init(.error, location, "source", "Compose configs can only define one source type: \(sourceKeys.joined(separator: ", "))."))
                }
            }
        }
        return issues
    }

    private func unknownKeys(in map: [String: YAMLValue], known: Set<String>, location: String, kind: String) -> [CompatibilityIssue] {
        map.keys.sorted().compactMap { key in
            if known.contains(key) || key.hasPrefix("x-") {
                return nil
            }
            return .init(.error, location, key, "This Compose \(kind) attribute is not implemented by apple-compose and would otherwise be ignored.")
        }
    }

    private func externalResourceIssues(in map: [String: YAMLValue], location: String, kind: String) -> [CompatibilityIssue] {
        guard resourceIsExternal(map) else { return [] }
        return map.keys.sorted().compactMap { key in
            if key == "external" || key == "name" || key.hasPrefix("x-") {
                return nil
            }
            return .init(.error, location, key, "External Compose \(kind)s can only specify external/name; apple-compose cannot apply local resource configuration to an external resource.")
        }
    }

    private func resourceIsExternal(_ map: [String: YAMLValue]) -> Bool {
        if let bool = exactBool(map["external"]) {
            return bool
        }
        return map["external"]?["name"] != nil
    }

    private func reservedComposeLabelIssues(_ labels: [String: String], location: String) -> [CompatibilityIssue] {
        let reserved = labels.keys
            .filter { $0 == "com.docker.compose" || $0.hasPrefix("com.docker.compose.") }
            .sorted()
        guard !reserved.isEmpty else {
            return []
        }
        return [
            .init(
                .error,
                location,
                "labels",
                "Compose reserves the com.docker.compose label prefix; remove reserved label(s): \(reserved.joined(separator: ", "))."
            )
        ]
    }

    private func emptyLabelKeyIssues(_ labels: [String: String], location: String) -> [CompatibilityIssue] {
        guard labels.keys.contains("") else {
            return []
        }
        return [
            .init(
                .error,
                location,
                "labels",
                "Compose accepts empty label keys in list form, but Apple container CLI label flags require key=value with a non-empty key; apple-compose omits empty label keys from generated commands."
            )
        ]
    }

    private func emptyEnvironmentKeyIssues(_ environment: [String: String?], location: String, feature: String) -> [CompatibilityIssue] {
        guard environment.keys.contains("") else {
            return []
        }
        return [
            .init(
                .error,
                location,
                feature,
                "Compose accepts empty \(feature) keys in list form, but Apple container CLI flags require key=value with a non-empty key; apple-compose omits empty \(feature) keys from generated commands."
            )
        ]
    }

    private func analyze(_ network: ComposeNetwork) -> [CompatibilityIssue] {
        var issues: [CompatibilityIssue] = []
        let location = "networks.\(network.key)"
        issues += emptyLabelKeyIssues(network.labels, location: location)
        issues += reservedComposeLabelIssues(network.labels, location: location)
        let ipv4SubnetCount = network.ipamSubnets.filter { !$0.contains(":") }.count
        let ipv6SubnetCount = network.ipamSubnets.filter { $0.contains(":") }.count
        if network.enableIPv4 == false {
            issues.append(.init(.error, location, "enable_ipv4", "Disabling IPv4 address assignment is defined by Compose but is not exposed by Apple container CLI."))
        }
        if network.enableIPv6 == true && ipv6SubnetCount == 0 {
            issues.append(.init(.error, location, "enable_ipv6", "Apple container network create can only enable IPv6 by receiving an explicit IPv6 --subnet-v6 prefix."))
        }
        if ipv4SubnetCount > 1 || ipv6SubnetCount > 1 {
            let duplicateFamilies = [
                ipv4SubnetCount > 1 ? "IPv4" : nil,
                ipv6SubnetCount > 1 ? "IPv6" : nil
            ].compactMap { $0 }.joined(separator: " and ")
            issues.append(.init(.error, location, "ipam.config", "Apple container network create accepts one IPv4 --subnet and one IPv6 --subnet-v6; extra \(duplicateFamilies) subnets cannot be applied."))
        }
        return issues
    }

    private func analyze(_ volume: ComposeVolume) -> [CompatibilityIssue] {
        var issues: [CompatibilityIssue] = []
        let location = "volumes.\(volume.key)"
        issues += emptyLabelKeyIssues(volume.labels, location: location)
        issues += reservedComposeLabelIssues(volume.labels, location: location)
        if let driver = volume.driver, !["local", "default"].contains(driver) {
            issues.append(.init(.error, location, "driver", "Apple container volumes do not expose Docker volume drivers."))
        }
        return issues
    }

    private func analyze(_ service: ComposeService, project: ComposeProject, plannedServiceNames: Set<String>?) -> [CompatibilityIssue] {
        guard let map = service.raw.map else { return [] }
        var issues: [CompatibilityIssue] = []
        let location = "services.\(service.name)"

        if service.image == nil && service.build == nil && !hasActiveProvider(map["provider"]) {
            issues.append(.init(.error, location, "image/build", "A service needs either image or build to run."))
        }
        if service.command?.isEmptyOverride == true {
            issues.append(.init(.error, location, "command", "Empty command overrides image CMD in Compose, but Apple container CLI does not expose a way to clear the image command without replacing it."))
        }
        if service.entrypoint?.isEmptyOverride == true {
            issues.append(.init(.error, location, "entrypoint", "Empty entrypoint overrides image ENTRYPOINT in Compose, but Apple container CLI does not expose a documented way to clear the image entrypoint."))
        }
        if !service.annotations.isEmpty {
            issues.append(.init(.error, location, "annotations", "Compose annotations define container annotations, but Apple container CLI 1.0.0 exposes labels only and no annotation flag."))
        }
        issues += emptyEnvironmentKeyIssues(service.environment, location: "\(location).environment", feature: "environment")
        issues += emptyLabelKeyIssues(service.labels, location: location)
        issues += reservedComposeLabelIssues(service.labels, location: location)
        if let attach = map["attach"], exactBool(attach) != false {
            issues.append(.init(.warning, location, "attach", "apple-compose runs containers detached and does not attach log streams during up."))
        }
        if let restart = map["restart"] {
            if let rawPolicy = exactString(restart), !rawPolicy.isEmpty {
                let policy = rawPolicy.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if policy != "no" {
                    issues.append(.init(.error, location, "restart", "Apple container CLI 1.0.0 does not expose Docker restart policies. Only Compose's explicit no/default restart policy can be represented."))
                }
            }
        }
        if let privileged = map["privileged"], exactBool(privileged) != false {
            issues.append(.init(.error, location, "privileged", "Privileged Docker container mode has no Apple container equivalent."))
        }
        if let oomKillDisable = map["oom_kill_disable"], exactBool(oomKillDisable) != false {
            issues.append(.init(.error, location, "oom_kill_disable", "OOM killer configuration is not exposed by Apple container CLI."))
        }
        if let useAPISocket = map["use_api_socket"], exactBool(useAPISocket) != false {
            issues.append(.init(.error, location, "use_api_socket", "Docker API socket mounting/delegation is not available with Apple container CLI."))
        }
        if let securityOpt = map["security_opt"] {
            issues += analyzeSecurityOpt(securityOpt, location: location)
        }
        if let memswapLimit = map["memswap_limit"], !isByteValue(memswapLimit, equalTo: 0, allowUnlimitedSwap: true) {
            if isPositiveByteValue(memswapLimit), !hasMemoryLimit(map) {
                issues.append(.init(.error, location, "memswap_limit + memory", "Compose requires positive memswap_limit values to be used with a memory limit. Set mem_limit or deploy.resources.limits.memory."))
            }
            issues.append(.init(.error, location, "memswap_limit", "Swap-inclusive memory limits are not exposed by Apple container CLI. Compose's explicit 0/no-op value is accepted."))
        }
        if let oomScoreAdj = map["oom_score_adj"], !isNumericValue(oomScoreAdj, equalTo: 0) {
            issues.append(.init(.error, location, "oom_score_adj", "OOM score adjustment is not exposed by Apple container CLI. Compose's explicit 0/default value is accepted."))
        }
        if let pidsLimit = map["pids_limit"], !isNoopPidsLimit(pidsLimit) {
            issues.append(.init(.error, location, "pids_limit", "PID limits are not exposed by Apple container CLI. Compose's explicit 0/default and -1/unlimited values are accepted as default behavior."))
        }
        if let healthcheck = map["healthcheck"], !isNoopHealthcheck(healthcheck), !isDisabledHealthcheck(healthcheck) {
            issues.append(.init(.error, location, "healthcheck", "Apple container CLI has no container healthcheck API; depends_on health conditions cannot be honored. Disabled healthcheck forms are accepted."))
        }
        if let networkMode = map["network_mode"], !isExactEmptyStringValue(networkMode) {
            let mode = networkMode.string?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if map["networks"] != nil {
                issues.append(.init(.error, location, "network_mode + networks", "Compose forbids setting both network_mode and networks on the same service."))
            }
            if mode == "host" && !service.ports.isEmpty {
                issues.append(.init(.error, location, "network_mode + ports", "Compose port mappings must not be used with network_mode: host because host networking already exposes container ports directly."))
            }
            if mode != "none" {
                issues.append(.init(.error, location, "network_mode", "Only network_mode: none can be represented by omitting Apple container network attachments. Docker network_mode values such as host, service, and container are not exposed by Apple container CLI."))
            }
        }

        let unsupportedServiceKeys: [(String, String)] = [
            ("blkio_config", "Block I/O throttling is not exposed by Apple container CLI."),
            ("cgroup_parent", "Cgroup parent selection is not exposed by Apple container CLI."),
            ("sysctls", "Linux sysctl injection is not exposed by Apple container CLI."),
            ("devices", "Device passthrough is not exposed by Apple container CLI."),
            ("device_cgroup_rules", "Device cgroup rules are not exposed by Apple container CLI."),
            ("gpus", "GPU device reservation/passthrough is not exposed by Apple container CLI."),
            ("group_add", "Supplementary groups are not exposed by Apple container CLI; only --gid/--user are available."),
            ("pid", "PID namespace modes are not exposed by Apple container CLI."),
            ("ipc", "IPC namespace modes are not exposed by Apple container CLI."),
            ("cgroup", "Cgroup namespace modes are not exposed by Apple container CLI."),
            ("uts", "UTS namespace modes are not exposed by Apple container CLI."),
            ("external_links", "Legacy external links are not supported by Apple container CLI."),
            ("extra_hosts", "Custom /etc/hosts entries are not exposed by Apple container CLI."),
            ("hostname", "Container hostname cannot be set through Apple container CLI 1.0.0."),
            ("logging", "Docker logging drivers cannot be configured through Apple container CLI."),
            ("credential_spec", "Windows credential_spec has no macOS Apple container equivalent."),
            ("isolation", "Docker isolation modes have no Apple container equivalent."),
            ("models", "Docker Compose model-runner integration is not available in Apple container CLI."),
            ("provider", "Compose provider delegation is not implemented by apple-compose."),
            ("develop", "Compose develop/watch behavior is not available in Apple container CLI."),
            ("storage_opt", "Container storage driver options are not exposed by Apple container CLI."),
            ("userns_mode", "User namespace modes are not exposed by Apple container CLI."),
            ("volumes_from", "Mounting all volumes from another container is not exposed by Apple container CLI.")
        ]
        for (key, message) in unsupportedServiceKeys {
            guard let value = map[key], !isEmptyNoopValue(value), !isUnsupportedNoopValue(key, value) else {
                continue
            }
            issues.append(.init(.error, location, key, message))
        }
        if let cpuPercent = map["cpu_percent"], !isNumericValue(cpuPercent, equalTo: 0) {
            issues.append(.init(.error, location, "cpu_percent", "Apple container CLI exposes --cpus, but not Docker cpu_percent. Compose's explicit 0/default value is accepted."))
        }
        for key in ["cpu_shares", "cpu_period", "cpu_quota"] where map[key] != nil && !isNumericValue(map[key]!, equalTo: 0) {
            issues.append(.init(.error, location, key, cpuControlMessage(for: key)))
        }
        for key in ["cpu_rt_runtime", "cpu_rt_period"] where map[key] != nil && !isZeroDurationOrMicroseconds(map[key]!) {
            issues.append(.init(.error, location, key, cpuControlMessage(for: key)))
        }
        if let cpuset = map["cpuset"], !isEmptyStringValue(cpuset) {
            issues.append(.init(.error, location, "cpuset", "CPU set pinning is not exposed by Apple container CLI. Compose's empty/default value is accepted."))
        }
        if let memReservation = map["mem_reservation"], !isByteValue(memReservation, equalTo: 0) {
            issues.append(.init(.error, location, "mem_reservation", "Memory reservation is not exposed by Apple container CLI; only a hard --memory limit can be applied. Compose's explicit 0/default reservation is accepted."))
        }
        if let memSwappiness = map["mem_swappiness"], !isNumericValue(memSwappiness, equalTo: 0) {
            issues.append(.init(.error, location, "mem_swappiness", "Memory swappiness is not exposed by Apple container CLI. Compose's explicit 0/default value is accepted."))
        }

        for key in map.keys where !knownServiceKeys.contains(key) && !key.hasPrefix("x-") {
            issues.append(.init(.error, location, key, "This Compose service attribute is not implemented by apple-compose yet and would otherwise be ignored."))
        }
        issues += analyzeNestedServiceMaps(service, location: location)

        if let deploy = map["deploy"]?.map {
            let supportedDeployKeys: Set<String> = ["endpoint_mode", "labels", "mode", "placement", "replicas", "resources", "restart_policy", "rollback_config", "update_config"]
            for key in deploy.keys where !supportedDeployKeys.contains(key) && !key.hasPrefix("x-") {
                issues.append(.init(.error, "\(location).deploy", key, "Apple containers are not a Swarm orchestrator, so this deploy setting cannot be applied."))
            }
            if let labels = deploy["labels"], !isEmptyNoopValue(labels) {
                issues.append(.init(.error, "\(location).deploy", "labels", "Compose deploy labels are service metadata and are not inherited by containers; Apple container CLI has no service object to label."))
            }
            if let modeValue = deploy["mode"],
               !isExactEmptyStringValue(modeValue),
               let mode = modeValue.string,
               mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "replicated" {
                issues.append(.init(.error, "\(location).deploy", "mode", "Only the default replicated deploy mode can be mapped to local Apple containers. Mode '\(mode)' requires orchestrator semantics."))
            }
            if let endpointMode = deploy["endpoint_mode"], !isExactEmptyStringValue(endpointMode) {
                issues.append(.init(.error, "\(location).deploy", "endpoint_mode", "Deploy endpoint modes require Swarm service networking and cannot be applied to local Apple containers."))
            }
            if let placement = deploy["placement"], !isEmptyNoopValue(placement) {
                issues.append(.init(.error, "\(location).deploy", "placement", "Deploy placement constraints and preferences require a Swarm orchestrator and cannot be applied to local Apple containers."))
            }
            if let updateConfig = deploy["update_config"], !isDeployUpdateConfigNoopValue(updateConfig) {
                issues.append(.init(.error, "\(location).deploy", "update_config", "Deploy update_config requires Swarm rolling-update orchestration and cannot be applied to local Apple containers."))
            }
            if let rollbackConfig = deploy["rollback_config"], !isDeployUpdateConfigNoopValue(rollbackConfig) {
                issues.append(.init(.error, "\(location).deploy", "rollback_config", "Deploy rollback_config requires Swarm rollback orchestration and cannot be applied to local Apple containers."))
            }
            if let restartPolicy = deploy["restart_policy"]?.map {
                issues += analyzeDeployRestartPolicy(restartPolicy, location: "\(location).deploy.restart_policy")
            }
            if let resources = deploy["resources"]?.map {
                for key in resources.keys where !["limits", "reservations"].contains(key) && !key.hasPrefix("x-") {
                    issues.append(.init(.error, "\(location).deploy.resources", key, "This deploy resource setting is not defined by the modern Compose deploy specification."))
                }
                if let limits = resources["limits"]?.map {
                    for key in limits.keys where !["cpus", "memory", "pids"].contains(key) && !key.hasPrefix("x-") {
                        issues.append(.init(.error, "\(location).deploy.resources.limits", key, "Only CPU and memory limits can be mapped to Apple container flags; Apple container CLI does not expose deploy resource limit '\(key)'."))
                    }
                    if let pids = limits["pids"], !isNoopPidsLimit(pids) {
                        issues.append(.init(.error, "\(location).deploy.resources.limits", "pids", "PID limits are not exposed by Apple container CLI. Compose's explicit 0/default and -1/unlimited values are accepted as default behavior."))
                    }
                    if let serviceCPUs = map["cpus"]?.string,
                       !isNumericValue(map["cpus"]!, equalTo: 0),
                       let deployCPUs = limits["cpus"]?.string,
                       !cpuValuesConsistent(serviceCPUs, deployCPUs) {
                        issues.append(.init(.error, location, "cpus + deploy.resources.limits.cpus", "Compose requires service cpus to be consistent with deploy.resources.limits.cpus when both are set."))
                    }
                    if let serviceMemory = map["mem_limit"]?.string,
                       !isByteValue(map["mem_limit"]!, equalTo: 0),
                       let deployMemory = limits["memory"]?.string,
                       !byteValuesConsistent(serviceMemory, deployMemory) {
                        issues.append(.init(.error, location, "mem_limit + deploy.resources.limits.memory", "Compose requires mem_limit to be consistent with deploy.resources.limits.memory when both are set."))
                    }
                    if let servicePids = map["pids_limit"]?.int,
                       !isNumericValue(map["pids_limit"]!, equalTo: 0),
                       let deployPids = limits["pids"]?.int,
                       servicePids != deployPids {
                        issues.append(.init(.error, location, "pids_limit + deploy.resources.limits.pids", "Compose requires pids_limit to be consistent with deploy.resources.limits.pids when both are set."))
                    }
                }
                if let reservations = resources["reservations"]?.map {
                    if reservations["devices"] != nil {
                        issues.append(.init(.error, "\(location).deploy.resources.reservations", "devices", "Device reservations are orchestration-time scheduling constraints and are not exposed by Apple container CLI."))
                    }
                    if let genericResources = reservations["generic_resources"], !isEmptyNoopValue(genericResources) {
                        issues.append(.init(.error, "\(location).deploy.resources.reservations", "generic_resources", "Generic resource reservations are orchestration-time scheduling constraints and are not exposed by Apple container CLI."))
                    }
                    if let serviceMemoryReservation = map["mem_reservation"]?.string,
                       !isByteValue(map["mem_reservation"]!, equalTo: 0),
                       let deployMemoryReservation = reservations["memory"]?.string,
                       !byteValuesConsistent(serviceMemoryReservation, deployMemoryReservation) {
                        issues.append(.init(.error, location, "mem_reservation + deploy.resources.reservations.memory", "Compose requires mem_reservation to be consistent with deploy.resources.reservations.memory when both are set."))
                    }
                    if let cpus = reservations["cpus"], !isNumericValue(cpus, equalTo: 0) {
                        issues.append(.init(.error, "\(location).deploy.resources.reservations", "cpus", "CPU reservations are scheduler guarantees; Apple container CLI only exposes hard CPU limits. Compose's explicit 0/default reservation is accepted."))
                    }
                    if let memory = reservations["memory"], !isByteValue(memory, equalTo: 0) {
                        issues.append(.init(.error, "\(location).deploy.resources.reservations", "memory", "Memory reservations are scheduler guarantees; Apple container CLI only exposes hard memory limits. Compose's explicit 0/default reservation is accepted."))
                    }
                    for key in reservations.keys where !["cpus", "devices", "generic_resources", "memory"].contains(key) && !key.hasPrefix("x-") {
                        issues.append(.init(.error, "\(location).deploy.resources.reservations", key, "Resource reservations are scheduler guarantees; Apple container CLI only exposes hard CPU and memory limits."))
                    }
                }
            }
        }

        for (dependency, spec) in service.dependsOn {
            let dependencyDefined = project.services[dependency] != nil
            let dependencyInPlan = plannedServiceNames?.contains(dependency) ?? dependencyDefined
            if !dependencyInPlan && dependencyDefined {
                issues.append(.init(.warning, "\(location).depends_on.\(dependency)", "selection", "Dependency '\(dependency)' is not included in the selected plan; apple-compose will not enforce this depends_on relationship."))
                continue
            }
            if !dependencyDefined && spec.required == false {
                issues.append(.init(.warning, "\(location).depends_on.\(dependency)", "required", "Optional dependency '\(dependency)' is not defined or not active; apple-compose will warn and omit it from the plan."))
                continue
            }
            if !dependencyDefined {
                issues.append(.init(.error, "\(location).depends_on.\(dependency)", "dependency", "Dependency '\(dependency)' is not defined or not active."))
                continue
            }
            if let condition = spec.condition, condition != "service_started" {
                issues.append(.init(.error, "\(location).depends_on.\(dependency)", "condition", "Only service_started can be approximated. Apple containers do not report Compose health or completion state."))
            }
            if spec.restart {
                issues.append(.init(.error, "\(location).depends_on.\(dependency)", "restart", "Compose dependency restart propagation is a client operation and is not implemented by apple-compose."))
            }
        }

        for (index, link) in service.links.enumerated() {
            let linkLocation = "\(location).links[\(index)]"
            let dependencyDefined = project.services[link.source] != nil
            let dependencyInPlan = plannedServiceNames?.contains(link.source) ?? dependencyDefined
            if !dependencyInPlan && dependencyDefined {
                issues.append(.init(.warning, linkLocation, "selection", "Linked service '\(link.source)' is not included in the selected plan; apple-compose will not enforce this links dependency."))
            } else if !dependencyDefined {
                issues.append(.init(.error, linkLocation, "dependency", "Linked service '\(link.source)' is not defined or not active."))
            }
            if let alias = link.alias {
                issues.append(.init(.error, linkLocation, "alias", "Link alias '\(alias)' requires per-service network aliases, which Apple container CLI does not expose. Use the linked service name on a shared network."))
            }
        }

        for (index, port) in service.ports.enumerated() {
            let portLocation = "\(location).ports[\(index)]"
            if port.name != nil {
                issues.append(.init(.warning, portLocation, "name", "Port names are metadata only and are not passed to Apple container CLI."))
            }
            if port.appProtocol != nil {
                issues.append(.init(.warning, portLocation, "app_protocol", "Application protocol metadata is not passed to Apple container CLI."))
            }
            if let protocolName = port.protocolName,
               !["tcp", "udp"].contains(protocolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
                issues.append(.init(.error, portLocation, "protocol", "Apple container port publishing only documents TCP and UDP; Compose protocol '\(protocolName)' cannot be applied with exact semantics."))
            }
            if port.target == nil {
                issues.append(.init(.error, portLocation, "target", "Compose port mappings must define a container target port."))
            }
            if port.published == nil {
                issues.append(.init(.error, portLocation, "published", "Compose target-only ports require automatic host-port allocation, but Apple container --publish requires an explicit host port and container port."))
            }
            if !hasSupportedPublishedRange(port) {
                issues.append(.init(.error, portLocation, "range", "Port ranges can only be represented when published and target are fixed ranges of equal length. Apple container CLI does not expose Compose's host-port range allocation semantics."))
            }
        }

        if let pullPolicy = service.pullPolicy?.lowercased() {
            if pullPolicy == "build" && service.build == nil {
                issues.append(.init(.error, location, "pull_policy", "pull_policy=build requires a build section; apple-compose cannot build an image-only service."))
            }
        }

        if service.replicas > 1 && service.ports.contains(where: hasFixedPublishedPort) {
            issues.append(.init(.error, location, "replicas + fixed ports", "Multiple replicas cannot bind the same published host port."))
        }

        for envFile in service.envFiles {
            guard let format = envFile.format?.lowercased(), !["compose", "raw"].contains(format) else {
                continue
            }
            issues.append(.init(.error, location, "env_file.format", "Unsupported env_file format '\(format)'. Compose supports default/compose and raw formats."))
        }

        for hook in service.postStart where hook.privileged {
            issues.append(.init(.error, "\(location).post_start", "privileged", "Apple container exec does not support privileged lifecycle hook commands."))
        }
        for hook in service.preStop where hook.privileged {
            issues.append(.init(.error, "\(location).pre_stop", "privileged", "Apple container exec does not support privileged lifecycle hook commands."))
        }
        for (index, hook) in service.postStart.enumerated() {
            issues += emptyEnvironmentKeyIssues(hook.environment, location: "\(location).post_start[\(index)].environment", feature: "environment")
        }
        for (index, hook) in service.preStop.enumerated() {
            issues += emptyEnvironmentKeyIssues(hook.environment, location: "\(location).pre_stop[\(index)].environment", feature: "environment")
        }
        if !service.postStart.isEmpty {
            issues.append(.init(.warning, location, "post_start", "Hooks are run by apple-compose with container exec after container run returns; exact Compose timing is best-effort."))
        }
        if !service.preStop.isEmpty {
            issues.append(.init(.warning, location, "pre_stop", "Hooks are run by apple-compose before managed stops/deletes; hooks cannot run when a container exits by itself."))
        }

        for volume in service.volumes {
            let volumeLocation = "\(location).volumes[\(volume.target)]"
            if let type = volume.type, !["bind", "volume", "tmpfs"].contains(type) {
                issues.append(.init(.error, volumeLocation, "type", "Mount type '\(type)' is not supported by Apple container CLI."))
            }
            if volume.consistency != nil {
                issues.append(.init(.warning, volumeLocation, "consistency", "macOS bind consistency hints are not exposed by Apple container CLI."))
            }
            if volume.shortOptions.contains(where: { $0 == "z" || $0 == "Z" }) {
                issues.append(.init(.warning, volumeLocation, "SELinux relabel", "SELinux relabeling from short volume syntax is ignored by Apple container CLI."))
            }
            for option in volume.shortOptions where !knownShortVolumeOptions.contains(option) {
                issues.append(.init(.error, volumeLocation, option, "Unknown or unsupported short-syntax volume access mode."))
            }
            if exactString(volume.bind?["propagation"])?.isEmpty == false {
                issues.append(.init(.error, volumeLocation, "bind.propagation", "Apple container --mount does not expose Compose bind propagation modes."))
            }
            if let recursive = volume.bind?["recursive"],
               let mode = exactString(recursive)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               mode != "enabled" {
                issues.append(.init(.error, volumeLocation, "bind.recursive", "Apple container --mount does not expose Compose bind recursive modes. Only the default enabled behavior can be approximated."))
            }
            if volume.bind?["selinux"] != nil {
                issues.append(.init(.warning, volumeLocation, "bind.selinux", "SELinux relabeling is ignored on platforms without SELinux, including Apple container hosts."))
            }
            let activeNocopy = exactBool(volume.volume?["nocopy"]) == true
            let activeSubpath = exactString(volume.volume?["subpath"])?.isEmpty == false
            if activeNocopy || activeSubpath {
                issues.append(.init(.error, volumeLocation, "volume", "Apple container volume mounts do not expose Compose volume nocopy or subpath options."))
            }
            if !volume.volumeLabels.isEmpty {
                issues += emptyLabelKeyIssues(volume.volumeLabels, location: "\(volumeLocation).volume")
                issues += reservedComposeLabelIssues(volume.volumeLabels, location: "\(volumeLocation).volume")
                if resolvedVolumeType(volume) == "volume",
                   let source = volume.source,
                   project.volumes[source]?.external == true {
                    issues.append(.init(.error, "\(volumeLocation).volume", "labels", "Service-level volume labels cannot be applied to an external volume that apple-compose does not create."))
                }
            }
            if volume.tmpfs?["mode"] != nil || volume.tmpfs?["size"] != nil {
                issues.append(.init(.error, volumeLocation, "tmpfs", "Apple container --tmpfs accepts a target path only; Compose tmpfs mode and size cannot be applied."))
            }
        }

        for tmpfs in service.tmpfs where tmpfs.options != nil {
            issues.append(.init(.error, "\(location).tmpfs[\(tmpfs.target)]", "options", "Apple container --tmpfs accepts a target path only; Compose tmpfs options cannot be applied."))
        }

        let attachments = networkModeIsNone(service.networkMode) ? [:] : (service.networks ?? ["default": .empty(key: "default")])
        for attachment in attachments.values {
            let netLocation = "\(location).networks.\(attachment.key)"
            if !attachment.aliases.isEmpty {
                issues.append(.init(.error, netLocation, "aliases", "Per-service network aliases cannot be configured through Apple container CLI."))
            }
            if attachment.ipv4Address != nil || attachment.ipv6Address != nil {
                issues.append(.init(.error, netLocation, "static IP", "Static per-container IP assignment is not exposed by Apple container CLI."))
            }
            let unsupportedDriverOptions = attachment.driverOptions.keys.sorted().filter { $0 != "mtu" }
            if !unsupportedDriverOptions.isEmpty {
                issues.append(.init(.error, netLocation, "driver_opts", "Apple container --network accepts mtu but not other per-container network driver options: \(unsupportedDriverOptions.joined(separator: ", "))."))
            }
            if attachment.interfaceName != nil || attachment.gwPriority != nil || !attachment.linkLocalIPs.isEmpty {
                issues.append(.init(.error, netLocation, "advanced attachment options", "Apple container --network does not expose Compose interface_name, gw_priority, or link_local_ips."))
            }
        }

        for grant in service.secrets {
            if let secret = project.secrets[grant.source] {
                if secret.external {
                    issues.append(.init(.error, "\(location).secrets.\(grant.source)", "external", "Apple container CLI has no external secret store integration."))
                } else {
                    issues += analyzeSecretGrantOptions(grant, secret: secret, location: "\(location).secrets.\(grant.source)")
                }
            } else {
                issues.append(.init(.error, "\(location).secrets.\(grant.source)", "source", "Service secret grants must reference a top-level secret definition."))
            }
        }

        for grant in service.configs {
            if let config = project.configs[grant.source] {
                if config.external {
                    issues.append(.init(.error, "\(location).configs.\(grant.source)", "external", "Apple container CLI has no external config store integration."))
                } else {
                    issues += analyzeConfigGrantOptions(grant, config: config, location: "\(location).configs.\(grant.source)")
                }
            } else {
                issues.append(.init(.error, "\(location).configs.\(grant.source)", "source", "Service config grants must reference a top-level config definition."))
            }
        }

        if let build = service.build, buildIsActive(service) {
            let buildMap = map["build"]?.map ?? [:]
            if looksLikeRemoteBuildContext(build.context) {
                issues.append(.init(.error, "\(location).build", "context", "Remote/Git build contexts are supported by Compose but Apple container build accepts a local context directory."))
            }
            if let privileged = buildMap["privileged"], exactBool(privileged) != false {
                issues.append(.init(.error, "\(location).build", "privileged", "Privileged image builds are not exposed by Apple container build."))
            }
            if let provenance = buildMap["provenance"], !isEmptyStringValue(provenance), exactBool(provenance) != false {
                issues.append(.init(.error, "\(location).build", "provenance", "Build provenance attestations are not exposed by Apple container build."))
            }
            if let sbom = buildMap["sbom"], !isEmptyStringValue(sbom), exactBool(sbom) != false {
                issues.append(.init(.error, "\(location).build", "sbom", "Build SBOM attestations are not exposed by Apple container build."))
            }
            if let networkValue = buildMap["network"],
               !isEmptyStringValue(networkValue),
               let network = exactString(networkValue),
               network.lowercased() != "default" {
                issues.append(.init(.error, "\(location).build", "network", "Build network mode is not exposed by Apple container build. Only the default build network can be represented."))
            }
            if build.shmSize != nil {
                issues.append(.init(.error, "\(location).build", "shm_size", "Compose build shared memory sizing is not exposed by Apple container build."))
            }
            if !build.ulimits.isEmpty {
                issues.append(.init(.error, "\(location).build", "ulimits", "Compose build ulimits are not exposed by Apple container build."))
            }
            if let cacheFrom = buildMap["cache_from"], !isEmptyNoopValue(cacheFrom), !isEmptyStringArray(cacheFrom) {
                issues.append(.init(.warning, "\(location).build", "cache_from", "Apple container build does not expose cache import flags; Compose Build permits unsupported cache sources to be ignored."))
            }
            if let cacheTo = buildMap["cache_to"], !isEmptyNoopValue(cacheTo), !isEmptyStringArray(cacheTo) {
                issues.append(.init(.warning, "\(location).build", "cache_to", "Apple container build does not expose cache export flags; Compose Build permits unsupported cache targets to be ignored."))
            }
            issues += emptyEnvironmentKeyIssues(build.args, location: "\(location).build.args", feature: "build argument")
            issues += emptyLabelKeyIssues(build.labels, location: "\(location).build")
            let unsupportedBuildKeys: [(String, String)] = [
                ("additional_contexts", "Apple container build help does not expose BuildKit additional contexts."),
                ("entitlements", "Build entitlements are not exposed by Apple container build."),
                ("extra_hosts", "Build extra_hosts are not exposed by Apple container build."),
                ("isolation", "Build isolation is not exposed by Apple container build."),
                ("ssh", "Build SSH mounts are not exposed by Apple container build 1.0.0.")
            ]
            for (key, message) in unsupportedBuildKeys {
                guard let value = buildMap[key], !isEmptyNoopValue(value), !isBuildEmptyStringNoop(key, value) else {
                    continue
                }
                issues.append(.init(.error, "\(location).build", key, message))
            }
            for key in buildMap.keys where !knownBuildKeys.contains(key) && !key.hasPrefix("x-") {
                issues.append(.init(.error, "\(location).build", key, "This Compose build attribute is not implemented by apple-compose and would otherwise be ignored."))
            }
            if let dockerfile = buildMap["dockerfile"],
               let dockerfileInline = buildMap["dockerfile_inline"],
               !isEmptyNoopValue(dockerfile),
               !isEmptyNoopValue(dockerfileInline),
               !isEmptyStringValue(dockerfile),
               !isEmptyStringValue(dockerfileInline) {
                issues.append(.init(.error, "\(location).build", "dockerfile + dockerfile_inline", "Compose build definitions must not set both dockerfile and dockerfile_inline."))
            }
            if let servicePlatform = service.platform, !build.platforms.isEmpty && !build.platforms.contains(servicePlatform) {
                issues.append(.init(.error, "\(location).build", "platforms", "Service platform '\(servicePlatform)' is not listed in build.platforms, so apple-compose cannot build the image it will run."))
            } else if service.platform == nil && build.platforms.count > 1 {
                issues.append(.init(.error, "\(location).build", "platforms", "Apple container build can build one platform per invocation; set service platform to select which build.platforms entry should be built and run."))
            }
            for grant in build.secrets {
                if let secret = project.secrets[grant.source] {
                    if secret.external {
                        issues.append(.init(.error, "\(location).build.secrets.\(grant.source)", "external", "Apple container build has no external secret store integration."))
                    }
                } else {
                    issues.append(.init(.error, "\(location).build.secrets.\(grant.source)", "source", "Build secret grants must reference a top-level secret definition."))
                }
                if grant.uid != nil || grant.gid != nil || grant.mode != nil {
                    issues.append(.init(.error, "\(location).build.secrets.\(grant.source)", "uid/gid/mode", "Compose build secrets can set uid, gid, and mode inside the build container, but Apple container build --secret only exposes id/env/src."))
                }
            }
        }

        return issues
    }

    private func analyzeDeployRestartPolicy(_ restartPolicy: [String: YAMLValue], location: String) -> [CompatibilityIssue] {
        guard !isDeployRestartPolicyNoopValue(.map(restartPolicy)) else {
            return []
        }
        let condition = exactString(restartPolicy["condition"])?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if condition == "none", restartPolicy.keys.allSatisfy({ $0 == "condition" || $0.hasPrefix("x-") }) {
            return []
        }
        return [
            .init(.error, location, "condition", "Only deploy.restart_policy.condition: none can be represented as Apple container's default no-restart behavior. Active restart policies are not exposed by Apple container CLI.")
        ]
    }

    private func isDeployRestartPolicyNoopValue(_ value: YAMLValue) -> Bool {
        switch value {
        case .null:
            return true
        case .map(let map):
            return map.allSatisfy { key, value in
                if key.hasPrefix("x-") {
                    return true
                }
                if key == "condition" {
                    return isExactEmptyStringValue(value)
                }
                return false
            }
        case .reset(let value), .overrideValue(let value):
            return isDeployRestartPolicyNoopValue(value)
        default:
            return false
        }
    }

    private func isDeployUpdateConfigNoopValue(_ value: YAMLValue) -> Bool {
        switch value {
        case .null:
            return true
        case .map(let map):
            return map.allSatisfy { key, value in
                if key.hasPrefix("x-") {
                    return true
                }
                if key == "failure_action" {
                    return isExactEmptyStringValue(value)
                }
                return false
            }
        case .reset(let value), .overrideValue(let value):
            return isDeployUpdateConfigNoopValue(value)
        default:
            return false
        }
    }

    private func analyzeSecretGrantOptions(_ grant: ServiceFileGrant, secret: ComposeSecret, location: String) -> [CompatibilityIssue] {
        if secret.file != nil {
            return []
        }
        guard grant.uid != nil || grant.gid != nil else {
            return []
        }
        return [
            .init(.error, location, "uid/gid", "Compose can set uid/gid for environment-backed service secrets, but Apple container bind mounts do not expose container-visible ownership remapping. Secret mode is applied for generated secrets.")
        ]
    }

    private func analyzeConfigGrantOptions(_ grant: ServiceFileGrant, config _: ComposeConfig, location: String) -> [CompatibilityIssue] {
        var issues: [CompatibilityIssue] = []
        if grant.uid != nil || grant.gid != nil {
            issues.append(.init(.error, location, "uid/gid", "Compose configs can set mounted file ownership, but Apple container bind mounts do not expose container-visible ownership remapping. Config mode is applied by generated config artifacts."))
        }
        return issues
    }

    private func analyzeNestedServiceMaps(_ service: ComposeService, location: String) -> [CompatibilityIssue] {
        guard let map = service.raw.map else { return [] }
        var issues: [CompatibilityIssue] = []
        issues += analyzeDependsOnMap(map["depends_on"], location: "\(location).depends_on")
        issues += analyzeEnvFileEntries(map["env_file"], location: "\(location).env_file")
        issues += analyzePortEntries(map["ports"], location: "\(location).ports")
        issues += analyzeVolumeEntries(map["volumes"], location: "\(location).volumes")
        issues += analyzeNetworkAttachmentEntries(map["networks"], location: "\(location).networks")
        issues += analyzeHealthcheckMap(map["healthcheck"], location: "\(location).healthcheck")
        issues += analyzeFileGrantEntries(map["secrets"], location: "\(location).secrets", kind: "secret grant")
        issues += analyzeFileGrantEntries(map["configs"], location: "\(location).configs", kind: "config grant")
        issues += analyzeLifecycleHookEntries(map["post_start"], location: "\(location).post_start")
        issues += analyzeLifecycleHookEntries(map["pre_stop"], location: "\(location).pre_stop")
        if buildIsActive(service), let buildMap = map["build"]?.map {
            issues += analyzeFileGrantEntries(buildMap["secrets"], location: "\(location).build.secrets", kind: "build secret grant")
            issues += analyzeUlimitEntries(buildMap["ulimits"], location: "\(location).build.ulimits")
        }
        issues += analyzeUlimitEntries(map["ulimits"], location: "\(location).ulimits")
        return issues
    }

    private func analyzeDependsOnMap(_ node: YAMLValue?, location: String) -> [CompatibilityIssue] {
        guard let map = node?.map else { return [] }
        var issues: [CompatibilityIssue] = []
        for (dependency, value) in map.sorted(by: { $0.key < $1.key }) {
            guard let dependencyMap = value.map else { continue }
            issues += unknownKeys(in: dependencyMap, known: knownDependsOnKeys, location: "\(location).\(dependency)", kind: "depends_on")
        }
        return issues
    }

    private func analyzeEnvFileEntries(_ node: YAMLValue?, location: String) -> [CompatibilityIssue] {
        guard let node else { return [] }
        let entries = node.array ?? [node]
        var issues: [CompatibilityIssue] = []
        for (index, entry) in entries.enumerated() {
            guard let map = entry.map else { continue }
            issues += unknownKeys(in: map, known: knownEnvFileKeys, location: "\(location)[\(index)]", kind: "env_file")
        }
        return issues
    }

    private func analyzePortEntries(_ node: YAMLValue?, location: String) -> [CompatibilityIssue] {
        guard let node else { return [] }
        let entries = node.array ?? [node]
        var issues: [CompatibilityIssue] = []
        for (index, entry) in entries.enumerated() {
            guard let map = entry.map else { continue }
            let entryLocation = "\(location)[\(index)]"
            issues += unknownKeys(in: map, known: knownPortKeys, location: entryLocation, kind: "port")
            if let mode = exactString(map["mode"])?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               !mode.isEmpty,
               mode != "host" {
                issues.append(.init(.error, entryLocation, "mode", "Compose port mode=\(mode) cannot be mapped exactly to Apple container --publish. Use mode=host for local host-port publishing."))
            }
        }
        return issues
    }

    private func analyzeVolumeEntries(_ node: YAMLValue?, location: String) -> [CompatibilityIssue] {
        guard let node else { return [] }
        let entries = node.array ?? [node]
        var issues: [CompatibilityIssue] = []
        for (index, entry) in entries.enumerated() {
            guard let map = entry.map else { continue }
            let entryLocation = "\(location)[\(index)]"
            issues += unknownKeys(in: map, known: knownServiceVolumeKeys, location: entryLocation, kind: "volume")
            if map["image"] != nil {
                issues.append(.init(.error, entryLocation, "image", "Image-backed mounts are not exposed by Apple container CLI."))
            }
            if map["cluster"] != nil {
                issues.append(.init(.error, entryLocation, "cluster", "Cluster-backed mounts are not exposed by Apple container CLI."))
            }
            if let bind = map["bind"]?.map {
                issues += unknownKeys(in: bind, known: knownBindVolumeKeys, location: "\(entryLocation).bind", kind: "bind volume")
            }
            if let volume = map["volume"]?.map {
                issues += unknownKeys(in: volume, known: knownNamedVolumeKeys, location: "\(entryLocation).volume", kind: "named volume")
            }
            if let tmpfs = map["tmpfs"]?.map {
                issues += unknownKeys(in: tmpfs, known: knownTmpfsVolumeKeys, location: "\(entryLocation).tmpfs", kind: "tmpfs volume")
            }
        }
        return issues
    }

    private func analyzeNetworkAttachmentEntries(_ node: YAMLValue?, location: String) -> [CompatibilityIssue] {
        guard let map = node?.map else { return [] }
        var issues: [CompatibilityIssue] = []
        for (network, value) in map.sorted(by: { $0.key < $1.key }) {
            guard let attachmentMap = value.map else { continue }
            issues += unknownKeys(in: attachmentMap, known: knownNetworkAttachmentKeys, location: "\(location).\(network)", kind: "network attachment")
        }
        return issues
    }

    private func analyzeHealthcheckMap(_ node: YAMLValue?, location: String) -> [CompatibilityIssue] {
        guard let map = node?.map else { return [] }
        return unknownKeys(in: map, known: knownHealthcheckKeys, location: location, kind: "healthcheck")
    }

    private func analyzeFileGrantEntries(_ node: YAMLValue?, location: String, kind: String) -> [CompatibilityIssue] {
        guard let node else { return [] }
        let entries = node.array ?? [node]
        var issues: [CompatibilityIssue] = []
        for (index, entry) in entries.enumerated() {
            guard let map = entry.map else { continue }
            let entryLocation = "\(location)[\(index)]"
            issues += unknownKeys(in: map, known: knownFileGrantKeys, location: entryLocation, kind: kind)
            if map["source"] == nil {
                issues.append(.init(.error, entryLocation, "source", "Long-form Compose \(kind)s must define source."))
            }
        }
        return issues
    }

    private func analyzeLifecycleHookEntries(_ node: YAMLValue?, location: String) -> [CompatibilityIssue] {
        guard let node else { return [] }
        let entries = node.array ?? [node]
        var issues: [CompatibilityIssue] = []
        for (index, entry) in entries.enumerated() {
            guard let map = entry.map else { continue }
            issues += unknownKeys(in: map, known: knownLifecycleHookKeys, location: "\(location)[\(index)]", kind: "lifecycle hook")
        }
        return issues
    }

    private func analyzeUlimitEntries(_ node: YAMLValue?, location: String) -> [CompatibilityIssue] {
        guard let map = node?.map else { return [] }
        var issues: [CompatibilityIssue] = []
        for (name, value) in map.sorted(by: { $0.key < $1.key }) {
            guard let limitMap = value.map else { continue }
            issues += unknownKeys(in: limitMap, known: knownUlimitKeys, location: "\(location).\(name)", kind: "ulimit")
        }
        return issues
    }

    private func hasFixedPublishedPort(_ port: PortSpec) -> Bool {
        guard let published = port.published else { return false }
        return !published.isEmpty
    }

    private func hasSupportedPublishedRange(_ port: PortSpec) -> Bool {
        let publishedIsRange = isPortRange(port.published)
        let targetIsRange = isPortRange(port.target)
        guard publishedIsRange || targetIsRange else {
            return true
        }
        guard let target = port.target else {
            return false
        }
        if port.published == nil {
            return true
        }
        guard let published = port.published else { return false }
        guard let publishedRange = portRangeValues(published), let targetRange = portRangeValues(target) else {
            return false
        }
        return publishedRange.count == targetRange.count
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

    private func resolvedVolumeType(_ volume: ServiceVolume) -> String {
        if let type = volume.type {
            return type
        }
        guard let source = volume.source else {
            return "volume"
        }
        return looksLikeHostPath(source) ? "bind" : "volume"
    }

    private func looksLikeHostPath(_ value: String) -> Bool {
        value.hasPrefix(".") || value.hasPrefix("/") || value.hasPrefix("~")
    }

    private func cpuValuesConsistent(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        if let leftNumber = Double(left), let rightNumber = Double(right) {
            return abs(leftNumber - rightNumber) < 0.000_000_001
        }
        return left == right
    }

    private func byteValuesConsistent(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        if let leftBytes = composeByteValueBytes(left),
           let rightBytes = composeByteValueBytes(right) {
            return leftBytes == rightBytes
        }
        return left == right
    }

    private func isNumericValue(_ value: YAMLValue, equalTo expected: Double) -> Bool {
        guard let raw = value.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              let number = Double(raw) else {
            return false
        }
        return abs(number - expected) < 0.000_000_001
    }

    private func isZeroDurationOrMicroseconds(_ value: YAMLValue) -> Bool {
        guard let raw = value.string?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return false
        }
        if let number = Int(raw) {
            return number == 0
        }
        return composeDurationSeconds(raw) == 0
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

    private func isUnsupportedNoopValue(_ key: String, _ value: YAMLValue) -> Bool {
        switch key {
        case "cgroup", "cgroup_parent", "hostname", "ipc", "isolation", "pid", "userns_mode", "uts":
            return isEmptyStringValue(value)
        case "group_add":
            return isEmptyStringArray(value)
        case "external_links":
            return isEmptyStringArray(value)
        case "logging":
            return isLoggingNoopValue(value)
        case "provider":
            return isProviderNoopValue(value)
        default:
            return false
        }
    }

    private func isEmptyStringArray(_ value: YAMLValue) -> Bool {
        switch value {
        case .array(let values):
            return values.allSatisfy { isExactEmptyStringValue($0) }
        case .reset(let value), .overrideValue(let value):
            return isEmptyStringArray(value)
        default:
            return false
        }
    }

    private func isExactEmptyStringValue(_ value: YAMLValue) -> Bool {
        switch value {
        case .string(let string):
            return string.isEmpty
        case .reset(let value), .overrideValue(let value):
            return isExactEmptyStringValue(value)
        default:
            return false
        }
    }

    private func isLoggingNoopValue(_ value: YAMLValue) -> Bool {
        switch value {
        case .map(let map):
            guard !map.isEmpty else { return true }
            return map.allSatisfy { key, value in
                switch key {
                case "driver":
                    return isEmptyStringValue(value) || isEmptyNoopValue(value)
                case "options":
                    return isEmptyNoopValue(value)
                default:
                    return key.hasPrefix("x-")
                }
            }
        case .reset(let value), .overrideValue(let value):
            return isLoggingNoopValue(value)
        default:
            return false
        }
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

    private func hasActiveProvider(_ value: YAMLValue?) -> Bool {
        guard let value else {
            return false
        }
        return !isEmptyNoopValue(value) && !isProviderNoopValue(value)
    }

    private func isBuildEmptyStringNoop(_ key: String, _ value: YAMLValue) -> Bool {
        switch key {
        case "isolation":
            return isEmptyStringValue(value)
        case "entitlements":
            return isEmptyStringArray(value)
        default:
            return false
        }
    }

    private func cpuControlMessage(for key: String) -> String {
        switch key {
        case "cpu_shares":
            return "CPU share weighting is not exposed by Apple container CLI. Compose's explicit 0/default value is accepted."
        case "cpu_period":
            return "Linux CFS CPU period is not exposed by Apple container CLI. Compose's explicit 0/default value is accepted."
        case "cpu_quota":
            return "Linux CFS CPU quota is not exposed by Apple container CLI. Compose's explicit 0/default value is accepted."
        case "cpu_rt_runtime":
            return "Linux realtime CPU runtime is not exposed by Apple container CLI. Compose's explicit 0/default value is accepted."
        case "cpu_rt_period":
            return "Linux realtime CPU period is not exposed by Apple container CLI. Compose's explicit 0/default value is accepted."
        default:
            return "CPU control is not exposed by Apple container CLI. Compose's explicit default value is accepted."
        }
    }

    private func isByteValue(_ value: YAMLValue, equalTo expected: Int64, allowUnlimitedSwap: Bool = false) -> Bool {
        guard let raw = value.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              let bytes = composeByteValueBytes(raw, allowUnlimitedSwap: allowUnlimitedSwap) else {
            return false
        }
        return bytes == expected
    }

    private func isIntegerValue(_ value: YAMLValue, equalTo expected: Int) -> Bool {
        guard let raw = value.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              let number = Int(raw) else {
            return false
        }
        return number == expected
    }

    private func isPositiveByteValue(_ value: YAMLValue) -> Bool {
        guard let raw = value.string?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              raw != "-1" else {
            return false
        }
        return (composeByteValueBytes(raw, allowUnlimitedSwap: true) ?? 0) > 0
    }

    private func isNoopPidsLimit(_ value: YAMLValue) -> Bool {
        guard let pids = pidsLimitValue(value) else {
            return false
        }
        return pids == 0 || pids == -1
    }

    private func pidsLimitValue(_ value: YAMLValue) -> Int? {
        switch value {
        case .int(let value, _):
            return value
        case .double(let value):
            guard value.isFinite, value >= Double(Int.min), value <= Double(Int.max) else {
                return nil
            }
            return Int(value.rounded(.towardZero))
        case .string(let value):
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        case .reset(let value), .overrideValue(let value):
            return pidsLimitValue(value)
        default:
            return nil
        }
    }

    private func hasMemoryLimit(_ map: [String: YAMLValue]) -> Bool {
        if let memLimit = map["mem_limit"], !isEmptyNoopValue(memLimit) {
            return true
        }
        if let deployMemory = map["deploy"]?["resources"]?["limits"]?["memory"],
           !isEmptyNoopValue(deployMemory) {
            return true
        }
        return false
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

    private func buildIsActive(_ service: ComposeService) -> Bool {
        guard service.build != nil else {
            return false
        }
        guard service.image != nil else {
            return true
        }
        guard let policy = service.pullPolicy?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !policy.isEmpty else {
            return true
        }
        if ["always", "never"].contains(policy) || pullPolicyIntervalSeconds(for: service) != nil {
            return false
        }
        return true
    }

    private func pullPolicyIntervalSeconds(for service: ComposeService) -> Int? {
        let policy = service.pullPolicy?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if policy == "refresh" {
            return composePullPolicyRefreshAfterSeconds(service.pullRefreshAfter)
        }
        return composePullPolicyIntervalSeconds(policy)
    }

    private func networkModeIsNone(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "none"
    }

    private func isDisabledHealthcheck(_ value: YAMLValue) -> Bool {
        guard let map = value.map else {
            return false
        }
        if exactBool(map["disable"]) == true {
            return true
        }
        guard let test = map["test"] else {
            return false
        }
        if let array = test.array, exactString(array.first)?.uppercased() == "NONE" {
            return true
        }
        return false
    }

    private func isNoopHealthcheck(_ value: YAMLValue) -> Bool {
        guard let map = value.map else {
            return false
        }
        return map.allSatisfy { key, value in
            key.hasPrefix("x-") || (key == "test" && (value.array?.isEmpty ?? false))
        }
    }

    private func exactBool(_ value: YAMLValue?) -> Bool? {
        guard let value else { return nil }
        switch value {
        case .bool(let bool):
            return bool
        case .string(let string):
            return composeBooleanString(string)
        case .reset(let value), .overrideValue(let value):
            return exactBool(value)
        default:
            return nil
        }
    }

    private func composeBooleanString(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "t", "1":
            return true
        case "false", "f", "0":
            return false
        default:
            return nil
        }
    }

    private func exactString(_ value: YAMLValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let string):
            return string
        case .reset(let value), .overrideValue(let value):
            return exactString(value)
        default:
            return nil
        }
    }

    private func analyzeSecurityOpt(_ value: YAMLValue, location: String) -> [CompatibilityIssue] {
        if isEmptyNoopValue(value) {
            return []
        }
        guard let entries = value.array else {
            return [.init(.error, location, "security_opt", "Compose security_opt must be a list of option strings.")]
        }

        var issues: [CompatibilityIssue] = []
        var hasActiveOption = false
        for (index, entryValue) in entries.enumerated() {
            guard let entry = entryValue.string?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                issues.append(.init(.error, "\(location).security_opt[\(index)]", "syntax", "Compose security_opt entries must be option strings."))
                continue
            }
            guard !entry.isEmpty else { continue }
            if !isDisabledSecurityOptEntry(entry) {
                hasActiveOption = true
            }
        }
        if hasActiveOption {
            issues.append(.init(.error, location, "security_opt", "Docker security options cannot be passed to Apple containers. Only no-new-privileges=false is accepted as default behavior."))
        }
        return issues
    }

    private func isDisabledSecurityOptEntry(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "no-new-privileges=false" || normalized == "no-new-privileges:false"
    }

    private var knownServiceKeys: Set<String> {
        [
            "annotations", "attach", "blkio_config", "build", "cap_add", "cap_drop", "cgroup",
            "cgroup_parent", "command", "configs", "container_name", "cpu_count", "cpu_percent",
            "cpu_period", "cpu_quota", "cpu_rt_period", "cpu_rt_runtime", "cpu_shares", "cpus",
            "cpuset", "credential_spec", "depends_on", "deploy", "develop", "device_cgroup_rules",
            "devices", "dns", "dns_opt", "dns_search", "domainname", "driver_opts", "entrypoint",
            "env_file", "environment", "expose", "extends", "external_links", "extra_hosts", "gpus",
            "group_add", "healthcheck", "hostname", "image", "init", "ipc", "isolation", "label_file",
            "labels", "links", "logging", "mac_address", "mem_limit", "mem_reservation",
            "mem_swappiness", "memswap_limit", "models", "network_mode", "networks",
            "oom_kill_disable", "oom_score_adj", "pid", "pids_limit", "platform", "ports",
            "post_start", "pre_stop", "privileged", "profiles", "provider", "pull_policy",
            "pull_refresh_after",
            "read_only", "restart", "runtime", "scale", "secrets", "security_opt", "shm_size",
            "stdin_open", "stop_grace_period", "stop_signal", "storage_opt", "sysctls", "tmpfs",
            "tty", "ulimits", "use_api_socket", "user", "userns_mode", "uts", "volumes",
            "volumes_from", "working_dir"
        ]
    }

    private var knownTopLevelKeys: Set<String> {
        [
            "configs", "include", "models", "name", "networks", "secrets",
            "services", "version", "volumes"
        ]
    }

    private var knownBuildKeys: Set<String> {
        [
            "additional_contexts", "args", "cache_from", "cache_to", "context", "dockerfile",
            "dockerfile_inline", "entitlements", "extra_hosts", "isolation", "labels", "network",
            "no_cache", "platforms", "privileged", "provenance", "pull", "sbom", "secrets",
            "shm_size", "ssh", "tags", "target", "ulimits"
        ]
    }

    private var knownNetworkKeys: Set<String> {
        [
            "attachable", "driver", "driver_opts", "enable_ipv4", "enable_ipv6", "external",
            "internal", "ipam", "labels", "name"
        ]
    }

    private var knownIPAMKeys: Set<String> {
        ["config", "driver", "options"]
    }

    private var knownVolumeKeys: Set<String> {
        ["driver", "driver_opts", "external", "labels", "name"]
    }

    private var knownSecretKeys: Set<String> {
        ["driver", "driver_opts", "environment", "external", "file", "labels", "name", "template_driver"]
    }

    private var knownConfigKeys: Set<String> {
        ["content", "environment", "external", "file", "labels", "name", "template_driver"]
    }

    private var knownDependsOnKeys: Set<String> {
        ["condition", "required", "restart"]
    }

    private var knownEnvFileKeys: Set<String> {
        ["format", "path", "required"]
    }

    private var knownPortKeys: Set<String> {
        ["app_protocol", "host_ip", "mode", "name", "protocol", "published", "target"]
    }

    private var knownServiceVolumeKeys: Set<String> {
        ["bind", "consistency", "image", "read_only", "source", "target", "tmpfs", "type", "volume"]
    }

    private var knownBindVolumeKeys: Set<String> {
        ["create_host_path", "propagation", "recursive", "selinux"]
    }

    private var knownNamedVolumeKeys: Set<String> {
        ["labels", "nocopy", "subpath"]
    }

    private var knownTmpfsVolumeKeys: Set<String> {
        ["mode", "size"]
    }

    private var knownShortVolumeOptions: Set<String> {
        ["rw", "ro", "z", "Z", "consistent", "cached", "delegated"]
    }

    private var knownNetworkAttachmentKeys: Set<String> {
        [
            "aliases", "driver_opts", "gw_priority", "interface_name", "ipv4_address",
            "ipv6_address", "link_local_ips", "mac_address", "priority"
        ]
    }

    private var knownHealthcheckKeys: Set<String> {
        ["disable", "interval", "retries", "start_interval", "start_period", "test", "timeout"]
    }

    private var knownFileGrantKeys: Set<String> {
        ["gid", "mode", "source", "target", "uid"]
    }

    private var knownLifecycleHookKeys: Set<String> {
        ["command", "environment", "privileged", "user", "working_dir"]
    }

    private var knownUlimitKeys: Set<String> {
        ["hard", "soft"]
    }
}

private extension CompatibilityIssue {
    static func warning(_ location: String, _ feature: String, _ message: String) -> CompatibilityIssue {
        CompatibilityIssue(.warning, location, feature, message)
    }
}
