# apple-compose

`apple-compose` is a Swift CLI that reads modern Docker Compose files and rolls them out with Apple's `container` CLI.

The implementation is intentionally strict by default. Docker Compose has features that require Docker Engine, Swarm, healthcheck state, secret/config stores, namespace controls, or Linux kernel flags that Apple `container` 1.0.0 does not expose. `apple-compose up` refuses those exact-semantic gaps unless you opt into `--compatibility-mode best-effort`.

## Install

```sh
swift build -c release
.build/release/apple-compose --help
```

Apple's `container` CLI must be installed and configured separately.

## Verify

```sh
scripts/smoke-test.sh
```

This environment's SwiftPM toolchain does not expose `Testing` or `XCTest`, so the repository currently uses a shell smoke test that builds the CLI, checks representative command planning, and verifies strict rejection of unsupported healthchecks.

## Usage

```sh
# Show compatibility findings and the Apple container commands that would run.
apple-compose plan -f compose.yaml

# Apply the project. Strict mode is the default.
apple-compose up -f compose.yaml

# Apply one service and its dependencies.
apple-compose up api

# Apply only the named service.
apple-compose up --no-deps api

# Apply while allowing documented best-effort behavior.
apple-compose up -f compose.yaml --compatibility-mode best-effort

# Print commands without executing them.
apple-compose up --dry-run

# Stop and delete project containers/networks.
apple-compose down

# Also delete named project volumes.
apple-compose down --volumes

# Print merged, interpolated Compose YAML for active profiles or selected services.
apple-compose config
apple-compose config api
```

Default file discovery matches modern Compose names: `compose.yaml`, `compose.yml`, `docker-compose.yaml`, and `docker-compose.yml`.

## Supported Compose Surface

The current Swift implementation parses and plans the core modern Compose model:

- multiple `-f` files with Compose merge rules for maps, appended sequences, shell-command overrides, unique `ports` / `volumes` / `secrets` / `configs` entries, and `!reset` / `!override` tags
- validated `include` short syntax and long syntax with string/list `path`, string `project_directory`, and string/list `env_file`, evaluated after selected Compose files are merged, with colliding included resources merged using Compose merge rules and local definitions overriding included values
- validated service `extends` string and mapping syntax for same-file and external-file base services, including Compose's healthcheck disable restriction, target/path resource overrides for ports, volumes, secrets, configs, devices, and blkio device-limit lists, duplicate removal for Compose-defined sequence fields, and duplicate-preserving DNS/env/tmpfs list merges
- Compose-relative path resolution for included/extended build contexts, env files, label files, bind mounts, configs, and secrets, with relative `build.dockerfile` paths resolved from the build context
- `.env`, `--env-file`, Compose env-file syntax including shell/earlier-value interpolation and single-quoted multiline values, and Compose-style `${VAR}`, `${VAR:-default}`, `${VAR?error}`, nested defaults/replacements, and related interpolation
- predefined Compose environment variables for file/profile/env-file selection: `COMPOSE_FILE`, `COMPOSE_PATH_SEPARATOR`, Compose-validated `COMPOSE_PROFILES`, `COMPOSE_ENV_FILES`, and `COMPOSE_DISABLE_ENV_FILE`
- `COMPOSE_PROJECT_NAME` interpolation from `-p` / `COMPOSE_PROJECT_NAME` / top-level `name` / directory fallback project names
- Compose-reserved `com.docker.compose` label prefix validation for service, network, and volume labels
- explicit empty values for known unsupported top-level/service `models`, empty/null service `develop`, Compose-compatible `provider` required-field and option shapes with empty provider type/options accepted as default behavior, develop watch required fields/action/target/exec shapes, other service attributes, and build attributes when they request no behavior after Compose merge/anchor expansion
- strict scalar, string-only, boolean/boolean-string, integer, string-list, map-or-list, top-level `name`/`version`, service/model/resource/dependency identifier, cgroup/network namespace values, IPC/PID/network namespace `service:<name>` references validated as required dependencies, IPC namespace strings including `host`/`shareable`/`service:<name>`, UTS namespace strings, realtime CPU duration/microsecond, short/long device mapping/CDI, device cgroup rule, GPU request and option forms including empty capability/device-id entries, string/number `group_add` entries with empty entries treated as no-ops, sysctls list-or-dict forms, logging option value, credential-spec source/key, Compose-compatible `external_links` string syntax, `volumes_from` access-mode, deploy subtree known-key validation, model required-field/known-key validation including top-level model names and service model references, provider/develop shape and known-key validation, unsupported service subtree known-key validation, service network/volume/secret/config/build-secret reference validation against top-level definitions with Compose's implicit `default` network exception, and external-resource shape/local-attribute validation including deprecated `external.name` mappings and `name`/`external.name` conflict checks for planner-significant service fields, build fields, known unsupported service fields, long-form `depends_on` flags, and top-level resource names/drivers/sources/IPAM fields
- `services` with `image`, `build`, Compose-validated `pull_policy` values including local-image preflight for `never`, Compose's `latest` and inspect-before-pull behavior for default/`missing`/`if_not_present`, pull-then-build fallback for default/`missing`/`if_not_present` `image`+`build` services, explicit `image`+`build` handling for `always` / `never` / `build`, `build` when a build section exists, and time-based `daily` / `weekly` / `every_<duration>` plus `refresh` pulls with optional `pull_refresh_after`, including zero intervals such as `every_0s` and bare `refresh`, tracked under `.apple-compose/<project>/pull-state`, `container_name` with Compose validation and scale restriction, validated `attach` booleans/boolean strings with explicit `attach: false` accepted, validated `command` and `entrypoint` string/list/null shapes, validated `environment` map/list syntax including valueless keys resolved from the project environment or unset when unresolved and Compose list-form empty keys reported as Apple gaps, validated Compose-parsed `env_file` including non-empty long-form `path` / `required` / `format` shapes and values, optional files, single-quoted multiline values, and `format: raw`, validated `labels` with map-form empty keys rejected and Compose list-form empty keys reported as Apple gaps, Compose-parsed non-empty `label_file` paths including env-file-style delimiters and interpolation, validated numeric `ports` short/long syntax, host IP values, protocol values, explicit `mode: host`, IPv6 publish formatting, and long-form field shapes including explicit fixed host/container mappings and fixed equivalent ranges, validated string/number `expose` as intra-network port metadata, `volumes` with Compose-style bind host-path creation defaults, short-syntax empty source/target rejection, long-form bind source requirements with explicit empty bind source resolved to the project directory, required long-form mount `type`, Compose-validated long-form mount types and entry keys, and validated nested long-form volume/bind/tmpfs/image option shapes including service-level volume labels, bind recursive modes, bind SELinux `z`/`Z`, byte-value tmpfs sizes including decimal and `t`/`p` suffix forms, and string/number tmpfs modes, validated `tmpfs` string/list syntax with active mode/uid/gid options reported as Apple gaps, validated `networks` list/map syntax including string/number service-level and attachment `driver_opts.mtu`, aliases with empty entries treated as no-ops, static IP address syntax, network MAC address syntax, Compose-truncated numeric `priority` ordering plus service-level MAC selection, Compose-truncated numeric gateway priority, interface names, and link-local IPs, validated `network_mode` string shape and Compose's `network_mode`/`networks` mutual exclusion with only `none` mapped exactly, validated `depends_on` list/map syntax with required long-form condition values and boolean/boolean-string `restart` plus boolean `required`, start ordering, and skipped/warned missing `required: false` dependencies, validated legacy `links` service/alias syntax with empty aliases treated as plain dependency links on shared networks, validated disabled and empty/no-op `healthcheck` forms, `healthcheck.test` string/list syntax with empty command arguments, healthcheck durations, and non-negative retries, Compose-compatible `profiles` handling with exact CLI profile values, comma-split `COMPOSE_PROFILES`, wildcard activation, empty profile entries treated as default/no-profile behavior, active-profile inclusion, and explicit selected-service activation, validated `platform` syntax with OS-only values mapped to Apple `--os` and amd64/x86_64 platforms enabling Rosetta, `runtime`, `mac_address` syntax with network priority selection, `working_dir`, `user`, and empty string unset/default forms for service scalar fields such as namespace, host, platform, runtime, user, and working-directory settings, validated `init`, `read_only`, `tty`, and `stdin_open` booleans/boolean strings, Compose-compatible `hostname`/`domainname` string handling, Compose-compatible DNS server/search/option strings, and Compose-compatible `extra_hosts` string/list/mapping syntax including loose host/address strings, bracketed IPv6, empty address values, and list-valued mappings, with `domainname` mapped to Apple `--dns-domain`, Compose-compatible capabilities with empty entries treated as no-ops, validated integer/string and soft/hard `ulimits`, validated non-negative `cpus` quantities, non-negative integer `cpu_count`, string/number Linux CFS CPU controls, and bounded `cpu_percent`, Compose-normalized byte-value memory limits/reservations and shared memory plus PID limits with config-time deploy-resource consistency checks, validated zero CPU/memory/reservation values, zero low-level CPU controls, empty `cpuset`, and `mem_swappiness: 0` as Compose default/no-op settings, validated explicit false/default `privileged`, Compose-compatible string-only `restart` field handling with active policies reported as Apple gaps and explicit `restart: "no"` or empty restart strings accepted as default behavior, validated explicit false/default `oom_kill_disable`, `use_api_socket`, validated `security_opt` list syntax with empty and `no-new-privileges=false` entries accepted as default behavior, validated `storage_opt` mapping shape, empty logging driver/options accepted as default behavior, byte-value `memswap_limit` including `0` and `-1` plus positive-value memory-limit consistency, string/number `pids_limit` and matching deploy PID limits including `0` and `-1`, `oom_score_adj: 0`, Compose-compatible `stop_signal` string validation including empty-string unset behavior, and Compose-duration `stop_grace_period` with Compose's 10-second default
- local build contexts, Dockerfiles, inline Dockerfiles with Compose's `dockerfile` / `dockerfile_inline` mutual exclusion, empty string/default build selector values for `build`, `context`, `dockerfile`, `dockerfile_inline`, `network`, `target`, and `isolation`, validated build args including valueless args resolved from the project environment or omitted when unresolved and Compose list-form empty keys reported as Apple gaps, validated build labels with Compose list-form empty keys reported as Apple gaps, target stage, one selected platform used for both build and run commands, validated service-selected `build.platforms` syntax, validated no-cache/pull and privileged booleans/boolean strings, validated Compose byte-value build shared memory with `0` accepted as default and active values reported as Apple gaps, validated integer/string soft/hard build ulimit shapes with active values reported as Apple gaps, Compose-compatible build tag lists with empty tags omitted from Apple tag commands, validated BuildKit option shapes for `additional_contexts` mapping with non-empty names and empty values plus `NAME=VALUE` list syntax with empty names/values accepted, `cache_from`, `cache_to`, and `entitlements` including all-empty lists as no-ops, Compose-compatible `extra_hosts` syntax, `isolation`, scalar/list/map `ssh` including `default`, `ID=path` list entries with empty sides, and scalar/null map values, boolean/string provenance/SBOM attestations with false or empty values accepted as defaults, ignored non-empty cache hints with warnings as permitted by Compose Build, file/env-backed build secrets with string-only uid/gid and without uid/gid/mode overrides, and validated explicit default build network mode
- selected service rollout for `up`/`plan`, with compatibility checks scoped to the planned services/resources, active provider-delegated services reported but omitted from generated Apple container commands, dependencies included by default, `--no-deps` available when you want only the named services, and `config` output filtered by active profiles or selected services with unused top-level resources pruned
- best-effort `post_start` and `pre_stop` lifecycle hooks using `container exec`, including validated hook list/mapping form plus command/string-user/privileged/working-directory/environment shapes and service-level `user` / `working_dir` defaults
- top-level `networks` with validated empty/mapping definitions, names, Compose-managed resource labels, validated user labels, boolean network flags including `attachable`, `internal`, `enable_ipv4`, and `enable_ipv6`, internal mode, Compose network `driver` mapped to Apple network plugins for non-default drivers with empty strings treated as default/unset behavior, validated string/number driver options passed as Apple network `--option` values, validated string-only IPAM driver options with `driver: default`, empty driver strings, and empty option maps accepted as defaults, validated IPAM config shapes and IP/CIDR values including subnet, IP range, gateway, and auxiliary addresses, one IPv4 plus one IPv6 subnet with unsupported extra same-family subnets reported as strict rollout gaps, and external-resource existence preflight
- top-level `volumes` with validated empty/mapping definitions, names, Compose-managed resource labels, validated user labels, local/default/empty driver values accepted as default behavior, validated string/number driver options including Apple `-s` size mapping from `driver_opts.size`, and external-resource existence preflight
- file-backed `secrets` and `configs`, with validated top-level definitions including labels plus secret driver/options and config/secret template-driver metadata with empty driver/template strings accepted as default behavior, secret source validation matching Compose's file/environment/external requirement, and service/build grant list syntax plus source/target/uid/gid and string/integer mode shapes checked against those definitions, Compose-style short/long mount targets mounted read-only as bind mounts, Docker Compose's documented ignore behavior for file-backed secret uid/gid/mode options, and generated secret/config mode materialization
- environment-backed `secrets`, plus file-backed, inline `content`, and environment-backed `configs`, with validated top-level definitions, exactly-one-source validation, and materialization under `.apple-compose/<project>/...` as read-only mounts
- validated deploy enum values, duration values, non-negative deploy counts, failure ratios, and shapes for `deploy.mode`, `deploy.labels`, `deploy.endpoint_mode`, `deploy.placement` including `max_replicas_per_node`, `deploy.restart_policy` with `condition: none` accepted as the default no-restart behavior, `deploy.update_config`, `deploy.rollback_config`, deploy CPU and byte-value memory resource limits, and CPU, byte-value memory, generic resource, and device reservations including option map/list forms, empty deploy labels/orchestration maps accepted as no-ops, `deploy.replicas` / `scale` for local replicas including zero replicas that skip resource/container/image/artifact work when those values are consistent and host ports do not conflict, with active `deploy.labels` service metadata reported as a strict rollout gap
- `down` cleanup for containers, networks, and optionally volumes

