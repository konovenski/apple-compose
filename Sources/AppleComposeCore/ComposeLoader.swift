import Foundation
import Darwin
import Yams

public struct ComposeLoadOptions: Equatable {
    public var files: [String]
    public var projectName: String?
    public var profiles: [String]
    public var envFiles: [String]
    public var workingDirectory: URL

    public init(
        files: [String] = [],
        projectName: String? = nil,
        profiles: [String] = [],
        envFiles: [String] = [],
        workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) {
        self.files = files
        self.projectName = projectName
        self.profiles = profiles
        self.envFiles = envFiles
        self.workingDirectory = workingDirectory
    }
}

public struct ComposeLoader {
    public init() {}

    public func load(options: ComposeLoadOptions) throws -> ComposeProject {
        let processEnvironment = DotEnv.processEnvironment()
        let controlEnvironment = try composeControlEnvironment(workingDirectory: options.workingDirectory, processEnvironment: processEnvironment)
        let defaultEnvFileDisabled = composeBool(controlEnvironment["COMPOSE_DISABLE_ENV_FILE"])
        let bootstrapEnvironment = defaultEnvFileDisabled ? processEnvironment : controlEnvironment
        let files = try resolveFiles(options.files, workingDirectory: options.workingDirectory, environment: bootstrapEnvironment)
        let projectDirectory = files.first?.deletingLastPathComponent() ?? options.workingDirectory
        let envPaths = interpolationEnvPaths(
            cliEnvFiles: options.envFiles,
            projectDirectory: projectDirectory,
            workingDirectory: options.workingDirectory,
            bootstrapEnvironment: bootstrapEnvironment,
            defaultEnvFileDisabled: defaultEnvFileDisabled
        )
        var environment = try DotEnv.load(paths: envPaths, environment: bootstrapEnvironment)
        environment.merge(processEnvironment) { _, process in process }

        let projectNameOverride = options.projectName ?? environment["COMPOSE_PROJECT_NAME"] ?? bootstrapEnvironment["COMPOSE_PROJECT_NAME"]
        let resolvedProjectName: String
        if let projectNameOverride {
            resolvedProjectName = sanitizeComposeProjectName(projectNameOverride)
        } else {
            var preliminaryIncludeConflicts: [ComposeIncludeConflict] = []
            let preliminary = try loadMergedFiles(files, environment: environment, includeConflicts: &preliminaryIncludeConflicts)
            let topName = try parseOptionalTopLevelString(preliminary["name"], key: "name")
            resolvedProjectName = sanitizeComposeProjectName(topName ?? projectDirectory.lastPathComponent)
        }

        var interpolationEnvironment = environment
        interpolationEnvironment["COMPOSE_PROJECT_NAME"] = resolvedProjectName

        var includeConflicts: [ComposeIncludeConflict] = []
        var loaded = try loadMergedFiles(files, environment: interpolationEnvironment, includeConflicts: &includeConflicts)
        loaded = try resolveExtends(in: loaded, projectDirectory: projectDirectory, environment: interpolationEnvironment)

        return try ComposeParser(
            root: loaded,
            projectDirectory: projectDirectory,
            environment: interpolationEnvironment,
            projectNameOverride: resolvedProjectName,
            activeProfiles: try activeProfiles(cliProfiles: options.profiles, environment: interpolationEnvironment, bootstrapEnvironment: bootstrapEnvironment),
            includeConflicts: includeConflicts
        ).parse()
    }

    private func loadMergedFiles(
        _ files: [URL],
        environment: [String: String],
        includeConflicts: inout [ComposeIncludeConflict]
    ) throws -> YAMLValue {
        var loaded = YAMLValue.map([:])
        var seen: Set<URL> = []
        for file in files {
            let value = try loadFile(file, environment: environment, seen: &seen, processIncludes: false, includeConflicts: &includeConflicts)
            loaded = mergeComposeValues(base: loaded, override: value)
        }
        return try resolveIncludes(in: loaded, environment: environment, seen: &seen, fallbackDirectory: files.first?.deletingLastPathComponent() ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath), includeConflicts: &includeConflicts)
    }

    private func composeControlEnvironment(workingDirectory: URL, processEnvironment: [String: String]) throws -> [String: String] {
        var environment = try DotEnv.load(paths: [workingDirectory.appendingPathComponent(".env")], environment: processEnvironment)
        environment.merge(processEnvironment) { _, process in process }
        return environment
    }

    private func interpolationEnvPaths(
        cliEnvFiles: [String],
        projectDirectory: URL,
        workingDirectory: URL,
        bootstrapEnvironment: [String: String],
        defaultEnvFileDisabled: Bool
    ) -> [URL] {
        if !cliEnvFiles.isEmpty {
            return cliEnvFiles.map { resolvePath($0, relativeTo: workingDirectory) }
        }
        if let composeEnvFiles = bootstrapEnvironment["COMPOSE_ENV_FILES"], !composeEnvFiles.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return splitPathList(composeEnvFiles, separator: ",").map { resolvePath($0, relativeTo: workingDirectory) }
        }
        if defaultEnvFileDisabled {
            return []
        }
        return [projectDirectory.appendingPathComponent(".env")]
    }

    private func resolveFiles(_ files: [String], workingDirectory: URL, environment: [String: String]) throws -> [URL] {
        if !files.isEmpty {
            return files.map { resolvePath($0, relativeTo: workingDirectory) }
        }
        if let composeFile = environment["COMPOSE_FILE"], !composeFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let configuredSeparator = environment["COMPOSE_PATH_SEPARATOR"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let separator = configuredSeparator?.isEmpty == false ? configuredSeparator! : ":"
            let paths = splitPathList(composeFile, separator: separator)
            if !paths.isEmpty {
                return paths.map { resolvePath($0, relativeTo: workingDirectory) }
            }
        }

        let candidates = ["compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"]
        for candidate in candidates {
            let url = workingDirectory.appendingPathComponent(candidate)
            if FileManager.default.fileExists(atPath: url.path) {
                return [url]
            }
        }
        throw ComposeError.missingComposeFile(candidates)
    }

    private func activeProfiles(cliProfiles: [String], environment: [String: String], bootstrapEnvironment: [String: String]) throws -> Set<String> {
        var profiles = Set(cliProfiles)
        let envProfiles = environment["COMPOSE_PROFILES"] ?? bootstrapEnvironment["COMPOSE_PROFILES"]
        profiles.formUnion(splitEnvironmentProfileList(envProfiles ?? ""))
        return profiles
    }

    private func splitEnvironmentProfileList(_ value: String) -> [String] {
        value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func splitPathList(_ value: String, separator: String) -> [String] {
        value.components(separatedBy: separator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func composeBool(_ value: String?) -> Bool {
        guard let value else { return false }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "y", "on":
            return true
        default:
            return false
        }
    }

    private struct IncludeSpec {
        var paths: [URL]
        var projectDirectory: URL?
        var envFiles: [URL]?
    }

    private func loadFile(_ file: URL, environment: [String: String], seen: inout Set<URL>, projectDirectory: URL? = nil) throws -> YAMLValue {
        var includeConflicts: [ComposeIncludeConflict] = []
        return try loadFile(file, environment: environment, seen: &seen, projectDirectory: projectDirectory, processIncludes: true, includeConflicts: &includeConflicts)
    }

    private func loadFile(
        _ file: URL,
        environment: [String: String],
        seen: inout Set<URL>,
        projectDirectory: URL? = nil,
        processIncludes: Bool,
        includeConflicts: inout [ComposeIncludeConflict]
    ) throws -> YAMLValue {
        let resolved = file.standardizedFileURL
        guard !seen.contains(resolved) else {
            return .map([:])
        }
        seen.insert(resolved)
        let fileDirectory = resolved.deletingLastPathComponent()
        let baseDirectory = projectDirectory ?? fileDirectory

        let text = try String(contentsOf: resolved, encoding: .utf8)
        guard let loaded = try Yams.compose(yaml: text) else {
            return .map([:])
        }
        var value = try YAMLValue(node: loaded).interpolated(with: environment)
        value = normalizePathFields(in: value, baseDirectory: baseDirectory, includeDirectory: fileDirectory)

        if processIncludes {
            value = try resolveIncludes(in: value, environment: environment, seen: &seen, fallbackDirectory: fileDirectory, includeConflicts: &includeConflicts)
        }

        return value
    }

    private func resolveIncludes(
        in value: YAMLValue,
        environment: [String: String],
        seen: inout Set<URL>,
        fallbackDirectory: URL,
        includeConflicts: inout [ComposeIncludeConflict]
    ) throws -> YAMLValue {
        guard var valueMap = value.map, let includes = valueMap["include"] else {
            return value
        }

        valueMap.removeValue(forKey: "include")
        var resolved = YAMLValue.map(valueMap)

        for include in try parseIncludes(includes, relativeTo: fallbackDirectory) {
            let includeProjectDirectory = include.projectDirectory ?? include.paths.first?.deletingLastPathComponent() ?? fallbackDirectory
            var includeEnvironment = try DotEnv.load(paths: include.envFiles ?? [includeProjectDirectory.appendingPathComponent(".env")], environment: environment)
            includeEnvironment.merge(environment) { _, local in local }
            var includeValue = YAMLValue.map([:])
            for path in include.paths {
                let pathValue = try loadFile(path, environment: includeEnvironment, seen: &seen, projectDirectory: includeProjectDirectory, processIncludes: true, includeConflicts: &includeConflicts)
                includeValue = mergeComposeValues(base: includeValue, override: pathValue)
            }
            resolved = copyIncludedResources(into: resolved, from: includeValue, includeConflicts: &includeConflicts)
        }

        return resolved
    }

    private func copyIncludedResources(
        into value: YAMLValue,
        from included: YAMLValue,
        includeConflicts: inout [ComposeIncludeConflict]
    ) -> YAMLValue {
        guard var valueMap = value.map, let includedMap = included.map else {
            return value
        }

        for section in includedResourceSections {
            guard let incomingSection = includedMap[section] else {
                continue
            }
            guard let existingSection = valueMap[section] else {
                valueMap[section] = incomingSection
                continue
            }
            valueMap[section] = mergeComposeSectionValues(section: section, base: incomingSection, override: existingSection)
        }

        return .map(valueMap)
    }

    private var includedResourceSections: [String] {
        ["services", "networks", "volumes", "secrets", "configs"]
    }

    private func parseIncludes(_ value: YAMLValue, relativeTo directory: URL) throws -> [IncludeSpec] {
        let entries: [YAMLValue]
        if let array = value.array {
            entries = array
        } else {
            entries = [value]
        }

        return try entries.compactMap { entry in
            if let string = entry.string {
                return IncludeSpec(paths: [resolvePath(string, relativeTo: directory)], projectDirectory: nil, envFiles: nil)
            }
            guard let map = entry.map else {
                throw ComposeError.invalidCompose("include entries must be strings or mappings")
            }
            let knownIncludeKeys: Set<String> = ["path", "project_directory", "env_file"]
            for key in map.keys.sorted() where !knownIncludeKeys.contains(key) && !key.hasPrefix("x-") {
                throw ComposeError.invalidCompose("include entry contains unsupported key '\(key)'")
            }
            guard let pathValue = map["path"] else {
                throw ComposeError.invalidCompose("include.path is required for long syntax include entries")
            }
            let paths = try includePaths(pathValue, relativeTo: directory)
            let projectDirectory = try includeProjectDirectory(map["project_directory"], relativeTo: directory)
            let envFiles: [URL]?
            if let envFileValue = map["env_file"] {
                envFiles = try includeEnvFiles(envFileValue, relativeTo: projectDirectory ?? paths.first?.deletingLastPathComponent() ?? directory)
            } else {
                envFiles = nil
            }
            return IncludeSpec(paths: paths, projectDirectory: projectDirectory, envFiles: envFiles)
        }
    }

    private func includePaths(_ value: YAMLValue, relativeTo directory: URL) throws -> [URL] {
        if let string = value.string, !string.isEmpty {
            return [resolvePath(string, relativeTo: directory)]
        }
        if let array = value.array {
            return try array.enumerated().map { index, item in
                guard let path = item.string, !path.isEmpty else {
                    throw ComposeError.invalidCompose("include.path[\(index)] must be a non-empty string")
                }
                return resolvePath(path, relativeTo: directory)
            }
        }
        throw ComposeError.invalidCompose("include.path must be a string or list of strings")
    }

    private func includeProjectDirectory(_ value: YAMLValue?, relativeTo directory: URL) throws -> URL? {
        guard let value else { return nil }
        guard let string = value.string, !string.isEmpty else {
            throw ComposeError.invalidCompose("include.project_directory must be a non-empty string")
        }
        return resolvePath(string, relativeTo: directory)
    }

    private func includeEnvFiles(_ value: YAMLValue, relativeTo directory: URL) throws -> [URL] {
        if let string = value.string, !string.isEmpty {
            return [resolvePath(string, relativeTo: directory)]
        }
        if let array = value.array {
            return try array.enumerated().map { index, item in
                guard let path = item.string, !path.isEmpty else {
                    throw ComposeError.invalidCompose("include.env_file[\(index)] must be a non-empty string")
                }
                return resolvePath(path, relativeTo: directory)
            }
        }
        throw ComposeError.invalidCompose("include.env_file must be a string or list of strings")
    }

    private func resolveExtends(in root: YAMLValue, projectDirectory: URL, environment: [String: String]) throws -> YAMLValue {
        guard var rootMap = root.map, let servicesMap = rootMap["services"]?.map else {
            return root
        }

        var resolvedServices: [String: YAMLValue] = [:]
        var resolving: Set<String> = []

        func resolveService(_ name: String) throws -> YAMLValue {
            if let resolved = resolvedServices[name] {
                return resolved
            }
            guard let service = servicesMap[name] else {
                throw ComposeError.invalidCompose("Service '\(name)' referenced by extends was not found")
            }
            if resolving.contains(name) {
                throw ComposeError.invalidCompose("Circular extends relationship involving service '\(name)'")
            }
            resolving.insert(name)
            defer { resolving.remove(name) }

            let resolved = try resolveServiceValue(service, serviceName: name, localServices: servicesMap, projectDirectory: projectDirectory, environment: environment, localResolver: resolveService)
            resolvedServices[name] = resolved
            return resolved
        }

        for name in servicesMap.keys {
            _ = try resolveService(name)
        }

        rootMap["services"] = .map(resolvedServices)
        return .map(rootMap)
    }

    private func resolveServiceValue(
        _ service: YAMLValue,
        serviceName: String,
        localServices: [String: YAMLValue],
        projectDirectory: URL,
        environment: [String: String],
        localResolver: (String) throws -> YAMLValue
    ) throws -> YAMLValue {
        guard var serviceMap = service.map, let extends = serviceMap["extends"] else {
            return service
        }
        let extendsSpec = try parseExtends(extends, serviceName: serviceName)
        let baseServiceName = extendsSpec.service

        let baseService: YAMLValue
        if let file = extendsSpec.file {
            let fileURL = resolvePath(file, relativeTo: projectDirectory)
            var seen: Set<URL> = []
            let externalRoot = try loadFile(fileURL, environment: environment, seen: &seen)
            guard let externalServices = externalRoot["services"]?.map, let externalService = externalServices[baseServiceName] else {
                throw ComposeError.invalidCompose("Service '\(baseServiceName)' referenced by extends was not found in \(file)")
            }
            baseService = try resolveServiceValue(externalService, serviceName: baseServiceName, localServices: externalServices, projectDirectory: fileURL.deletingLastPathComponent(), environment: environment, localResolver: { referenced in
                guard let referencedService = externalServices[referenced] else {
                    throw ComposeError.invalidCompose("Service '\(referenced)' referenced by extends was not found in \(file)")
                }
                return referencedService
            })
        } else {
            guard localServices[baseServiceName] != nil else {
                throw ComposeError.invalidCompose("Service '\(baseServiceName)' referenced by extends was not found")
            }
            baseService = try localResolver(baseServiceName)
        }

        try validateExtendsHealthcheck(base: baseService, override: serviceMap, serviceName: serviceName, baseServiceName: baseServiceName)
        serviceMap.removeValue(forKey: "extends")
        return mergeServiceValues(base: baseService, override: .map(serviceMap))
    }

    private func validateExtendsHealthcheck(
        base: YAMLValue,
        override serviceMap: [String: YAMLValue],
        serviceName: String,
        baseServiceName: String
    ) throws {
        guard isExactTrueBool(serviceMap["healthcheck"]?["disable"]) else {
            return
        }
        guard isExactTrueBool(base["healthcheck"]?["disable"]) else {
            throw ComposeError.invalidCompose("Service '\(serviceName)' cannot set healthcheck.disable: true unless extended service '\(baseServiceName)' also disables healthcheck")
        }
    }

    private func isExactTrueBool(_ node: YAMLValue?) -> Bool {
        guard let node else { return false }
        switch node {
        case .bool(true):
            return true
        case .reset(let value), .overrideValue(let value):
            return isExactTrueBool(value)
        default:
            return false
        }
    }

    private func parseExtends(_ value: YAMLValue, serviceName: String) throws -> (service: String, file: String?) {
        if value.map == nil {
            let service = try parseExtendsString(value, serviceName: serviceName, location: "extends", allowMappingError: true)
            return (service, nil)
        }

        guard let map = value.map else {
            throw ComposeError.invalidCompose("Service '\(serviceName)' extends must be a string or mapping")
        }
        let knownExtendsKeys: Set<String> = ["service", "file"]
        for key in map.keys.sorted() where !knownExtendsKeys.contains(key) && !key.hasPrefix("x-") {
            throw ComposeError.invalidCompose("Service '\(serviceName)' extends contains unsupported key '\(key)'")
        }
        guard let serviceNode = map["service"] else {
            throw ComposeError.invalidCompose("Service '\(serviceName)' extends.service is required")
        }
        let service = try parseExtendsString(serviceNode, serviceName: serviceName, location: "extends.service")
        if let fileNode = map["file"] {
            let file = try parseExtendsString(fileNode, serviceName: serviceName, location: "extends.file")
            return (service, file)
        }
        return (service, nil)
    }

    private func parseExtendsString(_ value: YAMLValue, serviceName: String, location: String, allowMappingError: Bool = false) throws -> String {
        switch value {
        case .string(let string):
            guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ComposeError.invalidCompose("Service '\(serviceName)' \(location) must be a non-empty string")
            }
            return string
        case .reset(let value), .overrideValue(let value):
            return try parseExtendsString(value, serviceName: serviceName, location: location, allowMappingError: allowMappingError)
        default:
            let expected = allowMappingError ? "string or mapping" : "non-empty string"
            throw ComposeError.invalidCompose("Service '\(serviceName)' \(location) must be a \(expected)")
        }
    }

    private func mergeServiceValues(base: YAMLValue, override: YAMLValue) -> YAMLValue {
        let wrappedBase = YAMLValue.map(["services": .map(["_": base])])
        let wrappedOverride = YAMLValue.map(["services": .map(["_": override])])
        return mergeComposeExtendsValues(base: wrappedBase, override: wrappedOverride)["services"]?["_"] ?? override
    }

    private func normalizePathFields(in value: YAMLValue, baseDirectory: URL, includeDirectory: URL) -> YAMLValue {
        guard var root = value.map else {
            return value
        }

        if let include = root["include"] {
            root["include"] = normalizeIncludePaths(include, includeDirectory: includeDirectory)
        }

        if var services = root["services"]?.map {
            for (serviceName, serviceValue) in services {
                services[serviceName] = normalizeServicePaths(serviceValue, baseDirectory: baseDirectory)
            }
            root["services"] = .map(services)
        }

        if var secrets = root["secrets"]?.map {
            for (key, secretValue) in secrets {
                if var secret = secretValue.map, let file = secret["file"]?.string {
                    secret["file"] = .string(resolvePath(file, relativeTo: baseDirectory).path)
                    secrets[key] = .map(secret)
                }
            }
            root["secrets"] = .map(secrets)
        }

        if var configs = root["configs"]?.map {
            for (key, configValue) in configs {
                if var config = configValue.map, let file = config["file"]?.string {
                    config["file"] = .string(resolvePath(file, relativeTo: baseDirectory).path)
                    configs[key] = .map(config)
                }
            }
            root["configs"] = .map(configs)
        }

        return .map(root)
    }

    private func normalizeIncludePaths(_ value: YAMLValue, includeDirectory: URL) -> YAMLValue {
        if let string = value.string {
            return .string(resolvePath(string, relativeTo: includeDirectory).path)
        }
        if let array = value.array {
            return .array(array.map { normalizeIncludeEntry($0, includeDirectory: includeDirectory) })
        }
        return normalizeIncludeEntry(value, includeDirectory: includeDirectory)
    }

    private func normalizeIncludeEntry(_ value: YAMLValue, includeDirectory: URL) -> YAMLValue {
        if let string = value.string {
            return .string(resolvePath(string, relativeTo: includeDirectory).path)
        }
        guard var map = value.map else {
            return value
        }

        let normalizedProjectDirectory = map["project_directory"]?.string.map { resolvePath($0, relativeTo: includeDirectory) }
        if let normalizedProjectDirectory {
            map["project_directory"] = .string(normalizedProjectDirectory.path)
        }
        if let path = map["path"] {
            map["path"] = normalizeIncludePathValue(path, includeDirectory: includeDirectory)
        }
        if let envFile = map["env_file"] {
            let envBase = normalizedProjectDirectory ?? firstIncludePathDirectory(map["path"]) ?? includeDirectory
            map["env_file"] = normalizePathList(envFile, baseDirectory: envBase)
        }
        return .map(map)
    }

    private func normalizeIncludePathValue(_ value: YAMLValue, includeDirectory: URL) -> YAMLValue {
        if let string = value.string {
            return .string(resolvePath(string, relativeTo: includeDirectory).path)
        }
        if let array = value.array {
            return .array(array.map { item in
                guard let string = item.string else {
                    return item
                }
                return .string(resolvePath(string, relativeTo: includeDirectory).path)
            })
        }
        return value
    }

    private func firstIncludePathDirectory(_ value: YAMLValue?) -> URL? {
        if let string = value?.string {
            return URL(fileURLWithPath: string).deletingLastPathComponent()
        }
        if let first = value?.array?.first?.string {
            return URL(fileURLWithPath: first).deletingLastPathComponent()
        }
        return nil
    }

    private func normalizeServicePaths(_ value: YAMLValue, baseDirectory: URL) -> YAMLValue {
        guard var service = value.map else {
            return value
        }

        if let build = service["build"] {
            service["build"] = normalizeBuildPaths(build, baseDirectory: baseDirectory)
        }
        if let envFile = service["env_file"] {
            service["env_file"] = normalizePathList(envFile, baseDirectory: baseDirectory)
        }
        if let labelFile = service["label_file"] {
            service["label_file"] = normalizePathList(labelFile, baseDirectory: baseDirectory)
        }
        if let volumes = service["volumes"] {
            service["volumes"] = normalizeServiceVolumes(volumes, baseDirectory: baseDirectory)
        }
        if var extends = service["extends"]?.map, let file = extends["file"]?.string {
            extends["file"] = .string(resolvePath(file, relativeTo: baseDirectory).path)
            service["extends"] = .map(extends)
        }

        return .map(service)
    }

    private func normalizeBuildPaths(_ value: YAMLValue, baseDirectory: URL) -> YAMLValue {
        if let context = value.string {
            return .string(looksLikeRemoteBuildContext(context) ? context : resolvePath(context, relativeTo: baseDirectory).path)
        }
        guard var build = value.map else {
            return value
        }

        let context: String
        if let contextNode = build["context"] {
            guard let parsedContext = contextNode.string else {
                return .map(build)
            }
            context = parsedContext
        } else {
            context = "."
        }
        let contextURL: URL?
        if looksLikeRemoteBuildContext(context) {
            contextURL = nil
            build["context"] = .string(context)
        } else {
            let resolvedContext = resolvePath(context, relativeTo: baseDirectory)
            contextURL = resolvedContext
            build["context"] = .string(resolvedContext.path)
        }
        if let dockerfile = build["dockerfile"]?.string, !dockerfile.isEmpty {
            if let contextURL {
                build["dockerfile"] = .string(resolvePath(dockerfile, relativeTo: contextURL).path)
            }
        }
        return .map(build)
    }

    private func normalizePathList(_ value: YAMLValue, baseDirectory: URL) -> YAMLValue {
        if let string = value.string {
            guard !string.isEmpty else {
                return .string(string)
            }
            return .string(resolvePath(string, relativeTo: baseDirectory).path)
        }
        guard let array = value.array else {
            return value
        }
        return .array(array.map { item in
            if let string = item.string {
                guard !string.isEmpty else {
                    return .string(string)
                }
                return .string(resolvePath(string, relativeTo: baseDirectory).path)
            }
            if var map = item.map, let path = map["path"]?.string {
                guard !path.isEmpty else {
                    return item
                }
                map["path"] = .string(resolvePath(path, relativeTo: baseDirectory).path)
                return .map(map)
            }
            return item
        })
    }

    private func normalizeServiceVolumes(_ value: YAMLValue, baseDirectory: URL) -> YAMLValue {
        guard let array = value.array else {
            return value
        }
        return .array(array.map { item in
            if let string = item.string {
                return .string(normalizeVolumeString(string, baseDirectory: baseDirectory))
            }
            guard var map = item.map else {
                return item
            }
            let type = map["type"]?.string
            if (type == nil || type == "bind"), let source = map["source"]?.string {
                if source.isEmpty {
                    map["source"] = .string(baseDirectory.path)
                } else if looksLikeRelativeHostPath(source) {
                    map["source"] = .string(resolvePath(source, relativeTo: baseDirectory).path)
                }
            }
            return .map(map)
        })
    }

    private func normalizeVolumeString(_ value: String, baseDirectory: URL) -> String {
        let parts = value.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, looksLikeRelativeHostPath(parts[0]) else {
            return value
        }
        var normalized = parts
        normalized[0] = resolvePath(parts[0], relativeTo: baseDirectory).path
        return normalized.joined(separator: ":")
    }

    private func looksLikeRelativeHostPath(_ value: String) -> Bool {
        value == "." || value == ".." || value.hasPrefix("./") || value.hasPrefix("../") || value.hasPrefix("~/")
    }
}

struct ComposeParser {
    let root: YAMLValue
    let projectDirectory: URL
    let environment: [String: String]
    let projectNameOverride: String?
    let activeProfiles: Set<String>
    let includeConflicts: [ComposeIncludeConflict]

    func parse() throws -> ComposeProject {
        guard let rootMap = root.map else {
            throw ComposeError.invalidCompose("Top-level YAML document must be a mapping")
        }
        try rejectUnknownKeys(
            in: rootMap,
            known: ["configs", "include", "models", "name", "networks", "secrets", "services", "version", "volumes"],
            location: "compose"
        )

        let topName = try parseOptionalTopLevelString(rootMap["name"], key: "name")
        _ = try parseOptionalTopLevelString(rootMap["version"], key: "version")
        let projectName = sanitizeComposeProjectName(projectNameOverride ?? topName ?? projectDirectory.lastPathComponent)
        let modelNames = try parseTopLevelUnsupportedShapes(rootMap)
        let networks = try parseNetworks(rootMap["networks"])
        let volumes = try parseVolumes(rootMap["volumes"])
        let secrets = try parseSecrets(rootMap["secrets"])
        let configs = try parseConfigs(rootMap["configs"])
        let services = try parseServices(rootMap["services"], modelNames: modelNames)

        if services.isEmpty {
            throw ComposeError.invalidCompose("Compose project must contain at least one service")
        }

        return ComposeProject(
            name: projectName,
            workingDirectory: projectDirectory,
            environment: environment,
            activeProfiles: activeProfiles,
            raw: root,
            includeConflicts: includeConflicts,
            services: services,
            networks: networks,
            volumes: volumes,
            secrets: secrets,
            configs: configs
        )
    }

    private func parseTopLevelUnsupportedShapes(_ rootMap: [String: YAMLValue]) throws -> Set<String> {
        try parseTopLevelModels(rootMap["models"])
    }

    private func parseTopLevelModels(_ node: YAMLValue?) throws -> Set<String> {
        guard let node else { return [] }
        guard let map = node.map else {
            throw ComposeError.invalidCompose("Top-level models must be a mapping")
        }
        var modelNames: Set<String> = []
        for (name, value) in map {
            try validateComposeIdentifier(name, kind: "Model")
            guard let modelMap = value.map else {
                throw ComposeError.invalidCompose("models.\(name) must be a mapping")
            }
            modelNames.insert(name)
            try rejectUnknownKeys(
                in: modelMap,
                known: ["context_size", "model", "name", "runtime_flags"],
                location: "models.\(name)"
            )
            guard let model = try parseOptionalString(modelMap["model"], location: "models.\(name).model"),
                  !model.isEmpty else {
                throw ComposeError.invalidCompose("models.\(name).model is required")
            }
            _ = try parseOptionalString(modelMap["name"], location: "models.\(name).name")
            _ = try parseOptionalInt(modelMap["context_size"], location: "models.\(name).context_size")
            _ = try parseStringList(modelMap["runtime_flags"], location: "models.\(name).runtime_flags")
        }
        return modelNames
    }