## Apple Container Gaps

These Compose features are currently impossible to support exactly with Apple `container` 1.0.0 and are reported by `plan`; strict `up` treats them as errors:

- active container healthchecks, `depends_on` conditions other than `service_started` for defined/active dependencies, and `depends_on.<service>.restart: true` dependency restart propagation; validated disabled healthcheck forms (`disable: true` or `test: ["NONE"]`) and empty/no-op healthcheck maps are accepted
- remote/Git build contexts; Apple `container build` accepts a local context directory
- active restart policies such as `always`, `on-failure`, `unless-stopped`, and active `deploy.restart_policy` values; Apple `container` has no restart-policy manager, so only Compose's explicit no/default restart policy is accepted
- Swarm/orchestrator deployment settings such as placement, update/rollback config, endpoint mode, replicated-job/global modes, CPU/memory/generic resource reservations, active deploy PID limits, and device reservations
- `deploy.labels` service metadata; Apple `container` has container labels but no separate service object, and Compose deploy labels are not inherited by containers
- empty environment variable, build-argument, and label keys from Compose list form; Apple container CLI flags require non-empty `key=value` entries, so apple-compose reports strict rollout gaps and omits those keys from generated commands
- external secret/config stores and top-level secret/config resource labels
- service secret/config uid/gid ownership remapping, and file-backed config mode overrides; Apple `container --mount` bind mounts do not expose container-visible ownership or mode remapping
- container annotations; Apple `container` 1.0.0 exposes labels but no annotation flag
- privileged lifecycle hooks; Apple `container exec` has no privileged mode
- per-service network aliases including legacy link aliases, static IP assignment, service-level and attachment driver options other than `mtu`, Docker `network_mode` values other than `none`, gateway priority, interface names, and link-local IPs are strict rollout gaps because Apple `container --network` only exposes network name, MAC address, and MTU
- service tmpfs mode/uid/gid options and long-form tmpfs size/mode are strict rollout gaps; Apple `container --tmpfs` accepts only a target path
- Docker volume drivers other than local/default, image/npipe/cluster mount types, volume subpath/nocopy strict rollout gaps, service-level volume labels on external volumes, bind propagation and non-default bind recursive modes as strict rollout gaps, and SELinux relabeling as a documented no-op on non-SELinux Apple hosts
- network attachable mode, disabled IPv4, `enable_ipv6` without an explicit IPv6 subnet, custom IPAM drivers/options, Docker IPAM fields other than subnet, and extra same-family IPAM subnets beyond Apple `container network create`'s one IPv4 `--subnet` plus one IPv6 `--subnet-v6`
- non-empty secret resource drivers/options/template drivers and config template drivers; Apple `container` has no secret/config driver API, so apple-compose can only materialize file, inline-content, or environment-backed resources as bind mounts
- privileged mode when enabled, device passthrough, namespace modes (`pid`, `ipc`, `cgroup`, `uts`), active/custom `security_opt`, sysctls, active OOM score tuning, active PID limits, non-empty logging drivers/options, Windows-only `credential_spec`, `external_links`, and `volumes_from`
- cgroup parent/mode settings, supplementary groups, block I/O controls, Linux CFS/realtime CPU controls, CPU pinning, memory reservations/swappiness/active swap limits, GPU passthrough, storage driver options, enabled Docker API socket delegation, enabled OOM killer configuration, and `volumes_from`
- any unrecognized non-extension service attribute is rejected during config parsing instead of being silently ignored
- any unrecognized non-extension nested service attribute in long-form ports, volumes, networks, env files, dependencies, lifecycle hooks, ulimits, or secret/config grants is rejected during config parsing or reported as a strict compatibility error instead of being silently ignored
- automatic/random host port allocation from target-only ports or non-fixed published port ranges, Compose's `network_mode: host` plus port mapping runtime error, long-form `ports[].mode` values other than `host`, and non-TCP/UDP published port protocols; Apple `container --publish` requires an explicit host port and container port and only maps documented local TCP/UDP host publishing
- empty `command` or `entrypoint` overrides (`[]` or `''`), because Apple `container run` does not expose a documented way to clear image CMD/ENTRYPOINT without replacing them
- custom hostnames and `extra_hosts`
- multi-platform image builds unless `services.<name>.platform` selects one listed `build.platforms` entry for the local rollout
- BuildKit/build-container features not exposed by `container build`, including additional contexts, build SSH, build shared-memory sizing, build ulimits, build secret uid/gid/mode ownership overrides, non-default build network modes, build extra hosts, build entitlements, and enabled privileged builds or configured provenance/SBOM attestations
- any unrecognized non-extension build attribute is rejected during config parsing instead of being silently ignored
- Compose `develop`, `models`, and non-empty `provider` delegation; active provider services are reported as unsupported and skipped by generated Apple container commands because provider setup/teardown and dependent-service environment injection require Compose's external provider mechanism
- any unrecognized non-extension top-level attribute is rejected during config parsing instead of being silently ignored
- any unrecognized non-extension top-level network, volume, config, secret, or IPAM attribute is rejected during config parsing instead of being silently ignored

Best-effort mode still prints the same findings before running commands.