    private func parseServices(_ node: YAMLValue?, modelNames: Set<String>) throws -> [String: ComposeService] {
        guard let map = node?.map else {
            throw ComposeError.invalidCompose("Top-level 'services' must be a mapping")
        }

        var services: [String: ComposeService] = [:]
        for (name, value) in map {
            try validateComposeIdentifier(name, kind: "Service")
            guard let serviceMap = value.map else {
                throw ComposeError.invalidCompose("Service '\(name)' must be a mapping")
            }
            try rejectUnknownKeys(in: serviceMap, known: knownServiceKeys, location: "Service '\(name)'")
            let profiles = try parseProfileList(serviceMap["profiles"], location: "Service '\(name)' profiles")
            let deploy = try parseOptionalMap(serviceMap["deploy"], location: "Service '\(name)' deploy")
            _ = try parseLabelMap(deploy?["labels"], location: "Service '\(name)' deploy.labels")
            let resources = try parseOptionalMap(deploy?["resources"], location: "Service '\(name)' deploy.resources")
            let limits = try parseOptionalMap(resources?["limits"], location: "Service '\(name)' deploy.resources.limits")
            let reservations = try parseOptionalMap(resources?["reservations"], location: "Service '\(name)' deploy.resources.reservations")
            try parseDeployOptions(deploy, serviceName: name)
            let serviceScale = try parseOptionalInt(serviceMap["scale"], location: "Service '\(name)' scale")
            let deployReplicas = try parseOptionalInt(deploy?["replicas"], location: "Service '\(name)' deploy.replicas")
            let replicas = serviceScale ?? deployReplicas ?? 1
            let containerName = try parseOptionalString(serviceMap["container_name"], location: "Service '\(name)' container_name")
            if let serviceScale, serviceScale < 0 {
                throw ComposeError.invalidCompose("Service '\(name)' scale must be zero or a positive integer")
            }
            if let deployReplicas, deployReplicas < 0 {
                throw ComposeError.invalidCompose("Service '\(name)' deploy.replicas must be zero or a positive integer")
            }
            if let serviceScale, let deployReplicas, serviceScale != deployReplicas {
                throw ComposeError.invalidCompose("Service '\(name)' scale must be consistent with deploy.replicas when both are set")
            }
            if let containerName, !isValidContainerName(containerName) {
                throw ComposeError.invalidCompose("Service '\(name)' container_name must match [a-zA-Z0-9][a-zA-Z0-9_.-]+")
            }
            if containerName != nil && replicas > 1 {
                throw ComposeError.invalidCompose("Service '\(name)' cannot set container_name when replicas are greater than 1")
            }
            let serviceDriverOptions = try parseDriverOptionsMap(serviceMap["driver_opts"], location: "Service '\(name)' driver_opts")
            let rawServiceCPUs = try parseOptionalCPUQuantity(serviceMap["cpus"], location: "Service '\(name)' cpus")
            let rawServiceCPUCount = try parseOptionalCPUCount(serviceMap["cpu_count"], location: "Service '\(name)' cpu_count")
            let rawDeployCPUs = try parseOptionalCPUQuantity(limits?["cpus"], location: "Service '\(name)' deploy.resources.limits.cpus")
            let rawServiceMemory = try parseOptionalByteValue(serviceMap["mem_limit"], location: "Service '\(name)' mem_limit")
            let rawDeployMemory = try parseOptionalByteValue(limits?["memory"], location: "Service '\(name)' deploy.resources.limits.memory")
            let rawServiceMemoryReservation = try parseOptionalByteValue(serviceMap["mem_reservation"], location: "Service '\(name)' mem_reservation")
            let deployMemoryReservation = try parseOptionalByteValue(reservations?["memory"], location: "Service '\(name)' deploy.resources.reservations.memory")
            let serviceCPUs = nonZeroCPUQuantity(rawServiceCPUs)
            let serviceCPUCount = nonZeroCPUQuantity(rawServiceCPUCount)
            let deployCPUs = nonZeroCPUQuantity(rawDeployCPUs)
            let serviceMemory = nonZeroByteValue(rawServiceMemory)
            let deployMemory = nonZeroByteValue(rawDeployMemory)
            let serviceMemoryReservation = nonZeroByteValue(rawServiceMemoryReservation)
            _ = try parseExpose(serviceMap["expose"], serviceName: name)
            _ = try parseOptionalBoolOrString(serviceMap["attach"], location: "Service '\(name)' attach")
            _ = try parseOptionalBoolOrString(serviceMap["privileged"], location: "Service '\(name)' privileged")
            _ = try parseOptionalBoolOrString(serviceMap["oom_kill_disable"], location: "Service '\(name)' oom_kill_disable")
            _ = try parseOptionalBoolLiteral(serviceMap["use_api_socket"], location: "Service '\(name)' use_api_socket")
            _ = try parseRestartPolicy(serviceMap["restart"], serviceName: name)
            _ = try parseOptionalByteValue(serviceMap["memswap_limit"], location: "Service '\(name)' memswap_limit", allowUnlimitedSwap: true)
            if let oomScoreAdj = try parseOptionalInt(serviceMap["oom_score_adj"], location: "Service '\(name)' oom_score_adj"),
               !(-1000...1000).contains(oomScoreAdj) {
                throw ComposeError.invalidCompose("Service '\(name)' oom_score_adj must be between -1000 and 1000")
            }
            let domainName = try parseDomainName(serviceMap["domainname"], serviceName: name)
            let macAddress = try parseMACAddress(serviceMap["mac_address"], location: "Service '\(name)' mac_address")
            let networkMode = try parseNetworkMode(serviceMap["network_mode"], serviceName: name)
            if networkMode != nil && serviceMap["networks"] != nil {
                throw ComposeError.invalidCompose("Service '\(name)' cannot set both network_mode and networks")
            }
            let pullPolicy = try parsePullPolicy(serviceMap["pull_policy"], serviceName: name)
            let pullRefreshAfter = try parsePullRefreshAfter(serviceMap["pull_refresh_after"], serviceName: name)
            let rawServicePidsLimit = try parseOptionalPidsLimit(serviceMap["pids_limit"], location: "Service '\(name)' pids_limit")
            let deployPidsLimit = try parseOptionalInt(limits?["pids"], location: "Service '\(name)' deploy.resources.limits.pids")
            try validateDeployResourceConsistency(
                serviceName: name,
                serviceCPUs: serviceCPUs,
                deployCPUs: rawDeployCPUs,
                serviceMemory: serviceMemory,
                deployMemory: rawDeployMemory,
                serviceMemoryReservation: serviceMemoryReservation,
                deployMemoryReservation: deployMemoryReservation,
                servicePidsLimit: nonZeroPidsLimit(rawServicePidsLimit),
                deployPidsLimit: deployPidsLimit
            )
            try parseUnsupportedServiceShapes(serviceMap, serviceName: name, modelNames: modelNames)
            try parseHealthcheck(serviceMap["healthcheck"], serviceName: name)

            services[name] = ComposeService(
                name: name,
                raw: value,
                image: try parseOptionalString(serviceMap["image"], location: "Service '\(name)' image"),
                build: try parseBuild(serviceMap["build"], serviceName: name),
                pullPolicy: pullPolicy,
                pullRefreshAfter: pullRefreshAfter,
                containerName: containerName,
                profiles: profiles,
                dependsOn: try parseDependsOn(serviceMap["depends_on"], serviceName: name),
                links: try parseLinks(serviceMap["links"], serviceName: name),
                environment: try parseEnvironmentMap(serviceMap["environment"], location: "Service '\(name)' environment"),
                envFiles: try parseEnvFiles(serviceMap["env_file"], serviceName: name),
                labels: try serviceLabels(serviceMap, serviceName: name),
                annotations: try parseLabelMap(serviceMap["annotations"], location: "Service '\(name)' annotations"),
                attach: try parseOptionalBoolOrString(serviceMap["attach"], location: "Service '\(name)' attach") ?? true,
                ports: try parsePorts(serviceMap["ports"], serviceName: name),
                volumes: try parseServiceVolumes(serviceMap["volumes"], serviceName: name),
                volumesFrom: try parseVolumesFrom(serviceMap["volumes_from"], serviceName: name),
                tmpfs: try parseTmpfs(serviceMap["tmpfs"], serviceName: name),
                networks: try parseServiceNetworks(serviceMap["networks"], serviceDriverOptions: serviceDriverOptions, serviceName: name),
                networkMode: networkMode,
                command: try parseCommand(serviceMap["command"], location: "Service '\(name)' command"),
                entrypoint: try parseCommand(serviceMap["entrypoint"], location: "Service '\(name)' entrypoint"),
                workingDir: try parseOptionalExactNonEmptyString(serviceMap["working_dir"], location: "Service '\(name)' working_dir"),
                user: try parseOptionalExactNonEmptyStringOrInt(serviceMap["user"], location: "Service '\(name)' user"),
                platform: try parsePlatform(serviceMap["platform"], location: "Service '\(name)' platform"),
                runtime: try parseOptionalExactNonEmptyString(serviceMap["runtime"], location: "Service '\(name)' runtime"),
                macAddress: macAddress,
                cpus: serviceCPUs ?? serviceCPUCount ?? deployCPUs,
                memory: serviceMemory ?? deployMemory,
                shmSize: try parseOptionalByteValue(serviceMap["shm_size"], location: "Service '\(name)' shm_size"),
                initProcess: try parseOptionalBoolOrString(serviceMap["init"], location: "Service '\(name)' init") ?? false,
                readOnly: try parseOptionalBoolOrString(serviceMap["read_only"], location: "Service '\(name)' read_only") ?? false,
                tty: try parseOptionalBoolOrString(serviceMap["tty"], location: "Service '\(name)' tty") ?? false,
                stdinOpen: try parseOptionalBoolOrString(serviceMap["stdin_open"], location: "Service '\(name)' stdin_open") ?? false,
                capAdd: try parseStringList(serviceMap["cap_add"], location: "Service '\(name)' cap_add", allowEmpty: true).filter { !$0.isEmpty },
                capDrop: try parseStringList(serviceMap["cap_drop"], location: "Service '\(name)' cap_drop", allowEmpty: true).filter { !$0.isEmpty },
                dns: try parseDNSList(serviceMap["dns"], serviceName: name),
                dnsSearch: try parseStringList(serviceMap["dns_search"], location: "Service '\(name)' dns_search", allowScalar: true, allowEmpty: true),
                domainName: domainName,
                dnsOptions: try parseStringList(serviceMap["dns_opt"], location: "Service '\(name)' dns_opt", allowEmpty: true),
                extraHosts: try parseExtraHosts(serviceMap["extra_hosts"], location: "Service '\(name)' extra_hosts"),
                ulimits: try parseUlimits(serviceMap["ulimits"], location: "Service '\(name)' ulimits"),
                secrets: try parseFileGrants(serviceMap["secrets"], defaultTargetPrefix: "/run/secrets", serviceName: name, location: "secrets"),
                configs: try parseFileGrants(serviceMap["configs"], defaultTargetPrefix: "/", serviceName: name, location: "configs"),
                postStart: try parseLifecycleHooks(serviceMap["post_start"], serviceName: name, key: "post_start"),
                preStop: try parseLifecycleHooks(serviceMap["pre_stop"], serviceName: name, key: "pre_stop"),
                stopSignal: try parseStopSignal(serviceMap["stop_signal"], serviceName: name),
                stopGracePeriod: try parseOptionalDuration(serviceMap["stop_grace_period"], location: "Service '\(name)' stop_grace_period"),
                replicas: max(0, replicas)
            )
        }
        return services
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
            "pull_refresh_after", "read_only", "restart", "runtime", "scale", "secrets",
            "security_opt", "shm_size", "stdin_open", "stop_grace_period", "stop_signal",
            "storage_opt", "sysctls", "tmpfs", "tty", "ulimits", "use_api_socket", "user",
            "userns_mode", "uts", "volumes", "volumes_from", "working_dir",
        ]
    }

    private func parseBuild(_ node: YAMLValue?, serviceName: String) throws -> BuildSpec? {
        guard let node else { return nil }
        if node.map == nil, let string = try parseOptionalString(node, location: "Service '\(serviceName)' build", allowEmpty: true) {
            return BuildSpec(
                context: string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "." : string,
                dockerfile: nil,
                dockerfileInline: nil,
                args: [:],
                labels: [:],
                target: nil,
                platforms: [],
                noCache: false,
                pull: false,
                shmSize: nil,
                ulimits: [],
                secrets: [],
                tags: []
            )
        }
        guard let map = node.map else {
            throw ComposeError.invalidCompose("'build' must be a string or mapping")
        }
        try rejectUnknownKeys(
            in: map,
            known: [
                "additional_contexts", "args", "cache_from", "cache_to", "context", "dockerfile",
                "dockerfile_inline", "entitlements", "extra_hosts", "isolation", "labels", "network",
                "no_cache", "platforms", "privileged", "provenance", "pull", "sbom", "secrets",
                "shm_size", "ssh", "tags", "target", "ulimits",
            ],
            location: "Service '\(serviceName)' build"
        )
        _ = try parseOptionalUnsettableString(map["network"], location: "Service '\(serviceName)' build.network")
        _ = try parseOptionalBoolOrString(map["privileged"], location: "Service '\(serviceName)' build.privileged")
        _ = try parseOptionalBoolOrStringScalar(map["provenance"], location: "Service '\(serviceName)' build.provenance")
        _ = try parseOptionalBoolOrStringScalar(map["sbom"], location: "Service '\(serviceName)' build.sbom")
        try parseUnsupportedBuildShapes(map, serviceName: serviceName)
        let dockerfile = try parseOptionalUnsettableString(map["dockerfile"], location: "Service '\(serviceName)' build.dockerfile")
        let dockerfileInline = try parseOptionalUnsettableString(map["dockerfile_inline"], location: "Service '\(serviceName)' build.dockerfile_inline")
        if dockerfile != nil && dockerfileInline != nil {
            throw ComposeError.invalidCompose("Service '\(serviceName)' build must not set both dockerfile and dockerfile_inline")
        }
        return BuildSpec(
            context: try parseOptionalUnsettableString(map["context"], location: "Service '\(serviceName)' build.context") ?? ".",
            dockerfile: dockerfile,
            dockerfileInline: dockerfileInline,
            args: try parseEnvironmentMap(map["args"], location: "Service '\(serviceName)' build.args"),
            labels: try parseLabelMap(map["labels"], location: "Service '\(serviceName)' build.labels"),
            target: try parseOptionalUnsettableString(map["target"], location: "Service '\(serviceName)' build.target"),
            platforms: try parsePlatformList(map["platforms"], location: "Service '\(serviceName)' build.platforms"),
            noCache: try parseOptionalBoolOrString(map["no_cache"], location: "Service '\(serviceName)' build.no_cache") ?? false,
            pull: try parseOptionalBoolOrString(map["pull"], location: "Service '\(serviceName)' build.pull") ?? false,
            shmSize: nonZeroByteValue(try parseOptionalByteValue(map["shm_size"], location: "Service '\(serviceName)' build.shm_size")),
            ulimits: try parseUlimits(map["ulimits"], location: "Service '\(serviceName)' build.ulimits"),
            secrets: try parseFileGrants(map["secrets"], defaultTargetPrefix: "", serviceName: serviceName, location: "build.secrets"),
            tags: try parseStringList(map["tags"], location: "Service '\(serviceName)' build.tags", allowEmpty: true).filter { !$0.isEmpty }
        )
    }

    private func parseUnsupportedBuildShapes(_ map: [String: YAMLValue], serviceName: String) throws {
        let location = "Service '\(serviceName)' build"
        _ = try parseNameValueMapOrStringList(map["additional_contexts"], location: "\(location).additional_contexts")
        _ = try parseStringList(map["cache_from"], location: "\(location).cache_from", allowEmpty: true)
        _ = try parseStringList(map["cache_to"], location: "\(location).cache_to", allowEmpty: true)
        _ = try parseStringList(map["entitlements"], location: "\(location).entitlements", allowEmpty: true)
        _ = try parseExtraHosts(map["extra_hosts"], location: "\(location).extra_hosts")
        _ = try parseOptionalUnsettableString(map["isolation"], location: "\(location).isolation")
        try parseBuildSSH(map["ssh"], location: "\(location).ssh")
    }

    private func parseBuildSSH(_ node: YAMLValue?, location: String) throws {
        guard let node else { return }
        if let map = node.map {
            for (id, value) in map.sorted(by: { $0.key < $1.key }) {
                let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedID.isEmpty else {
                    throw ComposeError.invalidCompose("\(location) keys must be non-empty SSH IDs")
                }
                _ = try parseOptionalBuildSSHMapValue(value, location: "\(location).\(id)")
            }
            return
        }
        let entries = try parseStringList(node, location: location, allowScalar: true)
        for (index, entry) in entries.enumerated() {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            let itemLocation = node.array == nil ? location : "\(location)[\(index)]"
            guard !trimmed.isEmpty else {
                throw ComposeError.invalidCompose("\(itemLocation) must be a non-empty string")
            }
            if trimmed == "default" {
                continue
            }
            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else {
                throw ComposeError.invalidCompose("\(itemLocation) must be 'default' or use ID=path syntax")
            }
        }
    }

    private func parseOptionalBuildSSHMapValue(_ node: YAMLValue, location: String) throws -> String? {
        switch node {
        case .null:
            return nil
        case .string(let value):
            return value
        case .int(let value, _):
            return String(value)
        case .double(let value) where value.isFinite:
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        case .reset(let value), .overrideValue(let value):
            return try parseOptionalBuildSSHMapValue(value, location: location)
        default:
            throw ComposeError.invalidCompose("\(location) must be a scalar value or null")
        }
    }

    private func parseNetworks(_ node: YAMLValue?) throws -> [String: ComposeNetwork] {
        guard let node else { return [:] }
        guard let map = node.map else {
            throw ComposeError.invalidCompose("Top-level 'networks' must be a mapping")
        }
        var result: [String: ComposeNetwork] = [:]
        for (key, value) in map {
            try validateComposeIdentifier(key, kind: "Network")
            let networkMap = try resourceDefinitionMap(value, location: "networks.\(key)")
            try rejectUnknownKeys(
                in: networkMap,
                known: ["attachable", "driver", "driver_opts", "enable_ipv4", "enable_ipv6", "external", "internal", "ipam", "labels", "name"],
                location: "networks.\(key)"
            )
            let external = try resourceIsExternal(networkMap, location: "networks.\(key)")
            try validateExternalResourceAttributes(networkMap, external: external, location: "networks.\(key)")
            _ = try parseOptionalBoolOrString(networkMap["attachable"], location: "networks.\(key).attachable")
            let subnets = try parseIPAMSubnets(networkMap["ipam"], location: "networks.\(key).ipam")
            result[key] = ComposeNetwork(
                key: key,
                name: try resourceName(networkMap, location: "networks.\(key)"),
                external: external,
                driver: try parseOptionalUnsettableString(networkMap["driver"], location: "networks.\(key).driver"),
                driverOptions: try parseDriverOptionsMap(networkMap["driver_opts"], location: "networks.\(key).driver_opts"),
                labels: try parseLabelMap(networkMap["labels"], location: "networks.\(key).labels"),
                internalNetwork: try parseOptionalBoolOrString(networkMap["internal"], location: "networks.\(key).internal") ?? false,
                ipamSubnets: subnets,
                enableIPv4: try parseOptionalBoolOrString(networkMap["enable_ipv4"], location: "networks.\(key).enable_ipv4"),
                enableIPv6: try parseOptionalBoolOrString(networkMap["enable_ipv6"], location: "networks.\(key).enable_ipv6")
            )
        }
        return result
    }

    private func parseVolumes(_ node: YAMLValue?) throws -> [String: ComposeVolume] {
        guard let node else { return [:] }
        guard let map = node.map else {
            throw ComposeError.invalidCompose("Top-level 'volumes' must be a mapping")
        }
        var result: [String: ComposeVolume] = [:]
        for (key, value) in map {
            try validateComposeIdentifier(key, kind: "Volume")
            let volumeMap = try resourceDefinitionMap(value, location: "volumes.\(key)")
            try rejectUnknownKeys(
                in: volumeMap,
                known: ["driver", "driver_opts", "external", "labels", "name"],
                location: "volumes.\(key)"
            )
            let external = try resourceIsExternal(volumeMap, location: "volumes.\(key)")
            try validateExternalResourceAttributes(volumeMap, external: external, location: "volumes.\(key)")
            result[key] = ComposeVolume(
                key: key,
                name: try resourceName(volumeMap, location: "volumes.\(key)"),
                external: external,
                driver: try parseOptionalUnsettableString(volumeMap["driver"], location: "volumes.\(key).driver"),
                driverOptions: try parseDriverOptionsMap(volumeMap["driver_opts"], location: "volumes.\(key).driver_opts"),
                labels: try parseLabelMap(volumeMap["labels"], location: "volumes.\(key).labels")
            )
        }
        return result
    }

    private func parseSecrets(_ node: YAMLValue?) throws -> [String: ComposeSecret] {
        guard let node else { return [:] }
        guard let map = node.map else {
            throw ComposeError.invalidCompose("Top-level 'secrets' must be a mapping")
        }
        return Dictionary(uniqueKeysWithValues: try map.map { key, value in
            try validateComposeIdentifier(key, kind: "Secret")
            let item = try resourceDefinitionMap(value, location: "secrets.\(key)")
            try rejectUnknownKeys(
                in: item,
                known: ["driver", "driver_opts", "environment", "external", "file", "labels", "name", "template_driver"],
                location: "secrets.\(key)"
            )
            let external = try resourceIsExternal(item, location: "secrets.\(key)")
            try validateExternalResourceAttributes(item, external: external, location: "secrets.\(key)")
            let file = try parseOptionalString(item["file"], location: "secrets.\(key).file")
            let environment = try parseOptionalString(item["environment"], location: "secrets.\(key).environment")
            _ = try parseOptionalUnsettableString(item["driver"], location: "secrets.\(key).driver")
            _ = try parseOptionalUnsettableString(item["template_driver"], location: "secrets.\(key).template_driver")
            _ = try parseDriverOptionsMap(item["driver_opts"], location: "secrets.\(key).driver_opts")
            _ = try parseLabelMap(item["labels"], location: "secrets.\(key).labels")
            try validateResourceSources(
                item,
                sourceValues: ["file": file, "environment": environment],
                external: external,
                location: "secrets.\(key)",
                kind: "secret",
                sourceDescription: "file, environment, or external"
            )
            return (key, ComposeSecret(
                key: key,
                name: try resourceName(item, location: "secrets.\(key)"),
                file: file,
                environment: environment,
                external: external
            ))
        })
    }

    private func parseConfigs(_ node: YAMLValue?) throws -> [String: ComposeConfig] {
        guard let node else { return [:] }
        guard let map = node.map else {
            throw ComposeError.invalidCompose("Top-level 'configs' must be a mapping")
        }
        return Dictionary(uniqueKeysWithValues: try map.map { key, value in
            try validateComposeIdentifier(key, kind: "Config")
            let item = try resourceDefinitionMap(value, location: "configs.\(key)")
            try rejectUnknownKeys(
                in: item,
                known: ["content", "environment", "external", "file", "labels", "name", "template_driver"],
                location: "configs.\(key)"
            )
            let external = try resourceIsExternal(item, location: "configs.\(key)")
            try validateExternalResourceAttributes(item, external: external, location: "configs.\(key)")
            let file = try parseOptionalString(item["file"], location: "configs.\(key).file")
            let content = try parseOptionalString(item["content"], location: "configs.\(key).content", allowEmpty: true)
            let environment = try parseOptionalString(item["environment"], location: "configs.\(key).environment")
            _ = try parseOptionalUnsettableString(item["template_driver"], location: "configs.\(key).template_driver")
            _ = try parseLabelMap(item["labels"], location: "configs.\(key).labels")
            try validateResourceSources(
                item,
                sourceValues: ["file": file, "content": content, "environment": environment],
                external: external,
                location: "configs.\(key)",
                kind: "config",
                sourceDescription: "file, content, environment, or external"
            )
            return (key, ComposeConfig(
                key: key,
                name: try resourceName(item, location: "configs.\(key)"),
                file: file,
                content: content,
                environment: environment,
                external: external
            ))
        })
    }

    private func parseDependsOn(_ node: YAMLValue?, serviceName: String) throws -> [String: ServiceDependency] {
        guard let node else { return [:] }
        if let array = node.array {
            var dependencies: [String: ServiceDependency] = [:]
            for (index, item) in array.enumerated() {
                guard case .string(let dependency) = item,
                      !dependency.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ComposeError.invalidCompose("Service '\(serviceName)' depends_on[\(index)] must be a service name")
                }
                try validateComposeIdentifier(dependency, kind: "Dependency")
                dependencies[dependency] = ServiceDependency(condition: "service_started", restart: false, required: true)
            }
            return dependencies
        }
        guard let map = node.map else {
            throw ComposeError.invalidCompose("Service '\(serviceName)' depends_on must be a list of service names or a mapping")
        }
        return Dictionary(uniqueKeysWithValues: try map.map { key, value in
            try validateComposeIdentifier(key, kind: "Dependency")
            let dependency: [String: YAMLValue]
            if let valueMap = value.map {
                dependency = valueMap
            } else if case .null = value {
                dependency = [:]
            } else {
                throw ComposeError.invalidCompose("Service '\(serviceName)' depends_on.\(key) must be a mapping")
            }
            try rejectUnknownKeys(
                in: dependency,
                known: ["condition", "required", "restart"],
                location: "Service '\(serviceName)' depends_on.\(key)"
            )
            guard let condition = try parseOptionalEnum(
                dependency["condition"],
                allowed: ["service_completed_successfully", "service_healthy", "service_started"],
                location: "Service '\(serviceName)' depends_on.\(key).condition"
            ) else {
                throw ComposeError.invalidCompose("Service '\(serviceName)' depends_on.\(key).condition is required")
            }
            return (key, ServiceDependency(
                condition: condition,
                restart: try parseOptionalBoolOrString(dependency["restart"], location: "Service '\(serviceName)' depends_on.\(key).restart") ?? false,
                required: try parseOptionalBoolOrString(dependency["required"], location: "Service '\(serviceName)' depends_on.\(key).required") ?? true
            ))
        })
    }

    private func parseLinks(_ node: YAMLValue?, serviceName: String) throws -> [ServiceLink] {
        try parseStringList(node, location: "Service '\(serviceName)' links").map { value in
            let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard let source = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty else {
                throw ComposeError.invalidCompose("Service '\(serviceName)' links source must not be empty")
            }
            let alias = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : nil
            return ServiceLink(source: source, alias: alias?.isEmpty == true ? nil : alias)
        }
    }

    private func parseEnvFiles(_ node: YAMLValue?, serviceName: String) throws -> [EnvFileSpec] {
        guard let node else { return [] }
        let entries = node.array ?? [node]
        return try entries.enumerated().map { index, item in
            if case .string(let path) = item {
                guard !path.isEmpty else {
                    throw ComposeError.invalidCompose("Service '\(serviceName)' env_file[\(index)] path must not be empty")
                }
                return EnvFileSpec(path: path, required: true, format: nil)
            }
            guard let map = item.map else {
                throw ComposeError.invalidCompose("Service '\(serviceName)' env_file[\(index)] must be a file path or mapping")
            }
            try rejectUnknownKeys(
                in: map,
                known: ["format", "path", "required"],
                location: "Service '\(serviceName)' env_file[\(index)]"
            )
            guard let path = try parseOptionalString(map["path"], location: "Service '\(serviceName)' env_file[\(index)].path"), !path.isEmpty else {
                throw ComposeError.invalidCompose("Service '\(serviceName)' env_file[\(index)].path is required")
            }
            return EnvFileSpec(
                path: path,
                required: try parseOptionalBoolOrString(map["required"], location: "Service '\(serviceName)' env_file[\(index)].required") ?? true,
                format: try parseEnvFileFormat(map["format"], location: "Service '\(serviceName)' env_file[\(index)].format")
            )
        }
    }

    private func parseEnvFileFormat(_ node: YAMLValue?, location: String) throws -> String? {
        guard let format = try parseOptionalString(node, location: location, allowEmpty: true) else {
            return nil
        }
        if format.isEmpty {
            return nil
        }
        let normalized = format.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["compose", "raw"].contains(normalized) else {
            throw ComposeError.invalidCompose("\(location) must be raw or compose, not '\(format)'")
        }
        return format
    }

    private func parsePorts(_ node: YAMLValue?, serviceName: String) throws -> [PortSpec] {
        guard let node else { return [] }
        return try (node.array ?? [node]).enumerated().map { index, item in
            if item.map == nil {
                let string: String
                switch item {
                case .string, .int, .reset, .overrideValue:
                    guard let parsedString = try parseOptionalStringOrInt(item, location: "Service '\(serviceName)' ports[\(index)]") else {
                        throw ComposeError.invalidCompose("Service '\(serviceName)' ports[\(index)] must be a port string or mapping")
                    }
                    string = parsedString
                default:
                    throw ComposeError.invalidCompose("Service '\(serviceName)' ports[\(index)] must be a port string or mapping")
                }
                let parsed = parseComposePortString(string)
                guard let target = parsed.target, !target.isEmpty else {
                    throw ComposeError.invalidCompose("Service '\(serviceName)' ports[\(index)] must define a container target port")
                }
                try validatePortValue(target, location: "Service '\(serviceName)' ports[\(index)] target", allowRange: true, allowZero: false)
                if let published = parsed.published {
                    try validatePortValue(published, location: "Service '\(serviceName)' ports[\(index)] published", allowRange: true, allowZero: true)
                }
                try validatePortProtocol(parsed.protocolName, location: "Service '\(serviceName)' ports[\(index)]")
                try validatePortHostIP(parsed.hostIP, location: "Service '\(serviceName)' ports[\(index)].host_ip")
                return PortSpec(raw: string, target: parsed.target, published: parsed.published, hostIP: parsed.hostIP, protocolName: parsed.protocolName, appProtocol: nil, name: nil)
            }
            guard let map = item.map else {
                throw ComposeError.invalidCompose("Service '\(serviceName)' ports[\(index)] must be a port string or mapping")
            }
            try rejectUnknownKeys(
                in: map,
                known: ["app_protocol", "host_ip", "mode", "name", "protocol", "published", "target"],
                location: "Service '\(serviceName)' ports[\(index)]"
            )
            guard let target = try parseOptionalStringOrInt(map["target"], location: "Service '\(serviceName)' ports[\(index)].target"), !target.isEmpty else {
                throw ComposeError.invalidCompose("Service '\(serviceName)' ports[\(index)].target is required")
            }
            try validatePortValue(target, location: "Service '\(serviceName)' ports[\(index)].target", allowRange: true, allowZero: false)
            let published = try parseOptionalPortPublished(map["published"], location: "Service '\(serviceName)' ports[\(index)].published")
            if let published {
                try validatePortValue(published, location: "Service '\(serviceName)' ports[\(index)].published", allowRange: true, allowZero: true)
            }
            _ = try parseOptionalString(map["mode"], location: "Service '\(serviceName)' ports[\(index)].mode", allowEmpty: true)
            let protocolName = try parseOptionalPortProtocol(map["protocol"], location: "Service '\(serviceName)' ports[\(index)].protocol")
            let hostIP = try parseOptionalPortHostIP(map["host_ip"], location: "Service '\(serviceName)' ports[\(index)].host_ip")
            return PortSpec(
                raw: nil,
                target: target,
                published: published,
                hostIP: hostIP,
                protocolName: protocolName,
                appProtocol: try parseOptionalExactNonEmptyString(map["app_protocol"], location: "Service '\(serviceName)' ports[\(index)].app_protocol"),
                name: try parseOptionalExactNonEmptyString(map["name"], location: "Service '\(serviceName)' ports[\(index)].name")
            )
        }
    }

    private func validatePortProtocol(_ protocolName: String?, location: String) throws {
        guard let protocolName else { return }
        let normalized = protocolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return }
        guard ["tcp", "udp", "sctp"].contains(normalized) else {
            throw ComposeError.invalidCompose("\(location) protocol must be tcp, udp, or sctp")
        }
    }

    private func parseOptionalPortProtocol(_ node: YAMLValue?, location: String) throws -> String? {
        guard let protocolName = try parseOptionalString(node, location: location, allowEmpty: true) else {
            return nil
        }
        return protocolName.isEmpty ? nil : protocolName
    }

    private func parseOptionalPortPublished(_ node: YAMLValue?, location: String) throws -> String? {
        if case .string(let value)? = node, value.isEmpty {
            return nil
        }
        return try parseOptionalStringOrInt(node, location: location)
    }

    private func parseOptionalPortHostIP(_ node: YAMLValue?, location: String) throws -> String? {
        guard let hostIP = try parseOptionalString(node, location: location) else {
            return nil
        }
        try validatePortHostIP(hostIP, location: location)
        return hostIP
    }

    private func validatePortHostIP(_ hostIP: String?, location: String) throws {
        guard let hostIP else { return }
        guard let address = portHostIPAddress(hostIP), isValidIPAddress(address, version: .any) else {
            throw ComposeError.invalidCompose("\(location) must be a valid IPv4 or IPv6 address")
        }
    }

    private func portHostIPAddress(_ hostIP: String) -> String? {
        if hostIP.hasPrefix("[") || hostIP.hasSuffix("]") {
            guard hostIP.hasPrefix("["), hostIP.hasSuffix("]"), hostIP.count > 2 else {
                return nil
            }
            let start = hostIP.index(after: hostIP.startIndex)
            let end = hostIP.index(before: hostIP.endIndex)
            let inner = String(hostIP[start..<end])
            guard inner.contains(":") else {
                return nil
            }
            return inner
        }
        return hostIP
    }

    private func parseExpose(_ node: YAMLValue?, serviceName: String) throws -> [String] {
        guard let node else { return [] }
        guard let array = node.array else {
            throw ComposeError.invalidCompose("Service '\(serviceName)' expose must be a list of strings or numbers")
        }
        let entries = try array.enumerated().map { index, item in
            try parseRequiredStringOrNumber(item, location: "Service '\(serviceName)' expose[\(index)]")
        }
        for (index, entry) in entries.enumerated() {
            try validateExposeEntry(entry, location: "Service '\(serviceName)' expose[\(index)]")
        }
        return entries
    }

    private func validateExposeEntry(_ entry: String, location: String) throws {
        let pieces = entry.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard !pieces.isEmpty, !pieces[0].isEmpty, !pieces[0].contains(":") else {
            throw ComposeError.invalidCompose("\(location) must use container ports only: <port>[/protocol] or <start-end>[/protocol]")
        }

        let range = pieces[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard range.count == 1 || range.count == 2 else {
            throw ComposeError.invalidCompose("\(location) must use <port>[/protocol] or <start-end>[/protocol]")
        }
        guard let start = parseExposePort(range[0]) else {
            throw ComposeError.invalidCompose("\(location) must use numeric container ports")
        }
        if range.count == 2 {
            guard let end = parseExposePort(range[1]) else {
                throw ComposeError.invalidCompose("\(location) must use numeric container ports")
            }
            guard start <= end else {
                throw ComposeError.invalidCompose("\(location) port range start must be less than or equal to the end")
            }
        }
    }

    private func parseExposePort(_ value: String) -> Int? {
        guard !value.isEmpty, value.allSatisfy(\.isNumber), let port = Int(value), (1...65535).contains(port) else {
            return nil
        }
        return port
    }

    private func validatePortValue(_ value: String, location: String, allowRange: Bool, allowZero: Bool) throws {
        let range = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard range.count == 1 || (allowRange && range.count == 2) else {
            throw ComposeError.invalidCompose("\(location) must be a numeric port\(allowRange ? " or range" : "")")
        }
        guard let start = parsePortNumber(range[0], allowZero: allowZero) else {
            throw ComposeError.invalidCompose("\(location) must be a numeric port\(allowRange ? " or range" : "")")
        }
        if range.count == 2 {
            guard let end = parsePortNumber(range[1], allowZero: allowZero) else {
                throw ComposeError.invalidCompose("\(location) must be a numeric port or range")
            }
            guard start <= end else {
                throw ComposeError.invalidCompose("\(location) range start must be less than or equal to the end")
            }
        }
    }

    private func parsePortNumber(_ value: String, allowZero: Bool) -> Int? {
        guard !value.isEmpty, value.allSatisfy(\.isNumber), let port = Int(value) else {
            return nil
        }
        let lowerBound = allowZero ? 0 : 1
        guard (lowerBound...65535).contains(port) else {
            return nil
        }
        return port
    }

    private func parseServiceVolumes(_ node: YAMLValue?, serviceName: String) throws -> [ServiceVolume] {
        guard let node else { return [] }
        let entries = node.array ?? [node]
        var volumes: [ServiceVolume] = []
        for (index, item) in entries.enumerated() {
            if let string = item.string {
                let parts = string.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
                switch parts.count {
                case 1:
                    volumes.append(ServiceVolume(type: "volume", source: nil, target: parts[0], readOnly: false, consistency: nil, shortOptions: [], createHostPath: false, bind: nil, volume: nil, volumeLabels: [:], tmpfs: nil))
                case 2:
                    guard !parts[0].isEmpty else {
                        throw ComposeError.invalidCompose("Service '\(serviceName)' volumes[\(index)] source must not be empty")
                    }
                    guard !parts[1].isEmpty else {
                        throw ComposeError.invalidCompose("Service '\(serviceName)' volumes[\(index)] target must not be empty")
                    }
                    let source = parts[0]
                    volumes.append(ServiceVolume(type: nil, source: source, target: parts[1], readOnly: false, consistency: nil, shortOptions: [], createHostPath: looksLikeHostPath(source), bind: nil, volume: nil, volumeLabels: [:], tmpfs: nil))
                default:
                    let mode = parts[2].split(separator: ",").map(String.init)
                    let consistency = mode.first { ["consistent", "cached", "delegated"].contains($0) }
                    guard !parts[0].isEmpty else {
                        throw ComposeError.invalidCompose("Service '\(serviceName)' volumes[\(index)] source must not be empty")
                    }
                    guard !parts[1].isEmpty else {
                        throw ComposeError.invalidCompose("Service '\(serviceName)' volumes[\(index)] target must not be empty")
                    }
                    let source = parts[0]
                    volumes.append(ServiceVolume(type: nil, source: source, target: parts[1], readOnly: mode.contains("ro"), consistency: consistency, shortOptions: mode, createHostPath: looksLikeHostPath(source), bind: nil, volume: nil, volumeLabels: [:], tmpfs: nil))
                }
                continue
            }
            guard let map = item.map else {
                throw ComposeError.invalidCompose("Service '\(serviceName)' volumes[\(index)] must be a volume string or mapping")
            }
            try rejectUnknownKeys(
                in: map,
                known: ["bind", "consistency", "image", "read_only", "source", "target", "tmpfs", "type", "volume"],
                location: "Service '\(serviceName)' volumes[\(index)]"
            )
            guard let target = try parseOptionalString(map["target"], location: "Service '\(serviceName)' volumes[\(index)].target"), !target.isEmpty else {
                throw ComposeError.invalidCompose("Service '\(serviceName)' volumes[\(index)].target is required")
            }
            guard let type = try parseOptionalVolumeType(map["type"], location: "Service '\(serviceName)' volumes[\(index)].type") else {
                throw ComposeError.invalidCompose("Service '\(serviceName)' volumes[\(index)].type is required")
            }
            let parsedSource = try parseOptionalString(map["source"], location: "Service '\(serviceName)' volumes[\(index)].source", allowEmpty: true)
            let source = normalizedLongVolumeSource(parsedSource, type: type)
            if type == "bind", source == nil {
                throw ComposeError.invalidCompose("Service '\(serviceName)' volumes[\(index)].source is required for bind mounts")
            }
            let readOnly = try parseOptionalBoolOrString(map["read_only"], location: "Service '\(serviceName)' volumes[\(index)].read_only") ?? false
            let bind = try parseOptionalVolumeOptionMap(map["bind"], known: ["create_host_path", "propagation", "recursive", "selinux"], location: "Service '\(serviceName)' volumes[\(index)].bind")
            let volume = try parseOptionalVolumeOptionMap(map["volume"], known: ["labels", "nocopy", "subpath"], location: "Service '\(serviceName)' volumes[\(index)].volume")
            let tmpfs = try parseOptionalVolumeOptionMap(map["tmpfs"], known: ["mode", "size"], location: "Service '\(serviceName)' volumes[\(index)].tmpfs")
            let image = try parseOptionalVolumeOptionMap(map["image"], known: ["subpath"], location: "Service '\(serviceName)' volumes[\(index)].image")
            let isBindMount = type == "bind"
            let createHostPath = try parseOptionalBoolOrString(bind?["create_host_path"], location: "Service '\(serviceName)' volumes[\(index)].bind.create_host_path") ?? true
            _ = try parseOptionalExactNonEmptyString(bind?["propagation"], location: "Service '\(serviceName)' volumes[\(index)].bind.propagation")
            _ = try parseOptionalEnum(bind?["selinux"], allowed: ["z", "Z"], location: "Service '\(serviceName)' volumes[\(index)].bind.selinux")
            _ = try parseOptionalEnum(bind?["recursive"], allowed: ["disabled", "enabled", "readonly", "writable"], location: "Service '\(serviceName)' volumes[\(index)].bind.recursive")
            _ = try parseOptionalBoolOrString(volume?["nocopy"], location: "Service '\(serviceName)' volumes[\(index)].volume.nocopy")
            _ = try parseOptionalString(volume?["subpath"], location: "Service '\(serviceName)' volumes[\(index)].volume.subpath", allowEmpty: true)
            let volumeLabels = try parseLabelMap(volume?["labels"], location: "Service '\(serviceName)' volumes[\(index)].volume.labels")
            _ = try parseOptionalByteValue(tmpfs?["size"], location: "Service '\(serviceName)' volumes[\(index)].tmpfs.size", allowDoubleScalar: false)
            _ = try parseOptionalStringOrNumber(tmpfs?["mode"], location: "Service '\(serviceName)' volumes[\(index)].tmpfs.mode")
            _ = try parseOptionalString(image?["subpath"], location: "Service '\(serviceName)' volumes[\(index)].image.subpath", allowEmpty: true)
            let consistency = try parseOptionalExactNonEmptyString(map["consistency"], location: "Service '\(serviceName)' volumes[\(index)].consistency")
            volumes.append(ServiceVolume(
                type: type,
                source: source,
                target: target,
                readOnly: readOnly,
                consistency: consistency,
                shortOptions: [],
                createHostPath: isBindMount ? createHostPath : false,
                bind: bind.map(YAMLValue.map),
                volume: volume.map(YAMLValue.map),
                volumeLabels: volumeLabels,
                tmpfs: tmpfs.map(YAMLValue.map)
            ))
            _ = image
        }
        return volumes
    }

    private func normalizedLongVolumeSource(_ source: String?, type: String) -> String? {
        guard let source else {
            return nil
        }
        if source.isEmpty {
            return type == "bind" ? projectDirectory.path : nil
        }
        return source
    }

    private func parseTmpfs(_ node: YAMLValue?, serviceName: String) throws -> [TmpfsSpec] {
        guard let node else { return [] }
        return try (node.array ?? [node]).enumerated().map { index, item in
            guard let value = item.string, !value.isEmpty else {
                throw ComposeError.invalidCompose("Service '\(serviceName)' tmpfs[\(index)] must be a non-empty string")
            }
            let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard let target = parts.first, !target.isEmpty else {
                throw ComposeError.invalidCompose("Service '\(serviceName)' tmpfs[\(index)] target must not be empty")
            }
            if parts.count > 1, !parts[1].isEmpty {
                try validateTmpfsOptions(parts[1], location: "Service '\(serviceName)' tmpfs[\(index)]")
            }
            return TmpfsSpec(
                target: target,
                options: parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
            )
        }
    }

    private func validateTmpfsOptions(_ options: String, location: String) throws {
        let allowed: Set<String> = ["gid", "mode", "uid"]
        let entries = options.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        for entry in entries {
            let pieces = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard pieces.count == 2, !pieces[0].isEmpty, !pieces[1].isEmpty else {
                throw ComposeError.invalidCompose("\(location) options must use mode=...,uid=...,gid=... syntax")
            }
            guard allowed.contains(pieces[0]) else {
                throw ComposeError.invalidCompose("\(location) option '\(pieces[0])' must be one of: gid, mode, uid")
            }
        }
    }

    private func looksLikeHostPath(_ value: String) -> Bool {
        value.hasPrefix(".") || value.hasPrefix("/") || value.hasPrefix("~")
    }

    private func parseOptionalVolumeType(_ node: YAMLValue?, location: String) throws -> String? {
        guard let value = try parseOptionalString(node, location: location) else {
            return nil
        }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed: Set<String> = ["bind", "cluster", "image", "npipe", "tmpfs", "volume"]
        guard allowed.contains(normalized) else {
            throw ComposeError.invalidCompose("\(location) must be one of: \(allowed.sorted().joined(separator: ", "))")
        }
        return normalized
    }

    private func parseServiceNetworks(_ node: YAMLValue?, serviceDriverOptions: [String: String] = [:], serviceName: String) throws -> [String: NetworkAttachment]? {
        guard let node else {
            return defaultServiceNetworkAttachment(serviceDriverOptions)
        }
        if let array = node.array {
            var attachments: [String: NetworkAttachment] = [:]
            for (index, item) in array.enumerated() {
                guard let key = item.string, !key.isEmpty else {
                    throw ComposeError.invalidCompose("Service '\(serviceName)' networks[\(index)] must be a network name")
                }
                var attachment = NetworkAttachment.empty(key: key)
                attachment.driverOptions = serviceDriverOptions
                attachments[key] = attachment
            }
            return attachments.isEmpty ? defaultServiceNetworkAttachment(serviceDriverOptions) : attachments
        }
        guard let map = node.map else {
            throw ComposeError.invalidCompose("Service '\(serviceName)' networks must be a list of names or a mapping")
        }
        guard !map.isEmpty else {
            return defaultServiceNetworkAttachment(serviceDriverOptions)
        }
        var attachments: [String: NetworkAttachment] = [:]
        for (key, value) in map {
            let item: [String: YAMLValue]
            if let valueMap = value.map {
                item = valueMap
            } else if case .null = value {
                item = [:]
            } else {
                throw ComposeError.invalidCompose("Service '\(serviceName)' networks.\(key) must be a mapping")
            }
            try rejectUnknownKeys(
                in: item,
                known: [
                    "aliases", "driver_opts", "gw_priority", "interface_name", "ipv4_address",
                    "ipv6_address", "link_local_ips", "mac_address", "priority",
                ],
                location: "Service '\(serviceName)' networks.\(key)"
            )
            var driverOptions = serviceDriverOptions
            driverOptions.merge(try parseDriverOptionsMap(item["driver_opts"], location: "Service '\(serviceName)' networks.\(key).driver_opts")) { _, explicit in explicit }
            attachments[key] = NetworkAttachment(
                key: key,
                aliases: try parseStringList(item["aliases"], location: "Service '\(serviceName)' networks.\(key).aliases", allowEmpty: true).filter { !$0.isEmpty },
                ipv4Address: try parseOptionalIPAddress(item["ipv4_address"], version: .ipv4, location: "Service '\(serviceName)' networks.\(key).ipv4_address"),
                ipv6Address: try parseOptionalIPAddress(item["ipv6_address"], version: .ipv6, location: "Service '\(serviceName)' networks.\(key).ipv6_address"),
                macAddress: try parseMACAddress(item["mac_address"], location: "Service '\(serviceName)' networks.\(key).mac_address"),
                driverOptions: driverOptions,
                priority: try parseOptionalTruncatedNumber(item["priority"], location: "Service '\(serviceName)' networks.\(key).priority"),
                interfaceName: try parseOptionalString(item["interface_name"], location: "Service '\(serviceName)' networks.\(key).interface_name"),
                gwPriority: try parseOptionalTruncatedNumber(item["gw_priority"], location: "Service '\(serviceName)' networks.\(key).gw_priority"),
                linkLocalIPs: try parseIPAddressList(item["link_local_ips"], location: "Service '\(serviceName)' networks.\(key).link_local_ips")
            )
        }
        return attachments
    }

    private func defaultServiceNetworkAttachment(_ serviceDriverOptions: [String: String]) -> [String: NetworkAttachment]? {
        guard !serviceDriverOptions.isEmpty else { return nil }
        var attachment = NetworkAttachment.empty(key: "default")
        attachment.driverOptions = serviceDriverOptions
        return ["default": attachment]
    }

    private func parseDeployOptions(_ deploy: [String: YAMLValue]?, serviceName: String) throws {
        guard let deploy else { return }
        let location = "Service '\(serviceName)' deploy"
        try rejectUnknownKeys(
            in: deploy,
            known: ["endpoint_mode", "labels", "mode", "placement", "replicas", "resources", "restart_policy", "rollback_config", "update_config"],
            location: location
        )
        _ = try parseOptionalEnumAllowingExactEmptyDefault(deploy["mode"], allowed: ["global", "global-job", "replicated", "replicated-job"], location: "\(location).mode")
        _ = try parseOptionalEnumAllowingExactEmptyDefault(deploy["endpoint_mode"], allowed: ["dnsrr", "vip"], location: "\(location).endpoint_mode")
        try parseDeployPlacement(deploy["placement"], location: "\(location).placement")
        try parseDeployRestartPolicy(deploy["restart_policy"], location: "\(location).restart_policy")
        try parseDeployUpdateConfig(deploy["update_config"], location: "\(location).update_config", allowedFailureActions: ["continue", "pause", "rollback"])
        try parseDeployUpdateConfig(deploy["rollback_config"], location: "\(location).rollback_config", allowedFailureActions: ["continue", "pause"])

        let resources = try parseOptionalMap(deploy["resources"], location: "\(location).resources")
        if let resources {
            try rejectUnknownKeys(in: resources, known: ["limits", "reservations"], location: "\(location).resources")
        }
        let limits = try parseOptionalMap(resources?["limits"], location: "\(location).resources.limits")
        if let limits {
            try rejectUnknownKeys(in: limits, known: ["cpus", "memory", "pids"], location: "\(location).resources.limits")
        }
        _ = try parseOptionalCPUQuantity(limits?["cpus"], location: "\(location).resources.limits.cpus")
        _ = try parseOptionalByteValue(limits?["memory"], location: "\(location).resources.limits.memory")
        _ = try parseOptionalInt(limits?["pids"], location: "\(location).resources.limits.pids")

        let reservations = try parseOptionalMap(resources?["reservations"], location: "\(location).resources.reservations")
        if let reservations {
            try rejectUnknownKeys(in: reservations, known: ["cpus", "devices", "generic_resources", "memory"], location: "\(location).resources.reservations")
        }
        _ = try parseOptionalCPUQuantity(reservations?["cpus"], location: "\(location).resources.reservations.cpus")
        _ = try parseOptionalByteValue(reservations?["memory"], location: "\(location).resources.reservations.memory")
        try parseDeployGenericResources(reservations?["generic_resources"], location: "\(location).resources.reservations.generic_resources")
        try parseDeployDeviceReservations(reservations?["devices"], location: "\(location).resources.reservations.devices")
    }

    private func parseDeployPlacement(_ node: YAMLValue?, location: String) throws {
        guard let node else { return }
        if case .null = node {
            return
        }
        guard let map = node.map else {
            throw ComposeError.invalidCompose("\(location) must be a mapping")
        }
        try rejectUnknownKeys(in: map, known: ["constraints", "max_replicas_per_node", "preferences"], location: location)
        _ = try parseStringList(map["constraints"], location: "\(location).constraints")
        _ = try parseOptionalNonNegativeInt(map["max_replicas_per_node"], location: "\(location).max_replicas_per_node")
        guard let preferences = map["preferences"] else { return }
        guard let array = preferences.array else {
            throw ComposeError.invalidCompose("\(location).preferences must be a list of mappings")
        }
        for (index, item) in array.enumerated() {
            guard let preference = item.map else {
                throw ComposeError.invalidCompose("\(location).preferences[\(index)] must be a mapping")
            }
            try rejectUnknownKeys(in: preference, known: ["spread"], location: "\(location).preferences[\(index)]")
            _ = try parseOptionalString(preference["spread"], location: "\(location).preferences[\(index)].spread")
        }
    }

    private func parseDeployRestartPolicy(_ node: YAMLValue?, location: String) throws {
        guard let node else { return }
        if case .null = node {
            return
        }
        guard let map = node.map else {
            throw ComposeError.invalidCompose("\(location) must be a mapping")
        }
        try rejectUnknownKeys(in: map, known: ["condition", "delay", "max_attempts", "window"], location: location)
        _ = try parseOptionalEnumAllowingExactEmptyDefault(map["condition"], allowed: ["any", "none", "on-failure"], location: "\(location).condition")
        _ = try parseOptionalDuration(map["delay"], location: "\(location).delay")
        _ = try parseOptionalNonNegativeInt(map["max_attempts"], location: "\(location).max_attempts")
        _ = try parseOptionalDuration(map["window"], location: "\(location).window")
    }

    private func parseDeployUpdateConfig(_ node: YAMLValue?, location: String, allowedFailureActions: Set<String>) throws {
        guard let node else { return }
        if case .null = node {
            return
        }
        guard let map = node.map else {
            throw ComposeError.invalidCompose("\(location) must be a mapping")
        }
        try rejectUnknownKeys(in: map, known: ["delay", "failure_action", "max_failure_ratio", "monitor", "order", "parallelism"], location: location)
        _ = try parseOptionalNonNegativeInt(map["parallelism"], location: "\(location).parallelism")
        _ = try parseOptionalDuration(map["delay"], location: "\(location).delay")
        _ = try parseOptionalDuration(map["monitor"], location: "\(location).monitor")
        _ = try parseOptionalEnumAllowingExactEmptyDefault(map["failure_action"], allowed: allowedFailureActions, location: "\(location).failure_action")
        _ = try parseOptionalFailureRatio(map["max_failure_ratio"], location: "\(location).max_failure_ratio")
        _ = try parseOptionalEnum(map["order"], allowed: ["start-first", "stop-first"], location: "\(location).order")
    }

    private func parseDeployGenericResources(_ node: YAMLValue?, location: String) throws {
        guard let node else { return }
        if case .null = node {
            return
        }
        guard let array = node.array else {
            throw ComposeError.invalidCompose("\(location) must be a list of mappings")
        }
        for (index, item) in array.enumerated() {
            let itemLocation = "\(location)[\(index)]"
            guard let map = item.map else {
                throw ComposeError.invalidCompose("\(itemLocation) must be a mapping")
            }
            try rejectUnknownKeys(in: map, known: ["discrete_resource_spec"], location: itemLocation)
            guard let spec = map["discrete_resource_spec"] else { continue }
            guard let specMap = spec.map else {
                throw ComposeError.invalidCompose("\(itemLocation).discrete_resource_spec must be a mapping")
            }
            try rejectUnknownKeys(in: specMap, known: ["kind", "value"], location: "\(itemLocation).discrete_resource_spec")
            _ = try parseOptionalString(specMap["kind"], location: "\(itemLocation).discrete_resource_spec.kind")
            _ = try parseOptionalStringOrNumber(specMap["value"], location: "\(itemLocation).discrete_resource_spec.value")
        }
    }

    private func parseDeployDeviceReservations(_ node: YAMLValue?, location: String) throws {
        guard let node else { return }
        if case .null = node {
            return
        }
        guard let array = node.array else {
            throw ComposeError.invalidCompose("\(location) must be a list of mappings")
        }
        for (index, item) in array.enumerated() {
            let itemLocation = "\(location)[\(index)]"
            guard let map = item.map else {
                throw ComposeError.invalidCompose("\(itemLocation) must be a mapping")
            }
            try rejectUnknownKeys(in: map, known: ["capabilities", "count", "device_ids", "driver", "options"], location: itemLocation)
            guard map["capabilities"] != nil else {
                throw ComposeError.invalidCompose("\(itemLocation).capabilities is required")
            }
            _ = try parseStringList(map["capabilities"], location: "\(itemLocation).capabilities", allowEmpty: true)
            _ = try parseOptionalString(map["driver"], location: "\(itemLocation).driver")
            _ = try parseOptionalDeviceCount(map["count"], location: "\(itemLocation).count")
            _ = try parseStringList(map["device_ids"], location: "\(itemLocation).device_ids", allowEmpty: true)
            if map["count"] != nil && map["device_ids"] != nil {
                throw ComposeError.invalidCompose("\(itemLocation) cannot set both count and device_ids")
            }
            try parseListOrDictOptions(map["options"], location: "\(itemLocation).options")
        }
    }

    private func parseOptionalDeviceCount(_ node: YAMLValue?, location: String) throws -> String? {
        guard let node else { return nil }
        if case .null = node {
            return nil
        }
        switch node {
        case .string(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased() == "all" {
                return value
            }
            guard let parsed = Int(trimmed), parsed >= 0 else {
                throw ComposeError.invalidCompose("\(location) must be 'all' or a non-negative integer")
            }
            return value
        case .int(let value, _):
            guard value >= 0 else {
                throw ComposeError.invalidCompose("\(location) must be 'all' or a non-negative integer")
            }
            return String(value)
        case .double(let value) where value.rounded() == value:
            let integer = Int(value)
            guard integer >= 0 else {
                throw ComposeError.invalidCompose("\(location) must be 'all' or a non-negative integer")
            }
            return String(integer)
        case .reset(let value), .overrideValue(let value):
            return try parseOptionalDeviceCount(value, location: location)
        default:
            throw ComposeError.invalidCompose("\(location) must be 'all' or a non-negative integer")
        }
    }

    private func parseUnsupportedServiceShapes(
        _ serviceMap: [String: YAMLValue],
        serviceName: String,
        modelNames: Set<String>
    ) throws {
        try parseBlkioConfig(serviceMap["blkio_config"], serviceName: serviceName)
        try parseDevices(serviceMap["devices"], serviceName: serviceName)
        try parseExternalLinks(serviceMap["external_links"], serviceName: serviceName)
        _ = try parseVolumesFrom(serviceMap["volumes_from"], serviceName: serviceName)
        try parseDeviceCgroupRules(serviceMap["device_cgroup_rules"], serviceName: serviceName)
        for key in ["cgroup_parent", "isolation", "userns_mode"] {
            _ = try parseOptionalUnsettableString(serviceMap[key], location: "Service '\(serviceName)' \(key)")
        }
        _ = try parseOptionalString(serviceMap["cpuset"], location: "Service '\(serviceName)' cpuset", allowEmpty: true)
        try parsePIDMode(serviceMap["pid"], serviceName: serviceName)
        try parseIPCMode(serviceMap["ipc"], serviceName: serviceName)
        if let cgroup = try parseOptionalUnsettableString(serviceMap["cgroup"], location: "Service '\(serviceName)' cgroup") {
            let normalized = cgroup.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard ["host", "private"].contains(normalized) else {
                throw ComposeError.invalidCompose("Service '\(serviceName)' cgroup must be one of: host, private")
            }
        }
        _ = try parseOptionalUnsettableString(serviceMap["uts"], location: "Service '\(serviceName)' uts")
        try parseHostname(serviceMap["hostname"], serviceName: serviceName)
        if let cpuPercent = try parseOptionalInt(serviceMap["cpu_percent"], location: "Service '\(serviceName)' cpu_percent"),
           !(0...100).contains(cpuPercent) {
            throw ComposeError.invalidCompose("Service '\(serviceName)' cpu_percent must be between 0 and 100")
        }
        for key in ["cpu_shares", "cpu_period", "cpu_quota"] {
            _ = try parseOptionalStringOrNumber(serviceMap[key], location: "Service '\(serviceName)' \(key)")
        }
        for key in ["cpu_rt_runtime", "cpu_rt_period"] {
            _ = try parseOptionalDurationOrMicroseconds(serviceMap[key], location: "Service '\(serviceName)' \(key)")
        }
        for key in ["mem_reservation"] {
            _ = try parseOptionalByteValue(serviceMap[key], location: "Service '\(serviceName)' \(key)")
        }
        if let memSwappiness = try parseOptionalInt(serviceMap["mem_swappiness"], location: "Service '\(serviceName)' mem_swappiness"),
           !(0...100).contains(memSwappiness) {
            throw ComposeError.invalidCompose("Service '\(serviceName)' mem_swappiness must be between 0 and 100")
        }
        _ = try parseStringOrNumberList(serviceMap["group_add"], location: "Service '\(serviceName)' group_add", allowEmpty: true)
        _ = try parseExtraHosts(serviceMap["extra_hosts"], location: "Service '\(serviceName)' extra_hosts")
        try parseSysctls(serviceMap["sysctls"], serviceName: serviceName)
        _ = try parseOptionalMap(serviceMap["storage_opt"], location: "Service '\(serviceName)' storage_opt")
        _ = try parseStringList(serviceMap["security_opt"], location: "Service '\(serviceName)' security_opt", allowEmpty: true)
        try parseLogging(serviceMap["logging"], serviceName: serviceName)
        try parseCredentialSpec(serviceMap["credential_spec"], serviceName: serviceName)
        try parseGPUs(serviceMap["gpus"], serviceName: serviceName)
        try parseServiceModels(serviceMap["models"], serviceName: serviceName, modelNames: modelNames)
        try parseProvider(serviceMap["provider"], serviceName: serviceName)
        try parseDevelop(serviceMap["develop"], serviceName: serviceName)
    }

    private func validateDeployResourceConsistency(
        serviceName: String,
        serviceCPUs: String?,
        deployCPUs: String?,
        serviceMemory: String?,
        deployMemory: String?,
        serviceMemoryReservation: String?,
        deployMemoryReservation: String?,
        servicePidsLimit: Int?,
        deployPidsLimit: Int?
    ) throws {
        if let serviceCPUs,
           let deployCPUs,
           !cpuValuesConsistent(serviceCPUs, deployCPUs) {
            throw ComposeError.invalidCompose("Service '\(serviceName)' cannot set distinct values for cpus and deploy.resources.limits.cpus")
        }
        if let serviceMemory,
           let deployMemory,
           serviceMemory != deployMemory {
            throw ComposeError.invalidCompose("Service '\(serviceName)' cannot set distinct values for mem_limit and deploy.resources.limits.memory")
        }
        if let serviceMemoryReservation,
           let deployMemoryReservation,
           serviceMemoryReservation != deployMemoryReservation {
            throw ComposeError.invalidCompose("Service '\(serviceName)' cannot set distinct values for mem_reservation and deploy.resources.reservations.memory")
        }
        if let servicePidsLimit,
           let deployPidsLimit,
           servicePidsLimit != deployPidsLimit {
            throw ComposeError.invalidCompose("Service '\(serviceName)' cannot set distinct values for pids_limit and deploy.resources.limits.pids")
        }
    }

    private func cpuValuesConsistent(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        if let leftNumber = Double(left), let rightNumber = Double(right) {
            return abs(leftNumber - rightNumber) < 0.000_000_001
        }
        return left == right
    }

    private func parseBlkioConfig(_ node: YAMLValue?, serviceName: String) throws {
        guard let node else { return }
        if case .null = node {
            return
        }
        let location = "Service '\(serviceName)' blkio_config"
        guard let map = node.map else {
            throw ComposeError.invalidCompose("\(location) must be a mapping")
        }
        try rejectUnknownKeys(
            in: map,
            known: ["device_read_bps", "device_read_iops", "device_write_bps", "device_write_iops", "weight", "weight_device"],
            location: location
        )
        if let weight = try parseOptionalInt(map["weight"], location: "\(location).weight"),
           !(10...1000).contains(weight) {
            throw ComposeError.invalidCompose("\(location).weight must be between 10 and 1000")
        }
        try parseBlkioDeviceList(map["weight_device"], valueKey: "weight", valueKind: .integer, location: "\(location).weight_device")
        try parseBlkioDeviceList(map["device_read_bps"], valueKey: "rate", valueKind: .stringOrNumber, location: "\(location).device_read_bps")
        try parseBlkioDeviceList(map["device_write_bps"], valueKey: "rate", valueKind: .stringOrNumber, location: "\(location).device_write_bps")
        try parseBlkioDeviceList(map["device_read_iops"], valueKey: "rate", valueKind: .integer, location: "\(location).device_read_iops")
        try parseBlkioDeviceList(map["device_write_iops"], valueKey: "rate", valueKind: .integer, location: "\(location).device_write_iops")
    }

    private func parseDeviceCgroupRules(_ node: YAMLValue?, serviceName: String) throws {
        let location = "Service '\(serviceName)' device_cgroup_rules"
        let rules = try parseStringList(node, location: location)
        for (index, rule) in rules.enumerated() where !isValidDeviceCgroupRule(rule) {
            throw ComposeError.invalidCompose("\(location)[\(index)] must use Linux device cgroup rule syntax like 'c 1:3 mr'")
        }
    }

    private func parseDevices(_ node: YAMLValue?, serviceName: String) throws {
        let location = "Service '\(serviceName)' devices"
        guard let node else { return }
        if case .null = node {
            return
        }
        guard let devices = node.array else {
            throw ComposeError.invalidCompose("\(location) must be a list of strings or mappings")
        }
        for (index, device) in devices.enumerated() {
            let itemLocation = "\(location)[\(index)]"
            if let value = device.string {
                try validateDeviceEntry(value, location: itemLocation)
                continue
            }
            guard let map = device.map else {
                throw ComposeError.invalidCompose("\(itemLocation) must be a device string or mapping")
            }
            try rejectUnknownKeys(in: map, known: ["permissions", "source", "target"], location: itemLocation)
            guard let source = map["source"] else {
                throw ComposeError.invalidCompose("\(itemLocation).source is required")
            }
            _ = try parseRequiredString(source, location: "\(itemLocation).source")
            _ = try parseOptionalString(map["target"], location: "\(itemLocation).target")
            if let permissions = try parseOptionalString(map["permissions"], location: "\(itemLocation).permissions"),
               !isValidDevicePermissionSet(permissions) {
                throw ComposeError.invalidCompose("\(itemLocation).permissions must contain only r, w, and m")
            }
        }
    }

    private func validateDeviceEntry(_ entry: String, location: String) throws {
        if entry.contains("=") && !entry.contains(":") {
            guard isValidCDIDeviceName(entry) else {
                throw ComposeError.invalidCompose("\(location) must use CDI syntax like 'vendor.com/device=name'")
            }
            return
        }

        let parts = entry.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 3 else {
            throw ComposeError.invalidCompose("\(location) must use HOST_PATH:CONTAINER_PATH[:CGROUP_PERMISSIONS] or CDI syntax")
        }
        guard !parts[0].isEmpty, !parts[1].isEmpty else {
            throw ComposeError.invalidCompose("\(location) host and container paths must not be empty")
        }
        if parts.count == 3, !isValidDevicePermissionSet(parts[2]) {
            throw ComposeError.invalidCompose("\(location) permissions must contain only r, w, and m")
        }
    }

    private func isValidDeviceCgroupRule(_ value: String) -> Bool {
        let parts = value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard parts.count == 3, ["a", "b", "c"].contains(parts[0]) else {
            return false
        }
        let deviceParts = parts[1].split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard deviceParts.count == 2,
              deviceParts.allSatisfy({ $0 == "*" || UInt($0) != nil }) else {
            return false
        }
        let permissions = Set(parts[2])
        return !permissions.isEmpty && permissions.isSubset(of: Set("rwm"))
    }

    private func isValidDevicePermissionSet(_ value: String) -> Bool {
        let permissions = Set(value)
        return !permissions.isEmpty && permissions.isSubset(of: Set("rwm"))
    }

    private func isValidCDIDeviceName(_ value: String) -> Bool {
        value.range(
            of: #"^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*=[A-Za-z0-9][A-Za-z0-9_.-]*$"#,
            options: .regularExpression
        ) != nil
    }

    private enum BlkioValueKind {
        case integer
        case stringOrNumber
    }

    private func parseBlkioDeviceList(_ node: YAMLValue?, valueKey: String, valueKind: BlkioValueKind, location: String) throws {
        guard let node else { return }
        if case .null = node {
            return
        }
        guard let array = node.array else {
            throw ComposeError.invalidCompose("\(location) must be a list of mappings")
        }
        for (index, item) in array.enumerated() {
            let itemLocation = "\(location)[\(index)]"
            guard let map = item.map else {
                throw ComposeError.invalidCompose("\(itemLocation) must be a mapping")
            }
            try rejectUnknownKeys(in: map, known: ["path", valueKey], location: itemLocation)
            guard map["path"] != nil else {
                throw ComposeError.invalidCompose("\(itemLocation).path is required")
            }
            guard map[valueKey] != nil else {
                throw ComposeError.invalidCompose("\(itemLocation).\(valueKey) is required")
            }
            _ = try parseOptionalString(map["path"], location: "\(itemLocation).path")
            switch valueKind {
            case .integer:
                _ = try parseOptionalInt(map[valueKey], location: "\(itemLocation).\(valueKey)")
            case .stringOrNumber:
                _ = try parseOptionalStringOrNumber(map[valueKey], location: "\(itemLocation).\(valueKey)")
            }
        }
    }

    private func parseLogging(_ node: YAMLValue?, serviceName: String) throws {
        guard let node else { return }
        if case .null = node {
            return
        }
        guard let map = node.map else {
            throw ComposeError.invalidCompose("Service '\(serviceName)' logging must be a mapping")
        }
        try rejectUnknownKeys(in: map, known: ["driver", "options"], location: "Service '\(serviceName)' logging")
        _ = try parseOptionalUnsettableString(map["driver"], location: "Service '\(serviceName)' logging.driver")
        try parseLoggingOptions(map["options"], location: "Service '\(serviceName)' logging.options")
    }

    private func parseLoggingOptions(_ node: YAMLValue?, location: String) throws {
        guard let node else { return }
        guard let map = node.map else {
            throw ComposeError.invalidCompose("\(location) must be a mapping")
        }
        for (key, value) in map {
            switch value {
            case .string, .int, .double, .null:
                continue
            case .reset(let wrapped), .overrideValue(let wrapped):
                try parseLoggingOptionValue(wrapped, location: "\(location).\(key)")
            default:
                throw ComposeError.invalidCompose("\(location).\(key) must be a string, number, or null value")
            }
        }
    }

    private func parseLoggingOptionValue(_ node: YAMLValue, location: String) throws {
        switch node {
        case .string, .int, .double, .null:
            return
        case .reset(let value), .overrideValue(let value):
            try parseLoggingOptionValue(value, location: location)
        default:
            throw ComposeError.invalidCompose("\(location) must be a string, number, or null value")
        }
    }

    private func parseCredentialSpec(_ node: YAMLValue?, serviceName: String) throws {
        guard let node else { return }
        if case .null = node {
            return
        }
        guard let map = node.map else {
            throw ComposeError.invalidCompose("Service '\(serviceName)' credential_spec must be a mapping")
        }
        try rejectUnknownKeys(in: map, known: ["config", "file", "registry"], location: "Service '\(serviceName)' credential_spec")
        let sourceKeys = map.keys
            .filter { !$0.hasPrefix("x-") }
            .sorted()
        guard !sourceKeys.isEmpty else {
            return
        }
        guard sourceKeys.count == 1 else {
            throw ComposeError.invalidCompose("Service '\(serviceName)' credential_spec can only define one credential source: \(sourceKeys.joined(separator: ", "))")
        }
        let sourceKey = sourceKeys[0]
        _ = try parseRequiredString(map[sourceKey]!, location: "Service '\(serviceName)' credential_spec.\(sourceKey)")
    }

    private func parseVolumesFrom(_ node: YAMLValue?, serviceName: String) throws -> [VolumesFromSpec] {
        let location = "Service '\(serviceName)' volumes_from"
        let entries = try parseStringList(node, location: location)
        return try entries.enumerated().map { index, entry in
            try parseVolumesFromEntry(entry, location: "\(location)[\(index)]")
        }
    }

    private func parseExternalLinks(_ node: YAMLValue?, serviceName: String) throws {
        let location = "Service '\(serviceName)' external_links"
        _ = try parseStringList(node, location: location, allowEmpty: true)
    }

    private func parseVolumesFromEntry(_ entry: String, location: String) throws -> VolumesFromSpec {
        let pieces = entry.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if pieces.first == "container" {
            guard pieces.count == 2 || pieces.count == 3 else {
                throw ComposeError.invalidCompose("\(location) must use container:<name> or container:<name>:ro|rw syntax")
            }
            guard pieces.count > 1, !pieces[1].isEmpty else {
                throw ComposeError.invalidCompose("\(location) container name must not be empty")
            }
            let readOnly = pieces.count == 3 ? try parseVolumesFromAccessMode(pieces[2], location: location) : nil
            return VolumesFromSpec(source: pieces[1], containerReference: true, readOnly: readOnly)
        }
        guard pieces.count == 1 || pieces.count == 2 else {
            throw ComposeError.invalidCompose("\(location) must use SERVICE[:ro|rw] or container:<name>[:ro|rw] syntax")
        }
        guard let source = pieces.first, !source.isEmpty else {
            throw ComposeError.invalidCompose("\(location) source must not be empty")
        }
        let readOnly = pieces.count == 2 ? try parseVolumesFromAccessMode(pieces[1], location: location) : nil
        return VolumesFromSpec(source: source, containerReference: false, readOnly: readOnly)
    }

    private func parseVolumesFromAccessMode(_ value: String, location: String) throws -> Bool {
        guard ["ro", "rw"].contains(value) else {
            throw ComposeError.invalidCompose("\(location) access mode must be ro or rw")
        }
        return value == "ro"
    }

    private func parseGPUs(_ node: YAMLValue?, serviceName: String) throws {
        guard let node else { return }
        if case .null = node {
            return
        }
        let location = "Service '\(serviceName)' gpus"
        if node.array == nil {
            guard let value = try parseOptionalString(node, location: location),
                  value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "all" else {
                throw ComposeError.invalidCompose("\(location) must be 'all' or a list of device request mappings")
            }
            return
        }
        guard let array = node.array else {
            throw ComposeError.invalidCompose("\(location) must be a string or list of mappings")
        }
        for (index, item) in array.enumerated() {
            guard let map = item.map else {
                throw ComposeError.invalidCompose("\(location)[\(index)] must be a mapping")
            }
            try rejectUnknownKeys(in: map, known: ["capabilities", "count", "device_ids", "driver", "options"], location: "\(location)[\(index)]")
            _ = try parseOptionalString(map["driver"], location: "\(location)[\(index)].driver")
            _ = try parseOptionalDeviceCount(map["count"], location: "\(location)[\(index)].count")
            _ = try parseStringList(map["device_ids"], location: "\(location)[\(index)].device_ids", allowEmpty: true)
            if map["count"] != nil && map["device_ids"] != nil {
                throw ComposeError.invalidCompose("\(location)[\(index)] cannot set both count and device_ids")
            }
            _ = try parseStringList(map["capabilities"], location: "\(location)[\(index)].capabilities", allowEmpty: true)
            try parseListOrDictOptions(map["options"], location: "\(location)[\(index)].options")
        }
    }

    private func parseServiceModels(_ node: YAMLValue?, serviceName: String, modelNames: Set<String>) throws {
        guard let node else { return }
        let location = "Service '\(serviceName)' models"
        if let array = node.array {
            for (index, item) in array.enumerated() {
                let modelName = try parseRequiredString(item, location: "\(location)[\(index)]")
                try validateComposeIdentifier(modelName, kind: "Model")
                try validateServiceModelReference(modelName, serviceName: serviceName, declaredModelNames: modelNames)
            }
            return
        }
        guard let map = node.map else {
            throw ComposeError.invalidCompose("\(location) must be a list of strings or mapping")
        }
        for (modelName, value) in map {
            try validateComposeIdentifier(modelName, kind: "Model")
            try validateServiceModelReference(modelName, serviceName: serviceName, declaredModelNames: modelNames)
            if case .null = value {
                continue
            }
            guard let modelMap = value.map else {
                throw ComposeError.invalidCompose("\(location).\(modelName) must be a mapping")
            }
            try rejectUnknownKeys(
                in: modelMap,
                known: ["endpoint_var", "model_var"],
                location: "\(location).\(modelName)"
            )
            _ = try parseOptionalString(modelMap["endpoint_var"], location: "\(location).\(modelName).endpoint_var")
            _ = try parseOptionalString(modelMap["model_var"], location: "\(location).\(modelName).model_var")
        }
    }

    private func validateServiceModelReference(
        _ modelName: String,
        serviceName: String,
        declaredModelNames: Set<String>
    ) throws {
        guard declaredModelNames.contains(modelName) else {
            throw ComposeError.invalidCompose("Service '\(serviceName)' models references undefined model '\(modelName)'")
        }
    }

    private func parseProvider(_ node: YAMLValue?, serviceName: String) throws {
        guard let node else { return }
        let location = "Service '\(serviceName)' provider"
        guard let map = node.map else {
            throw ComposeError.invalidCompose("\(location) must be a mapping")
        }
        try rejectUnknownKeys(in: map, known: ["options", "type"], location: location)
        guard map["type"] != nil else {
            throw ComposeError.invalidCompose("\(location).type is required")
        }
        guard try parseOptionalString(map["type"], location: "\(location).type", allowEmpty: true) != nil else {
            throw ComposeError.invalidCompose("\(location).type must be a string")
        }
        if let options = map["options"] {
            try parseProviderOptions(options, location: "\(location).options")
        }
    }

    private func parseProviderOptions(_ node: YAMLValue, location: String) throws {
        guard let map = node.map else {
            throw ComposeError.invalidCompose("\(location) must be a mapping")
        }
        for (key, value) in map {
            guard !key.isEmpty else {
                throw ComposeError.invalidCompose("\(location) option keys must not be empty")
            }
            try parseProviderOptionValue(value, location: "\(location).\(key)")
        }
    }

    private func parseProviderOptionValue(_ node: YAMLValue, location: String) throws {
        switch node {
        case .string, .bool, .int, .double:
            return
        case .array(let values):
            for (index, value) in values.enumerated() {
                switch value {
                case .string, .bool, .int, .double:
                    continue
                case .reset(let wrapped), .overrideValue(let wrapped):
                    try parseProviderOptionArrayValue(wrapped, location: "\(location)[\(index)]")
                default:
                    throw ComposeError.invalidCompose("\(location)[\(index)] must be a string, number, or boolean value")
                }
            }
        case .reset(let value), .overrideValue(let value):
            try parseProviderOptionValue(value, location: location)
        default:
            throw ComposeError.invalidCompose("\(location) must be a string, number, boolean, or list of string/number/boolean values")
        }
    }

    private func parseProviderOptionArrayValue(_ node: YAMLValue, location: String) throws {
        switch node {
        case .string, .bool, .int, .double:
            return
        case .reset(let value), .overrideValue(let value):
            try parseProviderOptionArrayValue(value, location: location)
        default:
            throw ComposeError.invalidCompose("\(location) must be a string, number, or boolean value")
        }
    }

    private func parseDevelop(_ node: YAMLValue?, serviceName: String) throws {
        guard let node else { return }
        if case .null = node {
            return
        }
        let location = "Service '\(serviceName)' develop"
        guard let map = node.map else {
            throw ComposeError.invalidCompose("\(location) must be a mapping")
        }
        try rejectUnknownKeys(in: map, known: ["watch"], location: location)
        guard let watch = map["watch"] else { return }
        guard let array = watch.array else {
            throw ComposeError.invalidCompose("\(location).watch must be a list of mappings")
        }
        for (index, item) in array.enumerated() {
            let itemLocation = "\(location).watch[\(index)]"
            guard let watchMap = item.map else {
                throw ComposeError.invalidCompose("\(itemLocation) must be a mapping")
            }
            try rejectUnknownKeys(in: watchMap, known: ["action", "exec", "ignore", "include", "initial_sync", "path", "target"], location: itemLocation)
            guard let action = watchMap["action"] else {
                throw ComposeError.invalidCompose("\(itemLocation).action is required")
            }
            guard let path = watchMap["path"] else {
                throw ComposeError.invalidCompose("\(itemLocation).path is required")
            }
            let parsedAction = try parseOptionalEnum(action, allowed: ["rebuild", "restart", "sync", "sync+exec", "sync+restart"], location: "\(itemLocation).action")
            _ = try parseRequiredString(path, location: "\(itemLocation).path")
            let target = try parseOptionalString(watchMap["target"], location: "\(itemLocation).target")
            if ["sync", "sync+exec", "sync+restart"].contains(parsedAction ?? ""), target == nil {
                throw ComposeError.invalidCompose("\(itemLocation).target is required for \(parsedAction ?? "sync")")
            }
            _ = try parseStringList(watchMap["ignore"], location: "\(itemLocation).ignore", allowScalar: true)
            _ = try parseStringList(watchMap["include"], location: "\(itemLocation).include", allowScalar: true)
            _ = try parseOptionalBoolLiteral(watchMap["initial_sync"], location: "\(itemLocation).initial_sync")
            try parseDevelopWatchExec(watchMap["exec"], location: "\(itemLocation).exec")
        }
    }

    private func parseDevelopWatchExec(_ node: YAMLValue?, location: String) throws {
        guard let node else { return }
        if case .null = node {
            return
        }
        guard let map = node.map else {
            throw ComposeError.invalidCompose("\(location) must be a mapping")
        }
        try rejectUnknownKeys(in: map, known: ["command", "environment", "privileged", "user", "working_dir"], location: location)
        guard try parseCommand(map["command"], location: "\(location).command") != nil else {
            throw ComposeError.invalidCompose("\(location).command is required")
        }
        _ = try parseOptionalString(map["user"], location: "\(location).user")
        _ = try parseOptionalBoolOrString(map["privileged"], location: "\(location).privileged")
        _ = try parseOptionalString(map["working_dir"], location: "\(location).working_dir")
        _ = try parseEnvironmentMap(map["environment"], location: "\(location).environment")
    }

    private func parseExtraHosts(_ node: YAMLValue?, location: String) throws -> [ExtraHostEntry] {
        guard let node else { return [] }
        if let map = node.map {
            var entries: [ExtraHostEntry] = []
            for (host, value) in map.sorted(by: { $0.key < $1.key }) {
                guard !host.isEmpty else {
                    throw ComposeError.invalidCompose("\(location) host names must not be empty")
                }
                entries += try parseExtraHostMapAddresses(value, host: host, location: "\(location).\(host)")
            }
            return entries
        }
        if let array = node.array {
            var entries: [ExtraHostEntry] = []
            for (index, item) in array.enumerated() {
                let entry = try parseRequiredString(item, location: "\(location)[\(index)]")
                entries.append(try parseExtraHostEntry(entry, location: "\(location)[\(index)]"))
            }
            return entries
        }
        throw ComposeError.invalidCompose("\(location) must be a mapping or list of strings")
    }

    private func parseExtraHostMapAddresses(_ node: YAMLValue, host: String, location: String) throws -> [ExtraHostEntry] {
        if let array = node.array {
            return try array.enumerated().map { index, item in
                ExtraHostEntry(host: host, address: try parseExtraHostAddressValue(item, location: "\(location)[\(index)]"))
            }
        }
        guard node.map == nil else {
            throw ComposeError.invalidCompose("\(location) must be a string or list of strings")
        }
        return [ExtraHostEntry(host: host, address: try parseExtraHostAddressValue(node, location: location))]
    }

    private func parseExtraHostEntry(_ entry: String, location: String) throws -> ExtraHostEntry {
        let separatorIndex = entry.firstIndex(of: "=") ?? entry.firstIndex(of: ":")
        guard let separatorIndex else {
            throw ComposeError.invalidCompose("\(location) must use HOSTNAME=IP or HOSTNAME:IP syntax")
        }
        let host = String(entry[..<separatorIndex])
        guard !host.isEmpty else {
            throw ComposeError.invalidCompose("\(location) host must not be empty")
        }
        let addressStart = entry.index(after: separatorIndex)
        let address = String(entry[addressStart...])
        return ExtraHostEntry(host: host, address: normalizedExtraHostAddress(address))
    }

    private func parseExtraHostAddressValue(_ node: YAMLValue, location: String) throws -> String {
        switch node {
        case .string(let value):
            return normalizedExtraHostAddress(value)
        case .reset(let value), .overrideValue(let value):
            return try parseExtraHostAddressValue(value, location: location)
        default:
            throw ComposeError.invalidCompose("\(location) must be a string")
        }
    }

    private func normalizedExtraHostAddress(_ value: String) -> String {
        if value.hasPrefix("[") && value.hasSuffix("]") && value.count > 2 {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private func parseSysctls(_ node: YAMLValue?, serviceName: String) throws {
        try parseListOrDictOptions(node, location: "Service '\(serviceName)' sysctls")
    }

    private func parseCommand(_ node: YAMLValue?, location: String) throws -> CommandSpec? {
        guard let node else { return nil }
        if case .null = node {
            return nil
        }
        if let array = node.array {
            return .list(try array.enumerated().map { index, item in
                try parseCommandArgument(item, location: "\(location)[\(index)]")
            })
        }
        if let string = try parseOptionalString(node, location: location, allowEmpty: true) {
            return .string(string)
        }
        throw ComposeError.invalidCompose("\(location) must be a string, list of strings, or null")
    }

    private func parseCommandArgument(_ node: YAMLValue, location: String) throws -> String {
        switch node {
        case .string(let value):
            return value
        case .reset(let value), .overrideValue(let value):
            return try parseCommandArgument(value, location: location)
        default:
            throw ComposeError.invalidCompose("\(location) must be a command argument string")
        }
    }

    private func parseRestartPolicy(_ node: YAMLValue?, serviceName: String) throws -> String? {
        guard let node else { return nil }
        if case .null = node {
            return nil
        }
        let location = "Service '\(serviceName)' restart"
        switch node {
        case .string(let value):
            return value
        case .reset(let value), .overrideValue(let value):
            return try parseRestartPolicy(value, serviceName: serviceName)
        default:
            throw ComposeError.invalidCompose("\(location) must be a string")
        }
    }

    private func parseStopSignal(_ node: YAMLValue?, serviceName: String) throws -> String? {
        guard let node else { return nil }
        let location = "Service '\(serviceName)' stop_signal"
        switch node {
        case .string(let value):
            return value.isEmpty ? nil : value
        case .reset(let value), .overrideValue(let value):
            return try parseStopSignal(value, serviceName: serviceName)
        default:
            throw ComposeError.invalidCompose("\(location) must be a string")
        }
    }

    private func parseNetworkMode(_ node: YAMLValue?, serviceName: String) throws -> String? {
        guard let value = try parseOptionalExactNonEmptyString(node, location: "Service '\(serviceName)' network_mode") else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let mode = trimmed.lowercased()
        if ["bridge", "host", "none"].contains(mode) {
            return value
        }
        for prefix in ["service:", "container:"] where mode.hasPrefix(prefix) {
            let target = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty else {
                throw ComposeError.invalidCompose("Service '\(serviceName)' network_mode \(prefix.dropLast()) reference must not be empty")
            }
            return value
        }
        return value
    }

    private func parseIPCMode(_ node: YAMLValue?, serviceName: String) throws {
        guard let value = try parseOptionalUnsettableString(node, location: "Service '\(serviceName)' ipc") else {
            return
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let mode = trimmed.lowercased()
        if ["host", "shareable"].contains(mode) {
            return
        }
        if mode.hasPrefix("service:") {
            let target = trimmed.dropFirst("service:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty else {
                throw ComposeError.invalidCompose("Service '\(serviceName)' ipc service reference must not be empty")
            }
            return
        }
    }

    private func parsePIDMode(_ node: YAMLValue?, serviceName: String) throws {
        guard let value = try parseOptionalUnsettableString(node, location: "Service '\(serviceName)' pid") else {
            return
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("service:") else {
            return
        }
        let target = trimmed.dropFirst("service:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            throw ComposeError.invalidCompose("Service '\(serviceName)' pid service reference must not be empty")
        }
    }

    private func parseDomainName(_ node: YAMLValue?, serviceName: String) throws -> String? {
        try parseOptionalUnsettableString(node, location: "Service '\(serviceName)' domainname")
    }

    private func parseHostname(_ node: YAMLValue?, serviceName: String) throws {
        _ = try parseOptionalUnsettableString(node, location: "Service '\(serviceName)' hostname")
    }

    private func parseMACAddress(_ node: YAMLValue?, location: String) throws -> String? {
        guard let macAddress = try parseOptionalUnsettableString(node, location: location) else {
            return nil
        }
        guard isValidMACAddress(macAddress) else {
            throw ComposeError.invalidCompose("\(location) must use six hexadecimal octets separated by ':'")
        }
        return macAddress
    }

    private enum IPVersion {
        case any
        case ipv4
        case ipv6
    }

    private func parseOptionalIPAddress(_ node: YAMLValue?, version: IPVersion, location: String) throws -> String? {
        guard let address = try parseOptionalString(node, location: location) else {
            return nil
        }
        guard isValidIPAddress(address, version: version) else {
            throw ComposeError.invalidCompose("\(location) must be a valid \(ipVersionDescription(version)) address")
        }
        return address
    }

    private func parseIPAddressList(_ node: YAMLValue?, location: String) throws -> [String] {
        let addresses = try parseStringList(node, location: location)
        for (index, address) in addresses.enumerated() where !isValidIPAddress(address, version: .any) {
            throw ComposeError.invalidCompose("\(location)[\(index)] must be a valid IPv4 or IPv6 address")
        }
        return addresses
    }

    private func parseDNSList(_ node: YAMLValue?, serviceName: String) throws -> [String] {
        let location = "Service '\(serviceName)' dns"
        return try parseStringList(node, location: location, allowScalar: true, allowEmpty: true).filter { !$0.isEmpty }
    }

    private func parseIPAddressMap(_ node: YAMLValue?, location: String) throws -> [String: String] {
        let addresses = try parseStringValueMap(node, location: location)
        for (key, address) in addresses.sorted(by: { $0.key < $1.key }) where !isValidIPAddress(address, version: .any) {
            throw ComposeError.invalidCompose("\(location).\(key) must be a valid IPv4 or IPv6 address")
        }
        return addresses
    }

    private func parseOptionalCIDR(_ node: YAMLValue?, location: String) throws -> String? {
        guard let cidr = try parseOptionalString(node, location: location) else {
            return nil
        }
        guard isValidCIDR(cidr) else {
            throw ComposeError.invalidCompose("\(location) must be a valid IPv4 or IPv6 CIDR range")
        }
        return cidr
    }

    private func ipVersionDescription(_ version: IPVersion) -> String {
        switch version {
        case .any:
            return "IPv4 or IPv6"
        case .ipv4:
            return "IPv4"
        case .ipv6:
            return "IPv6"
        }
    }

    private func isValidIPAddress(_ value: String, version: IPVersion) -> Bool {
        switch version {
        case .any:
            return isValidIPv4Address(value) || isValidIPv6Address(value)
        case .ipv4:
            return isValidIPv4Address(value)
        case .ipv6:
            return isValidIPv6Address(value)
        }
    }

    private func isValidCIDR(_ value: String) -> Bool {
        let pieces = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard pieces.count == 2, let prefix = Int(pieces[1]) else {
            return false
        }
        if isValidIPv4Address(pieces[0]) {
            return (0...32).contains(prefix)
        }
        if isValidIPv6Address(pieces[0]) {
            return (0...128).contains(prefix)
        }
        return false
    }

    private func parsePlatform(_ node: YAMLValue?, location: String) throws -> String? {
        guard let platform = try parseOptionalUnsettableString(node, location: location) else {
            return nil
        }
        guard isValidComposePlatform(platform) else {
            throw ComposeError.invalidCompose("\(location) must use os[/arch[/variant]] syntax")
        }
        return platform
    }

    private func parsePlatformList(_ node: YAMLValue?, location: String) throws -> [String] {
        let platforms = try parseStringList(node, location: location)
        for (index, platform) in platforms.enumerated() where !isValidComposePlatform(platform) {
            throw ComposeError.invalidCompose("\(location)[\(index)] must use os[/arch[/variant]] syntax")
        }
        return platforms
    }

    private func parsePullPolicy(_ node: YAMLValue?, serviceName: String) throws -> String? {
        guard let value = try parseOptionalString(node, location: "Service '\(serviceName)' pull_policy") else {
            return nil
        }
        let policy = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let fixedPolicies: Set<String> = ["always", "never", "missing", "if_not_present", "build", "refresh", "daily", "weekly"]
        if fixedPolicies.contains(policy) {
            return value
        }
        if policy.hasPrefix("every_") {
            guard composePullPolicyIntervalSeconds(policy) != nil else {
                throw ComposeError.invalidCompose("Service '\(serviceName)' pull_policy '\(value)' must use a duration with w, d, h, m, or s units")
            }
            return value
        }
        throw ComposeError.invalidCompose("Service '\(serviceName)' pull_policy must be one of: always, build, daily, every_<duration>, if_not_present, missing, never, refresh, weekly")
    }

    private func parsePullRefreshAfter(_ node: YAMLValue?, serviceName: String) throws -> String? {
        guard let value = try parseOptionalString(node, location: "Service '\(serviceName)' pull_refresh_after") else {
            return nil
        }
        guard composePullPolicyRefreshAfterSeconds(value) != nil else {
            throw ComposeError.invalidCompose("Service '\(serviceName)' pull_refresh_after '\(value)' must use a duration with w, d, h, m, or s units")
        }
        return value
    }

    private func parseHealthcheck(_ node: YAMLValue?, serviceName: String) throws {
        guard let node else { return }
        if case .null = node {
            return
        }
        guard let map = node.map else {
            throw ComposeError.invalidCompose("Service '\(serviceName)' healthcheck must be a mapping")
        }
        try rejectUnknownKeys(
            in: map,
            known: ["disable", "interval", "retries", "start_interval", "start_period", "test", "timeout"],
            location: "Service '\(serviceName)' healthcheck"
        )
        _ = try parseOptionalBoolOrString(map["disable"], location: "Service '\(serviceName)' healthcheck.disable")
        try parseHealthcheckTest(map["test"], serviceName: serviceName)
        _ = try parseOptionalDuration(map["interval"], location: "Service '\(serviceName)' healthcheck.interval")
        _ = try parseOptionalDuration(map["timeout"], location: "Service '\(serviceName)' healthcheck.timeout")
        _ = try parseOptionalDuration(map["start_period"], location: "Service '\(serviceName)' healthcheck.start_period")
        _ = try parseOptionalDuration(map["start_interval"], location: "Service '\(serviceName)' healthcheck.start_interval")
        _ = try parseOptionalNonNegativeInt(map["retries"], location: "Service '\(serviceName)' healthcheck.retries")
    }

    private func parseHealthcheckTest(_ node: YAMLValue?, serviceName: String) throws {
        guard let node else { return }
        let location = "Service '\(serviceName)' healthcheck.test"
        if case .null = node {
            throw ComposeError.invalidCompose("\(location) must be a string or list of strings")
        }
        if node.array == nil {
            _ = try parseOptionalString(node, location: location, allowEmpty: true)
            return
        }
        guard let array = node.array else {
            throw ComposeError.invalidCompose("\(location) must be a string or list of strings")
        }
        if array.isEmpty {
            return
        }
        let command = try parseRequiredString(array[0], location: "\(location)[0]")
        guard ["NONE", "CMD", "CMD-SHELL"].contains(command.uppercased()) else {
            throw ComposeError.invalidCompose("\(location)[0] must be NONE, CMD, or CMD-SHELL")
        }
        for (index, item) in array.dropFirst().enumerated() {
            _ = try parseRequiredStringValue(item, location: "\(location)[\(index + 1)]")
        }
    }

    private func parseUlimits(_ node: YAMLValue?, location: String) throws -> [UlimitSpec] {
        guard let node else { return [] }
        guard let map = node.map else {
            throw ComposeError.invalidCompose("\(location) must be a mapping")
        }
        return try map.map { key, value in
            if value.map == nil, let scalar = try parseOptionalStringOrInt(value, location: "\(location).\(key)") {
                return UlimitSpec(name: key, soft: scalar, hard: nil)
            }
            guard let limit = value.map else {
                throw ComposeError.invalidCompose("\(location).\(key) must be a scalar limit or a soft/hard mapping")
            }
            try rejectUnknownKeys(in: limit, known: ["hard", "soft"], location: "\(location).\(key)")
            guard let soft = try parseOptionalStringOrInt(limit["soft"], location: "\(location).\(key).soft") else {
                throw ComposeError.invalidCompose("\(location).\(key).soft is required")
            }
            guard let hard = try parseOptionalStringOrInt(limit["hard"], location: "\(location).\(key).hard") else {
                throw ComposeError.invalidCompose("\(location).\(key).hard is required")
            }
            return UlimitSpec(name: key, soft: soft, hard: hard)
        }
    }

    private func parseLifecycleHooks(_ node: YAMLValue?, serviceName: String, key: String) throws -> [LifecycleHook] {
        guard let node else { return [] }
        guard let entries = node.array else {
            throw ComposeError.invalidCompose("Service '\(serviceName)' \(key) must be a list of hook mappings")
        }
        return try entries.enumerated().map { index, item in
            guard let map = item.map else {
                throw ComposeError.invalidCompose("Service '\(serviceName)' \(key)[\(index)] must be a mapping")
            }
            guard let command = try parseCommand(map["command"], location: "Service '\(serviceName)' \(key)[\(index)].command") else {
                throw ComposeError.invalidCompose("Service '\(serviceName)' \(key)[\(index)].command is required")
            }
            try rejectUnknownKeys(
                in: map,
                known: ["command", "environment", "privileged", "user", "working_dir"],
                location: "Service '\(serviceName)' \(key)[\(index)]"
            )
            return LifecycleHook(
                command: command,
                user: try parseOptionalString(map["user"], location: "Service '\(serviceName)' \(key)[\(index)].user"),
                privileged: try parseOptionalBoolOrString(map["privileged"], location: "Service '\(serviceName)' \(key)[\(index)].privileged") ?? false,
                workingDir: try parseOptionalString(map["working_dir"], location: "Service '\(serviceName)' \(key)[\(index)].working_dir"),
                environment: try parseEnvironmentMap(map["environment"], location: "Service '\(serviceName)' \(key)[\(index)].environment")
            )
        }
    }

    private func parseFileGrants(_ node: YAMLValue?, defaultTargetPrefix: String, serviceName: String, location: String) throws -> [ServiceFileGrant] {
        guard let node else { return [] }
        guard let array = node.array else {
            throw ComposeError.invalidCompose("Service '\(serviceName)' \(location) must be a list of source names or mappings")
        }
        return try array.enumerated().map { index, item in
            if item.map == nil, let source = try parseOptionalString(item, location: "Service '\(serviceName)' \(location)[\(index)] source") {
                guard !source.isEmpty else {
                    throw ComposeError.invalidCompose("Service '\(serviceName)' \(location)[\(index)] source must not be empty")
                }
                return ServiceFileGrant(
                    source: source,
                    target: defaultFileGrantTarget(source: source, explicitTarget: nil, defaultTargetPrefix: defaultTargetPrefix),
                    uid: nil,
                    gid: nil,
                    mode: nil
                )
            }
            guard let map = item.map else {
                throw ComposeError.invalidCompose("Service '\(serviceName)' \(location)[\(index)] must be a source name or mapping")
            }
            try rejectUnknownKeys(
                in: map,
                known: ["gid", "mode", "source", "target", "uid"],
                location: "Service '\(serviceName)' \(location)[\(index)]"
            )
            guard let source = try parseOptionalString(map["source"], location: "Service '\(serviceName)' \(location)[\(index)].source"), !source.isEmpty else {
                throw ComposeError.invalidCompose("Service '\(serviceName)' \(location)[\(index)].source is required")
            }
            let target = try parseOptionalString(map["target"], location: "Service '\(serviceName)' \(location)[\(index)].target")
            return ServiceFileGrant(
                source: source,
                target: defaultFileGrantTarget(source: source, explicitTarget: target, defaultTargetPrefix: defaultTargetPrefix),
                uid: try parseOptionalString(map["uid"], location: "Service '\(serviceName)' \(location)[\(index)].uid"),
                gid: try parseOptionalString(map["gid"], location: "Service '\(serviceName)' \(location)[\(index)].gid"),
                mode: try parseOptionalPermissionMode(map["mode"], location: "Service '\(serviceName)' \(location)[\(index)].mode")
            )
        }
    }

    private func defaultFileGrantTarget(source: String, explicitTarget: String?, defaultTargetPrefix: String) -> String? {
        if let explicitTarget {
            guard !defaultTargetPrefix.isEmpty, !explicitTarget.hasPrefix("/") else {
                return explicitTarget
            }
            return joinedFileGrantTarget(prefix: defaultTargetPrefix, name: explicitTarget)
        }
        guard !defaultTargetPrefix.isEmpty else {
            return source
        }
        return joinedFileGrantTarget(prefix: defaultTargetPrefix, name: source)
    }

    private func joinedFileGrantTarget(prefix: String, name: String) -> String {
        if prefix == "/" {
            return "/\(name)"
        }
        return "\(prefix)/\(name)"
    }

    private func resourceIsExternal(_ map: [String: YAMLValue], location: String) throws -> Bool {
        guard let external = map["external"] else {
            return false
        }
        if case .null = external {
            return false
        }
        if let externalMap = external.map {
            guard let name = try parseOptionalString(externalMap["name"], location: "\(location).external.name"), !name.isEmpty else {
                throw ComposeError.invalidCompose("\(location).external.name must be a non-empty string")
            }
            for key in externalMap.keys.sorted() where key != "name" && !key.hasPrefix("x-") {
                throw ComposeError.invalidCompose("\(location).external contains unsupported key '\(key)'")
            }
            return true
        }
        if let value = try parseOptionalBoolOrString(external, location: "\(location).external") {
            return value
        }
        throw ComposeError.invalidCompose("\(location).external must be a boolean value, boolean string, or external name mapping")
    }

    private func resourceName(_ map: [String: YAMLValue], location: String) throws -> String? {
        try parseOptionalString(map["name"], location: "\(location).name")
            ?? parseOptionalString(map["external"]?["name"], location: "\(location).external.name")
    }

    private func validateExternalResourceAttributes(_ map: [String: YAMLValue], external: Bool, location: String) throws {
        guard external else { return }
        if let name = try parseOptionalString(map["name"], location: "\(location).name"),
           let externalName = try parseOptionalString(map["external"]?["name"], location: "\(location).external.name"),
           name != externalName {
            throw ComposeError.invalidCompose("\(location) name and external.name conflict; only use name")
        }
        for key in map.keys.sorted() where key != "external" && key != "name" && !key.hasPrefix("x-") {
            throw ComposeError.invalidCompose("\(location) is external and can only specify external/name, not \(key)")
        }
    }

    private func validateResourceSources(
        _ map: [String: YAMLValue],
        sourceValues: [String: String?],
        external: Bool,
        location: String,
        kind: String,
        sourceDescription: String
    ) throws {
        let sourceKeys = sourceValues.compactMap { key, value in
            value == nil ? nil : key
        }.sorted()
        if external {
            if !sourceKeys.isEmpty {
                throw ComposeError.invalidCompose("\(location) is external and can only specify external/name, not \(sourceKeys.joined(separator: ", "))")
            }
            return
        }
        if sourceKeys.isEmpty {
            throw ComposeError.invalidCompose("\(location) must define \(sourceDescription)")
        }
        if sourceKeys.count > 1 {
            throw ComposeError.invalidCompose("\(location) can only define one \(kind) source type: \(sourceKeys.joined(separator: ", "))")
        }
    }

    private func parseOptionalMap(_ node: YAMLValue?, location: String) throws -> [String: YAMLValue]? {
        guard let node else { return nil }
        if case .null = node {
            return nil
        }
        guard let map = node.map else {
            throw ComposeError.invalidCompose("\(location) must be a mapping")
        }
        return map
    }

    private func rejectUnknownKeys(in map: [String: YAMLValue], known: Set<String>, location: String) throws {
        for key in map.keys.sorted() where !known.contains(key) && !key.hasPrefix("x-") {
            throw ComposeError.invalidCompose("\(location) contains unsupported key '\(key)'")
        }
    }

    private func parseOptionalVolumeOptionMap(_ node: YAMLValue?, known: Set<String>, location: String) throws -> [String: YAMLValue]? {
        guard let node else { return nil }
        if case .null = node {
            return nil
        }
        guard let map = node.map else {
            throw ComposeError.invalidCompose("\(location) must be a mapping")
        }
        try rejectUnknownKeys(in: map, known: known, location: location)
        return map
    }

    private func parseOptionalStringOrNumber(_ node: YAMLValue?, location: String, allowEmpty: Bool = false) throws -> String? {
        guard let node else { return nil }
        if case .null = node {
            return nil
        }
        let value: String
        switch node {
        case .string(let string):
            value = string
        case .int(let int, _):
            value = String(int)
        case .double(let double):
            value = String(double)
        case .reset(let value), .overrideValue(let value):
            return try parseOptionalStringOrNumber(value, location: location, allowEmpty: allowEmpty)
        default:
            throw ComposeError.invalidCompose("\(location) must be a string or number")
        }
        if !allowEmpty && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ComposeError.invalidCompose("\(location) must be a non-empty string or number")
        }
        return value
    }

    private func parseOptionalCPUQuantity(_ node: YAMLValue?, location: String) throws -> String? {
        guard let node else { return nil }
        if case .null = node {
            return nil
        }
        let value: String
        switch node {
        case .string(let string):
            value = string
        case .int(let int, _):
            value = String(int)
        case .double(let double):
            value = String(double)
        case .reset(let value), .overrideValue(let value):
            return try parseOptionalCPUQuantity(value, location: location)
        default:
            throw ComposeError.invalidCompose("\(location) must be a non-negative CPU number")
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Double(trimmed), parsed.isFinite, parsed >= 0 else {
            throw ComposeError.invalidCompose("\(location) must be a non-negative CPU number")
        }
        return value
    }

    private func nonZeroCPUQuantity(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Double(trimmed), parsed == 0 else {
            return value
        }
        return nil
    }

    private func nonZeroByteValue(_ value: String?) -> String? {
        guard let value else { return nil }
        return value == "0" ? nil : value
    }

    private func nonZeroPidsLimit(_ value: Int?) -> Int? {
        guard let value else { return nil }
        return value == 0 ? nil : value
    }

    private func parseOptionalCPUCount(_ node: YAMLValue?, location: String) throws -> String? {
        guard let node else { return nil }
        if case .null = node {
            return nil
        }
        let value: String
        switch node {
        case .string(let string):
            value = string
        case .int(let int, _):
            value = String(int)
        case .double(let double) where double.rounded() == double:
            value = String(Int(double))
        case .reset(let value), .overrideValue(let value):
            return try parseOptionalCPUCount(value, location: location)
        default:
            throw ComposeError.invalidCompose("\(location) must be a non-negative integer CPU count")
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Int(trimmed), parsed >= 0 else {
            throw ComposeError.invalidCompose("\(location) must be a non-negative integer CPU count")
        }
        return value
    }

    private func parseOptionalFailureRatio(_ node: YAMLValue?, location: String) throws -> Double? {
        guard let value = try parseOptionalStringOrNumber(node, location: location) else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Double(trimmed), parsed.isFinite, (0...1).contains(parsed) else {
            throw ComposeError.invalidCompose("\(location) must be a failure ratio between 0 and 1")
        }
        return parsed
    }

    private func parseOptionalNumber(_ node: YAMLValue?, location: String) throws -> Double? {
        guard let node else { return nil }
        if case .null = node {
            return nil
        }
        switch node {
        case .int(let value, _):
            return Double(value)
        case .double(let value) where value.isFinite:
            return value
        case .reset(let value), .overrideValue(let value):
            return try parseOptionalNumber(value, location: location)
        default:
            throw ComposeError.invalidCompose("\(location) must be a number")
        }
    }

    private func parseOptionalTruncatedNumber(_ node: YAMLValue?, location: String) throws -> Int? {
        guard let node else { return nil }
        if case .null = node {
            return nil
        }
        switch node {
        case .int(let value, _):
            return value
        case .double(let value) where value.isFinite:
            let truncated = value.rounded(.towardZero)
            guard truncated >= Double(Int.min), truncated < Double(Int.max) else {
                throw ComposeError.invalidCompose("\(location) must fit in an integer")
            }
            return Int(truncated)
        case .reset(let value), .overrideValue(let value):
            return try parseOptionalTruncatedNumber(value, location: location)
        default:
            throw ComposeError.invalidCompose("\(location) must be a number")
        }
    }

    private func parseOptionalDuration(_ node: YAMLValue?, location: String) throws -> String? {
        guard let value = try parseOptionalStringOrNumber(node, location: location) else {
            return nil
        }
        guard composeDurationSeconds(value) != nil else {
            throw ComposeError.invalidCompose("\(location) must be a valid Compose duration using ns, us, ms, s, m, or h")
        }
        return value
    }

    private func parseOptionalDurationOrMicroseconds(_ node: YAMLValue?, location: String) throws -> String? {
        guard let value = try parseOptionalStringOrNumber(node, location: location) else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let intValue = Int(trimmed), intValue >= 0 {
            return value
        }
        guard composeDurationSeconds(trimmed) != nil else {
            throw ComposeError.invalidCompose("\(location) must be a non-negative integer microsecond value or Compose duration using ns, us, ms, s, m, or h")
        }
        return value
    }

    private func parseOptionalByteValue(
        _ node: YAMLValue?,
        location: String,
        allowUnlimitedSwap: Bool = false,
        allowDoubleScalar: Bool = false
    ) throws -> String? {
        guard let node else { return nil }
        if case .null = node {
            return nil
        }
        switch node {
        case .string(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw ComposeError.invalidCompose("\(location) must be a non-empty string or number byte value")
            }
            guard let normalized = normalizedComposeByteValue(trimmed, allowUnlimitedSwap: allowUnlimitedSwap) else {
                throw ComposeError.invalidCompose(byteValueErrorMessage(location: location, allowUnlimitedSwap: allowUnlimitedSwap))
            }
            return normalized
        case .int(let value, _):
            if allowUnlimitedSwap && value == -1 {
                return String(value)
            }
            guard value >= 0 else {
                throw ComposeError.invalidCompose(byteValueErrorMessage(location: location, allowUnlimitedSwap: allowUnlimitedSwap))
            }
            return String(value)
        case .double(let value):
            if allowUnlimitedSwap && value == -1 {
                return "-1"
            }
            guard value.isFinite, value >= 0, value <= Double(Int64.max) else {
                throw ComposeError.invalidCompose(byteValueErrorMessage(location: location, allowUnlimitedSwap: allowUnlimitedSwap))
            }
            return String(Int64(value.rounded(.towardZero)))
        case .reset(let value), .overrideValue(let value):
            return try parseOptionalByteValue(value, location: location, allowUnlimitedSwap: allowUnlimitedSwap, allowDoubleScalar: allowDoubleScalar)
        default:
            throw ComposeError.invalidCompose("\(location) must be a string or number byte value")
        }
    }

    private func byteValueErrorMessage(location: String, allowUnlimitedSwap: Bool) -> String {
        let base = "\(location) must be a valid byte value using b, k/kb, m/mb, g/gb, t/tb, or p/pb units, or a numeric byte count"
        return allowUnlimitedSwap ? "\(base), with -1 accepted for unlimited swap" : base
    }

    private func parseOptionalPidsLimit(_ node: YAMLValue?, location: String) throws -> Int? {
        guard let node else { return nil }
        if case .null = node {
            return nil
        }
        switch node {
        case .int(let value, _):
            return value
        case .double(let value):
            guard value.isFinite, value >= Double(Int.min), value <= Double(Int.max) else {
                throw ComposeError.invalidCompose("\(location) must be an integer string or number")
            }
            return Int(value.rounded(.towardZero))
        case .string(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = Int(trimmed) else {
                throw ComposeError.invalidCompose("\(location) must be an integer string or number")
            }
            return parsed
        case .reset(let value), .overrideValue(let value):
            return try parseOptionalPidsLimit(value, location: location)
        default:
            throw ComposeError.invalidCompose("\(location) must be an integer string or number")
        }
    }

    private func parseOptionalString(_ node: YAMLValue?, location: String, allowEmpty: Bool = false) throws -> String? {
        guard let node else { return nil }
        if case .null = node {
            return nil
        }
        switch node {
        case .string(let value):
            if !allowEmpty && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ComposeError.invalidCompose("\(location) must be a non-empty string")
            }
            return value
        case .reset(let value), .overrideValue(let value):
            return try parseOptionalString(value, location: location, allowEmpty: allowEmpty)
        default:
            throw ComposeError.invalidCompose("\(location) must be a string")
        }
    }

    private func parseOptionalExactNonEmptyString(_ node: YAMLValue?, location: String) throws -> String? {
        guard let value = try parseOptionalString(node, location: location, allowEmpty: true) else {
            return nil
        }
        return value.isEmpty ? nil : value
    }

    private func parseOptionalUnsettableString(_ node: YAMLValue?, location: String) throws -> String? {
        guard let value = try parseOptionalString(node, location: location, allowEmpty: true) else {
            return nil
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }

    private func parseOptionalEnum(_ node: YAMLValue?, allowed: Set<String>, location: String) throws -> String? {
        guard let value = try parseOptionalString(node, location: location) else {
            return nil
        }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard allowed.contains(normalized) else {
            throw ComposeError.invalidCompose("\(location) must be one of: \(allowed.sorted().joined(separator: ", "))")
        }
        return value
    }

    private func parseOptionalEnumAllowingExactEmptyDefault(_ node: YAMLValue?, allowed: Set<String>, location: String) throws -> String? {
        guard let value = try parseOptionalString(node, location: location, allowEmpty: true) else {
            return nil
        }
        guard !value.isEmpty else {
            return nil
        }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            return value
        }
        guard allowed.contains(normalized) else {
            throw ComposeError.invalidCompose("\(location) must be one of: \(allowed.sorted().joined(separator: ", "))")
        }
        return value
    }

    private func parseOptionalStringOrInt(_ node: YAMLValue?, location: String, allowEmpty: Bool = false) throws -> String? {
        guard let node else { return nil }
        if case .null = node {
            return nil
        }
        switch node {
        case .string(let value):
            if !allowEmpty && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ComposeError.invalidCompose("\(location) must be a non-empty string or number value")
            }
            return value
        case .int(let value, _):
            return String(value)
        case .reset(let value), .overrideValue(let value):
            return try parseOptionalStringOrInt(value, location: location, allowEmpty: allowEmpty)
        default:
            throw ComposeError.invalidCompose("\(location) must be a string or integer value")
        }
    }

    private func parseOptionalUnsettableStringOrInt(_ node: YAMLValue?, location: String) throws -> String? {
        guard let value = try parseOptionalStringOrInt(node, location: location, allowEmpty: true) else {
            return nil
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }

    private func parseOptionalExactNonEmptyStringOrInt(_ node: YAMLValue?, location: String) throws -> String? {
        guard let value = try parseOptionalStringOrInt(node, location: location, allowEmpty: true) else {
            return nil
        }
        return value.isEmpty ? nil : value
    }

    private func parseOptionalPermissionMode(_ node: YAMLValue?, location: String, allowEmpty: Bool = false) throws -> String? {
        guard let node else { return nil }
        if case .null = node {
            return nil
        }
        switch node {
        case .string(let value):
            if !allowEmpty && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ComposeError.invalidCompose("\(location) must be a non-empty string or integer value")
            }
            return value
        case .int(_, let rawValue):
            if !allowEmpty && rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ComposeError.invalidCompose("\(location) must be a non-empty string or integer value")
            }
            return rawValue
        case .reset(let value), .overrideValue(let value):
            return try parseOptionalPermissionMode(value, location: location, allowEmpty: allowEmpty)
        default:
            throw ComposeError.invalidCompose("\(location) must be a string or integer value")
        }
    }

    private func parseOptionalBoolLiteral(_ node: YAMLValue?, location: String) throws -> Bool? {
        guard let node else { return nil }
        if case .null = node {
            return nil
        }
        switch node {
        case .bool(let value):
            return value
        case .reset(let value), .overrideValue(let value):
            return try parseOptionalBoolLiteral(value, location: location)
        default:
            throw ComposeError.invalidCompose("\(location) must be a boolean value")
        }
    }

    private func parseOptionalBoolOrString(_ node: YAMLValue?, location: String) throws -> Bool? {
        guard let node else { return nil }
        if case .null = node {
            return nil
        }
        switch node {
        case .bool(let value):
            return value
        case .string(let value):
            guard let parsed = composeBooleanString(value) else {
                throw ComposeError.invalidCompose("\(location) must be a boolean value or boolean string")
            }
            return parsed
        case .reset(let value), .overrideValue(let value):
            return try parseOptionalBoolOrString(value, location: location)
        default:
            throw ComposeError.invalidCompose("\(location) must be a boolean value or boolean string")
        }
    }

    private func parseOptionalBoolOrStringScalar(_ node: YAMLValue?, location: String) throws -> String? {
        guard let node else { return nil }
        if case .null = node {
            return nil
        }
        switch node {
        case .bool(let value):
            return value ? "true" : "false"
        case .string(let value):
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return nil
            }
            return value
        case .reset(let value), .overrideValue(let value):
            return try parseOptionalBoolOrStringScalar(value, location: location)
        default:
            throw ComposeError.invalidCompose("\(location) must be a boolean value or non-empty string")
        }
    }

    private func composeBooleanString(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "y", "on":
            return true
        case "false", "no", "n", "off":
            return false
        default:
            return nil
        }
    }

    private func parseOptionalInt(_ node: YAMLValue?, location: String) throws -> Int? {
        guard let node else { return nil }
        if case .null = node {
            return nil
        }
        switch node {
        case .int(let value, _):
            return value
        case .double(let value) where value.rounded() == value:
            return Int(value)
        case .string(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = Int(trimmed) else {
                throw ComposeError.invalidCompose("\(location) must be an integer value")
            }
            return parsed
        case .reset(let value), .overrideValue(let value):
            return try parseOptionalInt(value, location: location)
        default:
            throw ComposeError.invalidCompose("\(location) must be an integer value")
        }
    }

    private func parseOptionalNonNegativeInt(_ node: YAMLValue?, location: String) throws -> Int? {
        guard let value = try parseOptionalInt(node, location: location) else {
            return nil
        }
        guard value >= 0 else {
            throw ComposeError.invalidCompose("\(location) must be a non-negative integer value")
        }
        return value
    }

    private func parseStringList(_ node: YAMLValue?, location: String, allowScalar: Bool = false, allowEmpty: Bool = false) throws -> [String] {
        guard let node else { return [] }
        let parseString = allowEmpty ? parseRequiredStringValue : parseRequiredString
        if let array = node.array {
            return try array.enumerated().map { index, item in
                try parseString(item, "\(location)[\(index)]")
            }
        }
        if allowScalar {
            return [try parseString(node, location)]
        }
        throw ComposeError.invalidCompose("\(location) must be \(allowScalar ? "a string or list of strings" : "a list of strings")")
    }

    private func parseProfileList(_ node: YAMLValue?, location: String) throws -> [String] {
        guard let node else { return [] }
        guard let array = node.array else {
            throw ComposeError.invalidCompose("\(location) must be a list of strings")
        }
        return try array.enumerated().map { index, item in
            try parseProfileValue(item, location: "\(location)[\(index)]")
        }
    }

    private func parseProfileValue(_ node: YAMLValue, location: String) throws -> String {
        switch node {
        case .string(let value):
            return value
        case .reset(let value), .overrideValue(let value):
            return try parseProfileValue(value, location: location)
        default:
            throw ComposeError.invalidCompose("\(location) must be a string")
        }
    }

    private func parseStringOrNumberList(_ node: YAMLValue?, location: String, allowEmpty: Bool = false) throws -> [String] {
        guard let node else { return [] }
        guard let array = node.array else {
            throw ComposeError.invalidCompose("\(location) must be a list of strings or numbers")
        }
        return try array.enumerated().map { index, item in
            try parseRequiredStringOrNumber(item, location: "\(location)[\(index)]", allowEmpty: allowEmpty)
        }
    }

    private func parseStringMapOrStringList(_ node: YAMLValue?, location: String) throws -> [String: String] {
        guard let node else { return [:] }
        if let map = node.map {
            return Dictionary(uniqueKeysWithValues: try map.map { key, value in
                guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ComposeError.invalidCompose("\(location) keys must not be empty")
                }
                return (key, try parseRequiredStringValue(value, location: "\(location).\(key)"))
            })
        }
        if let array = node.array {
            for (index, item) in array.enumerated() {
                _ = try parseRequiredString(item, location: "\(location)[\(index)]")
            }
            return [:]
        }
        throw ComposeError.invalidCompose("\(location) must be a mapping or list of strings")
    }

    private func parseNameValueMapOrStringList(_ node: YAMLValue?, location: String) throws -> [String: String] {
        guard let node else { return [:] }
        if let map = node.map {
            return Dictionary(uniqueKeysWithValues: try map.map { key, value in
                guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ComposeError.invalidCompose("\(location) keys must not be empty")
                }
                return (key, try parseRequiredStringValue(value, location: "\(location).\(key)"))
            })
        }
        if let array = node.array {
            for (index, item) in array.enumerated() {
                let entry = try parseRequiredString(item, location: "\(location)[\(index)]")
                let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 2 else {
                    throw ComposeError.invalidCompose("\(location)[\(index)] must use NAME=VALUE syntax")
                }
            }
            return [:]
        }
        throw ComposeError.invalidCompose("\(location) must be a mapping or list of NAME=VALUE strings")
    }

    private func parseStringOrNumberMapOrStringList(_ node: YAMLValue?, location: String) throws -> [String: String] {
        guard let node else { return [:] }
        if node.map != nil {
            return try parseStringOrNumberMap(node, location: location)
        }
        if let array = node.array {
            for (index, item) in array.enumerated() {
                _ = try parseRequiredString(item, location: "\(location)[\(index)]")
            }
            return [:]
        }
        throw ComposeError.invalidCompose("\(location) must be a mapping or list of strings")
    }

    private func parseListOrDictOptions(_ node: YAMLValue?, location: String) throws {
        guard let node else { return }
        if case .null = node {
            return
        }
        if let map = node.map {
            for (key, value) in map {
                guard !key.isEmpty else {
                    throw ComposeError.invalidCompose("\(location) option keys must not be empty")
                }
                try parseListOrDictOptionValue(value, location: "\(location).\(key)")
            }
            return
        }
        if let array = node.array {
            for (index, item) in array.enumerated() {
                _ = try parseRequiredString(item, location: "\(location)[\(index)]")
            }
            return
        }
        throw ComposeError.invalidCompose("\(location) must be a mapping or list of strings")
    }

    private func parseListOrDictOptionValue(_ node: YAMLValue, location: String) throws {
        switch node {
        case .string, .bool, .int, .double, .null:
            return
        case .reset(let value), .overrideValue(let value):
            try parseListOrDictOptionValue(value, location: location)
        default:
            throw ComposeError.invalidCompose("\(location) must be a string, number, boolean, or null value")
        }
    }

    private func parseStringOrNumberMap(_ node: YAMLValue?, location: String) throws -> [String: String] {
        guard let node else { return [:] }
        guard let map = node.map else {
            throw ComposeError.invalidCompose("\(location) must be a mapping")
        }
        return Dictionary(uniqueKeysWithValues: try map.map { key, value in
            (key, try parseRequiredStringOrNumber(value, location: "\(location).\(key)"))
        })
    }

    private func parseStringValueMap(_ node: YAMLValue?, location: String) throws -> [String: String] {
        guard let node else { return [:] }
        guard let map = node.map else {
            throw ComposeError.invalidCompose("\(location) must be a mapping")
        }
        return Dictionary(uniqueKeysWithValues: try map.map { key, value in
            guard !key.isEmpty else {
                throw ComposeError.invalidCompose("\(location) keys must not be empty")
            }
            return (key, try parseRequiredStringValue(value, location: "\(location).\(key)"))
        })
    }

    private func parseRequiredStringValue(_ node: YAMLValue, location: String) throws -> String {
        switch node {
        case .string(let value):
            return value
        case .reset(let value), .overrideValue(let value):
            return try parseRequiredStringValue(value, location: location)
        default:
            throw ComposeError.invalidCompose("\(location) must be a string")
        }
    }

    private func parseDriverOptionsMap(_ node: YAMLValue?, location: String) throws -> [String: String] {
        guard let node else { return [:] }
        guard let map = node.map else {
            throw ComposeError.invalidCompose("\(location) must be a mapping")
        }
        return Dictionary(uniqueKeysWithValues: try map.map { key, value in
            (key, try parseRequiredDriverOptionValue(value, location: "\(location).\(key)"))
        })
    }

    private func parseRequiredDriverOptionValue(_ node: YAMLValue, location: String) throws -> String {
        switch node {
        case .string(let value):
            return value
        case .int(let value, _):
            return String(value)
        case .double(let value):
            return String(value)
        case .reset(let value), .overrideValue(let value):
            return try parseRequiredDriverOptionValue(value, location: location)
        default:
            throw ComposeError.invalidCompose("\(location) must be a string or number")
        }
    }

    private func parseRequiredString(_ node: YAMLValue, location: String) throws -> String {
        switch node {
        case .string(let value):
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ComposeError.invalidCompose("\(location) must be a non-empty string")
            }
            return value
        case .reset(let value), .overrideValue(let value):
            return try parseRequiredString(value, location: location)
        default:
            throw ComposeError.invalidCompose("\(location) must be a non-empty string")
        }
    }

    private func parseRequiredStringOrInteger(_ node: YAMLValue, location: String) throws -> String {
        switch node {
        case .string(let value):
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ComposeError.invalidCompose("\(location) must be a non-empty string or integer value")
            }
            return value
        case .int(let value, _):
            return String(value)
        case .double(let value) where value.rounded() == value:
            return String(Int(value))
        case .reset(let value), .overrideValue(let value):
            return try parseRequiredStringOrInteger(value, location: location)
        default:
            throw ComposeError.invalidCompose("\(location) must be a non-empty string or integer value")
        }
    }

    private func parseRequiredStringOrNumber(_ node: YAMLValue, location: String, allowEmpty: Bool = false) throws -> String {
        switch node {
        case .string(let value):
            guard allowEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ComposeError.invalidCompose("\(location) must be a non-empty string or number")
            }
            return value
        case .int(let value, _):
            return String(value)
        case .double(let value):
            return String(value)
        case .reset(let value), .overrideValue(let value):
            return try parseRequiredStringOrNumber(value, location: location, allowEmpty: allowEmpty)
        default:
            throw ComposeError.invalidCompose("\(location) must be a non-empty string or number")
        }
    }

    private func serviceLabels(_ serviceMap: [String: YAMLValue], serviceName: String) throws -> [String: String] {
        var labels: [String: String] = [:]
        for file in try parseStringList(serviceMap["label_file"], location: "Service '\(serviceName)' label_file", allowScalar: true) {
            let url = resolvePath(file, relativeTo: projectDirectory)
            labels.merge(try loadLabelFile(url)) { _, new in new }
        }
        labels.merge(try parseLabelMap(serviceMap["labels"], location: "Service '\(serviceName)' labels")) { _, explicit in explicit }
        return labels
    }

    private func loadLabelFile(_ url: URL) throws -> [String: String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let parser = ComposeEnvFileParser(environment: environment, format: .compose)
        return try parser.parse(text).mapValues { $0 ?? "" }
    }

    private func parseEnvironmentMap(_ node: YAMLValue?, location: String) throws -> [String: String?] {
        guard let node else { return [:] }
        if let map = node.map {
            return Dictionary(uniqueKeysWithValues: try map.map { key, value in
                guard !key.isEmpty else {
                    throw ComposeError.invalidCompose("\(location) keys must not be empty")
                }
                if case .null = value {
                    return (key, nil)
                }
                guard let string = value.string else {
                    throw ComposeError.invalidCompose("\(location).\(key) must be a scalar value or null")
                }
                return (key, string)
            })
        }
        if let array = node.array {
            var values: [String: String?] = [:]
            for (index, item) in array.enumerated() {
                guard let entry = item.string else {
                    throw ComposeError.invalidCompose("\(location)[\(index)] must be a KEY or KEY=VALUE string")
                }
                if let equals = entry.firstIndex(of: "=") {
                    let key = String(entry[..<equals])
                    values[key] = String(entry[entry.index(after: equals)...])
                } else {
                    values.updateValue(nil, forKey: entry)
                }
            }
            return values
        }
        throw ComposeError.invalidCompose("\(location) must be a mapping or list of KEY=VALUE strings")
    }

    private func parseLabelMap(_ node: YAMLValue?, location: String) throws -> [String: String] {
        guard let node else { return [:] }
        if let map = node.map {
            return Dictionary(uniqueKeysWithValues: try map.map { key, value in
                guard !key.isEmpty else {
                    throw ComposeError.invalidCompose("\(location) keys must not be empty")
                }
                if case .null = value {
                    return (key, "")
                }
                guard let string = value.string else {
                    throw ComposeError.invalidCompose("\(location).\(key) must be a scalar value or null")
                }
                return (key, string)
            })
        }
        if let array = node.array {
            var values: [String: String] = [:]
            for (index, item) in array.enumerated() {
                guard let entry = item.string else {
                    throw ComposeError.invalidCompose("\(location)[\(index)] must be a KEY or KEY=VALUE string")
                }
                if let equals = entry.firstIndex(of: "=") {
                    let key = String(entry[..<equals])
                    values[key] = String(entry[entry.index(after: equals)...])
                } else {
                    values[entry] = ""
                }
            }
            return values
        }
        throw ComposeError.invalidCompose("\(location) must be a mapping or list of KEY=VALUE strings")
    }

    private func parseScalarMap(_ node: YAMLValue?, location: String) throws -> [String: String] {
        guard let node else { return [:] }
        guard let map = node.map else {
            throw ComposeError.invalidCompose("\(location) must be a mapping")
        }
        return Dictionary(uniqueKeysWithValues: try map.map { key, value in
            guard let string = value.string else {
                throw ComposeError.invalidCompose("\(location).\(key) must be a scalar value")
            }
            return (key, string)
        })
    }

    private func resourceDefinitionMap(_ node: YAMLValue, location: String) throws -> [String: YAMLValue] {
        if case .null = node {
            return [:]
        }
        guard let map = node.map else {
            throw ComposeError.invalidCompose("\(location) must be empty or a mapping")
        }
        return map
    }

    private func validateComposeIdentifier(_ value: String, kind: String) throws {
        guard isValidComposeIdentifier(value) else {
            throw ComposeError.invalidCompose("\(kind) name '\(value)' must match [a-zA-Z0-9._-]+")
        }
    }

    private func parseIPAMSubnets(_ node: YAMLValue?, location: String) throws -> [String] {
        guard let node else { return [] }
        guard let map = node.map else {
            throw ComposeError.invalidCompose("\(location) must be a mapping")
        }
        try rejectUnknownKeys(in: map, known: ["config", "driver", "options"], location: location)
        _ = try parseOptionalUnsettableString(map["driver"], location: "\(location).driver")
        _ = try parseStringValueMap(map["options"], location: "\(location).options")
        guard let configNode = map["config"] else { return [] }
        guard let config = configNode.array else {
            throw ComposeError.invalidCompose("\(location).config must be a list of mappings")
        }
        return try config.enumerated().compactMap { index, value in
            guard let configMap = value.map else {
                throw ComposeError.invalidCompose("\(location).config[\(index)] must be a mapping")
            }
            try rejectUnknownKeys(in: configMap, known: ["aux_addresses", "gateway", "ip_range", "subnet"], location: "\(location).config[\(index)]")
            _ = try parseOptionalCIDR(configMap["ip_range"], location: "\(location).config[\(index)].ip_range")
            _ = try parseOptionalIPAddress(configMap["gateway"], version: .any, location: "\(location).config[\(index)].gateway")
            _ = try parseIPAddressMap(configMap["aux_addresses"], location: "\(location).config[\(index)].aux_addresses")
            return try parseOptionalCIDR(configMap["subnet"], location: "\(location).config[\(index)].subnet")
        }
    }

}

private func parseOptionalTopLevelString(_ node: YAMLValue?, key: String) throws -> String? {
    guard let node else { return nil }
    switch node {
    case .string(let value):
        return value
    case .reset(let value), .overrideValue(let value):
        return try parseOptionalTopLevelString(value, key: key)
    default:
        throw ComposeError.invalidCompose("Top-level \(key) must be a string")
    }
}

func sanitizeComposeProjectName(_ value: String) -> String {
    let lower = value.lowercased()
    let scalars = lower.unicodeScalars.map { scalar -> Character in
        CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" ? Character(scalar) : "-"
    }
    let sanitized = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
    return sanitized.isEmpty ? "apple-compose" : sanitized
}

extension NetworkAttachment {
    static func empty(key: String) -> NetworkAttachment {
        NetworkAttachment(
            key: key,
            aliases: [],
            ipv4Address: nil,
            ipv6Address: nil,
            macAddress: nil,
            driverOptions: [:],
            priority: nil,
            interfaceName: nil,
            gwPriority: nil,
            linkLocalIPs: []
        )
    }
}

func resolvePath(_ path: String, relativeTo base: URL) -> URL {
    if path.hasPrefix("/") {
        return URL(fileURLWithPath: path).standardizedFileURL
    }
    if path == "~" || path.hasPrefix("~/") {
        return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL
    }
    return base.appendingPathComponent(path).standardizedFileURL
}

func looksLikeRemoteBuildContext(_ value: String) -> Bool {
    let lowercased = value.lowercased()
    return lowercased.contains("://") || lowercased.hasPrefix("git@")
}

func isValidContainerName(_ value: String) -> Bool {
    value.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
}

func isValidComposeIdentifier(_ value: String) -> Bool {
    value.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
}

func isValidMACAddress(_ value: String) -> Bool {
    value.range(of: #"^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$"#, options: .regularExpression) != nil
}

func isValidIPv4Address(_ value: String) -> Bool {
    let address = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard address == value, !address.isEmpty else {
        return false
    }
    var storage = in_addr()
    return address.withCString { inet_pton(AF_INET, $0, &storage) == 1 }
}

func isValidIPv6Address(_ value: String) -> Bool {
    let address = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard address == value, !address.isEmpty else {
        return false
    }
    var storage = in6_addr()
    return address.withCString { inet_pton(AF_INET6, $0, &storage) == 1 }
}

func isValidComposePlatform(_ value: String) -> Bool {
    guard value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
        return false
    }
    let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard (1...3).contains(parts.count) else {
        return false
    }
    return parts.allSatisfy { part in
        part.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil
    }
}

func isValidRFC1123Hostname(_ value: String) -> Bool {
    let hostname = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !hostname.isEmpty, hostname.count <= 253, !hostname.hasSuffix(".") else {
        return false
    }
    let labels = hostname.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard !labels.isEmpty else {
        return false
    }
    for label in labels {
        guard !label.isEmpty, label.count <= 63 else {
            return false
        }
        guard label.range(of: #"^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$"#, options: .regularExpression) != nil else {
            return false
        }
    }
    return true
}
