#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary="$repo_root/.build/debug/apple-compose"

swift build --package-path "$repo_root" >/dev/null

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

mkdir -p "$tmpdir/src" "$tmpdir/other"
export SMOKE_SECRET="from-env-secret"
export SMOKE_INLINE_CONFIG="from-env-config"
export SMOKE_ENV_SUFFIX="host-suffix"
cat > "$tmpdir/.env" <<'EOF'
APP_TAG=2.0
IMAGE_SUFFIX=${SMOKE_ENV_SUFFIX}
IMAGE_TAG=${APP_TAG}-${IMAGE_SUFFIX}
NESTED_TAG=${MISSING_TAG:-${APP_TAG}}
ALT_TAG=${APP_TAG:+${IMAGE_SUFFIX}}
EOF
printf 'secret' > "$tmpdir/password.txt"
printf 'relative-secret' > "$tmpdir/rel-secret.txt"
printf 'config' > "$tmpdir/app.conf"
printf 'relative-config' > "$tmpdir/rel.conf"
cat > "$tmpdir/app.labels" <<'EOF'
com.example.from-file=yes
com.example.from-colon: colon-label # comment
com.example.interpolated=${APP_TAG}
com.example.nested-default=${MISSING_TAG:-${APP_TAG}}
com.example.nested-alt=${APP_TAG:+${IMAGE_SUFFIX}}
com.example.env-nested=${NESTED_TAG}-${ALT_TAG}
com.example.empty
EOF
cat > "$tmpdir/runtime.env" <<'EOF'
FROM_FILE=plain
FROM_COLON: colon-value # comment
INTERPOLATED="tag-${APP_TAG}"
RAWISH='${APP_TAG}'
REMOVE_ME
EOF
cat > "$tmpdir/runtime.raw.env" <<'EOF'
RAW_VALUE="${APP_TAG}" # kept raw
EOF

cat > "$tmpdir/compose.yaml" <<'YAML'
name: smoke
services:
  web:
    build:
      context: .
      dockerfile: Dockerfile
      args:
        APP_TAG: ${APP_TAG:-latest}
    image: example/web:${IMAGE_TAG:-latest}
    runtime: container-runtime-linux
    mac_address: "02:00:00:00:00:01"
    user: "1000:1000"
    working_dir: /srv
    environment:
      PORT: "8080"
    env_file:
      - runtime.env
      - path: missing.env
        required: "false"
      - path: runtime.raw.env
        format: raw
    label_file: ./app.labels
    labels:
      com.example.explicit: ok
    annotations:
      com.example.annotation: metadata
    post_start:
      - command: echo started
        environment:
          HOOK: post
        working_dir: /app
    pre_stop:
      - command: ["echo", "stopping"]
    stop_grace_period: 1500ms
    ports:
      - "19090:9090"
      - "19092-19093:9092-9093/udp"
      - target: 8080
        published: "18080"
    volumes:
      - type: bind
        source: ./src
        target: /app
        read_only: "true"
      - type: bind
        source: ./long-default
        target: /long-default
      - type: bind
        source: ./long-no-create
        target: /long-no-create
        bind:
          create_host_path: "false"
      - cache-data:/cache
      - sized-data:/sized
    tmpfs:
      - /scratch
      - /run/tmp:mode=755,uid=1009,gid=1009
    networks:
      app:
        priority: 100
      aux:
        priority: 10
        driver_opts:
          mtu: "1450"
      side:
        priority: 0
        mac_address: "02:00:00:00:00:02"
    secrets:
      - db_password
      - env_secret
      - source: rel_secret
        target: rel_password
    configs:
      - source: app_conf
        target: /etc/app.conf
      - source: rel_conf
        target: rel.conf
      - source: inline_conf
        target: /etc/inline.conf
      - source: env_conf
        target: /etc/env.conf
  worker:
    image: example/worker:latest
    platform: linux/arm64
    build:
      context: .
      dockerfile_inline: |
        FROM busybox
      platforms:
        - linux/amd64
        - linux/arm64
      shm_size: 128M
      ulimits:
        nofile:
          soft: 20000
          hard: 40000
        nproc: 65535
      tags:
        - example/worker:extra
      secrets:
        - source: db_password
          target: build_password
networks:
  app:
    internal: "true"
    labels:
      - com.example.network-label
  aux: {}
  side: {}
volumes:
  cache-data:
    labels:
      - com.example.volume-label
  sized-data:
    driver_opts:
      size: 1G
      backing: sparse
secrets:
  db_password:
    file: ./password.txt
  rel_secret:
    file: ./rel-secret.txt
  env_secret:
    environment: SMOKE_SECRET
configs:
  app_conf:
    file: ./app.conf
  rel_conf:
    file: ./rel.conf
  inline_conf:
    content: |
      debug=true
      value=${APP_TAG}
  env_conf:
    environment: SMOKE_INLINE_CONFIG
YAML

cat > "$tmpdir/override.yaml" <<'YAML'
services:
  web:
    ports:
      - "19091:9090"
    volumes:
      - ./other:/app:ro,z
    environment:
      EXTRA: "yes"
YAML

plan="$(cd "$tmpdir" && "$binary" plan -f compose.yaml -f override.yaml)"

grep -F "container network create --internal --label com.docker.compose.project=smoke --label com.docker.compose.network=app --label com.example.network-label= smoke_app" <<<"$plan" >/dev/null
grep -F "container volume create --label com.docker.compose.project=smoke --label com.docker.compose.volume=cache-data --label com.example.volume-label= smoke_cache-data" <<<"$plan" >/dev/null
grep -F "container volume create --label com.docker.compose.project=smoke --label com.docker.compose.volume=sized-data -s 1G --opt backing=sparse smoke_sized-data" <<<"$plan" >/dev/null
grep -F "apple-compose-build-fallback example/web:2.0-host-suffix" <<<"$plan" >/dev/null
grep -F "container build --tag example/web:2.0-host-suffix" <<<"$plan" >/dev/null
grep -F "container build --tag example/worker:latest --file" <<<"$plan" >/dev/null
grep -F "container build --tag example/worker:latest" <<<"$plan" | grep -F -- "--platform linux/arm64" >/dev/null
if grep -F "container build --tag example/worker:latest" <<<"$plan" | grep -F -- "--shm-size" >/dev/null; then
  echo "expected build.shm_size not to emit unsupported Apple container build flags" >&2
  exit 1
fi
if grep -F "container build --tag example/worker:latest" <<<"$plan" | grep -F -- "--ulimit" >/dev/null; then
  echo "expected build.ulimits not to emit unsupported Apple container build flags" >&2
  exit 1
fi
grep -F "services.worker.build: shm_size" <<<"$plan" >/dev/null
grep -F "services.worker.build: ulimits" <<<"$plan" >/dev/null
grep -F ".apple-compose/smoke/build/worker.Dockerfile" <<<"$plan" >/dev/null
grep -F -- "--secret id=build_password,src=" <<<"$plan" >/dev/null
grep -F "password.txt" <<<"$plan" >/dev/null
grep -F "apple-compose-build-fallback example/worker:latest" <<<"$plan" >/dev/null
grep -F 'image tag "$image" "$tag"' <<<"$plan" >/dev/null
grep -F "example/worker:extra" <<<"$plan" >/dev/null
grep -F -- "--runtime container-runtime-linux" <<<"$plan" >/dev/null
grep -F "# Create bind host path requested by Compose volume syntax." <<<"$plan" >/dev/null
grep -F "/bin/mkdir -p" <<<"$plan" | grep -F "/other" >/dev/null
grep -F "/bin/mkdir -p" <<<"$plan" | grep -F "/long-default" >/dev/null
if grep -F "/bin/mkdir -p" <<<"$plan" | grep -F "/long-no-create" >/dev/null; then
  echo "expected bind.create_host_path=false to suppress host path creation" >&2
  exit 1
fi
grep -F -- "--label com.example.from-file=yes" <<<"$plan" >/dev/null
grep -F -- "--label com.example.from-colon=colon-label" <<<"$plan" >/dev/null
grep -F -- "--label com.example.interpolated=2.0" <<<"$plan" >/dev/null
grep -F -- "--label com.example.nested-default=2.0" <<<"$plan" >/dev/null
grep -F -- "--label com.example.nested-alt=host-suffix" <<<"$plan" >/dev/null
grep -F -- "--label com.example.env-nested=2.0-host-suffix" <<<"$plan" >/dev/null
grep -F -- "--label com.example.empty=" <<<"$plan" >/dev/null
grep -F -- "--label com.example.explicit=ok" <<<"$plan" >/dev/null
grep -F -- "--publish 18080:8080" <<<"$plan" >/dev/null
grep -F -- "--publish 19091:9090" <<<"$plan" >/dev/null
grep -F -- "--publish 19090:9090" <<<"$plan" >/dev/null
grep -F -- "--publish 19092:9092/udp" <<<"$plan" >/dev/null
grep -F -- "--publish 19093:9093/udp" <<<"$plan" >/dev/null
grep -F -- "--network smoke_app,mac=02:00:00:00:00:01" <<<"$plan" >/dev/null
grep -F -- "--network smoke_aux,mtu=1450" <<<"$plan" >/dev/null
grep -F -- "--network smoke_app,mac=02:00:00:00:00:01 --network smoke_aux,mtu=1450 --network smoke_side,mac=02:00:00:00:00:02" <<<"$plan" >/dev/null
if grep -F -- "--network smoke_aux,mac=" <<<"$plan" >/dev/null; then
  echo "expected service-level mac_address to apply only to the highest-priority network" >&2
  exit 1
fi
if grep -F "networks.app: priority" <<<"$plan" >/dev/null; then
  echo "expected network priority to be applied without a compatibility warning" >&2
  exit 1
fi
if grep -F -- "services.web.networks.aux: driver_opts" <<<"$plan" >/dev/null; then
  echo "expected supported network attachment mtu not to warn as ignored" >&2
  exit 1
fi
grep -F -- "--network smoke_side,mac=02:00:00:00:00:02" <<<"$plan" >/dev/null
grep -F -- "--tmpfs /scratch" <<<"$plan" >/dev/null
grep -F -- "--tmpfs /run/tmp" <<<"$plan" >/dev/null
if grep -F -- "--tmpfs /run/tmp:mode=755" <<<"$plan" >/dev/null; then
  echo "expected Compose tmpfs options to be reported and omitted from Apple --tmpfs" >&2
  exit 1
fi
grep -F "tmpfs[/run/tmp]: options" <<<"$plan" >/dev/null
grep -F "/other,target=/app,readonly" <<<"$plan" >/dev/null
grep -F "SELinux relabel" <<<"$plan" >/dev/null
grep -F "source=smoke_cache-data,target=/cache" <<<"$plan" >/dev/null
grep -F "source=smoke_sized-data,target=/sized" <<<"$plan" >/dev/null
if grep -F "/src,target=/app,readonly" <<<"$plan" >/dev/null; then
  echo "expected override volume with the same target to replace base volume" >&2
  exit 1
fi
grep -F "target=/run/secrets/db_password,readonly" <<<"$plan" >/dev/null
grep -F "target=/run/secrets/env_secret,readonly" <<<"$plan" >/dev/null
grep -F "rel-secret.txt,target=/run/secrets/rel_password,readonly" <<<"$plan" >/dev/null
grep -F "target=/etc/app.conf,readonly" <<<"$plan" >/dev/null
grep -F "rel.conf,target=/rel.conf,readonly" <<<"$plan" >/dev/null
grep -F "target=/etc/inline.conf,readonly" <<<"$plan" >/dev/null
grep -F "target=/etc/env.conf,readonly" <<<"$plan" >/dev/null
grep -F "# write sensitive file" <<<"$plan" >/dev/null
grep -F "# write file" <<<"$plan" >/dev/null
grep -F ".apple-compose/smoke/env/web.env mode 600" <<<"$plan" >/dev/null
grep -F -- "--env-file" <<<"$plan" >/dev/null
grep -F ".apple-compose/smoke/env/web.env" <<<"$plan" >/dev/null
grep -F "container run --detach" <<<"$plan" | grep -F -- "--user 1000:1000" | grep -F -- "--workdir /srv" >/dev/null
grep -F "container stop --time 2 smoke-web-1" <<<"$plan" >/dev/null
grep -F "container stop --time 10 smoke-worker-1" <<<"$plan" >/dev/null
grep -F "container exec --env HOOK=post --user 1000:1000 --workdir /app smoke-web-1 /bin/sh -c 'echo started'" <<<"$plan" >/dev/null
grep -F "container exec --user 1000:1000 --workdir /srv smoke-web-1 echo stopping" <<<"$plan" >/dev/null
grep -F "annotations" <<<"$plan" >/dev/null

annotations_gap_dir="$tmpdir/annotations-gap"
mkdir -p "$annotations_gap_dir"
cat > "$annotations_gap_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    annotations:
      com.example.annotation: metadata
YAML
if (cd "$annotations_gap_dir" && "$binary" up --dry-run >/tmp/apple-compose-annotations-gap.out 2>&1); then
  echo "expected strict up to reject container annotations" >&2
  exit 1
fi
grep -F "services.web: annotations" /tmp/apple-compose-annotations-gap.out >/dev/null
grep -F "no annotation flag" /tmp/apple-compose-annotations-gap.out >/dev/null

service_driver_opts_dir="$tmpdir/service-driver-opts"
mkdir -p "$service_driver_opts_dir"
cat > "$service_driver_opts_dir/compose.yaml" <<'YAML'
name: service_driver_opts
services:
  app:
    image: nginx
    driver_opts:
      mtu: "1400"
    networks:
      - front
      - back
  override:
    image: nginx
    driver_opts:
      mtu: "1400"
    networks:
      back:
        driver_opts:
          mtu: "1450"
  unsupported:
    image: nginx
    driver_opts:
      foo: bar
networks:
  front: {}
  back: {}
YAML
service_driver_opts_plan="$(cd "$service_driver_opts_dir" && "$binary" plan)"
grep -F "service_driver_opts-app-1" <<<"$service_driver_opts_plan" | grep -F -- "--network service_driver_opts_back,mtu=1400" >/dev/null
grep -F "service_driver_opts-app-1" <<<"$service_driver_opts_plan" | grep -F -- "--network service_driver_opts_front,mtu=1400" >/dev/null
grep -F "service_driver_opts-override-1" <<<"$service_driver_opts_plan" | grep -F -- "--network service_driver_opts_back,mtu=1450" >/dev/null
if grep -F "service_driver_opts-override-1" <<<"$service_driver_opts_plan" | grep -F -- "--network service_driver_opts_back,mtu=1400" >/dev/null; then
  echo "expected network attachment driver_opts.mtu to override service-level driver_opts.mtu" >&2
  exit 1
fi
grep -F "services.unsupported.networks.default: driver_opts" <<<"$service_driver_opts_plan" >/dev/null
if (cd "$service_driver_opts_dir" && "$binary" up --dry-run >/tmp/apple-compose-service-driver-opts.out 2>&1); then
  echo "expected strict up to reject unsupported network attachment driver_opts" >&2
  exit 1
fi
grep -F "services.unsupported.networks.default: driver_opts" /tmp/apple-compose-service-driver-opts.out >/dev/null
grep -F "not other per-container network driver options: foo" /tmp/apple-compose-service-driver-opts.out >/dev/null

reset_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir"' EXIT
cat > "$reset_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    ports:
      - "8080:80"
      - "9090:90"
    dns:
      - 1.1.1.1
YAML
cat > "$reset_dir/override.yaml" <<'YAML'
services:
  app:
    ports: !reset []
    dns: !override
      - 8.8.8.8
YAML
merged="$(cd "$reset_dir" && "$binary" config -f compose.yaml -f override.yaml)"
grep -F "ports: []" <<<"$merged" >/dev/null
grep -F -- "- 8.8.8.8" <<<"$merged" >/dev/null
if grep -F -- "- 1.1.1.1" <<<"$merged" >/dev/null; then
  echo "expected !override to replace dns instead of appending" >&2
  exit 1
fi

merge_sequence_dir="$tmpdir/merge-sequence"
mkdir -p "$merge_sequence_dir"
trap 'rm -rf "$tmpdir" "$reset_dir" "$merge_sequence_dir"' EXIT
cat > "$merge_sequence_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    cap_add:
      - NET_RAW
YAML
cat > "$merge_sequence_dir/override.yaml" <<'YAML'
services:
  app:
    cap_add:
      - NET_RAW
YAML
merged_sequence="$(cd "$merge_sequence_dir" && "$binary" config -f compose.yaml -f override.yaml)"
if [ "$(grep -c -- "- NET_RAW" <<<"$merged_sequence")" -ne 2 ]; then
  echo "expected multi-file merge to append ordinary service sequences without de-duplicating" >&2
  exit 1
fi

extends_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$merge_sequence_dir" "$extends_dir"' EXIT
cat > "$extends_dir/common.yml" <<'YAML'
services:
  base:
    image: busybox
    cap_add:
      - NET_ADMIN
      - NET_RAW
    dns:
      - 1.1.1.1
    expose:
      - "8080"
    environment:
      TZ: utc
      PORT: "80"
    volumes:
      - base-data:/data:rw
YAML
cat > "$extends_dir/compose.yaml" <<'YAML'
services:
  app:
    extends:
      file: common.yml
      service: base
    environment:
      PORT: "8080"
    cap_add:
      - NET_RAW
      - SYS_TIME
    dns:
      - 1.1.1.1
    expose:
      - "8080"
      - "9090"
    volumes:
      - app-data:/data:ro
volumes:
  app-data: {}
YAML
extended="$(cd "$extends_dir" && "$binary" config)"
grep -F "image: busybox" <<<"$extended" >/dev/null
grep -F "TZ: utc" <<<"$extended" >/dev/null
grep -F "PORT: '8080'" <<<"$extended" >/dev/null
grep -F -- "- NET_ADMIN" <<<"$extended" >/dev/null
grep -F -- "- SYS_TIME" <<<"$extended" >/dev/null
if [ "$(grep -c -- "- NET_RAW" <<<"$extended")" -ne 1 ]; then
  echo "expected extends sequence merge to remove duplicate cap_add entries" >&2
  exit 1
fi
if [ "$(grep -c -- "- '8080'" <<<"$extended")" -ne 1 ]; then
  echo "expected extends sequence merge to remove duplicate expose entries" >&2
  exit 1
fi
grep -F -- "- '9090'" <<<"$extended" >/dev/null
if [ "$(grep -c -- "- 1.1.1.1" <<<"$extended")" -ne 2 ]; then
  echo "expected extends dns list syntax to preserve duplicates" >&2
  exit 1
fi
grep -F -- "- app-data:/data:ro" <<<"$extended" >/dev/null
if grep -F -- "- base-data:/data:rw" <<<"$extended" >/dev/null; then
  echo "expected extends volume override by target path" >&2
  exit 1
fi

bad_extends_healthcheck_dir="$tmpdir/bad-extends-healthcheck"
mkdir -p "$bad_extends_healthcheck_dir"
cat > "$bad_extends_healthcheck_dir/compose.yaml" <<'YAML'
services:
  base:
    image: busybox
    healthcheck:
      test: ["CMD", "true"]
  app:
    extends:
      service: base
    healthcheck:
      disable: true
YAML
if (cd "$bad_extends_healthcheck_dir" && "$binary" config >/tmp/apple-compose-bad-extends-healthcheck.out 2>&1); then
  echo "expected extends healthcheck disable restriction to be rejected" >&2
  exit 1
fi
grep -F "cannot set healthcheck.disable: true" /tmp/apple-compose-bad-extends-healthcheck.out >/dev/null

scalar_extends_dir="$tmpdir/scalar-extends"
mkdir -p "$scalar_extends_dir"
cat > "$scalar_extends_dir/compose.yaml" <<'YAML'
services:
  base:
    image: busybox
    environment:
      FROM_BASE: from-base
  app:
    extends: base
    environment:
      FROM_APP: from-app
YAML
scalar_extended="$(cd "$scalar_extends_dir" && "$binary" config)"
grep -F "FROM_BASE: from-base" <<<"$scalar_extended" >/dev/null
grep -F "FROM_APP: from-app" <<<"$scalar_extended" >/dev/null

bad_extends_shape_dir="$tmpdir/bad-extends-shape"
mkdir -p "$bad_extends_shape_dir"
cat > "$bad_extends_shape_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    extends:
      - base
YAML
if (cd "$bad_extends_shape_dir" && "$binary" config >/tmp/apple-compose-bad-extends-shape.out 2>&1); then
  echo "expected list extends value to be rejected" >&2
  exit 1
fi
grep -F "extends must be a string" /tmp/apple-compose-bad-extends-shape.out >/dev/null

bad_extends_file_dir="$tmpdir/bad-extends-file"
mkdir -p "$bad_extends_file_dir"
cat > "$bad_extends_file_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    extends:
      service: base
      file:
        path: common.yml
YAML
if (cd "$bad_extends_file_dir" && "$binary" config >/tmp/apple-compose-bad-extends-file.out 2>&1); then
  echo "expected invalid extends.file value to be rejected" >&2
  exit 1
fi
grep -F "extends.file must be a non-empty string" /tmp/apple-compose-bad-extends-file.out >/dev/null

bad_extends_unknown_dir="$tmpdir/bad-extends-unknown"
mkdir -p "$bad_extends_unknown_dir"
cat > "$bad_extends_unknown_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    extends:
      service: base
      project: common
YAML
if (cd "$bad_extends_unknown_dir" && "$binary" config >/tmp/apple-compose-bad-extends-unknown.out 2>&1); then
  echo "expected unsupported extends keys to be rejected" >&2
  exit 1
fi
grep -F "extends contains unsupported key 'project'" /tmp/apple-compose-bad-extends-unknown.out >/dev/null

include_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$merge_sequence_dir" "$extends_dir" "$scalar_extends_dir" "$bad_extends_healthcheck_dir" "$bad_extends_shape_dir" "$bad_extends_file_dir" "$bad_extends_unknown_dir" "$include_dir"' EXIT
mkdir -p "$include_dir/common/ctx" "$include_dir/common/data"
cat > "$include_dir/common/include.env" <<'EOF'
INC_TAG=from-include
EOF
cat > "$include_dir/common/service.env" <<'EOF'
SERVICE_ENV=ok
EOF
cat > "$include_dir/common/app.labels" <<'EOF'
com.example.included=yes
EOF
printf 'included-secret' > "$include_dir/common/secret.txt"
cat > "$include_dir/common/compose.yaml" <<'YAML'
services:
  included:
    build:
      context: ./ctx
      dockerfile: Dockerfile
    image: example/included:${INC_TAG}
    env_file: ./service.env
    label_file: ./app.labels
    volumes:
      - ./data:/data:ro
    secrets:
      - included_secret
secrets:
  included_secret:
    file: ./secret.txt
YAML
cat > "$include_dir/compose.yaml" <<'YAML'
include:
  - path: common/compose.yaml
    project_directory: common
    env_file: include.env
services:
  main:
    image: nginx
YAML
included_plan="$(cd "$include_dir" && "$binary" plan)"
grep -F "container build --tag example/included:from-include --file" <<<"$included_plan" >/dev/null
grep -F "common/ctx/Dockerfile" <<<"$included_plan" >/dev/null
grep -F "common/ctx" <<<"$included_plan" >/dev/null
grep -F -- "--env-file" <<<"$included_plan" >/dev/null
grep -F ".apple-compose/" <<<"$included_plan" >/dev/null
grep -F "/env/included.env" <<<"$included_plan" >/dev/null
grep -F -- "--label com.example.included=yes" <<<"$included_plan" >/dev/null
grep -F "common/data,target=/data,readonly" <<<"$included_plan" >/dev/null
grep -F "common/secret.txt,target=/run/secrets/included_secret,readonly" <<<"$included_plan" >/dev/null
included_config="$(cd "$include_dir" && "$binary" config)"
grep -F "included:" <<<"$included_config" >/dev/null
grep -F "main:" <<<"$included_config" >/dev/null
if grep -F "include:" <<<"$included_config" >/dev/null; then
  echo "expected resolved config output not to retain top-level include" >&2
  exit 1
fi

include_conflict_dir="$tmpdir/include-conflict"
mkdir -p "$include_conflict_dir/common"
cat > "$include_conflict_dir/common/compose.yaml" <<'YAML'
services:
  app:
    image: busybox
    environment:
      FROM_INCLUDE: included
    volumes:
      - data:/from-include
      - data:/override-me:ro
  sidecar:
    image: alpine
volumes:
  data:
    labels:
      com.example.owner: include
      com.example.include: included
YAML
cat > "$include_conflict_dir/compose.yaml" <<'YAML'
include:
  - common/compose.yaml
services:
  app:
    image: nginx
    volumes:
      - data:/local
      - data:/override-me:rw
volumes:
  data:
    labels:
      com.example.owner: local
YAML
include_conflict_config="$(cd "$include_conflict_dir" && "$binary" config)"
grep -F "app:" <<<"$include_conflict_config" >/dev/null
grep -F "sidecar:" <<<"$include_conflict_config" >/dev/null
grep -F "image: nginx" <<<"$include_conflict_config" >/dev/null
grep -F "FROM_INCLUDE: included" <<<"$include_conflict_config" >/dev/null
grep -F -- "- data:/from-include" <<<"$include_conflict_config" >/dev/null
grep -F -- "- data:/local" <<<"$include_conflict_config" >/dev/null
grep -F -- "- data:/override-me:rw" <<<"$include_conflict_config" >/dev/null
if grep -F "data:/override-me:ro" <<<"$include_conflict_config" >/dev/null; then
  echo "expected local include resource volume target to override included target" >&2
  exit 1
fi
grep -F "com.example.include: included" <<<"$include_conflict_config" >/dev/null
grep -F "com.example.owner: local" <<<"$include_conflict_config" >/dev/null
include_conflict_plan="$(cd "$include_conflict_dir" && "$binary" plan)"
if grep -F "[warning] services.app: include" <<<"$include_conflict_plan" >/dev/null || grep -F "[warning] volumes.data: include" <<<"$include_conflict_plan" >/dev/null; then
  echo "expected include resource conflicts to merge without compatibility warnings" >&2
  exit 1
fi

include_merge_order_dir="$tmpdir/include-merge-order"
mkdir -p "$include_merge_order_dir/common"
cat > "$include_merge_order_dir/common/compose.yaml" <<'YAML'
services:
  app:
    image: busybox
    environment:
      FROM_INCLUDE: included
YAML
cat > "$include_merge_order_dir/base.yaml" <<'YAML'
include:
  - common/compose.yaml
services:
  app:
    image: nginx
YAML
cat > "$include_merge_order_dir/override.yaml" <<'YAML'
services:
  app:
    command: ["sleep", "1"]
YAML
include_merge_order_config="$(cd "$include_merge_order_dir" && "$binary" config -f base.yaml -f override.yaml)"
grep -F "image: nginx" <<<"$include_merge_order_config" >/dev/null
grep -F -- "- sleep" <<<"$include_merge_order_config" >/dev/null
grep -F "FROM_INCLUDE: included" <<<"$include_merge_order_config" >/dev/null

bad_include_dir="$tmpdir/bad-include"
mkdir -p "$bad_include_dir"
cat > "$bad_include_dir/compose.yaml" <<'YAML'
include:
  - project_directory: common
services:
  main:
    image: nginx
YAML
if (cd "$bad_include_dir" && "$binary" config >/tmp/apple-compose-bad-include.out 2>&1); then
  echo "expected missing include.path to be rejected" >&2
  exit 1
fi
grep -F "include.path is required" /tmp/apple-compose-bad-include.out >/dev/null

bad_include_path_shape_dir="$tmpdir/bad-include-path-shape"
mkdir -p "$bad_include_path_shape_dir"
cat > "$bad_include_path_shape_dir/compose.yaml" <<'YAML'
include:
  - path:
      - common/compose.yaml
      - path: nested
services:
  app:
    image: nginx
YAML
if (cd "$bad_include_path_shape_dir" && "$binary" config >/tmp/apple-compose-bad-include-path-shape.out 2>&1); then
  echo "expected invalid include.path list entry to be rejected" >&2
  exit 1
fi
grep -F "include.path[1] must be a non-empty string" /tmp/apple-compose-bad-include-path-shape.out >/dev/null

bad_include_env_shape_dir="$tmpdir/bad-include-env-shape"
mkdir -p "$bad_include_env_shape_dir"
cat > "$bad_include_env_shape_dir/common.yaml" <<'YAML'
services:
  common:
    image: nginx
YAML
cat > "$bad_include_env_shape_dir/compose.yaml" <<'YAML'
include:
  - path: common.yaml
    env_file:
      - env/common.env
      - path: nested
services:
  app:
    image: nginx
YAML
if (cd "$bad_include_env_shape_dir" && "$binary" config >/tmp/apple-compose-bad-include-env-shape.out 2>&1); then
  echo "expected invalid include.env_file list entry to be rejected" >&2
  exit 1
fi
grep -F "include.env_file[1] must be a non-empty string" /tmp/apple-compose-bad-include-env-shape.out >/dev/null

context_dockerfile_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$extends_dir" "$include_dir" "$bad_include_dir" "$bad_include_path_shape_dir" "$bad_include_env_shape_dir" "$context_dockerfile_dir"' EXIT
mkdir -p "$context_dockerfile_dir/app/docker"
cat > "$context_dockerfile_dir/compose.yaml" <<'YAML'
services:
  app:
    image: example/context-dockerfile:latest
    build:
      context: ./app
      dockerfile: docker/Dockerfile
YAML
context_dockerfile_plan="$(cd "$context_dockerfile_dir" && "$binary" plan)"
grep -F "container build --tag example/context-dockerfile:latest" <<<"$context_dockerfile_plan" >/dev/null
grep -F "app/docker/Dockerfile" <<<"$context_dockerfile_plan" >/dev/null

envvars_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$extends_dir" "$include_dir" "$context_dockerfile_dir" "$envvars_dir"' EXIT
cat > "$envvars_dir/.env" <<'EOF'
COMPOSE_FILE=base.yaml|override.yaml
COMPOSE_PATH_SEPARATOR=|
COMPOSE_PROFILES=debug
COMPOSE_ENV_FILES=values.env
APP_TAG=wrong
EOF
cat > "$envvars_dir/values.env" <<'EOF'
APP_TAG=from-values
EOF
cat > "$envvars_dir/base.yaml" <<'YAML'
name: envvars
services:
  app:
    image: example/app:${APP_TAG}
  debug:
    image: example/debug:${APP_TAG}
    profiles:
      - debug
  hidden:
    image: example/hidden:${APP_TAG}
    profiles:
      - hidden
YAML
cat > "$envvars_dir/override.yaml" <<'YAML'
services:
  app:
    environment:
      OVERRIDE: "yes"
YAML
envvars_plan="$(cd "$envvars_dir" && "$binary" plan)"
grep -F "Project: envvars" <<<"$envvars_plan" >/dev/null
grep -F "example/app:from-values" <<<"$envvars_plan" >/dev/null
grep -F "example/debug:from-values" <<<"$envvars_plan" >/dev/null
grep -F -- "--env OVERRIDE=yes" <<<"$envvars_plan" >/dev/null
if grep -F "example/hidden" <<<"$envvars_plan" >/dev/null; then
  echo "expected inactive profile service to stay out of the plan" >&2
  exit 1
fi
envvars_config="$(cd "$envvars_dir" && "$binary" config)"
grep -F "app:" <<<"$envvars_config" >/dev/null
grep -F "debug:" <<<"$envvars_config" >/dev/null
if grep -F "hidden:" <<<"$envvars_config" >/dev/null; then
  echo "expected inactive profile service to stay out of config output" >&2
  exit 1
fi
envvars_profile_config="$(cd "$envvars_dir" && "$binary" config --profile hidden)"
grep -F "hidden:" <<<"$envvars_profile_config" >/dev/null
targeted_hidden_plan="$(cd "$envvars_dir" && "$binary" plan hidden)"
grep -F "example/hidden:from-values" <<<"$targeted_hidden_plan" >/dev/null
if grep -F "example/app:from-values" <<<"$targeted_hidden_plan" >/dev/null; then
  echo "expected explicit inactive profile service selection not to include unrelated active services" >&2
  exit 1
fi
if grep -F "example/debug:from-values" <<<"$targeted_hidden_plan" >/dev/null; then
  echo "expected explicit inactive profile service selection not to include unrelated active-profile services" >&2
  exit 1
fi
targeted_hidden_config="$(cd "$envvars_dir" && "$binary" config hidden)"
grep -F "hidden:" <<<"$targeted_hidden_config" >/dev/null
if grep -F "app:" <<<"$targeted_hidden_config" >/dev/null; then
  echo "expected explicit inactive profile service config not to include unrelated active services" >&2
  exit 1
fi

profile_only_dir="$tmpdir/profile-only"
mkdir -p "$profile_only_dir"
cat > "$profile_only_dir/compose.yaml" <<'YAML'
name: profile_only
services:
  debug:
    image: example/debug:latest
    profiles:
      - debug
YAML
if (cd "$profile_only_dir" && "$binary" plan >/tmp/apple-compose-profile-only.out 2>&1); then
  echo "expected all-inactive profile plan to reject with no service selected" >&2
  exit 1
fi
grep -F "no service selected" /tmp/apple-compose-profile-only.out >/dev/null
profile_only_targeted_plan="$(cd "$profile_only_dir" && "$binary" plan debug)"
grep -F "profile_only-debug-1" <<<"$profile_only_targeted_plan" >/dev/null
profile_only_config="$(cd "$profile_only_dir" && "$binary" config)"
grep -F "services: {}" <<<"$profile_only_config" >/dev/null
profile_only_targeted_config="$(cd "$profile_only_dir" && "$binary" config debug)"
grep -F "debug:" <<<"$profile_only_targeted_config" >/dev/null

profile_dependency_dir="$tmpdir/profile-dependency"
mkdir -p "$profile_dependency_dir"
cat > "$profile_dependency_dir/compose.yaml" <<'YAML'
name: profile_dependency
services:
  app:
    image: example/app:latest
    profiles:
      - app
    depends_on:
      - dep
  dep:
    image: example/dep:latest
    profiles:
      - dep
YAML
if (cd "$profile_dependency_dir" && "$binary" plan app >/tmp/apple-compose-profile-dependency.out 2>&1); then
  echo "expected inactive required profiled dependency to be rejected" >&2
  exit 1
fi
grep -F "depends on service 'dep' which is not defined or not active" /tmp/apple-compose-profile-dependency.out >/dev/null
if (cd "$profile_dependency_dir" && "$binary" config app >/tmp/apple-compose-profile-dependency-config.out 2>&1); then
  echo "expected config to reject inactive required profiled dependency" >&2
  exit 1
fi
grep -F "depends on service 'dep' which is not defined or not active" /tmp/apple-compose-profile-dependency-config.out >/dev/null
profile_dependency_selected_plan="$(cd "$profile_dependency_dir" && "$binary" plan app dep)"
grep -F "profile_dependency-dep-1" <<<"$profile_dependency_selected_plan" >/dev/null
grep -F "profile_dependency-app-1" <<<"$profile_dependency_selected_plan" >/dev/null
profile_dependency_selected_config="$(cd "$profile_dependency_dir" && "$binary" config app dep)"
grep -F "app:" <<<"$profile_dependency_selected_config" >/dev/null
grep -F "dep:" <<<"$profile_dependency_selected_config" >/dev/null

profile_resource_config_dir="$tmpdir/profile-resource-config"
mkdir -p "$profile_resource_config_dir"
cat > "$profile_resource_config_dir/compose.yaml" <<'YAML'
name: profile_resource_config
services:
  app:
    image: example/app:latest
    networks:
      - appnet
    volumes:
      - data:/data
    secrets:
      - used_secret
    configs:
      - used_config
  hidden:
    image: example/hidden:latest
    profiles:
      - hidden
    networks:
      - hidden_net
    volumes:
      - hidden_data:/data
    secrets:
      - hidden_secret
    configs:
      - hidden_config
networks:
  appnet: {}
  hidden_net: {}
  unused_net: {}
volumes:
  data: {}
  hidden_data: {}
  unused_data: {}
secrets:
  used_secret:
    file: ./used.secret
  hidden_secret:
    file: ./hidden.secret
  unused_secret:
    file: ./unused.secret
configs:
  used_config:
    file: ./used.conf
  hidden_config:
    file: ./hidden.conf
  unused_config:
    file: ./unused.conf
YAML
: > "$profile_resource_config_dir/used.secret"
: > "$profile_resource_config_dir/hidden.secret"
: > "$profile_resource_config_dir/unused.secret"
: > "$profile_resource_config_dir/used.conf"
: > "$profile_resource_config_dir/hidden.conf"
: > "$profile_resource_config_dir/unused.conf"
profile_resource_config="$(cd "$profile_resource_config_dir" && "$binary" config)"
grep -F "appnet:" <<<"$profile_resource_config" >/dev/null
grep -F "data:" <<<"$profile_resource_config" >/dev/null
grep -F "used_secret:" <<<"$profile_resource_config" >/dev/null
grep -F "used_config:" <<<"$profile_resource_config" >/dev/null
if grep -F "unused_net:" <<<"$profile_resource_config" >/dev/null || grep -F "hidden_net:" <<<"$profile_resource_config" >/dev/null; then
  echo "expected config to prune unused and inactive-profile networks" >&2
  exit 1
fi
if grep -F "unused_data:" <<<"$profile_resource_config" >/dev/null || grep -F "hidden_data:" <<<"$profile_resource_config" >/dev/null; then
  echo "expected config to prune unused and inactive-profile volumes" >&2
  exit 1
fi
if grep -F "unused_secret:" <<<"$profile_resource_config" >/dev/null || grep -F "hidden_secret:" <<<"$profile_resource_config" >/dev/null; then
  echo "expected config to prune unused and inactive-profile secrets" >&2
  exit 1
fi
if grep -F "unused_config:" <<<"$profile_resource_config" >/dev/null || grep -F "hidden_config:" <<<"$profile_resource_config" >/dev/null; then
  echo "expected config to prune unused and inactive-profile configs" >&2
  exit 1
fi
profile_resource_target_config="$(cd "$profile_resource_config_dir" && "$binary" config hidden)"
grep -F "hidden_net:" <<<"$profile_resource_target_config" >/dev/null
grep -F "hidden_data:" <<<"$profile_resource_target_config" >/dev/null
grep -F "hidden_secret:" <<<"$profile_resource_target_config" >/dev/null
grep -F "hidden_config:" <<<"$profile_resource_target_config" >/dev/null
if grep -F "appnet:" <<<"$profile_resource_target_config" >/dev/null || grep -F "unused_net:" <<<"$profile_resource_target_config" >/dev/null; then
  echo "expected selected service config to keep only selected service resources" >&2
  exit 1
fi

implicit_default_config_dir="$tmpdir/implicit-default-config"
mkdir -p "$implicit_default_config_dir"
cat > "$implicit_default_config_dir/compose.yaml" <<'YAML'
name: implicit_default_config
services:
  app:
    image: example/app:latest
YAML
implicit_default_config="$(cd "$implicit_default_config_dir" && "$binary" config)"
grep -F "default: {}" <<<"$implicit_default_config" >/dev/null

bad_resource_reference_dir="$tmpdir/bad-resource-reference"
mkdir -p "$bad_resource_reference_dir"
cat > "$bad_resource_reference_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    networks:
      - missing_net
YAML
if (cd "$bad_resource_reference_dir" && "$binary" config >/tmp/apple-compose-bad-resource-network.out 2>&1); then
  echo "expected undefined explicit service network to be rejected" >&2
  exit 1
fi
grep -F "refers to undefined network 'missing_net'" /tmp/apple-compose-bad-resource-network.out >/dev/null

bad_volume_reference_dir="$tmpdir/bad-volume-reference"
mkdir -p "$bad_volume_reference_dir"
cat > "$bad_volume_reference_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    volumes:
      - missing_data:/data
YAML
if (cd "$bad_volume_reference_dir" && "$binary" config >/tmp/apple-compose-bad-resource-volume.out 2>&1); then
  echo "expected undefined named volume to be rejected" >&2
  exit 1
fi
grep -F "refers to undefined volume 'missing_data'" /tmp/apple-compose-bad-resource-volume.out >/dev/null

profile_behavior_dir="$tmpdir/profile-behavior"
mkdir -p "$profile_behavior_dir"
cat > "$profile_behavior_dir/compose.yaml" <<'YAML'
name: profile_behavior
services:
  defaulted:
    image: nginx
    profiles:
      - ""
  dot:
    image: nginx
    profiles:
      - .bad
  single:
    image: nginx
    profiles:
      - a
  beta:
    image: nginx
    profiles:
      - b
  spaced:
    image: nginx
    profiles:
      - " a "
  whitespace:
    image: nginx
    profiles:
      - "   "
  comma:
    image: nginx
    profiles:
      - a,b
  star:
    image: nginx
    profiles:
      - "*"
YAML
profile_default="$(cd "$profile_behavior_dir" && "$binary" config)"
grep -F "defaulted:" <<<"$profile_default" >/dev/null
if grep -F "dot:" <<<"$profile_default" >/dev/null || grep -F "single:" <<<"$profile_default" >/dev/null; then
  echo "expected profiled services to stay out of config output by default" >&2
  exit 1
fi
if grep -F "whitespace:" <<<"$profile_default" >/dev/null || grep -F "comma:" <<<"$profile_default" >/dev/null; then
  echo "expected exact whitespace and comma profiles to stay inactive by default" >&2
  exit 1
fi
profile_dot="$(cd "$profile_behavior_dir" && "$binary" config --profile .bad)"
grep -F "dot:" <<<"$profile_dot" >/dev/null
profile_single="$(cd "$profile_behavior_dir" && "$binary" config --profile a)"
grep -F "single:" <<<"$profile_single" >/dev/null
if grep -F "spaced:" <<<"$profile_single" >/dev/null || grep -F "comma:" <<<"$profile_single" >/dev/null; then
  echo "expected CLI profile values not to trim or comma-split" >&2
  exit 1
fi
profile_spaced="$(cd "$profile_behavior_dir" && "$binary" config --profile ' a ')"
grep -F "spaced:" <<<"$profile_spaced" >/dev/null
if grep -F "single:" <<<"$profile_spaced" >/dev/null; then
  echo "expected exact spaced CLI profile not to activate trimmed profile" >&2
  exit 1
fi
profile_whitespace="$(cd "$profile_behavior_dir" && "$binary" config --profile '   ')"
grep -F "whitespace:" <<<"$profile_whitespace" >/dev/null
profile_comma="$(cd "$profile_behavior_dir" && "$binary" config --profile 'a,b')"
grep -F "comma:" <<<"$profile_comma" >/dev/null
if grep -F "single:" <<<"$profile_comma" >/dev/null || grep -F "beta:" <<<"$profile_comma" >/dev/null; then
  echo "expected comma-containing CLI profile to be exact" >&2
  exit 1
fi
profile_env="$(cd "$profile_behavior_dir" && COMPOSE_PROFILES=' a ,b' "$binary" config)"
grep -F "single:" <<<"$profile_env" >/dev/null
grep -F "beta:" <<<"$profile_env" >/dev/null
if grep -F "spaced:" <<<"$profile_env" >/dev/null || grep -F "comma:" <<<"$profile_env" >/dev/null; then
  echo "expected COMPOSE_PROFILES to trim and split comma-separated values" >&2
  exit 1
fi
profile_star="$(cd "$profile_behavior_dir" && "$binary" config --profile '*')"
grep -F "dot:" <<<"$profile_star" >/dev/null
grep -F "single:" <<<"$profile_star" >/dev/null
grep -F "beta:" <<<"$profile_star" >/dev/null
grep -F "spaced:" <<<"$profile_star" >/dev/null
grep -F "whitespace:" <<<"$profile_star" >/dev/null
grep -F "comma:" <<<"$profile_star" >/dev/null
grep -F "star:" <<<"$profile_star" >/dev/null

bad_profile_shape_dir="$tmpdir/bad-profile-shape"
mkdir -p "$bad_profile_shape_dir"
cat > "$bad_profile_shape_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    profiles: debug
YAML
if (cd "$bad_profile_shape_dir" && "$binary" config >/tmp/apple-compose-bad-profile-shape.out 2>&1); then
  echo "expected scalar profiles to be rejected" >&2
  exit 1
fi
grep -F "profiles must be a list of strings" /tmp/apple-compose-bad-profile-shape.out >/dev/null

bad_profile_entry_shape_dir="$tmpdir/bad-profile-entry-shape"
mkdir -p "$bad_profile_entry_shape_dir"
cat > "$bad_profile_entry_shape_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    profiles:
      - 123
YAML
if (cd "$bad_profile_entry_shape_dir" && "$binary" config >/tmp/apple-compose-bad-profile-entry-shape.out 2>&1); then
  echo "expected non-string profile entries to be rejected" >&2
  exit 1
fi
grep -F "profiles[0] must be a string" /tmp/apple-compose-bad-profile-entry-shape.out >/dev/null

disabled_env_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$extends_dir" "$include_dir" "$envvars_dir" "$disabled_env_dir"' EXIT
cat > "$disabled_env_dir/.env" <<'EOF'
COMPOSE_DISABLE_ENV_FILE=true
COMPOSE_FILE=missing.yaml
APP_TAG=wrong
EOF
cat > "$disabled_env_dir/compose.yaml" <<'YAML'
services:
  app:
    image: example/app:${APP_TAG:-default}
YAML
disabled_env_plan="$(cd "$disabled_env_dir" && "$binary" plan)"
grep -F "example/app:default" <<<"$disabled_env_plan" >/dev/null

project_name_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$extends_dir" "$include_dir" "$envvars_dir" "$disabled_env_dir" "$project_name_dir"' EXIT
cat > "$project_name_dir/compose.yaml" <<'YAML'
name: Top_App
services:
  app:
    image: busybox
    command: echo ${COMPOSE_PROJECT_NAME}
    environment:
      PROJECT_NAME: ${COMPOSE_PROJECT_NAME}
YAML
project_name_plan="$(cd "$project_name_dir" && "$binary" plan)"
grep -F "Project: top_app" <<<"$project_name_plan" >/dev/null
grep -F -- "--env PROJECT_NAME=top_app" <<<"$project_name_plan" >/dev/null
grep -F "busybox echo top_app" <<<"$project_name_plan" >/dev/null

project_name_override_plan="$(cd "$project_name_dir" && "$binary" plan -p Cli_App)"
grep -F "Project: cli_app" <<<"$project_name_override_plan" >/dev/null
grep -F -- "--env PROJECT_NAME=cli_app" <<<"$project_name_override_plan" >/dev/null
grep -F "busybox echo cli_app" <<<"$project_name_override_plan" >/dev/null

multiline_env_dir="$tmpdir/multiline-env"
mkdir -p "$multiline_env_dir"
cat > "$multiline_env_dir/app.env" <<'EOF'
MULTI='alpha
beta'
ESCAPED='Let\'s go!'
EOF
cat > "$multiline_env_dir/.env" <<'EOF'
DOT_MULTI='from-dotenv
line-two'
EOF
cat > "$multiline_env_dir/compose.yaml" <<'YAML'
name: multiline_env
services:
  app:
    image: nginx
    env_file:
      - app.env
    environment:
      FROM_DOTENV: ${DOT_MULTI}
YAML
multiline_env_plan="$(cd "$multiline_env_dir" && "$binary" plan)"
grep -F "multiline_env-app-1" <<<"$multiline_env_plan" >/dev/null
grep -F -- "--env 'MULTI=alpha" <<<"$multiline_env_plan" >/dev/null
grep -F "beta'" <<<"$multiline_env_plan" >/dev/null
grep -F -- "--env 'ESCAPED=Let'\\''s go!'" <<<"$multiline_env_plan" >/dev/null
grep -F -- "--env 'FROM_DOTENV=from-dotenv" <<<"$multiline_env_plan" >/dev/null
grep -F "line-two'" <<<"$multiline_env_plan" >/dev/null
if grep -F -- "--env-file" <<<"$multiline_env_plan" >/dev/null; then
  echo "expected multiline env values to be passed with --env instead of --env-file" >&2
  exit 1
fi

env_resolution_dir="$tmpdir/env-resolution"
mkdir -p "$env_resolution_dir"
cat > "$env_resolution_dir/.env" <<'EOF'
INHERITED_FROM_DOTENV=resolved
HOOK_FROM_DOTENV=hooked
EOF
cat > "$env_resolution_dir/app.env" <<'EOF'
REMOVE_ME=from-file
KEEP_ME='keep
value'
EOF
cat > "$env_resolution_dir/compose.yaml" <<'YAML'
name: env_resolution
services:
  app:
    image: nginx
    env_file:
      - app.env
    environment:
      EXPLICIT_EMPTY: ""
      INHERITED_FROM_DOTENV:
      REMOVE_ME:
    post_start:
      - command: echo hook
        environment:
          HOOK_FROM_DOTENV:
          HOOK_UNRESOLVED:
YAML
env_resolution_plan="$(cd "$env_resolution_dir" && "$binary" plan)"
grep -F -- "--env 'KEEP_ME=keep" <<<"$env_resolution_plan" >/dev/null
grep -F "value'" <<<"$env_resolution_plan" >/dev/null
grep -F -- "--env EXPLICIT_EMPTY=" <<<"$env_resolution_plan" >/dev/null
grep -F -- "--env INHERITED_FROM_DOTENV=resolved" <<<"$env_resolution_plan" >/dev/null
grep -F "container exec --env HOOK_FROM_DOTENV=hooked" <<<"$env_resolution_plan" >/dev/null
if grep -F "REMOVE_ME" <<<"$env_resolution_plan" >/dev/null; then
  echo "expected valueless unresolved service environment to remove env_file value" >&2
  exit 1
fi
if grep -F "HOOK_UNRESOLVED" <<<"$env_resolution_plan" >/dev/null; then
  echo "expected unresolved valueless hook environment to be omitted" >&2
  exit 1
fi
if grep -F -- "--env-file" <<<"$env_resolution_plan" >/dev/null; then
  echo "expected multiline effective env_file values to be passed with --env instead of --env-file" >&2
  exit 1
fi

container_name_dir="$tmpdir/container-name"
mkdir -p "$container_name_dir"
cat > "$container_name_dir/compose.yaml" <<'YAML'
name: container_name_demo
services:
  web:
    image: nginx
    container_name: my-web-container
YAML
container_name_plan="$(cd "$container_name_dir" && "$binary" plan)"
grep -F "container stop --time 10 my-web-container" <<<"$container_name_plan" >/dev/null
grep -F "container delete --force my-web-container" <<<"$container_name_plan" >/dev/null
grep -F "container run --detach --name my-web-container" <<<"$container_name_plan" >/dev/null
if grep -F "container_name_demo-web-1" <<<"$container_name_plan" >/dev/null; then
  echo "expected container_name to replace generated service container name" >&2
  exit 1
fi
container_name_down_plan="$(cd "$container_name_dir" && "$binary" plan --action down)"
grep -F "container stop --time 10 my-web-container" <<<"$container_name_down_plan" >/dev/null
grep -F "container delete --force my-web-container" <<<"$container_name_down_plan" >/dev/null

bad_container_name_dir="$tmpdir/bad-container-name"
mkdir -p "$bad_container_name_dir"
cat > "$bad_container_name_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    container_name: -bad
YAML
if (cd "$bad_container_name_dir" && "$binary" config >/tmp/apple-compose-bad-container-name.out 2>&1); then
  echo "expected config to reject invalid container_name" >&2
  exit 1
fi

grep -F "Service 'web' container_name must match [a-zA-Z0-9][a-zA-Z0-9_.-]+" /tmp/apple-compose-bad-container-name.out >/dev/null

bad_container_name_scale_dir="$tmpdir/bad-container-name-scale"
mkdir -p "$bad_container_name_scale_dir"
cat > "$bad_container_name_scale_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    container_name: fixed-web
    scale: 2
YAML
if (cd "$bad_container_name_scale_dir" && "$binary" config >/tmp/apple-compose-bad-container-name-scale.out 2>&1); then
  echo "expected config to reject container_name with multiple replicas" >&2
  exit 1
fi
grep -F "Service 'web' cannot set container_name when replicas are greater than 1" /tmp/apple-compose-bad-container-name-scale.out >/dev/null

bad_image_shape_dir="$tmpdir/bad-image-shape"
mkdir -p "$bad_image_shape_dir"
cat > "$bad_image_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: true
YAML
if (cd "$bad_image_shape_dir" && "$binary" config >/tmp/apple-compose-bad-image-shape.out 2>&1); then
  echo "expected non-string image values to be rejected" >&2
  exit 1
fi
grep -F "image must be a string" /tmp/apple-compose-bad-image-shape.out >/dev/null

bad_depends_condition_shape_dir="$tmpdir/bad-depends-condition-shape"
mkdir -p "$bad_depends_condition_shape_dir"
cat > "$bad_depends_condition_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    depends_on:
      db:
        condition:
          - service_started
  db:
    image: postgres
YAML
if (cd "$bad_depends_condition_shape_dir" && "$binary" config >/tmp/apple-compose-bad-depends-condition-shape.out 2>&1); then
  echo "expected non-string depends_on condition values to be rejected" >&2
  exit 1
fi
grep -F "depends_on.db.condition must be a string" /tmp/apple-compose-bad-depends-condition-shape.out >/dev/null

bad_depends_condition_value_dir="$tmpdir/bad-depends-condition-value"
mkdir -p "$bad_depends_condition_value_dir"
cat > "$bad_depends_condition_value_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    depends_on:
      db:
        condition: service_waits_forever
  db:
    image: postgres
YAML
if (cd "$bad_depends_condition_value_dir" && "$binary" config >/tmp/apple-compose-bad-depends-condition-value.out 2>&1); then
  echo "expected invalid depends_on condition values to be rejected" >&2
  exit 1
fi
grep -F "depends_on.db.condition must be one of: service_completed_successfully, service_healthy, service_started" /tmp/apple-compose-bad-depends-condition-value.out >/dev/null

bad_depends_key_dir="$tmpdir/bad-depends-key"
mkdir -p "$bad_depends_key_dir"
cat > "$bad_depends_key_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    depends_on:
      db:
        condition: service_started
        timeout: 30s
  db:
    image: postgres
YAML
if (cd "$bad_depends_key_dir" && "$binary" config >/tmp/apple-compose-bad-depends-key.out 2>&1); then
  echo "expected unsupported depends_on keys to be rejected" >&2
  exit 1
fi
grep -F "Service 'web' depends_on.db contains unsupported key 'timeout'" /tmp/apple-compose-bad-depends-key.out >/dev/null

bad_secret_file_shape_dir="$tmpdir/bad-secret-file-shape"
mkdir -p "$bad_secret_file_shape_dir"
cat > "$bad_secret_file_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
secrets:
  app_secret:
    file:
      - secret.txt
YAML
if (cd "$bad_secret_file_shape_dir" && "$binary" config >/tmp/apple-compose-bad-secret-file-shape.out 2>&1); then
  echo "expected non-string secret file values to be rejected" >&2
  exit 1
fi
grep -F "secrets.app_secret.file must be a string" /tmp/apple-compose-bad-secret-file-shape.out >/dev/null

attach_dir="$tmpdir/attach"
mkdir -p "$attach_dir"
cat > "$attach_dir/compose.yaml" <<'YAML'
name: attach_demo
services:
  quiet:
    image: nginx
    attach: "false"
  loud:
    image: nginx
    attach: "true"
YAML
attach_plan="$(cd "$attach_dir" && "$binary" plan)"
grep -F "attach_demo-quiet-1" <<<"$attach_plan" >/dev/null
grep -F "services.loud: attach" <<<"$attach_plan" >/dev/null
if grep -F "services.quiet: attach" <<<"$attach_plan" >/dev/null; then
  echo "expected attach=false to be accepted as detached up behavior" >&2
  exit 1
fi

expose_dir="$tmpdir/expose"
mkdir -p "$expose_dir"
cat > "$expose_dir/compose.yaml" <<'YAML'
name: expose_demo
services:
  api:
    image: nginx
    expose:
      - 8080
      - "9090-9091/udp"
YAML
expose_plan="$(cd "$expose_dir" && "$binary" plan)"
grep -F "expose_demo-api-1" <<<"$expose_plan" >/dev/null
if grep -F "services.api: expose" <<<"$expose_plan" >/dev/null; then
  echo "expected expose to be accepted as intra-network metadata" >&2
  exit 1
fi
if grep -F -- "--publish" <<<"$expose_plan" >/dev/null; then
  echo "expected expose not to publish host ports" >&2
  exit 1
fi

bad_expose_entry_dir="$tmpdir/bad-expose-entry"
mkdir -p "$bad_expose_entry_dir"
cat > "$bad_expose_entry_dir/compose.yaml" <<'YAML'
services:
  api:
    image: nginx
    expose:
      - port: 8080
YAML
if (cd "$bad_expose_entry_dir" && "$binary" config >/tmp/apple-compose-bad-expose-entry.out 2>&1); then
  echo "expected invalid expose entries to be rejected" >&2
  exit 1
fi
grep -F "expose[0] must be a non-empty string or number" /tmp/apple-compose-bad-expose-entry.out >/dev/null

bad_expose_host_dir="$tmpdir/bad-expose-host"
mkdir -p "$bad_expose_host_dir"
cat > "$bad_expose_host_dir/compose.yaml" <<'YAML'
services:
  api:
    image: nginx
    expose:
      - "127.0.0.1:8080"
YAML
if (cd "$bad_expose_host_dir" && "$binary" config >/tmp/apple-compose-bad-expose-host.out 2>&1); then
  echo "expected host-bound expose syntax to be rejected" >&2
  exit 1
fi
grep -F "expose[0] must use container ports only" /tmp/apple-compose-bad-expose-host.out >/dev/null

expose_protocol_dir="$tmpdir/expose-protocol"
mkdir -p "$expose_protocol_dir"
cat > "$expose_protocol_dir/compose.yaml" <<'YAML'
services:
  api:
    image: nginx
    expose:
      - "8080/"
      - "9090/sctp"
      - "10000/custom"
YAML
(cd "$expose_protocol_dir" && "$binary" config >/tmp/apple-compose-expose-protocol.out)
grep -F "8080/" /tmp/apple-compose-expose-protocol.out >/dev/null
grep -F "9090/sctp" /tmp/apple-compose-expose-protocol.out >/dev/null
grep -F "10000/custom" /tmp/apple-compose-expose-protocol.out >/dev/null

disabled_boolean_dir="$tmpdir/disabled-booleans"
mkdir -p "$disabled_boolean_dir"
cat > "$disabled_boolean_dir/compose.yaml" <<'YAML'
name: disabled_booleans
services:
  web:
    image: nginx
    init: "false"
    read_only: "false"
    tty: "false"
    stdin_open: "false"
    oom_kill_disable: "false"
    use_api_socket: false
YAML
disabled_boolean_plan="$(cd "$disabled_boolean_dir" && "$binary" plan)"
grep -F "disabled_booleans-web-1" <<<"$disabled_boolean_plan" >/dev/null
if grep -F "oom_kill_disable" <<<"$disabled_boolean_plan" >/dev/null; then
  echo "expected oom_kill_disable=false to be accepted as default behavior" >&2
  exit 1
fi
if grep -F "use_api_socket" <<<"$disabled_boolean_plan" >/dev/null; then
  echo "expected use_api_socket=false to be accepted as default behavior" >&2
  exit 1
fi

bad_boolean_dir="$tmpdir/bad-booleans"
mkdir -p "$bad_boolean_dir"
cat > "$bad_boolean_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    oom_kill_disable: true
    use_api_socket: true
YAML
if (cd "$bad_boolean_dir" && "$binary" up --dry-run >/tmp/apple-compose-bad-booleans.out 2>&1); then
  echo "expected strict up to reject enabled unsupported booleans" >&2
  exit 1
fi

grep -F "services.web: oom_kill_disable" /tmp/apple-compose-bad-booleans.out >/dev/null
grep -F "services.web: use_api_socket" /tmp/apple-compose-bad-booleans.out >/dev/null

bad_service_boolean_shape_dir="$tmpdir/bad-service-boolean-shape"
mkdir -p "$bad_service_boolean_shape_dir"
cat > "$bad_service_boolean_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    read_only: "maybe"
YAML
if (cd "$bad_service_boolean_shape_dir" && "$binary" config >/tmp/apple-compose-bad-service-boolean-shape.out 2>&1); then
  echo "expected invalid service boolean strings to be rejected" >&2
  exit 1
fi
grep -F "read_only must be a boolean value or boolean string" /tmp/apple-compose-bad-service-boolean-shape.out >/dev/null

bad_attach_boolean_shape_dir="$tmpdir/bad-attach-boolean-shape"
mkdir -p "$bad_attach_boolean_shape_dir"
cat > "$bad_attach_boolean_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    attach: "maybe"
YAML
if (cd "$bad_attach_boolean_shape_dir" && "$binary" config >/tmp/apple-compose-bad-attach-boolean-shape.out 2>&1); then
  echo "expected invalid attach boolean strings to be rejected" >&2
  exit 1
fi
grep -F "attach must be a boolean value or boolean string" /tmp/apple-compose-bad-attach-boolean-shape.out >/dev/null

bad_privileged_boolean_shape_dir="$tmpdir/bad-privileged-boolean-shape"
mkdir -p "$bad_privileged_boolean_shape_dir"
cat > "$bad_privileged_boolean_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    privileged: "maybe"
YAML
if (cd "$bad_privileged_boolean_shape_dir" && "$binary" config >/tmp/apple-compose-bad-privileged-boolean-shape.out 2>&1); then
  echo "expected invalid privileged boolean strings to be rejected" >&2
  exit 1
fi
grep -F "privileged must be a boolean value or boolean string" /tmp/apple-compose-bad-privileged-boolean-shape.out >/dev/null

bad_build_boolean_shape_dir="$tmpdir/bad-build-boolean-shape"
mkdir -p "$bad_build_boolean_shape_dir"
cat > "$bad_build_boolean_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    build:
      context: .
      no_cache: "maybe"
YAML
if (cd "$bad_build_boolean_shape_dir" && "$binary" config >/tmp/apple-compose-bad-build-boolean-shape.out 2>&1); then
  echo "expected invalid build boolean strings to be rejected" >&2
  exit 1
fi
grep -F "build.no_cache must be a boolean value or boolean string" /tmp/apple-compose-bad-build-boolean-shape.out >/dev/null

bad_depends_boolean_shape_dir="$tmpdir/bad-depends-boolean-shape"
mkdir -p "$bad_depends_boolean_shape_dir"
cat > "$bad_depends_boolean_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    depends_on:
      db:
        condition: service_started
        required: "false"
  db:
    image: postgres
YAML
if (cd "$bad_depends_boolean_shape_dir" && "$binary" config >/tmp/apple-compose-bad-depends-boolean-shape.out 2>&1); then
  echo "expected string depends_on booleans to be rejected" >&2
  exit 1
fi
grep -F "depends_on.db.required must be a boolean value" /tmp/apple-compose-bad-depends-boolean-shape.out >/dev/null

disabled_resource_defaults_dir="$tmpdir/disabled-resource-defaults"
mkdir -p "$disabled_resource_defaults_dir"
cat > "$disabled_resource_defaults_dir/compose.yaml" <<'YAML'
name: disabled_resource_defaults
services:
  web:
    image: nginx
    cpu_percent: 0
    cpu_shares: 0
    cpu_period: 0
    cpu_quota: 0
    cpu_rt_runtime: 0
    cpu_rt_period: 0s
    cpuset: ""
    mem_swappiness: 0
    memswap_limit: 0
    pids_limit: -1.0
    oom_score_adj: 0
YAML
disabled_resource_defaults_plan="$(cd "$disabled_resource_defaults_dir" && "$binary" plan)"
grep -F "disabled_resource_defaults-web-1" <<<"$disabled_resource_defaults_plan" >/dev/null
for resource_key in cpu_percent cpu_shares cpu_period cpu_quota cpu_rt_runtime cpu_rt_period cpuset; do
  if grep -F "services.web: $resource_key" <<<"$disabled_resource_defaults_plan" >/dev/null; then
    echo "expected $resource_key default value to be accepted as default behavior" >&2
    exit 1
  fi
done
if grep -F "services.web: memswap_limit" <<<"$disabled_resource_defaults_plan" >/dev/null; then
  echo "expected memswap_limit=0 to be accepted as default behavior" >&2
  exit 1
fi
if grep -F "services.web: mem_swappiness" <<<"$disabled_resource_defaults_plan" >/dev/null; then
  echo "expected mem_swappiness=0 to be accepted as default behavior" >&2
  exit 1
fi
if grep -F "services.web: pids_limit" <<<"$disabled_resource_defaults_plan" >/dev/null; then
  echo "expected pids_limit=-1 to be accepted as default behavior" >&2
  exit 1
fi
if grep -F "services.web: oom_score_adj" <<<"$disabled_resource_defaults_plan" >/dev/null; then
  echo "expected oom_score_adj=0 to be accepted as default behavior" >&2
  exit 1
fi

bad_resource_defaults_dir="$tmpdir/bad-resource-defaults"
mkdir -p "$bad_resource_defaults_dir"
cat > "$bad_resource_defaults_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    mem_swappiness: 1
    memswap_limit: 1g
    pids_limit: 10.5
    oom_score_adj: 500
YAML
if (cd "$bad_resource_defaults_dir" && "$binary" up --dry-run >/tmp/apple-compose-bad-resource-defaults.out 2>&1); then
  echo "expected strict up to reject active unsupported resource defaults" >&2
  exit 1
fi

grep -F "services.web: memswap_limit" /tmp/apple-compose-bad-resource-defaults.out >/dev/null
grep -F "memswap_limit + memory" /tmp/apple-compose-bad-resource-defaults.out >/dev/null
grep -F "services.web: mem_swappiness" /tmp/apple-compose-bad-resource-defaults.out >/dev/null
grep -F "services.web: pids_limit" /tmp/apple-compose-bad-resource-defaults.out >/dev/null
grep -F "services.web: oom_score_adj" /tmp/apple-compose-bad-resource-defaults.out >/dev/null

pids_zero_dir="$tmpdir/pids-zero"
mkdir -p "$pids_zero_dir"
cat > "$pids_zero_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    pids_limit: 0
YAML
pids_zero_plan="$(cd "$pids_zero_dir" && "$binary" plan)"
if grep -F "services.web: pids_limit" <<<"$pids_zero_plan" >/dev/null; then
  echo "expected pids_limit=0 to be accepted as default behavior" >&2
  exit 1
fi

memswap_with_memory_dir="$tmpdir/memswap-with-memory"
mkdir -p "$memswap_with_memory_dir"
cat > "$memswap_with_memory_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    mem_limit: 512M
    memswap_limit: 1g
YAML
if (cd "$memswap_with_memory_dir" && "$binary" up --dry-run >/tmp/apple-compose-memswap-with-memory.out 2>&1); then
  echo "expected strict up to reject unsupported active memswap_limit" >&2
  exit 1
fi
grep -F "services.web: memswap_limit" /tmp/apple-compose-memswap-with-memory.out >/dev/null
if grep -F "memswap_limit + memory" /tmp/apple-compose-memswap-with-memory.out >/dev/null; then
  echo "expected memswap_limit with mem_limit to satisfy Compose memory consistency" >&2
  exit 1
fi

bad_resource_default_shape_dir="$tmpdir/bad-resource-default-shape"
mkdir -p "$bad_resource_default_shape_dir"
cat > "$bad_resource_default_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    memswap_limit: false
YAML
if (cd "$bad_resource_default_shape_dir" && "$binary" config >/tmp/apple-compose-bad-resource-default-shape.out 2>&1); then
  echo "expected boolean memswap_limit to be rejected" >&2
  exit 1
fi
grep -F "memswap_limit must be a string or number" /tmp/apple-compose-bad-resource-default-shape.out >/dev/null

bad_pids_limit_shape_dir="$tmpdir/bad-pids-limit-shape"
mkdir -p "$bad_pids_limit_shape_dir"
cat > "$bad_pids_limit_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    pids_limit:
      count: 10
YAML
if (cd "$bad_pids_limit_shape_dir" && "$binary" config >/tmp/apple-compose-bad-pids-limit-shape.out 2>&1); then
  echo "expected mapping pids_limit to be rejected" >&2
  exit 1
fi
grep -F "pids_limit must be an integer string or number" /tmp/apple-compose-bad-pids-limit-shape.out >/dev/null

bad_pids_limit_string_dir="$tmpdir/bad-pids-limit-string"
mkdir -p "$bad_pids_limit_string_dir"
cat > "$bad_pids_limit_string_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    pids_limit: "10.5"
YAML
if (cd "$bad_pids_limit_string_dir" && "$binary" config >/tmp/apple-compose-bad-pids-limit-string.out 2>&1); then
  echo "expected non-integer pids_limit strings to be rejected" >&2
  exit 1
fi
grep -F "pids_limit must be an integer string or number" /tmp/apple-compose-bad-pids-limit-string.out >/dev/null

bad_oom_score_range_dir="$tmpdir/bad-oom-score-range"
mkdir -p "$bad_oom_score_range_dir"
cat > "$bad_oom_score_range_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    oom_score_adj: 1001
YAML
if (cd "$bad_oom_score_range_dir" && "$binary" config >/tmp/apple-compose-bad-oom-score-range.out 2>&1); then
  echo "expected out-of-range oom_score_adj to be rejected" >&2
  exit 1
fi
grep -F "oom_score_adj must be between -1000 and 1000" /tmp/apple-compose-bad-oom-score-range.out >/dev/null

empty_unsupported_dir="$tmpdir/empty-unsupported"
mkdir -p "$empty_unsupported_dir"
cat > "$empty_unsupported_dir/compose.yaml" <<'YAML'
name: empty_unsupported
models: {}
services:
  web:
    build:
      context: ""
      dockerfile: ""
      dockerfile_inline: ""
      additional_contexts: {}
      entitlements: []
      extra_hosts: []
      isolation: ""
      network: ""
      target: ""
      ssh: []
      ulimits: {}
    devices: []
    device_cgroup_rules: []
    driver_opts: {}
    develop: {}
    blkio_config: {}
    cgroup: ""
    cgroup_parent: ""
    domainname: ""
    external_links: []
    extra_hosts: []
    group_add: []
    hostname: ""
    ipc: ""
    isolation: ""
    logging:
      driver: ""
      options: {}
    links: []
    mac_address: ""
    models: []
    network_mode: ""
    platform: ""
    runtime: ""
    storage_opt: {}
    sysctls: {}
    user: ""
    userns_mode: ""
    uts: ""
    volumes_from: []
    working_dir: ""
YAML
empty_unsupported_plan="$(cd "$empty_unsupported_dir" && "$binary" plan)"
grep -F "empty_unsupported-web-1" <<<"$empty_unsupported_plan" >/dev/null
if grep -F "[error]" <<<"$empty_unsupported_plan" >/dev/null; then
  echo "expected empty known-unsupported values to be accepted as no-ops" >&2
  exit 1
fi
for empty_flag in "--dns-domain" "--file" "--platform" "--runtime" "--target" "--user" "--workdir"; do
  if grep -F -- "$empty_flag" <<<"$empty_unsupported_plan" >/dev/null; then
    echo "expected empty service scalar defaults not to emit $empty_flag" >&2
    exit 1
  fi
done

empty_build_string_dir="$tmpdir/empty-build-string"
mkdir -p "$empty_build_string_dir"
cat > "$empty_build_string_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/web
    build: ""
YAML
empty_build_string_plan="$(cd "$empty_build_string_dir" && "$binary" plan)"
grep -F "empty-build-string-web-1" <<<"$empty_build_string_plan" >/dev/null
if grep -F "[error]" <<<"$empty_build_string_plan" >/dev/null; then
  echo "expected build empty string to use the default build context" >&2
  exit 1
fi

storage_opt_dir="$tmpdir/storage-opt"
mkdir -p "$storage_opt_dir"
cat > "$storage_opt_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    storage_opt:
      size: 1G
      encrypted: true
      nested:
        driver: value
YAML
if (cd "$storage_opt_dir" && "$binary" up --dry-run >/tmp/apple-compose-storage-opt.out 2>&1); then
  echo "expected strict up to reject active storage_opt" >&2
  exit 1
fi
grep -F "services.web: storage_opt" /tmp/apple-compose-storage-opt.out >/dev/null
grep -F "Container storage driver options" /tmp/apple-compose-storage-opt.out >/dev/null

bad_storage_opt_shape_dir="$tmpdir/bad-storage-opt-shape"
mkdir -p "$bad_storage_opt_shape_dir"
cat > "$bad_storage_opt_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    storage_opt: size=1G
YAML
if (cd "$bad_storage_opt_shape_dir" && "$binary" config >/tmp/apple-compose-bad-storage-opt-shape.out 2>&1); then
  echo "expected scalar storage_opt to be rejected" >&2
  exit 1
fi
grep -F "storage_opt must be a mapping" /tmp/apple-compose-bad-storage-opt-shape.out >/dev/null

bad_top_develop_dir="$tmpdir/bad-top-develop"
mkdir -p "$bad_top_develop_dir"
cat > "$bad_top_develop_dir/compose.yaml" <<'YAML'
develop: {}
services:
  web:
    image: nginx
YAML
if (cd "$bad_top_develop_dir" && "$binary" config >/tmp/apple-compose-bad-top-develop.out 2>&1); then
  echo "expected top-level develop to be rejected" >&2
  exit 1
fi
grep -F "compose contains unsupported key 'develop'" /tmp/apple-compose-bad-top-develop.out >/dev/null

bad_empty_unsupported_dir="$tmpdir/bad-empty-unsupported"
mkdir -p "$bad_empty_unsupported_dir"
cat > "$bad_empty_unsupported_dir/compose.yaml" <<'YAML'
services:
  web:
    build:
      context: .
      ssh:
        - default
    devices:
      - /dev/null:/dev/null
      - vendor1.com/device=gpu
YAML
if (cd "$bad_empty_unsupported_dir" && "$binary" up --dry-run >/tmp/apple-compose-bad-empty-unsupported.out 2>&1); then
  echo "expected strict up to reject non-empty unsupported values" >&2
  exit 1
fi

grep -F "services.web: devices" /tmp/apple-compose-bad-empty-unsupported.out >/dev/null
grep -F "services.web.build: ssh" /tmp/apple-compose-bad-empty-unsupported.out >/dev/null

cpu_rt_dir="$tmpdir/cpu-rt"
mkdir -p "$cpu_rt_dir"
cat > "$cpu_rt_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    cpu_rt_runtime: 400ms
    cpu_rt_period: "95000"
YAML
(cd "$cpu_rt_dir" && "$binary" config >/tmp/apple-compose-cpu-rt.out)
cpu_rt_plan="$(cd "$cpu_rt_dir" && "$binary" plan)"
grep -F "services.web: cpu_rt_runtime" <<<"$cpu_rt_plan" >/dev/null
grep -F "services.web: cpu_rt_period" <<<"$cpu_rt_plan" >/dev/null

bad_cpu_rt_dir="$tmpdir/bad-cpu-rt"
mkdir -p "$bad_cpu_rt_dir"
cat > "$bad_cpu_rt_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    cpu_rt_runtime: soon
YAML
if (cd "$bad_cpu_rt_dir" && "$binary" config >/tmp/apple-compose-bad-cpu-rt.out 2>&1); then
  echo "expected invalid realtime CPU duration to be rejected" >&2
  exit 1
fi
grep -F "cpu_rt_runtime must be a non-negative integer microsecond value or Compose duration" /tmp/apple-compose-bad-cpu-rt.out >/dev/null

credential_volumes_from_dir="$tmpdir/credential-volumes-from"
mkdir -p "$credential_volumes_from_dir"
cat > "$credential_volumes_from_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    credential_spec:
      config: gmsa_spec
    volumes_from:
      - db:ro
      - container:legacy:rw
configs:
  gmsa_spec:
    file: ./credential.json
YAML
credential_volumes_from_plan="$(cd "$credential_volumes_from_dir" && "$binary" plan)"
grep -F "services.web: credential_spec" <<<"$credential_volumes_from_plan" >/dev/null
grep -F "services.web: volumes_from" <<<"$credential_volumes_from_plan" >/dev/null

bad_credential_source_dir="$tmpdir/bad-credential-source"
mkdir -p "$bad_credential_source_dir"
cat > "$bad_credential_source_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    credential_spec:
      file: credential.json
      registry: example
YAML
if (cd "$bad_credential_source_dir" && "$binary" config >/tmp/apple-compose-bad-credential-source.out 2>&1); then
  echo "expected multiple credential_spec sources to be rejected" >&2
  exit 1
fi
grep -F "credential_spec can only define one credential source: file, registry" /tmp/apple-compose-bad-credential-source.out >/dev/null

bad_credential_key_dir="$tmpdir/bad-credential-key"
mkdir -p "$bad_credential_key_dir"
cat > "$bad_credential_key_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    credential_spec:
      file: credential.json
      protocol: custom
YAML
if (cd "$bad_credential_key_dir" && "$binary" config >/tmp/apple-compose-bad-credential-key.out 2>&1); then
  echo "expected unsupported credential_spec keys to be rejected" >&2
  exit 1
fi
grep -F "Service 'web' credential_spec contains unsupported key 'protocol'" /tmp/apple-compose-bad-credential-key.out >/dev/null

external_links_dir="$tmpdir/external-links"
mkdir -p "$external_links_dir"
cat > "$external_links_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    external_links:
      - external_db
      - external_cache:cache
YAML
external_links_plan="$(cd "$external_links_dir" && "$binary" plan)"
grep -F "services.web: external_links" <<<"$external_links_plan" >/dev/null
grep -F "Legacy external links are not supported" <<<"$external_links_plan" >/dev/null

bad_external_links_alias_dir="$tmpdir/bad-external-links-alias"
mkdir -p "$bad_external_links_alias_dir"
cat > "$bad_external_links_alias_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    external_links:
      - "external_db:"
YAML
if (cd "$bad_external_links_alias_dir" && "$binary" config >/tmp/apple-compose-bad-external-links-alias.out 2>&1); then
  echo "expected empty external_links alias to be rejected" >&2
  exit 1
fi
grep -F "external_links[0] alias must not be empty" /tmp/apple-compose-bad-external-links-alias.out >/dev/null

bad_volumes_from_access_dir="$tmpdir/bad-volumes-from-access"
mkdir -p "$bad_volumes_from_access_dir"
cat > "$bad_volumes_from_access_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    volumes_from:
      - db:shared
YAML
if (cd "$bad_volumes_from_access_dir" && "$binary" config >/tmp/apple-compose-bad-volumes-from-access.out 2>&1); then
  echo "expected invalid volumes_from access mode to be rejected" >&2
  exit 1
fi
grep -F "volumes_from[0] access mode must be ro or rw" /tmp/apple-compose-bad-volumes-from-access.out >/dev/null

ipc_dir="$tmpdir/ipc"
mkdir -p "$ipc_dir"
cat > "$ipc_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    ipc: shareable
YAML
ipc_plan="$(cd "$ipc_dir" && "$binary" plan)"
grep -F "services.web: ipc" <<<"$ipc_plan" >/dev/null
grep -F "IPC namespace modes are not exposed" <<<"$ipc_plan" >/dev/null

ipc_host_dir="$tmpdir/ipc-host"
mkdir -p "$ipc_host_dir"
cat > "$ipc_host_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    ipc: host
YAML
ipc_host_plan="$(cd "$ipc_host_dir" && "$binary" plan)"
grep -F "services.web: ipc" <<<"$ipc_host_plan" >/dev/null
grep -F "IPC namespace modes are not exposed" <<<"$ipc_host_plan" >/dev/null

bad_ipc_dir="$tmpdir/bad-ipc"
mkdir -p "$bad_ipc_dir"
cat > "$bad_ipc_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    ipc: "service:"
YAML
if (cd "$bad_ipc_dir" && "$binary" config >/tmp/apple-compose-bad-ipc.out 2>&1); then
  echo "expected empty ipc service reference to be rejected" >&2
  exit 1
fi
grep -F "ipc service reference must not be empty" /tmp/apple-compose-bad-ipc.out >/dev/null

ipc_private_dir="$tmpdir/ipc-private"
mkdir -p "$ipc_private_dir"
cat > "$ipc_private_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    ipc: private
YAML
ipc_private_plan="$(cd "$ipc_private_dir" && "$binary" plan)"
grep -F "services.web: ipc" <<<"$ipc_private_plan" >/dev/null
grep -F "IPC namespace modes are not exposed" <<<"$ipc_private_plan" >/dev/null

cgroup_dir="$tmpdir/cgroup"
mkdir -p "$cgroup_dir"
cat > "$cgroup_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    cgroup: private
YAML
cgroup_plan="$(cd "$cgroup_dir" && "$binary" plan)"
grep -F "services.web: cgroup" <<<"$cgroup_plan" >/dev/null
grep -F "Cgroup namespace modes are not exposed" <<<"$cgroup_plan" >/dev/null

bad_cgroup_dir="$tmpdir/bad-cgroup"
mkdir -p "$bad_cgroup_dir"
cat > "$bad_cgroup_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    cgroup: delegated
YAML
if (cd "$bad_cgroup_dir" && "$binary" config >/tmp/apple-compose-bad-cgroup.out 2>&1); then
  echo "expected invalid cgroup value to be rejected" >&2
  exit 1
fi
grep -F "cgroup must be one of: host, private" /tmp/apple-compose-bad-cgroup.out >/dev/null

bad_top_models_shape_dir="$tmpdir/bad-top-models-shape"
mkdir -p "$bad_top_models_shape_dir"
cat > "$bad_top_models_shape_dir/compose.yaml" <<'YAML'
models:
  - llm
services:
  web:
    image: nginx
YAML
if (cd "$bad_top_models_shape_dir" && "$binary" config >/tmp/apple-compose-bad-top-models-shape.out 2>&1); then
  echo "expected invalid top-level models shape to be rejected" >&2
  exit 1
fi
grep -F "Top-level models must be a mapping" /tmp/apple-compose-bad-top-models-shape.out >/dev/null

bad_top_models_null_dir="$tmpdir/bad-top-models-null"
mkdir -p "$bad_top_models_null_dir"
cat > "$bad_top_models_null_dir/compose.yaml" <<'YAML'
models:
services:
  web:
    image: nginx
YAML
if (cd "$bad_top_models_null_dir" && "$binary" config >/tmp/apple-compose-bad-top-models-null.out 2>&1); then
  echo "expected null top-level models to be rejected" >&2
  exit 1
fi
grep -F "Top-level models must be a mapping" /tmp/apple-compose-bad-top-models-null.out >/dev/null

bad_top_models_identifier_dir="$tmpdir/bad-top-models-identifier"
mkdir -p "$bad_top_models_identifier_dir"
cat > "$bad_top_models_identifier_dir/compose.yaml" <<'YAML'
models:
  "bad/model":
    model: ai/smollm2
services:
  web:
    image: nginx
YAML
if (cd "$bad_top_models_identifier_dir" && "$binary" config >/tmp/apple-compose-bad-top-models-identifier.out 2>&1); then
  echo "expected invalid top-level model identifiers to be rejected" >&2
  exit 1
fi
grep -F "Model name 'bad/model' must match [a-zA-Z0-9._-]+" /tmp/apple-compose-bad-top-models-identifier.out >/dev/null

bad_top_model_null_dir="$tmpdir/bad-top-model-null"
mkdir -p "$bad_top_model_null_dir"
cat > "$bad_top_model_null_dir/compose.yaml" <<'YAML'
models:
  llm:
services:
  web:
    image: nginx
YAML
if (cd "$bad_top_model_null_dir" && "$binary" config >/tmp/apple-compose-bad-top-model-null.out 2>&1); then
  echo "expected null top-level model entries to be rejected" >&2
  exit 1
fi
grep -F "models.llm must be a mapping" /tmp/apple-compose-bad-top-model-null.out >/dev/null

bad_service_models_shape_dir="$tmpdir/bad-service-models-shape"
mkdir -p "$bad_service_models_shape_dir"
cat > "$bad_service_models_shape_dir/compose.yaml" <<'YAML'
models:
  llm:
    model: ai/smollm2
services:
  web:
    image: nginx
    models: true
YAML
if (cd "$bad_service_models_shape_dir" && "$binary" config >/tmp/apple-compose-bad-service-models-shape.out 2>&1); then
  echo "expected invalid service models shape to be rejected" >&2
  exit 1
fi
grep -F "models must be a list of strings or mapping" /tmp/apple-compose-bad-service-models-shape.out >/dev/null

bad_service_models_null_dir="$tmpdir/bad-service-models-null"
mkdir -p "$bad_service_models_null_dir"
cat > "$bad_service_models_null_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    models:
YAML
if (cd "$bad_service_models_null_dir" && "$binary" config >/tmp/apple-compose-bad-service-models-null.out 2>&1); then
  echo "expected null service models to be rejected" >&2
  exit 1
fi
grep -F "models must be a list of strings or mapping" /tmp/apple-compose-bad-service-models-null.out >/dev/null

bad_service_models_list_identifier_dir="$tmpdir/bad-service-models-list-identifier"
mkdir -p "$bad_service_models_list_identifier_dir"
cat > "$bad_service_models_list_identifier_dir/compose.yaml" <<'YAML'
models:
  llm:
    model: ai/smollm2
services:
  web:
    image: nginx
    models:
      - "bad/model"
YAML
if (cd "$bad_service_models_list_identifier_dir" && "$binary" config >/tmp/apple-compose-bad-service-models-list-identifier.out 2>&1); then
  echo "expected invalid service model list identifiers to be rejected" >&2
  exit 1
fi
grep -F "Model name 'bad/model' must match [a-zA-Z0-9._-]+" /tmp/apple-compose-bad-service-models-list-identifier.out >/dev/null

bad_service_models_undefined_list_dir="$tmpdir/bad-service-models-undefined-list"
mkdir -p "$bad_service_models_undefined_list_dir"
cat > "$bad_service_models_undefined_list_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    models:
      - llm
YAML
if (cd "$bad_service_models_undefined_list_dir" && "$binary" config >/tmp/apple-compose-bad-service-models-undefined-list.out 2>&1); then
  echo "expected undefined service model list references to be rejected" >&2
  exit 1
fi
grep -F "Service 'web' models references undefined model 'llm'" /tmp/apple-compose-bad-service-models-undefined-list.out >/dev/null

bad_service_models_undefined_map_dir="$tmpdir/bad-service-models-undefined-map"
mkdir -p "$bad_service_models_undefined_map_dir"
cat > "$bad_service_models_undefined_map_dir/compose.yaml" <<'YAML'
models:
  other:
    model: ai/smollm2
services:
  web:
    image: nginx
    models:
      llm:
YAML
if (cd "$bad_service_models_undefined_map_dir" && "$binary" config >/tmp/apple-compose-bad-service-models-undefined-map.out 2>&1); then
  echo "expected undefined service model mapping references to be rejected" >&2
  exit 1
fi
grep -F "Service 'web' models references undefined model 'llm'" /tmp/apple-compose-bad-service-models-undefined-map.out >/dev/null

bad_top_models_missing_model_dir="$tmpdir/bad-top-models-missing-model"
mkdir -p "$bad_top_models_missing_model_dir"
cat > "$bad_top_models_missing_model_dir/compose.yaml" <<'YAML'
models:
  llm:
    context_size: 1024
services:
  web:
    image: nginx
YAML
if (cd "$bad_top_models_missing_model_dir" && "$binary" config >/tmp/apple-compose-bad-top-models-missing-model.out 2>&1); then
  echo "expected top-level model without model to be rejected" >&2
  exit 1
fi
grep -F "models.llm.model is required" /tmp/apple-compose-bad-top-models-missing-model.out >/dev/null

top_models_name_dir="$tmpdir/top-models-name"
mkdir -p "$top_models_name_dir"
cat > "$top_models_name_dir/compose.yaml" <<'YAML'
models:
  llm:
    model: ai/smollm2
    name: chat-model
    context_size: 1024
    runtime_flags:
      - --verbose
services:
  web:
    image: nginx
YAML
(cd "$top_models_name_dir" && "$binary" config >/tmp/apple-compose-top-models-name.out)
if grep -F "models:" /tmp/apple-compose-top-models-name.out >/dev/null; then
  echo "expected unused top-level models to be pruned from config output" >&2
  exit 1
fi

selected_models_config_dir="$tmpdir/selected-models-config"
mkdir -p "$selected_models_config_dir"
cat > "$selected_models_config_dir/compose.yaml" <<'YAML'
models:
  used:
    model: ai/used
  unused:
    model: ai/unused
services:
  web:
    image: nginx
    models:
      - used
  sidecar:
    image: nginx
YAML
(cd "$selected_models_config_dir" && "$binary" config web >/tmp/apple-compose-selected-models-web.out)
grep -F "models:" /tmp/apple-compose-selected-models-web.out >/dev/null
grep -F "used:" /tmp/apple-compose-selected-models-web.out >/dev/null
if grep -F "unused:" /tmp/apple-compose-selected-models-web.out >/dev/null; then
  echo "expected unused model definitions to be pruned from selected config output" >&2
  exit 1
fi
(cd "$selected_models_config_dir" && "$binary" config sidecar >/tmp/apple-compose-selected-models-sidecar.out)
if grep -F "models:" /tmp/apple-compose-selected-models-sidecar.out >/dev/null; then
  echo "expected unreferenced model definitions to be removed for selected services without models" >&2
  exit 1
fi
selected_models_sidecar_plan="$(cd "$selected_models_config_dir" && "$binary" plan sidecar)"
if grep -F "[error]" <<<"$selected_models_sidecar_plan" >/dev/null; then
  echo "expected unrelated top-level models not to affect selected service plans" >&2
  exit 1
fi

bad_top_models_name_shape_dir="$tmpdir/bad-top-models-name-shape"
mkdir -p "$bad_top_models_name_shape_dir"
cat > "$bad_top_models_name_shape_dir/compose.yaml" <<'YAML'
models:
  llm:
    model: ai/smollm2
    name:
      value: chat-model
services:
  web:
    image: nginx
YAML
if (cd "$bad_top_models_name_shape_dir" && "$binary" config >/tmp/apple-compose-bad-top-models-name-shape.out 2>&1); then
  echo "expected invalid top-level model name shape to be rejected" >&2
  exit 1
fi
grep -F "models.llm.name must be a string" /tmp/apple-compose-bad-top-models-name-shape.out >/dev/null

bad_top_models_key_dir="$tmpdir/bad-top-models-key"
mkdir -p "$bad_top_models_key_dir"
cat > "$bad_top_models_key_dir/compose.yaml" <<'YAML'
models:
  llm:
    model: ai/smollm2
    endpoint: http://example.invalid
services:
  web:
    image: nginx
YAML
if (cd "$bad_top_models_key_dir" && "$binary" config >/tmp/apple-compose-bad-top-models-key.out 2>&1); then
  echo "expected unsupported top-level model key to be rejected" >&2
  exit 1
fi
grep -F "models.llm contains unsupported key 'endpoint'" /tmp/apple-compose-bad-top-models-key.out >/dev/null

bad_service_models_identifier_dir="$tmpdir/bad-service-models-identifier"
mkdir -p "$bad_service_models_identifier_dir"
cat > "$bad_service_models_identifier_dir/compose.yaml" <<'YAML'
models:
  llm:
    model: ai/smollm2
services:
  web:
    image: nginx
    models:
      "bad/model":
        endpoint_var: MODEL_URL
YAML
if (cd "$bad_service_models_identifier_dir" && "$binary" config >/tmp/apple-compose-bad-service-models-identifier.out 2>&1); then
  echo "expected invalid service model identifiers to be rejected" >&2
  exit 1
fi
grep -F "Model name 'bad/model' must match [a-zA-Z0-9._-]+" /tmp/apple-compose-bad-service-models-identifier.out >/dev/null

bad_service_models_key_dir="$tmpdir/bad-service-models-key"
mkdir -p "$bad_service_models_key_dir"
cat > "$bad_service_models_key_dir/compose.yaml" <<'YAML'
models:
  llm:
    model: ai/smollm2
services:
  web:
    image: nginx
    models:
      llm:
        endpoint_var: MODEL_URL
        extra: bad
YAML
if (cd "$bad_service_models_key_dir" && "$binary" config >/tmp/apple-compose-bad-service-models-key.out 2>&1); then
  echo "expected unsupported service model key to be rejected" >&2
  exit 1
fi
grep -F "Service 'web' models.llm contains unsupported key 'extra'" /tmp/apple-compose-bad-service-models-key.out >/dev/null

bad_provider_null_dir="$tmpdir/bad-provider-null"
mkdir -p "$bad_provider_null_dir"
cat > "$bad_provider_null_dir/compose.yaml" <<'YAML'
services:
  database:
    provider:
YAML
if (cd "$bad_provider_null_dir" && "$binary" config >/tmp/apple-compose-bad-provider-null.out 2>&1); then
  echo "expected null provider to be rejected" >&2
  exit 1
fi
grep -F "provider must be a mapping" /tmp/apple-compose-bad-provider-null.out >/dev/null

bad_provider_empty_dir="$tmpdir/bad-provider-empty"
mkdir -p "$bad_provider_empty_dir"
cat > "$bad_provider_empty_dir/compose.yaml" <<'YAML'
services:
  database:
    provider: {}
YAML
if (cd "$bad_provider_empty_dir" && "$binary" config >/tmp/apple-compose-bad-provider-empty.out 2>&1); then
  echo "expected empty provider to be rejected" >&2
  exit 1
fi
grep -F "provider.type is required" /tmp/apple-compose-bad-provider-empty.out >/dev/null

bad_provider_extension_only_dir="$tmpdir/bad-provider-extension-only"
mkdir -p "$bad_provider_extension_only_dir"
cat > "$bad_provider_extension_only_dir/compose.yaml" <<'YAML'
services:
  database:
    provider:
      x-note: metadata
YAML
if (cd "$bad_provider_extension_only_dir" && "$binary" config >/tmp/apple-compose-bad-provider-extension-only.out 2>&1); then
  echo "expected provider without type but with extensions to be rejected" >&2
  exit 1
fi
grep -F "provider.type is required" /tmp/apple-compose-bad-provider-extension-only.out >/dev/null

bad_provider_shape_dir="$tmpdir/bad-provider-shape"
mkdir -p "$bad_provider_shape_dir"
cat > "$bad_provider_shape_dir/compose.yaml" <<'YAML'
services:
  database:
    provider:
      options:
        type: mysql
YAML
if (cd "$bad_provider_shape_dir" && "$binary" config >/tmp/apple-compose-bad-provider-shape.out 2>&1); then
  echo "expected provider without type to be rejected" >&2
  exit 1
fi
grep -F "provider.type is required" /tmp/apple-compose-bad-provider-shape.out >/dev/null

bad_provider_type_null_dir="$tmpdir/bad-provider-type-null"
mkdir -p "$bad_provider_type_null_dir"
cat > "$bad_provider_type_null_dir/compose.yaml" <<'YAML'
services:
  database:
    provider:
      type:
YAML
if (cd "$bad_provider_type_null_dir" && "$binary" config >/tmp/apple-compose-bad-provider-type-null.out 2>&1); then
  echo "expected null provider type to be rejected" >&2
  exit 1
fi
grep -F "provider.type must be a string" /tmp/apple-compose-bad-provider-type-null.out >/dev/null

bad_provider_type_number_dir="$tmpdir/bad-provider-type-number"
mkdir -p "$bad_provider_type_number_dir"
cat > "$bad_provider_type_number_dir/compose.yaml" <<'YAML'
services:
  database:
    provider:
      type: 123
YAML
if (cd "$bad_provider_type_number_dir" && "$binary" config >/tmp/apple-compose-bad-provider-type-number.out 2>&1); then
  echo "expected numeric provider type to be rejected" >&2
  exit 1
fi
grep -F "provider.type must be a string" /tmp/apple-compose-bad-provider-type-number.out >/dev/null

provider_empty_type_dir="$tmpdir/provider-empty-type"
mkdir -p "$provider_empty_type_dir"
cat > "$provider_empty_type_dir/compose.yaml" <<'YAML'
name: provider_empty_type
services:
  database:
    image: busybox
    provider:
      type: ""
      options: {}
YAML
(cd "$provider_empty_type_dir" && "$binary" config >/tmp/apple-compose-provider-empty-type.out)
grep -F "type: ''" /tmp/apple-compose-provider-empty-type.out >/dev/null
provider_empty_type_plan="$(cd "$provider_empty_type_dir" && "$binary" plan)"
grep -F "provider_empty_type-database-1" <<<"$provider_empty_type_plan" >/dev/null
if grep -F "[error]" <<<"$provider_empty_type_plan" >/dev/null; then
  echo "expected empty provider metadata to be accepted as default behavior" >&2
  exit 1
fi

bad_provider_key_dir="$tmpdir/bad-provider-key"
mkdir -p "$bad_provider_key_dir"
cat > "$bad_provider_key_dir/compose.yaml" <<'YAML'
services:
  database:
    provider:
      type: awesomecloud
      command: up
YAML
if (cd "$bad_provider_key_dir" && "$binary" config >/tmp/apple-compose-bad-provider-key.out 2>&1); then
  echo "expected unknown provider keys to be rejected" >&2
  exit 1
fi
grep -F "provider contains unsupported key 'command'" /tmp/apple-compose-bad-provider-key.out >/dev/null

provider_options_dir="$tmpdir/provider-options"
mkdir -p "$provider_options_dir"
cat > "$provider_options_dir/compose.yaml" <<'YAML'
services:
  database:
    provider:
      type: awesomecloud
      options:
        engine: mysql
        replicas: 2
        secure: true
        zones:
          - west
          - 1
          - false
YAML
(cd "$provider_options_dir" && "$binary" config >/tmp/apple-compose-provider-options.out)

provider_gap_dir="$tmpdir/provider-gap"
mkdir -p "$provider_gap_dir"
cat > "$provider_gap_dir/compose.yaml" <<'YAML'
services:
  database:
    provider:
      type: awesomecloud
      options:
        engine: mysql
YAML
if (cd "$provider_gap_dir" && "$binary" up --dry-run >/tmp/apple-compose-provider-gap.out 2>&1); then
  echo "expected strict up to reject active provider delegation" >&2
  exit 1
fi
grep -F "services.database: provider" /tmp/apple-compose-provider-gap.out >/dev/null
grep -F "provider delegation" /tmp/apple-compose-provider-gap.out >/dev/null
if grep -F "services.database: image/build" /tmp/apple-compose-provider-gap.out >/dev/null; then
  echo "expected active provider services not to require image/build" >&2
  exit 1
fi
provider_gap_plan="$(cd "$provider_gap_dir" && "$binary" plan)"
grep -F "services.database: provider" <<<"$provider_gap_plan" >/dev/null
if grep -F "container run --detach" <<<"$provider_gap_plan" >/dev/null; then
  echo "expected active provider services to be omitted from generated Apple container commands" >&2
  exit 1
fi

bad_provider_options_shape_dir="$tmpdir/bad-provider-options-shape"
mkdir -p "$bad_provider_options_shape_dir"
cat > "$bad_provider_options_shape_dir/compose.yaml" <<'YAML'
services:
  database:
    provider:
      type: awesomecloud
      options:
        engine:
          name: mysql
YAML
if (cd "$bad_provider_options_shape_dir" && "$binary" config >/tmp/apple-compose-bad-provider-options-shape.out 2>&1); then
  echo "expected invalid provider option shape to be rejected" >&2
  exit 1
fi
grep -F "provider.options.engine must be a string, number, boolean, or list of string/number/boolean values" /tmp/apple-compose-bad-provider-options-shape.out >/dev/null

bad_provider_options_list_shape_dir="$tmpdir/bad-provider-options-list-shape"
mkdir -p "$bad_provider_options_list_shape_dir"
cat > "$bad_provider_options_list_shape_dir/compose.yaml" <<'YAML'
services:
  database:
    provider:
      type: awesomecloud
      options:
        zones:
          - west
          - name: east
YAML
if (cd "$bad_provider_options_list_shape_dir" && "$binary" config >/tmp/apple-compose-bad-provider-options-list-shape.out 2>&1); then
  echo "expected invalid provider option list item shape to be rejected" >&2
  exit 1
fi
grep -F "provider.options.zones[1] must be a string, number, or boolean value" /tmp/apple-compose-bad-provider-options-list-shape.out >/dev/null

bad_develop_shape_dir="$tmpdir/bad-develop-shape"
mkdir -p "$bad_develop_shape_dir"
cat > "$bad_develop_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    develop:
      watch:
        - action: sync
          path: .
          target: /app
          initial_sync: "true"
YAML
if (cd "$bad_develop_shape_dir" && "$binary" config >/tmp/apple-compose-bad-develop-shape.out 2>&1); then
  echo "expected invalid develop watch shape to be rejected" >&2
  exit 1
fi
grep -F "develop.watch[0].initial_sync must be a boolean value" /tmp/apple-compose-bad-develop-shape.out >/dev/null

develop_sync_exec_dir="$tmpdir/develop-sync-exec"
mkdir -p "$develop_sync_exec_dir"
cat > "$develop_sync_exec_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    develop:
      watch:
        - action: sync+exec
          path: ./src
          target: /app/src
          exec:
            command: app reload
            user: "1000"
            privileged: "false"
            working_dir: /app
            environment:
              RELOAD: "1"
YAML
(cd "$develop_sync_exec_dir" && "$binary" config >/tmp/apple-compose-develop-sync-exec.out)

bad_develop_missing_action_dir="$tmpdir/bad-develop-missing-action"
mkdir -p "$bad_develop_missing_action_dir"
cat > "$bad_develop_missing_action_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    develop:
      watch:
        - path: ./src
YAML
if (cd "$bad_develop_missing_action_dir" && "$binary" config >/tmp/apple-compose-bad-develop-missing-action.out 2>&1); then
  echo "expected develop.watch without action to be rejected" >&2
  exit 1
fi
grep -F "develop.watch[0].action is required" /tmp/apple-compose-bad-develop-missing-action.out >/dev/null

bad_develop_missing_path_dir="$tmpdir/bad-develop-missing-path"
mkdir -p "$bad_develop_missing_path_dir"
cat > "$bad_develop_missing_path_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    develop:
      watch:
        - action: rebuild
YAML
if (cd "$bad_develop_missing_path_dir" && "$binary" config >/tmp/apple-compose-bad-develop-missing-path.out 2>&1); then
  echo "expected develop.watch without path to be rejected" >&2
  exit 1
fi
grep -F "develop.watch[0].path is required" /tmp/apple-compose-bad-develop-missing-path.out >/dev/null

develop_restart_no_target_dir="$tmpdir/develop-restart-no-target"
mkdir -p "$develop_restart_no_target_dir"
cat > "$develop_restart_no_target_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    develop:
      watch:
        - action: restart
          path: ./src
YAML
(cd "$develop_restart_no_target_dir" && "$binary" config >/tmp/apple-compose-develop-restart-no-target.out)

bad_develop_sync_missing_target_dir="$tmpdir/bad-develop-sync-missing-target"
mkdir -p "$bad_develop_sync_missing_target_dir"
cat > "$bad_develop_sync_missing_target_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    develop:
      watch:
        - action: sync
          path: ./src
YAML
if (cd "$bad_develop_sync_missing_target_dir" && "$binary" config >/tmp/apple-compose-bad-develop-sync-missing-target.out 2>&1); then
  echo "expected develop.watch sync without target to be rejected" >&2
  exit 1
fi
grep -F "develop.watch[0].target is required for sync" /tmp/apple-compose-bad-develop-sync-missing-target.out >/dev/null

bad_develop_sync_exec_missing_target_dir="$tmpdir/bad-develop-sync-exec-missing-target"
mkdir -p "$bad_develop_sync_exec_missing_target_dir"
cat > "$bad_develop_sync_exec_missing_target_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    develop:
      watch:
        - action: sync+exec
          path: ./src
YAML
if (cd "$bad_develop_sync_exec_missing_target_dir" && "$binary" config >/tmp/apple-compose-bad-develop-sync-exec-missing-target.out 2>&1); then
  echo "expected develop.watch sync+exec without target to be rejected" >&2
  exit 1
fi
grep -F "develop.watch[0].target is required for sync+exec" /tmp/apple-compose-bad-develop-sync-exec-missing-target.out >/dev/null

bad_develop_action_dir="$tmpdir/bad-develop-action"
mkdir -p "$bad_develop_action_dir"
cat > "$bad_develop_action_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    develop:
      watch:
        - action: copy
          path: .
YAML
if (cd "$bad_develop_action_dir" && "$binary" config >/tmp/apple-compose-bad-develop-action.out 2>&1); then
  echo "expected invalid develop.watch action to be rejected" >&2
  exit 1
fi
grep -F "develop.watch[0].action must be one of: rebuild, restart, sync, sync+exec, sync+restart" /tmp/apple-compose-bad-develop-action.out >/dev/null

bad_develop_watch_key_dir="$tmpdir/bad-develop-watch-key"
mkdir -p "$bad_develop_watch_key_dir"
cat > "$bad_develop_watch_key_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    develop:
      watch:
        - action: sync
          path: .
          target: /app
          delay: 1s
YAML
if (cd "$bad_develop_watch_key_dir" && "$binary" config >/tmp/apple-compose-bad-develop-watch-key.out 2>&1); then
  echo "expected unknown develop.watch keys to be rejected" >&2
  exit 1
fi
grep -F "develop.watch[0] contains unsupported key 'delay'" /tmp/apple-compose-bad-develop-watch-key.out >/dev/null

bad_develop_exec_shape_dir="$tmpdir/bad-develop-exec-shape"
mkdir -p "$bad_develop_exec_shape_dir"
cat > "$bad_develop_exec_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    develop:
      watch:
        - action: sync+exec
          path: .
          target: /app
          exec: reload
YAML
if (cd "$bad_develop_exec_shape_dir" && "$binary" config >/tmp/apple-compose-bad-develop-exec-shape.out 2>&1); then
  echo "expected invalid develop.watch exec shape to be rejected" >&2
  exit 1
fi
grep -F "develop.watch[0].exec must be a mapping" /tmp/apple-compose-bad-develop-exec-shape.out >/dev/null

bad_develop_exec_command_dir="$tmpdir/bad-develop-exec-command"
mkdir -p "$bad_develop_exec_command_dir"
cat > "$bad_develop_exec_command_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    develop:
      watch:
        - action: sync+exec
          path: .
          target: /app
          exec:
            user: "1000"
YAML
if (cd "$bad_develop_exec_command_dir" && "$binary" config >/tmp/apple-compose-bad-develop-exec-command.out 2>&1); then
  echo "expected develop.watch exec without command to be rejected" >&2
  exit 1
fi
grep -F "develop.watch[0].exec.command is required" /tmp/apple-compose-bad-develop-exec-command.out >/dev/null

bad_develop_exec_user_shape_dir="$tmpdir/bad-develop-exec-user-shape"
mkdir -p "$bad_develop_exec_user_shape_dir"
cat > "$bad_develop_exec_user_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    develop:
      watch:
        - action: sync+exec
          path: .
          target: /app
          exec:
            command: reload
            user: 1000
YAML
if (cd "$bad_develop_exec_user_shape_dir" && "$binary" config >/tmp/apple-compose-bad-develop-exec-user-shape.out 2>&1); then
  echo "expected numeric develop.watch exec user to be rejected" >&2
  exit 1
fi
grep -F "develop.watch[0].exec.user must be a string" /tmp/apple-compose-bad-develop-exec-user-shape.out >/dev/null

bad_develop_exec_key_dir="$tmpdir/bad-develop-exec-key"
mkdir -p "$bad_develop_exec_key_dir"
cat > "$bad_develop_exec_key_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    develop:
      watch:
        - action: sync+exec
          path: .
          target: /app
          exec:
            command: reload
            timeout: 1s
YAML
if (cd "$bad_develop_exec_key_dir" && "$binary" config >/tmp/apple-compose-bad-develop-exec-key.out 2>&1); then
  echo "expected unknown develop.watch exec keys to be rejected" >&2
  exit 1
fi
grep -F "develop.watch[0].exec contains unsupported key 'timeout'" /tmp/apple-compose-bad-develop-exec-key.out >/dev/null

bad_blkio_shape_dir="$tmpdir/bad-blkio-shape"
mkdir -p "$bad_blkio_shape_dir"
cat > "$bad_blkio_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    blkio_config: []
YAML
if (cd "$bad_blkio_shape_dir" && "$binary" config >/tmp/apple-compose-bad-blkio-shape.out 2>&1); then
  echo "expected invalid blkio_config shape to be rejected" >&2
  exit 1
fi
grep -F "blkio_config must be a mapping" /tmp/apple-compose-bad-blkio-shape.out >/dev/null

bad_blkio_weight_range_dir="$tmpdir/bad-blkio-weight-range"
mkdir -p "$bad_blkio_weight_range_dir"
cat > "$bad_blkio_weight_range_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    blkio_config:
      weight: 5
YAML
if (cd "$bad_blkio_weight_range_dir" && "$binary" config >/tmp/apple-compose-bad-blkio-weight-range.out 2>&1); then
  echo "expected out-of-range blkio_config weight to be rejected" >&2
  exit 1
fi
grep -F "blkio_config.weight must be between 10 and 1000" /tmp/apple-compose-bad-blkio-weight-range.out >/dev/null

bad_blkio_device_shape_dir="$tmpdir/bad-blkio-device-shape"
mkdir -p "$bad_blkio_device_shape_dir"
cat > "$bad_blkio_device_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    blkio_config:
      device_read_bps:
        - path: /dev/sdb
YAML
if (cd "$bad_blkio_device_shape_dir" && "$binary" config >/tmp/apple-compose-bad-blkio-device-shape.out 2>&1); then
  echo "expected incomplete blkio_config device entry to be rejected" >&2
  exit 1
fi
grep -F "blkio_config.device_read_bps[0].rate is required" /tmp/apple-compose-bad-blkio-device-shape.out >/dev/null

bad_blkio_key_dir="$tmpdir/bad-blkio-key"
mkdir -p "$bad_blkio_key_dir"
cat > "$bad_blkio_key_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    blkio_config:
      weight: 100
      burst: 10
YAML
if (cd "$bad_blkio_key_dir" && "$binary" config >/tmp/apple-compose-bad-blkio-key.out 2>&1); then
  echo "expected unsupported blkio_config key to be rejected" >&2
  exit 1
fi
grep -F "Service 'web' blkio_config contains unsupported key 'burst'" /tmp/apple-compose-bad-blkio-key.out >/dev/null

bad_blkio_device_key_dir="$tmpdir/bad-blkio-device-key"
mkdir -p "$bad_blkio_device_key_dir"
cat > "$bad_blkio_device_key_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    blkio_config:
      device_read_bps:
        - path: /dev/sda
          rate: 1mb
          burst: 2mb
YAML
if (cd "$bad_blkio_device_key_dir" && "$binary" config >/tmp/apple-compose-bad-blkio-device-key.out 2>&1); then
  echo "expected unsupported blkio_config device key to be rejected" >&2
  exit 1
fi
grep -F "Service 'web' blkio_config.device_read_bps[0] contains unsupported key 'burst'" /tmp/apple-compose-bad-blkio-device-key.out >/dev/null

blkio_merge_dir="$tmpdir/blkio-merge"
mkdir -p "$blkio_merge_dir"
cat > "$blkio_merge_dir/compose.yaml" <<'YAML'
services:
  base:
    image: nginx
    blkio_config:
      device_read_bps:
        - path: /dev/sda
          rate: 1mb
        - path: /dev/sdb
          rate: 3mb
  web:
    extends:
      service: base
    blkio_config:
      device_read_bps:
        - path: /dev/sda
          rate: 2mb
YAML
(cd "$blkio_merge_dir" && "$binary" config >/tmp/apple-compose-blkio-merge.out)
blkio_merge_web_block="$(awk '/^  web:/{active=1} /^  [^ ]/{if (active && $0 !~ /^  web:/) exit} active {print}' /tmp/apple-compose-blkio-merge.out)"
grep -F "path: /dev/sda" <<<"$blkio_merge_web_block" >/dev/null
grep -F "rate: 2mb" <<<"$blkio_merge_web_block" >/dev/null
grep -F "path: /dev/sdb" <<<"$blkio_merge_web_block" >/dev/null
grep -F "rate: 3mb" <<<"$blkio_merge_web_block" >/dev/null
if grep -F "rate: 1mb" <<<"$blkio_merge_web_block" >/dev/null; then
  echo "expected duplicate blkio_config device entries to merge by path" >&2
  exit 1
fi

bad_devices_shape_dir="$tmpdir/bad-devices-shape"
mkdir -p "$bad_devices_shape_dir"
cat > "$bad_devices_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    devices: /dev/null:/dev/null
YAML
if (cd "$bad_devices_shape_dir" && "$binary" config >/tmp/apple-compose-bad-devices-shape.out 2>&1); then
  echo "expected scalar devices to be rejected" >&2
  exit 1
fi
grep -F "devices must be a list of strings or mappings" /tmp/apple-compose-bad-devices-shape.out >/dev/null

bad_devices_permissions_dir="$tmpdir/bad-devices-permissions"
mkdir -p "$bad_devices_permissions_dir"
cat > "$bad_devices_permissions_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    devices:
      - /dev/null:/dev/null:rx
YAML
if (cd "$bad_devices_permissions_dir" && "$binary" config >/tmp/apple-compose-bad-devices-permissions.out 2>&1); then
  echo "expected invalid devices permissions to be rejected" >&2
  exit 1
fi
grep -F "devices[0] permissions must contain only r, w, and m" /tmp/apple-compose-bad-devices-permissions.out >/dev/null

devices_long_form_dir="$tmpdir/devices-long-form"
mkdir -p "$devices_long_form_dir"
cat > "$devices_long_form_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    devices:
      - source: /dev/null
        target: /dev/xnull
        permissions: r
YAML
(cd "$devices_long_form_dir" && "$binary" config >/tmp/apple-compose-devices-long-form.out)
grep -F "target: /dev/xnull" /tmp/apple-compose-devices-long-form.out >/dev/null
devices_long_form_plan="$(cd "$devices_long_form_dir" && "$binary" plan)"
grep -F "services.web: devices" <<<"$devices_long_form_plan" >/dev/null
grep -F "Device passthrough is not exposed" <<<"$devices_long_form_plan" >/dev/null

bad_devices_long_missing_source_dir="$tmpdir/bad-devices-long-missing-source"
mkdir -p "$bad_devices_long_missing_source_dir"
cat > "$bad_devices_long_missing_source_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    devices:
      - target: /dev/xnull
YAML
if (cd "$bad_devices_long_missing_source_dir" && "$binary" config >/tmp/apple-compose-bad-devices-long-missing-source.out 2>&1); then
  echo "expected long-form devices without source to be rejected" >&2
  exit 1
fi
grep -F "devices[0].source is required" /tmp/apple-compose-bad-devices-long-missing-source.out >/dev/null

bad_devices_long_key_dir="$tmpdir/bad-devices-long-key"
mkdir -p "$bad_devices_long_key_dir"
cat > "$bad_devices_long_key_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    devices:
      - source: /dev/null
        target: /dev/xnull
        mode: r
YAML
if (cd "$bad_devices_long_key_dir" && "$binary" config >/tmp/apple-compose-bad-devices-long-key.out 2>&1); then
  echo "expected unsupported long-form devices keys to be rejected" >&2
  exit 1
fi
grep -F "devices[0] contains unsupported key 'mode'" /tmp/apple-compose-bad-devices-long-key.out >/dev/null

device_merge_dir="$tmpdir/device-merge"
mkdir -p "$device_merge_dir"
cat > "$device_merge_dir/compose.yaml" <<'YAML'
services:
  base:
    image: nginx
    devices:
      - /dev/ttyUSB0:/dev/serial0:rwm
  web:
    extends:
      service: base
    devices:
      - source: /dev/null
        target: /dev/serial0
        permissions: r
YAML
(cd "$device_merge_dir" && "$binary" config >/tmp/apple-compose-device-merge.out)
device_merge_web_block="$(awk '/^  web:/{active=1} /^  [^ ]/{if (active && $0 !~ /^  web:/) exit} active {print}' /tmp/apple-compose-device-merge.out)"
grep -F "target: /dev/serial0" <<<"$device_merge_web_block" >/dev/null
grep -F "source: /dev/null" <<<"$device_merge_web_block" >/dev/null
if grep -F "/dev/ttyUSB0:/dev/serial0:rwm" <<<"$device_merge_web_block" >/dev/null; then
  echo "expected duplicate devices to merge by container target path" >&2
  exit 1
fi

device_cgroup_rules_dir="$tmpdir/device-cgroup-rules"
mkdir -p "$device_cgroup_rules_dir"
cat > "$device_cgroup_rules_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    device_cgroup_rules:
      - 'c 1:3 mr'
      - 'a 7:* rwm'
YAML
device_cgroup_rules_plan="$(cd "$device_cgroup_rules_dir" && "$binary" plan)"
grep -F "services.web: device_cgroup_rules" <<<"$device_cgroup_rules_plan" >/dev/null
grep -F "Device cgroup rules are not exposed" <<<"$device_cgroup_rules_plan" >/dev/null

bad_device_cgroup_rules_dir="$tmpdir/bad-device-cgroup-rules"
mkdir -p "$bad_device_cgroup_rules_dir"
cat > "$bad_device_cgroup_rules_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    device_cgroup_rules:
      - 'z 1:3 mr'
YAML
if (cd "$bad_device_cgroup_rules_dir" && "$binary" config >/tmp/apple-compose-bad-device-cgroup-rules.out 2>&1); then
  echo "expected invalid device_cgroup_rules syntax to be rejected" >&2
  exit 1
fi
grep -F "device_cgroup_rules[0] must use Linux device cgroup rule syntax" /tmp/apple-compose-bad-device-cgroup-rules.out >/dev/null

bad_extra_hosts_shape_dir="$tmpdir/bad-extra-hosts-shape"
mkdir -p "$bad_extra_hosts_shape_dir"
cat > "$bad_extra_hosts_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    extra_hosts: false
YAML
if (cd "$bad_extra_hosts_shape_dir" && "$binary" config >/tmp/apple-compose-bad-extra-hosts-shape.out 2>&1); then
  echo "expected boolean extra_hosts to be rejected" >&2
  exit 1
fi
grep -F "extra_hosts must be a mapping or list of strings" /tmp/apple-compose-bad-extra-hosts-shape.out >/dev/null

extra_hosts_dir="$tmpdir/extra-hosts"
mkdir -p "$extra_hosts_dir"
cat > "$extra_hosts_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    extra_hosts:
      - somehost=162.242.195.82
      - myhostv6=[::1]
      - colonhost:127.0.0.1
YAML
extra_hosts_plan="$(cd "$extra_hosts_dir" && "$binary" plan)"
grep -F "services.web: extra_hosts" <<<"$extra_hosts_plan" >/dev/null
grep -F "Custom /etc/hosts entries are not exposed" <<<"$extra_hosts_plan" >/dev/null

extra_hosts_map_dir="$tmpdir/extra-hosts-map"
mkdir -p "$extra_hosts_map_dir"
cat > "$extra_hosts_map_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    extra_hosts:
      somehost: "162.242.195.82"
      myhostv6: "::1"
YAML
(cd "$extra_hosts_map_dir" && "$binary" config >/tmp/apple-compose-extra-hosts-map.out)

extra_hosts_map_list_dir="$tmpdir/extra-hosts-map-list"
mkdir -p "$extra_hosts_map_list_dir"
cat > "$extra_hosts_map_list_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    extra_hosts:
      somehost:
        - "162.242.195.82"
        - "127.0.0.1"
      myhostv6:
        - "::1"
YAML
(cd "$extra_hosts_map_list_dir" && "$binary" config >/tmp/apple-compose-extra-hosts-map-list.out)

bad_extra_hosts_syntax_dir="$tmpdir/bad-extra-hosts-syntax"
mkdir -p "$bad_extra_hosts_syntax_dir"
cat > "$bad_extra_hosts_syntax_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    extra_hosts:
      - somehost
YAML
if (cd "$bad_extra_hosts_syntax_dir" && "$binary" config >/tmp/apple-compose-bad-extra-hosts-syntax.out 2>&1); then
  echo "expected malformed extra_hosts entry to be rejected" >&2
  exit 1
fi
grep -F "extra_hosts[0] must use HOSTNAME=IP or HOSTNAME:IP syntax" /tmp/apple-compose-bad-extra-hosts-syntax.out >/dev/null

bad_extra_hosts_host_dir="$tmpdir/bad-extra-hosts-host"
mkdir -p "$bad_extra_hosts_host_dir"
cat > "$bad_extra_hosts_host_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    extra_hosts:
      - bad_host=127.0.0.1
YAML
if (cd "$bad_extra_hosts_host_dir" && "$binary" config >/tmp/apple-compose-bad-extra-hosts-host.out 2>&1); then
  echo "expected invalid extra_hosts hostname to be rejected" >&2
  exit 1
fi
grep -F "extra_hosts[0] host must be a valid RFC 1123 hostname" /tmp/apple-compose-bad-extra-hosts-host.out >/dev/null

bad_extra_hosts_ip_dir="$tmpdir/bad-extra-hosts-ip"
mkdir -p "$bad_extra_hosts_ip_dir"
cat > "$bad_extra_hosts_ip_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    extra_hosts:
      somehost: not-an-ip
YAML
if (cd "$bad_extra_hosts_ip_dir" && "$binary" config >/tmp/apple-compose-bad-extra-hosts-ip.out 2>&1); then
  echo "expected invalid extra_hosts IP to be rejected" >&2
  exit 1
fi
grep -F "extra_hosts.somehost must be a valid IPv4 or IPv6 address" /tmp/apple-compose-bad-extra-hosts-ip.out >/dev/null

bad_extra_hosts_map_list_ip_dir="$tmpdir/bad-extra-hosts-map-list-ip"
mkdir -p "$bad_extra_hosts_map_list_ip_dir"
cat > "$bad_extra_hosts_map_list_ip_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    extra_hosts:
      somehost:
        - "127.0.0.1"
        - not-an-ip
YAML
if (cd "$bad_extra_hosts_map_list_ip_dir" && "$binary" config >/tmp/apple-compose-bad-extra-hosts-map-list-ip.out 2>&1); then
  echo "expected invalid extra_hosts IP list entries to be rejected" >&2
  exit 1
fi
grep -F "extra_hosts.somehost[1] must be a valid IPv4 or IPv6 address" /tmp/apple-compose-bad-extra-hosts-map-list-ip.out >/dev/null

sysctls_dir="$tmpdir/sysctls"
mkdir -p "$sysctls_dir"
cat > "$sysctls_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    sysctls:
      - net.core.somaxconn=1024
      - net.ipv4.tcp_syncookies=0
YAML
sysctls_plan="$(cd "$sysctls_dir" && "$binary" plan)"
grep -F "services.web: sysctls" <<<"$sysctls_plan" >/dev/null
grep -F "Linux sysctl injection is not exposed" <<<"$sysctls_plan" >/dev/null

sysctls_map_dir="$tmpdir/sysctls-map"
mkdir -p "$sysctls_map_dir"
cat > "$sysctls_map_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    sysctls:
      net.core.somaxconn: false
      net.ipv4.tcp_syncookies:
YAML
(cd "$sysctls_map_dir" && "$binary" config >/dev/null)

sysctls_list_dir="$tmpdir/sysctls-list"
mkdir -p "$sysctls_list_dir"
cat > "$sysctls_list_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    sysctls:
      - net.core.somaxconn
YAML
(cd "$sysctls_list_dir" && "$binary" config >/dev/null)

bad_sysctls_value_dir="$tmpdir/bad-sysctls-value"
mkdir -p "$bad_sysctls_value_dir"
cat > "$bad_sysctls_value_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    sysctls:
      net.core.somaxconn:
        bad: value
YAML
if (cd "$bad_sysctls_value_dir" && "$binary" config >/tmp/apple-compose-bad-sysctls-value.out 2>&1); then
  echo "expected nested sysctl values to be rejected" >&2
  exit 1
fi
grep -F "sysctls.net.core.somaxconn must be a string, number, boolean, or null value" /tmp/apple-compose-bad-sysctls-value.out >/dev/null

bad_sysctls_scalar_dir="$tmpdir/bad-sysctls-scalar"
mkdir -p "$bad_sysctls_scalar_dir"
cat > "$bad_sysctls_scalar_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    sysctls: net.core.somaxconn=1024
YAML
if (cd "$bad_sysctls_scalar_dir" && "$binary" config >/tmp/apple-compose-bad-sysctls-scalar.out 2>&1); then
  echo "expected scalar sysctls to be rejected" >&2
  exit 1
fi
grep -F "sysctls must be a mapping or list of strings" /tmp/apple-compose-bad-sysctls-scalar.out >/dev/null

group_add_dir="$tmpdir/group-add"
mkdir -p "$group_add_dir"
cat > "$group_add_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    group_add:
      - mail
      - 44.5
YAML
group_add_plan="$(cd "$group_add_dir" && "$binary" plan)"
grep -F "services.web: group_add" <<<"$group_add_plan" >/dev/null
grep -F "Supplementary groups are not exposed" <<<"$group_add_plan" >/dev/null
if (cd "$group_add_dir" && "$binary" up --dry-run >/tmp/apple-compose-group-add.out 2>&1); then
  echo "expected strict up to reject active group_add" >&2
  exit 1
fi
grep -F "services.web: group_add" /tmp/apple-compose-group-add.out >/dev/null

bad_group_add_shape_dir="$tmpdir/bad-group-add-shape"
mkdir -p "$bad_group_add_shape_dir"
cat > "$bad_group_add_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    group_add:
      - name: wheel
YAML
if (cd "$bad_group_add_shape_dir" && "$binary" config >/tmp/apple-compose-bad-group-add-shape.out 2>&1); then
  echo "expected mapping group_add entries to be rejected" >&2
  exit 1
fi
grep -F "group_add[0] must be a non-empty string or number" /tmp/apple-compose-bad-group-add-shape.out >/dev/null

valid_gpus_dir="$tmpdir/valid-gpus"
mkdir -p "$valid_gpus_dir"
cat > "$valid_gpus_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    gpus:
      - driver: nvidia
        count: all
        options:
          virtualization: false
          profile:
YAML
(cd "$valid_gpus_dir" && "$binary" config >/tmp/apple-compose-valid-gpus.out)

valid_gpus_options_list_dir="$tmpdir/valid-gpus-options-list"
mkdir -p "$valid_gpus_options_list_dir"
cat > "$valid_gpus_options_list_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    gpus:
      - driver: nvidia
        options:
          - profile=compute
          - mode=fast
YAML
(cd "$valid_gpus_options_list_dir" && "$binary" config >/tmp/apple-compose-valid-gpus-options-list.out)

bad_gpus_scalar_dir="$tmpdir/bad-gpus-scalar"
mkdir -p "$bad_gpus_scalar_dir"
cat > "$bad_gpus_scalar_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    gpus: some
YAML
if (cd "$bad_gpus_scalar_dir" && "$binary" config >/tmp/apple-compose-bad-gpus-scalar.out 2>&1); then
  echo "expected invalid gpus scalar to be rejected" >&2
  exit 1
fi
grep -F "gpus must be 'all' or a list of device request mappings" /tmp/apple-compose-bad-gpus-scalar.out >/dev/null

bad_gpus_count_dir="$tmpdir/bad-gpus-count"
mkdir -p "$bad_gpus_count_dir"
cat > "$bad_gpus_count_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    gpus:
      - count: many
YAML
if (cd "$bad_gpus_count_dir" && "$binary" config >/tmp/apple-compose-bad-gpus-count.out 2>&1); then
  echo "expected invalid gpus count to be rejected" >&2
  exit 1
fi
grep -F "gpus[0].count must be 'all' or a non-negative integer" /tmp/apple-compose-bad-gpus-count.out >/dev/null

bad_gpus_device_conflict_dir="$tmpdir/bad-gpus-device-conflict"
mkdir -p "$bad_gpus_device_conflict_dir"
cat > "$bad_gpus_device_conflict_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    gpus:
      - count: 1
        device_ids:
          - GPU-f123d1c9
YAML
if (cd "$bad_gpus_device_conflict_dir" && "$binary" config >/tmp/apple-compose-bad-gpus-device-conflict.out 2>&1); then
  echo "expected gpus count/device_ids conflict to be rejected" >&2
  exit 1
fi
grep -F "gpus[0] cannot set both count and device_ids" /tmp/apple-compose-bad-gpus-device-conflict.out >/dev/null

bad_gpus_options_nested_dir="$tmpdir/bad-gpus-options-nested"
mkdir -p "$bad_gpus_options_nested_dir"
cat > "$bad_gpus_options_nested_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    gpus:
      - options:
          nested:
            bad: value
YAML
if (cd "$bad_gpus_options_nested_dir" && "$binary" config >/tmp/apple-compose-bad-gpus-options-nested.out 2>&1); then
  echo "expected nested gpus options to be rejected" >&2
  exit 1
fi
grep -F "gpus[0].options.nested must be a string, number, boolean, or null value" /tmp/apple-compose-bad-gpus-options-nested.out >/dev/null

bad_gpus_key_dir="$tmpdir/bad-gpus-key"
mkdir -p "$bad_gpus_key_dir"
cat > "$bad_gpus_key_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    gpus:
      - driver: nvidia
        count: 1
        vendor: nvidia
YAML
if (cd "$bad_gpus_key_dir" && "$binary" config >/tmp/apple-compose-bad-gpus-key.out 2>&1); then
  echo "expected unsupported gpus request key to be rejected" >&2
  exit 1
fi
grep -F "Service 'web' gpus[0] contains unsupported key 'vendor'" /tmp/apple-compose-bad-gpus-key.out >/dev/null

unsupported_extension_keys_dir="$tmpdir/unsupported-extension-keys"
mkdir -p "$unsupported_extension_keys_dir"
cat > "$unsupported_extension_keys_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    blkio_config:
      x-note: ignored
      device_read_bps:
        - path: /dev/sda
          rate: 1mb
          x-note: ignored
    logging:
      driver: json-file
      x-note: ignored
    gpus:
      - driver: nvidia
        x-note: ignored
YAML
(cd "$unsupported_extension_keys_dir" && "$binary" config >/tmp/apple-compose-unsupported-extension-keys.out)

cpu_number_dir="$tmpdir/cpu-number"
mkdir -p "$cpu_number_dir"
cat > "$cpu_number_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    cpu_shares: 128.5
    cpu_period: "100000"
    cpu_quota: 50000.5
YAML
(cd "$cpu_number_dir" && "$binary" config >/dev/null)

bad_cpu_shape_dir="$tmpdir/bad-cpu-shape"
mkdir -p "$bad_cpu_shape_dir"
cat > "$bad_cpu_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    cpu_shares: true
YAML
if (cd "$bad_cpu_shape_dir" && "$binary" config >/tmp/apple-compose-bad-cpu-shape.out 2>&1); then
  echo "expected boolean cpu_shares to be rejected" >&2
  exit 1
fi
grep -F "cpu_shares must be a string or number" /tmp/apple-compose-bad-cpu-shape.out >/dev/null

bad_cpu_percent_range_dir="$tmpdir/bad-cpu-percent-range"
mkdir -p "$bad_cpu_percent_range_dir"
cat > "$bad_cpu_percent_range_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    cpu_percent: 101
YAML
if (cd "$bad_cpu_percent_range_dir" && "$binary" config >/tmp/apple-compose-bad-cpu-percent-range.out 2>&1); then
  echo "expected out-of-range cpu_percent to be rejected" >&2
  exit 1
fi
grep -F "cpu_percent must be between 0 and 100" /tmp/apple-compose-bad-cpu-percent-range.out >/dev/null

bad_mem_swappiness_range_dir="$tmpdir/bad-mem-swappiness-range"
mkdir -p "$bad_mem_swappiness_range_dir"
cat > "$bad_mem_swappiness_range_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    mem_swappiness: 101
YAML
if (cd "$bad_mem_swappiness_range_dir" && "$binary" config >/tmp/apple-compose-bad-mem-swappiness-range.out 2>&1); then
  echo "expected out-of-range mem_swappiness to be rejected" >&2
  exit 1
fi
grep -F "mem_swappiness must be between 0 and 100" /tmp/apple-compose-bad-mem-swappiness-range.out >/dev/null

bad_logging_shape_dir="$tmpdir/bad-logging-shape"
mkdir -p "$bad_logging_shape_dir"
cat > "$bad_logging_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    logging: []
YAML
if (cd "$bad_logging_shape_dir" && "$binary" config >/tmp/apple-compose-bad-logging-shape.out 2>&1); then
  echo "expected list logging to be rejected" >&2
  exit 1
fi
grep -F "logging must be a mapping" /tmp/apple-compose-bad-logging-shape.out >/dev/null

logging_options_dir="$tmpdir/logging-options"
mkdir -p "$logging_options_dir"
cat > "$logging_options_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    logging:
      driver: json-file
      options:
        max-size: 10m
        max-file: 3
        tag:
YAML
(cd "$logging_options_dir" && "$binary" config >/tmp/apple-compose-logging-options.out)

bad_logging_option_bool_dir="$tmpdir/bad-logging-option-bool"
mkdir -p "$bad_logging_option_bool_dir"
cat > "$bad_logging_option_bool_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    logging:
      driver: json-file
      options:
        compress: true
YAML
if (cd "$bad_logging_option_bool_dir" && "$binary" config >/tmp/apple-compose-bad-logging-option-bool.out 2>&1); then
  echo "expected boolean logging option to be rejected" >&2
  exit 1
fi
grep -F "logging.options.compress must be a string, number, or null value" /tmp/apple-compose-bad-logging-option-bool.out >/dev/null

bad_logging_key_dir="$tmpdir/bad-logging-key"
mkdir -p "$bad_logging_key_dir"
cat > "$bad_logging_key_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    logging:
      driver: json-file
      max-size: 10m
YAML
if (cd "$bad_logging_key_dir" && "$binary" config >/tmp/apple-compose-bad-logging-key.out 2>&1); then
  echo "expected unsupported logging key to be rejected" >&2
  exit 1
fi
grep -F "Service 'web' logging contains unsupported key 'max-size'" /tmp/apple-compose-bad-logging-key.out >/dev/null

disabled_security_dir="$tmpdir/disabled-security"
mkdir -p "$disabled_security_dir"
cat > "$disabled_security_dir/compose.yaml" <<'YAML'
name: disabled_security
services:
  web:
    image: nginx
    security_opt:
      - no-new-privileges=false
      - no-new-privileges:false
YAML
disabled_security_plan="$(cd "$disabled_security_dir" && "$binary" plan)"
grep -F "disabled_security-web-1" <<<"$disabled_security_plan" >/dev/null
if grep -F "services.web: security_opt" <<<"$disabled_security_plan" >/dev/null; then
  echo "expected disabled security_opt forms to be accepted as default behavior" >&2
  exit 1
fi

bad_security_shape_dir="$tmpdir/bad-security-shape"
mkdir -p "$bad_security_shape_dir"
cat > "$bad_security_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    security_opt:
      - no-new-privileges=false
      - label: role
YAML
if (cd "$bad_security_shape_dir" && "$binary" config >/tmp/apple-compose-bad-security-shape.out 2>&1); then
  echo "expected config to reject malformed security_opt entries" >&2
  exit 1
fi

grep -F "security_opt[1] must be a non-empty string" /tmp/apple-compose-bad-security-shape.out >/dev/null

bad_security_scalar_dir="$tmpdir/bad-security-scalar"
mkdir -p "$bad_security_scalar_dir"
cat > "$bad_security_scalar_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    security_opt: no-new-privileges=false
YAML
if (cd "$bad_security_scalar_dir" && "$binary" config >/tmp/apple-compose-bad-security-scalar.out 2>&1); then
  echo "expected config to reject scalar security_opt" >&2
  exit 1
fi

grep -F "security_opt must be a list of strings" /tmp/apple-compose-bad-security-scalar.out >/dev/null

bad_security_dir="$tmpdir/bad-security"
mkdir -p "$bad_security_dir"
cat > "$bad_security_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    security_opt:
      - no-new-privileges
YAML
if (cd "$bad_security_dir" && "$binary" up --dry-run >/tmp/apple-compose-bad-security.out 2>&1); then
  echo "expected strict up to reject active security options" >&2
  exit 1
fi

grep -F "services.web: security_opt" /tmp/apple-compose-bad-security.out >/dev/null

external_resource_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$extends_dir" "$include_dir" "$envvars_dir" "$disabled_env_dir" "$project_name_dir" "$external_resource_dir"' EXIT
cat > "$external_resource_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    networks:
      - outside
    volumes:
      - shared-data:/data
networks:
  outside:
    external: "true"
    name: preexisting_network
volumes:
  shared-data:
    external: "true"
    name: preexisting_volume
YAML
external_resource_plan="$(cd "$external_resource_dir" && "$binary" plan)"
grep -F "container network inspect preexisting_network" <<<"$external_resource_plan" >/dev/null
grep -F "container volume inspect preexisting_volume" <<<"$external_resource_plan" >/dev/null
grep -F -- "--network preexisting_network" <<<"$external_resource_plan" >/dev/null
grep -F "source=preexisting_volume,target=/data" <<<"$external_resource_plan" >/dev/null
if grep -F "network create" <<<"$external_resource_plan" >/dev/null; then
  echo "expected external network not to be created" >&2
  exit 1
fi
if grep -F "volume create" <<<"$external_resource_plan" >/dev/null; then
  echo "expected external volume not to be created" >&2
  exit 1
fi

bad_external_shape_dir="$tmpdir/bad-external-shape"
mkdir -p "$bad_external_shape_dir"
cat > "$bad_external_shape_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    networks:
      - outside
networks:
  outside:
    external: "maybe"
YAML
if (cd "$bad_external_shape_dir" && "$binary" config >/tmp/apple-compose-bad-external-shape.out 2>&1); then
  echo "expected invalid external resource flag string to be rejected" >&2
  exit 1
fi
grep -F "networks.outside.external must be a boolean value or boolean string" /tmp/apple-compose-bad-external-shape.out >/dev/null

bad_external_map_dir="$tmpdir/bad-external-map"
mkdir -p "$bad_external_map_dir"
cat > "$bad_external_map_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    volumes:
      - shared:/data
volumes:
  shared:
    external:
      id: actual-volume
YAML
if (cd "$bad_external_map_dir" && "$binary" config >/tmp/apple-compose-bad-external-map.out 2>&1); then
  echo "expected malformed external resource map to be rejected" >&2
  exit 1
fi
grep -F "volumes.shared.external.name must be a non-empty string" /tmp/apple-compose-bad-external-map.out >/dev/null

bad_external_map_key_dir="$tmpdir/bad-external-map-key"
mkdir -p "$bad_external_map_key_dir"
cat > "$bad_external_map_key_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    configs:
      - shared
configs:
  shared:
    external:
      name: actual-config
      lookup: strict
YAML
if (cd "$bad_external_map_key_dir" && "$binary" config >/tmp/apple-compose-bad-external-map-key.out 2>&1); then
  echo "expected external resource map with unsupported keys to be rejected" >&2
  exit 1
fi
grep -F "configs.shared.external contains unsupported key 'lookup'" /tmp/apple-compose-bad-external-map-key.out >/dev/null

external_name_map_dir="$tmpdir/external-name-map"
mkdir -p "$external_name_map_dir"
cat > "$external_name_map_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    networks:
      - outside
    volumes:
      - shared:/data
networks:
  outside:
    external:
      name: legacy_network
volumes:
  shared:
    name: legacy_volume
    external:
      name: legacy_volume
YAML
external_name_map_plan="$(cd "$external_name_map_dir" && "$binary" plan)"
grep -F "container network inspect legacy_network" <<<"$external_name_map_plan" >/dev/null
grep -F "container volume inspect legacy_volume" <<<"$external_name_map_plan" >/dev/null
grep -F -- "--network legacy_network" <<<"$external_name_map_plan" >/dev/null
grep -F "source=legacy_volume,target=/data" <<<"$external_name_map_plan" >/dev/null

resource_driver_defaults_dir="$tmpdir/resource-driver-defaults"
mkdir -p "$resource_driver_defaults_dir"
cat > "$resource_driver_defaults_dir/compose.yaml" <<'YAML'
name: resource_driver_defaults
services:
  app:
    image: nginx
    networks:
      - empty_net
      - bridge_net
    volumes:
      - empty_volume:/empty
      - default_volume:/default
      - local_volume:/local
networks:
  empty_net:
    driver: ""
  bridge_net:
    driver: bridge
volumes:
  empty_volume:
    driver: ""
  default_volume:
    driver: default
  local_volume:
    driver: local
YAML
resource_driver_defaults_config="$(cd "$resource_driver_defaults_dir" && "$binary" config)"
if grep -F 'driver: ""' <<<"$resource_driver_defaults_config" >/dev/null; then
  echo "expected empty top-level resource drivers to be omitted from normalized config" >&2
  exit 1
fi
resource_driver_defaults_plan="$(cd "$resource_driver_defaults_dir" && "$binary" plan)"
grep -F "container network create" <<<"$resource_driver_defaults_plan" | grep -F "resource_driver_defaults_empty_net" >/dev/null
grep -F "container network create" <<<"$resource_driver_defaults_plan" | grep -F "resource_driver_defaults_bridge_net" >/dev/null
grep -F "container volume create" <<<"$resource_driver_defaults_plan" | grep -F "resource_driver_defaults_empty_volume" >/dev/null
grep -F "container volume create" <<<"$resource_driver_defaults_plan" | grep -F "resource_driver_defaults_default_volume" >/dev/null
grep -F "container volume create" <<<"$resource_driver_defaults_plan" | grep -F "resource_driver_defaults_local_volume" >/dev/null
if grep -F -- "--plugin" <<<"$resource_driver_defaults_plan" >/dev/null; then
  echo "expected empty/default network drivers not to request Apple network plugins" >&2
  exit 1
fi
if grep -F "[error]" <<<"$resource_driver_defaults_plan" >/dev/null; then
  echo "expected empty/default top-level resource drivers to be accepted as defaults" >&2
  exit 1
fi

bad_external_name_conflict_dir="$tmpdir/bad-external-name-conflict"
mkdir -p "$bad_external_name_conflict_dir"
cat > "$bad_external_name_conflict_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    volumes:
      - shared:/data
volumes:
  shared:
    name: top_name
    external:
      name: nested_name
YAML
if (cd "$bad_external_name_conflict_dir" && "$binary" config >/tmp/apple-compose-bad-external-name-conflict.out 2>&1); then
  echo "expected conflicting name/external.name values to be rejected" >&2
  exit 1
fi
grep -F "volumes.shared name and external.name conflict; only use name" /tmp/apple-compose-bad-external-name-conflict.out >/dev/null

bad_resource_shape_dir="$tmpdir/bad-resource-shape"
mkdir -p "$bad_resource_shape_dir"
cat > "$bad_resource_shape_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    networks:
      - badnet
    volumes:
      - badvol:/data
networks:
  badnet: invalid
volumes:
  badvol:
    - invalid
YAML
if (cd "$bad_resource_shape_dir" && "$binary" config >/tmp/apple-compose-bad-resource-shape.out 2>&1); then
  echo "expected invalid top-level resource definitions to be rejected" >&2
  exit 1
fi
grep -F "networks.badnet must be empty or a mapping" /tmp/apple-compose-bad-resource-shape.out >/dev/null

bad_network_identifier_dir="$tmpdir/bad-network-identifier"
mkdir -p "$bad_network_identifier_dir"
cat > "$bad_network_identifier_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
networks:
  "bad/network": {}
YAML
if (cd "$bad_network_identifier_dir" && "$binary" config >/tmp/apple-compose-bad-network-identifier.out 2>&1); then
  echo "expected invalid top-level network identifiers to be rejected" >&2
  exit 1
fi
grep -F "Network name 'bad/network' must match [a-zA-Z0-9._-]+" /tmp/apple-compose-bad-network-identifier.out >/dev/null

bad_network_definition_key_dir="$tmpdir/bad-network-definition-key"
mkdir -p "$bad_network_definition_key_dir"
cat > "$bad_network_definition_key_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    networks:
      - appnet
networks:
  appnet:
    endpoint: local
YAML
if (cd "$bad_network_definition_key_dir" && "$binary" config >/tmp/apple-compose-bad-network-definition-key.out 2>&1); then
  echo "expected unsupported top-level network keys to be rejected" >&2
  exit 1
fi
grep -F "networks.appnet contains unsupported key 'endpoint'" /tmp/apple-compose-bad-network-definition-key.out >/dev/null

bad_volume_shape_dir="$tmpdir/bad-volume-shape"
mkdir -p "$bad_volume_shape_dir"
cat > "$bad_volume_shape_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    volumes:
      - badvol:/data
volumes:
  badvol:
    - invalid
YAML
if (cd "$bad_volume_shape_dir" && "$binary" config >/tmp/apple-compose-bad-volume-shape.out 2>&1); then
  echo "expected invalid top-level volume definition to be rejected" >&2
  exit 1
fi
grep -F "volumes.badvol must be empty or a mapping" /tmp/apple-compose-bad-volume-shape.out >/dev/null

bad_volume_identifier_dir="$tmpdir/bad-volume-identifier"
mkdir -p "$bad_volume_identifier_dir"
cat > "$bad_volume_identifier_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
volumes:
  "bad volume": {}
YAML
if (cd "$bad_volume_identifier_dir" && "$binary" config >/tmp/apple-compose-bad-volume-identifier.out 2>&1); then
  echo "expected invalid top-level volume identifiers to be rejected" >&2
  exit 1
fi
grep -F "Volume name 'bad volume' must match [a-zA-Z0-9._-]+" /tmp/apple-compose-bad-volume-identifier.out >/dev/null

bad_volume_definition_key_dir="$tmpdir/bad-volume-definition-key"
mkdir -p "$bad_volume_definition_key_dir"
cat > "$bad_volume_definition_key_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    volumes:
      - data:/data
volumes:
  data:
    mountpoint: /data
YAML
if (cd "$bad_volume_definition_key_dir" && "$binary" config >/tmp/apple-compose-bad-volume-definition-key.out 2>&1); then
  echo "expected unsupported top-level volume keys to be rejected" >&2
  exit 1
fi
grep -F "volumes.data contains unsupported key 'mountpoint'" /tmp/apple-compose-bad-volume-definition-key.out >/dev/null

bad_volume_driver_dir="$tmpdir/bad-volume-driver"
mkdir -p "$bad_volume_driver_dir"
cat > "$bad_volume_driver_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    volumes:
      - data:/data
volumes:
  data:
    driver: custom
YAML
if (cd "$bad_volume_driver_dir" && "$binary" up --dry-run >/tmp/apple-compose-bad-volume-driver.out 2>&1); then
  echo "expected strict up to reject active top-level volume drivers" >&2
  exit 1
fi
grep -F "volumes.data: driver" /tmp/apple-compose-bad-volume-driver.out >/dev/null
grep -F "Apple container volumes do not expose Docker volume drivers." /tmp/apple-compose-bad-volume-driver.out >/dev/null

bad_secret_shape_dir="$tmpdir/bad-secret-shape"
mkdir -p "$bad_secret_shape_dir"
cat > "$bad_secret_shape_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    secrets:
      - bad_secret
secrets:
  bad_secret: invalid
YAML
if (cd "$bad_secret_shape_dir" && "$binary" config >/tmp/apple-compose-bad-secret-shape.out 2>&1); then
  echo "expected invalid top-level secret definition to be rejected" >&2
  exit 1
fi
grep -F "secrets.bad_secret must be empty or a mapping" /tmp/apple-compose-bad-secret-shape.out >/dev/null

bad_secret_identifier_dir="$tmpdir/bad-secret-identifier"
mkdir -p "$bad_secret_identifier_dir"
cat > "$bad_secret_identifier_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
secrets:
  "bad/secret":
    environment: APP_SECRET
YAML
if (cd "$bad_secret_identifier_dir" && "$binary" config >/tmp/apple-compose-bad-secret-identifier.out 2>&1); then
  echo "expected invalid top-level secret identifiers to be rejected" >&2
  exit 1
fi
grep -F "Secret name 'bad/secret' must match [a-zA-Z0-9._-]+" /tmp/apple-compose-bad-secret-identifier.out >/dev/null

bad_secret_definition_key_dir="$tmpdir/bad-secret-definition-key"
mkdir -p "$bad_secret_definition_key_dir"
cat > "$bad_secret_definition_key_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    secrets:
      - app_secret
secrets:
  app_secret:
    environment: APP_SECRET
    mode: "0400"
YAML
if (cd "$bad_secret_definition_key_dir" && "$binary" config >/tmp/apple-compose-bad-secret-definition-key.out 2>&1); then
  echo "expected unsupported top-level secret keys to be rejected" >&2
  exit 1
fi
grep -F "secrets.app_secret contains unsupported key 'mode'" /tmp/apple-compose-bad-secret-definition-key.out >/dev/null

bad_config_shape_dir="$tmpdir/bad-config-shape"
mkdir -p "$bad_config_shape_dir"
cat > "$bad_config_shape_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    configs:
      - bad_config
configs:
  bad_config: invalid
YAML
if (cd "$bad_config_shape_dir" && "$binary" config >/tmp/apple-compose-bad-config-shape.out 2>&1); then
  echo "expected invalid top-level config definition to be rejected" >&2
  exit 1
fi
grep -F "configs.bad_config must be empty or a mapping" /tmp/apple-compose-bad-config-shape.out >/dev/null

bad_config_identifier_dir="$tmpdir/bad-config-identifier"
mkdir -p "$bad_config_identifier_dir"
cat > "$bad_config_identifier_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
configs:
  "bad config":
    content: ok
YAML
if (cd "$bad_config_identifier_dir" && "$binary" config >/tmp/apple-compose-bad-config-identifier.out 2>&1); then
  echo "expected invalid top-level config identifiers to be rejected" >&2
  exit 1
fi
grep -F "Config name 'bad config' must match [a-zA-Z0-9._-]+" /tmp/apple-compose-bad-config-identifier.out >/dev/null

bad_config_definition_key_dir="$tmpdir/bad-config-definition-key"
mkdir -p "$bad_config_definition_key_dir"
cat > "$bad_config_definition_key_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    configs:
      - app_config
configs:
  app_config:
    content: ok
    driver_opts:
      path: /app
YAML
if (cd "$bad_config_definition_key_dir" && "$binary" config >/tmp/apple-compose-bad-config-definition-key.out 2>&1); then
  echo "expected unsupported top-level config keys to be rejected" >&2
  exit 1
fi
grep -F "configs.app_config contains unsupported key 'driver_opts'" /tmp/apple-compose-bad-config-definition-key.out >/dev/null

bad_ipam_shape_dir="$tmpdir/bad-ipam-shape"
mkdir -p "$bad_ipam_shape_dir"
cat > "$bad_ipam_shape_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    networks:
      - appnet
networks:
  appnet:
    ipam:
      config:
        subnet: 172.28.0.0/16
YAML
if (cd "$bad_ipam_shape_dir" && "$binary" config >/tmp/apple-compose-bad-ipam-shape.out 2>&1); then
  echo "expected invalid IPAM config shape to be rejected" >&2
  exit 1
fi
grep -F "networks.appnet.ipam.config must be a list of mappings" /tmp/apple-compose-bad-ipam-shape.out >/dev/null

bad_ipam_key_dir="$tmpdir/bad-ipam-key"
mkdir -p "$bad_ipam_key_dir"
cat > "$bad_ipam_key_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    networks:
      - appnet
networks:
  appnet:
    ipam:
      allocator: default
YAML
if (cd "$bad_ipam_key_dir" && "$binary" config >/tmp/apple-compose-bad-ipam-key.out 2>&1); then
  echo "expected unsupported IPAM keys to be rejected" >&2
  exit 1
fi
grep -F "networks.appnet.ipam contains unsupported key 'allocator'" /tmp/apple-compose-bad-ipam-key.out >/dev/null

bad_ipam_subnet_shape_dir="$tmpdir/bad-ipam-subnet-shape"
mkdir -p "$bad_ipam_subnet_shape_dir"
cat > "$bad_ipam_subnet_shape_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    networks:
      - appnet
networks:
  appnet:
    ipam:
      config:
        - subnet:
            cidr: 172.28.0.0/16
YAML
if (cd "$bad_ipam_subnet_shape_dir" && "$binary" config >/tmp/apple-compose-bad-ipam-subnet-shape.out 2>&1); then
  echo "expected invalid IPAM subnet shape to be rejected" >&2
  exit 1
fi
grep -F "networks.appnet.ipam.config[0].subnet must be a string" /tmp/apple-compose-bad-ipam-subnet-shape.out >/dev/null

bad_ipam_config_key_dir="$tmpdir/bad-ipam-config-key"
mkdir -p "$bad_ipam_config_key_dir"
cat > "$bad_ipam_config_key_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    networks:
      - appnet
networks:
  appnet:
    ipam:
      config:
        - subnet: 172.28.0.0/16
          dns: 172.28.0.10
YAML
if (cd "$bad_ipam_config_key_dir" && "$binary" config >/tmp/apple-compose-bad-ipam-config-key.out 2>&1); then
  echo "expected unsupported IPAM config keys to be rejected" >&2
  exit 1
fi
grep -F "networks.appnet.ipam.config[0] contains unsupported key 'dns'" /tmp/apple-compose-bad-ipam-config-key.out >/dev/null

bad_ipam_subnet_value_dir="$tmpdir/bad-ipam-subnet-value"
mkdir -p "$bad_ipam_subnet_value_dir"
cat > "$bad_ipam_subnet_value_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    networks:
      - appnet
networks:
  appnet:
    ipam:
      config:
        - subnet: 172.28.0.0
YAML
if (cd "$bad_ipam_subnet_value_dir" && "$binary" config >/tmp/apple-compose-bad-ipam-subnet-value.out 2>&1); then
  echo "expected invalid IPAM subnet values to be rejected" >&2
  exit 1
fi
grep -F "networks.appnet.ipam.config[0].subnet must be a valid IPv4 or IPv6 CIDR range" /tmp/apple-compose-bad-ipam-subnet-value.out >/dev/null

bad_ipam_range_shape_dir="$tmpdir/bad-ipam-range-shape"
mkdir -p "$bad_ipam_range_shape_dir"
cat > "$bad_ipam_range_shape_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    networks:
      - appnet
networks:
  appnet:
    ipam:
      config:
        - subnet: 172.28.0.0/16
          ip_range:
            cidr: 172.28.5.0/24
YAML
if (cd "$bad_ipam_range_shape_dir" && "$binary" config >/tmp/apple-compose-bad-ipam-range-shape.out 2>&1); then
  echo "expected invalid IPAM ip_range shape to be rejected" >&2
  exit 1
fi
grep -F "networks.appnet.ipam.config[0].ip_range must be a string" /tmp/apple-compose-bad-ipam-range-shape.out >/dev/null

bad_ipam_range_value_dir="$tmpdir/bad-ipam-range-value"
mkdir -p "$bad_ipam_range_value_dir"
cat > "$bad_ipam_range_value_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    networks:
      - appnet
networks:
  appnet:
    ipam:
      config:
        - subnet: 172.28.0.0/16
          ip_range: 172.28.5.0/40
YAML
if (cd "$bad_ipam_range_value_dir" && "$binary" config >/tmp/apple-compose-bad-ipam-range-value.out 2>&1); then
  echo "expected invalid IPAM ip_range values to be rejected" >&2
  exit 1
fi
grep -F "networks.appnet.ipam.config[0].ip_range must be a valid IPv4 or IPv6 CIDR range" /tmp/apple-compose-bad-ipam-range-value.out >/dev/null

bad_ipam_aux_shape_dir="$tmpdir/bad-ipam-aux-shape"
mkdir -p "$bad_ipam_aux_shape_dir"
cat > "$bad_ipam_aux_shape_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    networks:
      - appnet
networks:
  appnet:
    ipam:
      config:
        - subnet: 172.28.0.0/16
          aux_addresses:
            host1:
              address: 172.28.1.5
YAML
if (cd "$bad_ipam_aux_shape_dir" && "$binary" config >/tmp/apple-compose-bad-ipam-aux-shape.out 2>&1); then
  echo "expected invalid IPAM aux_addresses shape to be rejected" >&2
  exit 1
fi
grep -F "networks.appnet.ipam.config[0].aux_addresses.host1 must be a string" /tmp/apple-compose-bad-ipam-aux-shape.out >/dev/null

bad_ipam_gateway_value_dir="$tmpdir/bad-ipam-gateway-value"
mkdir -p "$bad_ipam_gateway_value_dir"
cat > "$bad_ipam_gateway_value_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    networks:
      - appnet
networks:
  appnet:
    ipam:
      config:
        - subnet: 172.28.0.0/16
          gateway: 172.28.300.1
YAML
if (cd "$bad_ipam_gateway_value_dir" && "$binary" config >/tmp/apple-compose-bad-ipam-gateway-value.out 2>&1); then
  echo "expected invalid IPAM gateway values to be rejected" >&2
  exit 1
fi
grep -F "networks.appnet.ipam.config[0].gateway must be a valid IPv4 or IPv6 address" /tmp/apple-compose-bad-ipam-gateway-value.out >/dev/null

bad_ipam_aux_value_dir="$tmpdir/bad-ipam-aux-value"
mkdir -p "$bad_ipam_aux_value_dir"
cat > "$bad_ipam_aux_value_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    networks:
      - appnet
networks:
  appnet:
    ipam:
      config:
        - subnet: 172.28.0.0/16
          aux_addresses:
            host1: not-an-ip
YAML
if (cd "$bad_ipam_aux_value_dir" && "$binary" config >/tmp/apple-compose-bad-ipam-aux-value.out 2>&1); then
  echo "expected invalid IPAM aux_addresses values to be rejected" >&2
  exit 1
fi
grep -F "networks.appnet.ipam.config[0].aux_addresses.host1 must be a valid IPv4 or IPv6 address" /tmp/apple-compose-bad-ipam-aux-value.out >/dev/null

ipam_defaults_dir="$tmpdir/ipam-defaults"
mkdir -p "$ipam_defaults_dir"
cat > "$ipam_defaults_dir/compose.yaml" <<'YAML'
name: ipam_defaults
services:
  app:
    image: nginx
    networks:
      - default_driver
      - empty_driver
networks:
  default_driver:
    ipam:
      driver: default
      options: {}
      config:
        - subnet: 172.29.0.0/16
  empty_driver:
    ipam:
      driver: ""
      options: {}
YAML
ipam_defaults_plan="$(cd "$ipam_defaults_dir" && "$binary" plan)"
grep -F "ipam_defaults_default_driver" <<<"$ipam_defaults_plan" >/dev/null
grep -F -- "--subnet 172.29.0.0/16" <<<"$ipam_defaults_plan" >/dev/null
if grep -F "[error]" <<<"$ipam_defaults_plan" >/dev/null; then
  echo "expected default/empty IPAM settings to be accepted as no-ops" >&2
  exit 1
fi

bad_ipam_driver_dir="$tmpdir/bad-ipam-driver"
mkdir -p "$bad_ipam_driver_dir"
cat > "$bad_ipam_driver_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    networks:
      - appnet
networks:
  appnet:
    ipam:
      driver: custom
YAML
if (cd "$bad_ipam_driver_dir" && "$binary" up --dry-run >/tmp/apple-compose-bad-ipam-driver.out 2>&1); then
  echo "expected strict up to reject custom IPAM drivers" >&2
  exit 1
fi
grep -F "networks.appnet.ipam: driver" /tmp/apple-compose-bad-ipam-driver.out >/dev/null
grep -F "Custom IPAM drivers are not exposed" /tmp/apple-compose-bad-ipam-driver.out >/dev/null

ipam_options_dir="$tmpdir/ipam-options"
mkdir -p "$ipam_options_dir"
cat > "$ipam_options_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    networks:
      - appnet
networks:
  appnet:
    ipam:
      options:
        driver-option: "1500"
YAML
(cd "$ipam_options_dir" && "$binary" config >/tmp/apple-compose-ipam-options.out)
if (cd "$ipam_options_dir" && "$binary" up --dry-run >/tmp/apple-compose-ipam-options-gap.out 2>&1); then
  echo "expected strict up to reject custom IPAM options" >&2
  exit 1
fi
grep -F "networks.appnet.ipam: options" /tmp/apple-compose-ipam-options-gap.out >/dev/null
grep -F "Custom IPAM options are not exposed" /tmp/apple-compose-ipam-options-gap.out >/dev/null

bad_ipam_options_shape_dir="$tmpdir/bad-ipam-options-shape"
mkdir -p "$bad_ipam_options_shape_dir"
cat > "$bad_ipam_options_shape_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    networks:
      - appnet
networks:
  appnet:
    ipam:
      options:
        foo:
          bar: baz
YAML
if (cd "$bad_ipam_options_shape_dir" && "$binary" config >/tmp/apple-compose-bad-ipam-options-shape.out 2>&1); then
  echo "expected invalid IPAM options shape to be rejected" >&2
  exit 1
fi
grep -F "networks.appnet.ipam.options.foo must be a string" /tmp/apple-compose-bad-ipam-options-shape.out >/dev/null

bad_ipam_options_value_dir="$tmpdir/bad-ipam-options-value"
mkdir -p "$bad_ipam_options_value_dir"
cat > "$bad_ipam_options_value_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    networks:
      - appnet
networks:
  appnet:
    ipam:
      options:
        mtu: 1500
YAML
if (cd "$bad_ipam_options_value_dir" && "$binary" config >/tmp/apple-compose-bad-ipam-options-value.out 2>&1); then
  echo "expected non-string IPAM option values to be rejected" >&2
  exit 1
fi
grep -F "networks.appnet.ipam.options.mtu must be a string" /tmp/apple-compose-bad-ipam-options-value.out >/dev/null

bad_network_internal_shape_dir="$tmpdir/bad-network-internal-shape"
mkdir -p "$bad_network_internal_shape_dir"
cat > "$bad_network_internal_shape_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    networks:
      - appnet
networks:
  appnet:
    internal: "maybe"
YAML
if (cd "$bad_network_internal_shape_dir" && "$binary" config >/tmp/apple-compose-bad-network-internal-shape.out 2>&1); then
  echo "expected invalid network internal flag string to be rejected" >&2
  exit 1
fi
grep -F "networks.appnet.internal must be a boolean value or boolean string" /tmp/apple-compose-bad-network-internal-shape.out >/dev/null

bad_network_attachable_shape_dir="$tmpdir/bad-network-attachable-shape"
mkdir -p "$bad_network_attachable_shape_dir"
cat > "$bad_network_attachable_shape_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    networks:
      - appnet
networks:
  appnet:
    attachable: "yes"
YAML
if (cd "$bad_network_attachable_shape_dir" && "$binary" config >/tmp/apple-compose-bad-network-attachable-shape.out 2>&1); then
  echo "expected string network attachable flag to be rejected" >&2
  exit 1
fi
grep -F "networks.appnet.attachable must be a boolean value or boolean string" /tmp/apple-compose-bad-network-attachable-shape.out >/dev/null

bad_network_enable_ipv4_shape_dir="$tmpdir/bad-network-enable-ipv4-shape"
mkdir -p "$bad_network_enable_ipv4_shape_dir"
cat > "$bad_network_enable_ipv4_shape_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    networks:
      - appnet
networks:
  appnet:
    enable_ipv4: "off"
YAML
if (cd "$bad_network_enable_ipv4_shape_dir" && "$binary" config >/tmp/apple-compose-bad-network-enable-ipv4-shape.out 2>&1); then
  echo "expected invalid network enable_ipv4 flag string to be rejected" >&2
  exit 1
fi
grep -F "networks.appnet.enable_ipv4 must be a boolean value or boolean string" /tmp/apple-compose-bad-network-enable-ipv4-shape.out >/dev/null

bad_network_enable_ipv4_dir="$tmpdir/bad-network-enable-ipv4"
mkdir -p "$bad_network_enable_ipv4_dir"
cat > "$bad_network_enable_ipv4_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    networks:
      - appnet
networks:
  appnet:
    enable_ipv4: false
YAML
if (cd "$bad_network_enable_ipv4_dir" && "$binary" up --dry-run >/tmp/apple-compose-bad-network-enable-ipv4.out 2>&1); then
  echo "expected strict up to reject disabled network IPv4" >&2
  exit 1
fi
grep -F "networks.appnet: enable_ipv4" /tmp/apple-compose-bad-network-enable-ipv4.out >/dev/null
grep -F "Disabling IPv4 address assignment" /tmp/apple-compose-bad-network-enable-ipv4.out >/dev/null

ipam_dual_stack_dir="$tmpdir/ipam-dual-stack"
mkdir -p "$ipam_dual_stack_dir"
cat > "$ipam_dual_stack_dir/compose.yaml" <<'YAML'
name: ipam_dual_stack
services:
  app:
    image: nginx
    networks:
      - appnet
networks:
  appnet:
    enable_ipv6: "true"
    ipam:
      config:
        - subnet: 172.28.0.0/16
        - subnet: fd00:dead:beef::/64
YAML
ipam_dual_stack_plan="$(cd "$ipam_dual_stack_dir" && "$binary" plan)"
grep -F -- "--subnet 172.28.0.0/16" <<<"$ipam_dual_stack_plan" >/dev/null
grep -F -- "--subnet-v6 fd00:dead:beef::/64" <<<"$ipam_dual_stack_plan" >/dev/null
if grep -F "networks.appnet: ipam.config" <<<"$ipam_dual_stack_plan" >/dev/null; then
  echo "expected one IPv4 plus one IPv6 IPAM subnet to plan without an IPAM compatibility issue" >&2
  exit 1
fi

bad_ipam_enable_ipv6_dir="$tmpdir/bad-ipam-enable-ipv6"
mkdir -p "$bad_ipam_enable_ipv6_dir"
cat > "$bad_ipam_enable_ipv6_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    networks:
      - appnet
networks:
  appnet:
    enable_ipv6: true
    ipam:
      config:
        - subnet: 172.28.0.0/16
YAML
if (cd "$bad_ipam_enable_ipv6_dir" && "$binary" up --dry-run >/tmp/apple-compose-bad-ipam-enable-ipv6.out 2>&1); then
  echo "expected strict up to reject enable_ipv6 without an IPv6 subnet" >&2
  exit 1
fi
grep -F "networks.appnet: enable_ipv6" /tmp/apple-compose-bad-ipam-enable-ipv6.out >/dev/null
grep -F "explicit IPv6 --subnet-v6 prefix" /tmp/apple-compose-bad-ipam-enable-ipv6.out >/dev/null

ipam_duplicate_subnets_dir="$tmpdir/ipam-duplicate-subnets"
mkdir -p "$ipam_duplicate_subnets_dir"
cat > "$ipam_duplicate_subnets_dir/compose.yaml" <<'YAML'
name: ipam_duplicate_subnets
services:
  app:
    image: nginx
    networks:
      - appnet
networks:
  appnet:
    ipam:
      config:
        - subnet: 172.28.0.0/16
        - subnet: 172.29.0.0/16
        - subnet: fd00:dead:beef::/64
        - subnet: fd00:cafe:beef::/64
YAML
ipam_duplicate_subnets_plan="$(cd "$ipam_duplicate_subnets_dir" && "$binary" plan)"
grep -F "networks.appnet: ipam.config" <<<"$ipam_duplicate_subnets_plan" >/dev/null
grep -F "extra IPv4 and IPv6 subnets cannot be applied" <<<"$ipam_duplicate_subnets_plan" >/dev/null
if (cd "$ipam_duplicate_subnets_dir" && "$binary" up --dry-run >/tmp/apple-compose-ipam-duplicate-subnets.out 2>&1); then
  echo "expected strict up to reject extra same-family IPAM subnets" >&2
  exit 1
fi
grep -F "networks.appnet: ipam.config" /tmp/apple-compose-ipam-duplicate-subnets.out >/dev/null

network_plugin_dir="$tmpdir/network-plugin"
mkdir -p "$network_plugin_dir"
cat > "$network_plugin_dir/compose.yaml" <<'YAML'
name: network_plugin
services:
  app:
    image: nginx
    networks:
      - vmnet
  custom:
    image: nginx
    networks:
      - custom
networks:
  vmnet:
    driver: container-network-vmnet
  custom:
    driver: custom-network-plugin
    driver_opts:
      mode: fast
      mtu: "1500"
YAML
network_plugin_plan="$(cd "$network_plugin_dir" && "$binary" plan)"
grep -F "container network create --plugin container-network-vmnet" <<<"$network_plugin_plan" >/dev/null
grep -F "network_plugin_vmnet" <<<"$network_plugin_plan" >/dev/null
grep -F "container network create --plugin custom-network-plugin" <<<"$network_plugin_plan" | grep -F -- "--option mode=fast" | grep -F -- "--option mtu=1500" >/dev/null
grep -F "network_plugin_custom" <<<"$network_plugin_plan" >/dev/null
if (cd "$network_plugin_dir" && "$binary" up --dry-run >/tmp/apple-compose-network-plugin.out 2>&1); then
  :
else
  cat /tmp/apple-compose-network-plugin.out >&2
  echo "expected strict dry-run to accept custom network driver plugins" >&2
  exit 1
fi
if grep -F "networks.custom: driver" /tmp/apple-compose-network-plugin.out >/dev/null; then
  echo "expected custom network driver not to be reported as an Apple gap" >&2
  exit 1
fi

network_mode_none_dir="$tmpdir/network-mode-none"
mkdir -p "$network_mode_none_dir"
cat > "$network_mode_none_dir/compose.yaml" <<'YAML'
name: network_mode_none
services:
  app:
    image: nginx
    network_mode: none
    dns: 1.1.1.1
    domainname: app.example.test
YAML
network_mode_none_plan="$(cd "$network_mode_none_dir" && "$binary" plan)"
grep -F "network_mode_none-app-1" <<<"$network_mode_none_plan" >/dev/null
grep -F -- "--no-dns" <<<"$network_mode_none_plan" >/dev/null
if grep -F "network create" <<<"$network_mode_none_plan" >/dev/null; then
  echo "expected network_mode none not to create implicit default network" >&2
  exit 1
fi
if grep -F -- "--network" <<<"$network_mode_none_plan" >/dev/null; then
  echo "expected network_mode none not to attach a network" >&2
  exit 1
fi
if grep -F -- "--dns 1.1.1.1" <<<"$network_mode_none_plan" >/dev/null; then
  echo "expected network_mode none to suppress DNS configuration" >&2
  exit 1
fi
if grep -F -- "--dns-domain app.example.test" <<<"$network_mode_none_plan" >/dev/null; then
  echo "expected network_mode none to suppress DNS domain configuration" >&2
  exit 1
fi

domainname_dir="$tmpdir/domainname"
mkdir -p "$domainname_dir"
cat > "$domainname_dir/compose.yaml" <<'YAML'
name: domainname_demo
services:
  app:
    image: nginx
    domainname: app.example.test
YAML
domainname_plan="$(cd "$domainname_dir" && "$binary" plan)"
grep -F -- "--dns-domain app.example.test" <<<"$domainname_plan" >/dev/null

bad_domainname_dir="$tmpdir/bad-domainname"
mkdir -p "$bad_domainname_dir"
cat > "$bad_domainname_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    domainname: bad_domain.example.test
YAML
if (cd "$bad_domainname_dir" && "$binary" config >/tmp/apple-compose-bad-domainname.out 2>&1); then
  echo "expected invalid domainname values to be rejected" >&2
  exit 1
fi
grep -F "domainname must be a valid RFC 1123 hostname" /tmp/apple-compose-bad-domainname.out >/dev/null

hostname_dir="$tmpdir/hostname"
mkdir -p "$hostname_dir"
cat > "$hostname_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    hostname: app-host
YAML
hostname_plan="$(cd "$hostname_dir" && "$binary" plan)"
grep -F "services.app: hostname" <<<"$hostname_plan" >/dev/null
grep -F "Container hostname cannot be set" <<<"$hostname_plan" >/dev/null

bad_hostname_dir="$tmpdir/bad-hostname"
mkdir -p "$bad_hostname_dir"
cat > "$bad_hostname_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    hostname: bad_host
YAML
if (cd "$bad_hostname_dir" && "$binary" config >/tmp/apple-compose-bad-hostname.out 2>&1); then
  echo "expected invalid hostname values to be rejected" >&2
  exit 1
fi
grep -F "hostname must be a valid RFC 1123 hostname" /tmp/apple-compose-bad-hostname.out >/dev/null

bad_dns_opt_shape_dir="$tmpdir/bad-dns-opt-shape"
mkdir -p "$bad_dns_opt_shape_dir"
cat > "$bad_dns_opt_shape_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    dns_opt: use-vc
YAML
if (cd "$bad_dns_opt_shape_dir" && "$binary" config >/tmp/apple-compose-bad-dns-opt-shape.out 2>&1); then
  echo "expected scalar dns_opt to be rejected" >&2
  exit 1
fi
grep -F "dns_opt must be a list of strings" /tmp/apple-compose-bad-dns-opt-shape.out >/dev/null

dns_ipv6_dir="$tmpdir/dns-ipv6"
mkdir -p "$dns_ipv6_dir"
cat > "$dns_ipv6_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    dns:
      - 2001:4860:4860::8888
YAML
dns_ipv6_plan="$(cd "$dns_ipv6_dir" && "$binary" plan)"
grep -F -- "--dns 2001:4860:4860::8888" <<<"$dns_ipv6_plan" >/dev/null

bad_dns_value_dir="$tmpdir/bad-dns-value"
mkdir -p "$bad_dns_value_dir"
cat > "$bad_dns_value_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    dns: dns.example.test
YAML
if (cd "$bad_dns_value_dir" && "$binary" config >/tmp/apple-compose-bad-dns-value.out 2>&1); then
  echo "expected non-IP dns value to be rejected" >&2
  exit 1
fi
grep -F "dns must be a valid IPv4 or IPv6 address" /tmp/apple-compose-bad-dns-value.out >/dev/null

bad_dns_entry_shape_dir="$tmpdir/bad-dns-entry-shape"
mkdir -p "$bad_dns_entry_shape_dir"
cat > "$bad_dns_entry_shape_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    dns_opt:
      - true
YAML
if (cd "$bad_dns_entry_shape_dir" && "$binary" config >/tmp/apple-compose-bad-dns-entry-shape.out 2>&1); then
  echo "expected non-string dns_opt entries to be rejected" >&2
  exit 1
fi
grep -F "dns_opt[0] must be a non-empty string" /tmp/apple-compose-bad-dns-entry-shape.out >/dev/null

bad_network_mode_dir="$tmpdir/bad-network-mode"
mkdir -p "$bad_network_mode_dir"
cat > "$bad_network_mode_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    network_mode: host
YAML
if (cd "$bad_network_mode_dir" && "$binary" up --dry-run >/tmp/apple-compose-bad-network-mode.out 2>&1); then
  echo "expected strict up to reject unsupported network_mode values" >&2
  exit 1
fi

grep -F "services.app: network_mode" /tmp/apple-compose-bad-network-mode.out >/dev/null
grep -F "Only network_mode: none" /tmp/apple-compose-bad-network-mode.out >/dev/null

bad_network_mode_ports_dir="$tmpdir/bad-network-mode-ports"
mkdir -p "$bad_network_mode_ports_dir"
cat > "$bad_network_mode_ports_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    network_mode: host
    ports:
      - "8080:80"
YAML
if (cd "$bad_network_mode_ports_dir" && "$binary" up --dry-run >/tmp/apple-compose-bad-network-mode-ports.out 2>&1); then
  echo "expected strict up to reject ports with network_mode host" >&2
  exit 1
fi

grep -F "services.app: network_mode + ports" /tmp/apple-compose-bad-network-mode-ports.out >/dev/null
grep -F "port mappings must not be used with network_mode: host" /tmp/apple-compose-bad-network-mode-ports.out >/dev/null

network_mode_reference_dir="$tmpdir/network-mode-reference"
mkdir -p "$network_mode_reference_dir"
cat > "$network_mode_reference_dir/compose.yaml" <<'YAML'
services:
  db:
    image: nginx
  app:
    image: nginx
    network_mode: service:db
  worker:
    image: nginx
    network_mode: container:external_container
YAML
network_mode_reference_plan="$(cd "$network_mode_reference_dir" && "$binary" plan)"
grep -F "services.app: network_mode" <<<"$network_mode_reference_plan" >/dev/null
grep -F "services.worker: network_mode" <<<"$network_mode_reference_plan" >/dev/null

network_mode_custom_dir="$tmpdir/network-mode-custom"
mkdir -p "$network_mode_custom_dir"
cat > "$network_mode_custom_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    network_mode: customnet
YAML
(cd "$network_mode_custom_dir" && "$binary" config >/tmp/apple-compose-network-mode-custom-config.out)
grep -F "network_mode: customnet" /tmp/apple-compose-network-mode-custom-config.out >/dev/null
if (cd "$network_mode_custom_dir" && "$binary" up --dry-run >/tmp/apple-compose-network-mode-custom.out 2>&1); then
  echo "expected strict up to reject custom network_mode values" >&2
  exit 1
fi
grep -F "services.app: network_mode" /tmp/apple-compose-network-mode-custom.out >/dev/null
grep -F "Only network_mode: none" /tmp/apple-compose-network-mode-custom.out >/dev/null

bad_network_mode_reference_dir="$tmpdir/bad-network-mode-reference"
mkdir -p "$bad_network_mode_reference_dir"
cat > "$bad_network_mode_reference_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    network_mode: "service:"
YAML
if (cd "$bad_network_mode_reference_dir" && "$binary" config >/tmp/apple-compose-bad-network-mode-reference.out 2>&1); then
  echo "expected empty network_mode service reference to be rejected" >&2
  exit 1
fi
grep -F "network_mode service reference must not be empty" /tmp/apple-compose-bad-network-mode-reference.out >/dev/null

bad_network_mode_missing_reference_dir="$tmpdir/bad-network-mode-missing-reference"
mkdir -p "$bad_network_mode_missing_reference_dir"
cat > "$bad_network_mode_missing_reference_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    network_mode: service:missing
YAML
if (cd "$bad_network_mode_missing_reference_dir" && "$binary" config >/tmp/apple-compose-bad-network-mode-missing-reference.out 2>&1); then
  echo "expected undefined network_mode service references to be rejected" >&2
  exit 1
fi
grep -F "Service 'app' depends on service 'missing' which is not defined" /tmp/apple-compose-bad-network-mode-missing-reference.out >/dev/null

bad_namespace_inactive_reference_dir="$tmpdir/bad-namespace-inactive-reference"
mkdir -p "$bad_namespace_inactive_reference_dir"
cat > "$bad_namespace_inactive_reference_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    ipc: service:db
  db:
    image: nginx
    profiles:
      - debug
YAML
if (cd "$bad_namespace_inactive_reference_dir" && "$binary" config >/tmp/apple-compose-bad-namespace-inactive-reference.out 2>&1); then
  echo "expected inactive namespace service references to be rejected" >&2
  exit 1
fi
grep -F "Service 'app' depends on service 'db' which is not defined or not active" /tmp/apple-compose-bad-namespace-inactive-reference.out >/dev/null

bad_pid_reference_dir="$tmpdir/bad-pid-reference"
mkdir -p "$bad_pid_reference_dir"
cat > "$bad_pid_reference_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    pid: "service:"
YAML
if (cd "$bad_pid_reference_dir" && "$binary" config >/tmp/apple-compose-bad-pid-reference.out 2>&1); then
  echo "expected empty pid service references to be rejected" >&2
  exit 1
fi
grep -F "pid service reference must not be empty" /tmp/apple-compose-bad-pid-reference.out >/dev/null

bad_namespace_cycle_dir="$tmpdir/bad-namespace-cycle"
mkdir -p "$bad_namespace_cycle_dir"
cat > "$bad_namespace_cycle_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    pid: service:app
YAML
if (cd "$bad_namespace_cycle_dir" && "$binary" config >/tmp/apple-compose-bad-namespace-cycle.out 2>&1); then
  echo "expected namespace service reference cycles to be rejected" >&2
  exit 1
fi
grep -F "Circular depends_on relationship involving service 'app'" /tmp/apple-compose-bad-namespace-cycle.out >/dev/null

uts_dir="$tmpdir/uts"
mkdir -p "$uts_dir"
cat > "$uts_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    uts: host
YAML
uts_plan="$(cd "$uts_dir" && "$binary" plan)"
grep -F "services.app: uts" <<<"$uts_plan" >/dev/null
grep -F "UTS namespace modes are not exposed" <<<"$uts_plan" >/dev/null

uts_private_dir="$tmpdir/uts-private"
mkdir -p "$uts_private_dir"
cat > "$uts_private_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    uts: private
YAML
uts_private_plan="$(cd "$uts_private_dir" && "$binary" plan)"
grep -F "services.app: uts" <<<"$uts_private_plan" >/dev/null
grep -F "UTS namespace modes are not exposed" <<<"$uts_private_plan" >/dev/null

bad_uts_shape_dir="$tmpdir/bad-uts-shape"
mkdir -p "$bad_uts_shape_dir"
cat > "$bad_uts_shape_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    uts:
      mode: host
YAML
if (cd "$bad_uts_shape_dir" && "$binary" config >/tmp/apple-compose-bad-uts-shape.out 2>&1); then
  echo "expected invalid uts shape to be rejected" >&2
  exit 1
fi
grep -F "uts must be a string" /tmp/apple-compose-bad-uts-shape.out >/dev/null

bad_network_mode_combo_dir="$tmpdir/bad-network-mode-combo"
mkdir -p "$bad_network_mode_combo_dir"
cat > "$bad_network_mode_combo_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    network_mode: none
    networks:
      - default
YAML
if (cd "$bad_network_mode_combo_dir" && "$binary" config >/tmp/apple-compose-bad-network-mode-combo.out 2>&1); then
  echo "expected config to reject network_mode with networks" >&2
  exit 1
fi

grep -F "Service 'app' cannot set both network_mode and networks" /tmp/apple-compose-bad-network-mode-combo.out >/dev/null

bad_external_resource_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$extends_dir" "$include_dir" "$envvars_dir" "$disabled_env_dir" "$project_name_dir" "$external_resource_dir" "$bad_external_resource_dir"' EXIT
cat > "$bad_external_resource_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    networks:
      - outside
networks:
  outside:
    external: true
    name: preexisting_network
    labels:
      com.example.invalid: "yes"
YAML
if (cd "$bad_external_resource_dir" && "$binary" up --dry-run >/tmp/apple-compose-bad-external-resource.out 2>&1); then
  echo "expected strict up to reject local config on external resources" >&2
  exit 1
fi

grep -F "networks.outside" /tmp/apple-compose-bad-external-resource.out >/dev/null
grep -F "labels" /tmp/apple-compose-bad-external-resource.out >/dev/null

bad_reserved_label_dir="$tmpdir/bad-reserved-labels"
mkdir -p "$bad_reserved_label_dir"
cat > "$bad_reserved_label_dir/app.labels" <<'EOF'
com.docker.compose.project=bad
EOF
cat > "$bad_reserved_label_dir/compose.yaml" <<'YAML'
services:
  app:
    image: nginx
    label_file: app.labels
    networks:
      - front
    volumes:
      - data:/data
networks:
  front:
    labels:
      com.docker.compose.network: bad
volumes:
  data:
    labels:
      com.docker.compose.volume: bad
YAML
if (cd "$bad_reserved_label_dir" && "$binary" up --dry-run >/tmp/apple-compose-bad-reserved-labels.out 2>&1); then
  echo "expected strict up to reject reserved Compose labels" >&2
  exit 1
fi

grep -F "services.app: labels" /tmp/apple-compose-bad-reserved-labels.out >/dev/null
grep -F "com.docker.compose.project" /tmp/apple-compose-bad-reserved-labels.out >/dev/null
grep -F "networks.front: labels" /tmp/apple-compose-bad-reserved-labels.out >/dev/null
grep -F "com.docker.compose.network" /tmp/apple-compose-bad-reserved-labels.out >/dev/null
grep -F "volumes.data: labels" /tmp/apple-compose-bad-reserved-labels.out >/dev/null
grep -F "com.docker.compose.volume" /tmp/apple-compose-bad-reserved-labels.out >/dev/null

selection_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$extends_dir" "$include_dir" "$envvars_dir" "$disabled_env_dir" "$project_name_dir" "$external_resource_dir" "$bad_external_resource_dir" "$selection_dir"' EXIT
cat > "$selection_dir/compose.yaml" <<'YAML'
name: select
services:
  db:
    image: example/db
  api:
    image: example/api
    depends_on:
      db:
        condition: service_started
  linked:
    image: example/linked
    links:
      - db
  optional:
    image: example/optional
    depends_on:
      missing:
        condition: service_healthy
        restart: true
        required: false
  no_deps_probe:
    image: example/probe
    depends_on:
      db:
        condition: service_healthy
  worker:
    image: example/worker
    healthcheck:
      test: ["CMD", "true"]
  broken:
    image: example/broken
    depends_on:
      nowhere:
        condition: service_started
networks:
  unused_bad:
    attachable: true
YAML
selected_plan="$(cd "$selection_dir" && "$binary" plan api)"
grep -F "select-db-1" <<<"$selected_plan" >/dev/null
grep -F "select-api-1" <<<"$selected_plan" >/dev/null
if grep -F "select-worker-1" <<<"$selected_plan" >/dev/null; then
  echo "expected unselected service to stay out of selected plan" >&2
  exit 1
fi
selected_link_plan="$(cd "$selection_dir" && "$binary" plan linked)"
grep -F "select-db-1" <<<"$selected_link_plan" >/dev/null
grep -F "select-linked-1" <<<"$selected_link_plan" >/dev/null
if grep -F "[error]" <<<"$selected_link_plan" >/dev/null; then
  echo "expected plain links to be accepted as dependency ordering" >&2
  exit 1
fi
selected_no_deps_plan="$(cd "$selection_dir" && "$binary" plan --no-deps api)"
grep -F "select-api-1" <<<"$selected_no_deps_plan" >/dev/null
if grep -F "select-db-1" <<<"$selected_no_deps_plan" >/dev/null; then
  echo "expected --no-deps selected plan to omit dependencies" >&2
  exit 1
fi
selected_link_no_deps_plan="$(cd "$selection_dir" && "$binary" plan --no-deps linked)"
grep -F "select-linked-1" <<<"$selected_link_no_deps_plan" >/dev/null
grep -F "services.linked.links[0]: selection" <<<"$selected_link_no_deps_plan" >/dev/null
if grep -F "select-db-1" <<<"$selected_link_no_deps_plan" >/dev/null; then
  echo "expected --no-deps selected links plan to omit linked service commands" >&2
  exit 1
fi
optional_plan="$(cd "$selection_dir" && "$binary" plan optional)"
grep -F "select-optional-1" <<<"$optional_plan" >/dev/null
grep -F "services.optional.depends_on.missing: required" <<<"$optional_plan" >/dev/null
if grep -F "Only service_started can be approximated" <<<"$optional_plan" >/dev/null; then
  echo "expected missing optional dependency condition not to be fatal" >&2
  exit 1
fi
if ! (cd "$selection_dir" && "$binary" up --dry-run api >/tmp/apple-compose-selected-up.out 2>&1); then
  cat /tmp/apple-compose-selected-up.out >&2
  echo "expected strict selected up to ignore unsupported unselected services/resources" >&2
  exit 1
fi
grep -F "select-db-1" /tmp/apple-compose-selected-up.out >/dev/null
grep -F "select-api-1" /tmp/apple-compose-selected-up.out >/dev/null
if grep -F "healthcheck" /tmp/apple-compose-selected-up.out >/dev/null; then
  echo "expected unsupported unselected worker healthcheck not to be reported" >&2
  exit 1
fi
if grep -F "networks.unused_bad" /tmp/apple-compose-selected-up.out >/dev/null; then
  echo "expected unsupported unused network settings not to be reported" >&2
  exit 1
fi
if ! (cd "$selection_dir" && "$binary" up --dry-run --no-deps no_deps_probe >/tmp/apple-compose-selected-no-deps.out 2>&1); then
  cat /tmp/apple-compose-selected-no-deps.out >&2
  echo "expected --no-deps to skip unsupported dependency conditions" >&2
  exit 1
fi
grep -F "services.no_deps_probe.depends_on.db: selection" /tmp/apple-compose-selected-no-deps.out >/dev/null
grep -F "select-no_deps_probe-1" /tmp/apple-compose-selected-no-deps.out >/dev/null
if grep -F "select-db-1" /tmp/apple-compose-selected-no-deps.out >/dev/null; then
  echo "expected --no-deps strict up not to include dependency commands" >&2
  exit 1
fi

depends_restart_dir="$tmpdir/depends-restart"
mkdir -p "$depends_restart_dir"
cat > "$depends_restart_dir/compose.yaml" <<'YAML'
services:
  db:
    image: example/db
  web:
    image: example/web
    depends_on:
      db:
        condition: service_started
        restart: true
YAML
if (cd "$depends_restart_dir" && "$binary" up --dry-run >/tmp/apple-compose-depends-restart.out 2>&1); then
  echo "expected strict up to reject depends_on restart propagation" >&2
  exit 1
fi
grep -F "services.web.depends_on.db: restart" /tmp/apple-compose-depends-restart.out >/dev/null
grep -F "dependency restart propagation" /tmp/apple-compose-depends-restart.out >/dev/null

bad_depends_shape_dir="$tmpdir/bad-depends-shape"
mkdir -p "$bad_depends_shape_dir"
cat > "$bad_depends_shape_dir/compose.yaml" <<'YAML'
services:
  db:
    image: example/db
  web:
    image: example/web
    depends_on:
      - db
      - service: cache
YAML
if (cd "$bad_depends_shape_dir" && "$binary" config >/tmp/apple-compose-bad-depends-shape.out 2>&1); then
  echo "expected invalid depends_on list entry to be rejected" >&2
  exit 1
fi
grep -F "depends_on[1] must be a service name" /tmp/apple-compose-bad-depends-shape.out >/dev/null

bad_depends_value_dir="$tmpdir/bad-depends-value"
mkdir -p "$bad_depends_value_dir"
cat > "$bad_depends_value_dir/compose.yaml" <<'YAML'
services:
  db:
    image: example/db
  web:
    image: example/web
    depends_on:
      db: service_healthy
YAML
if (cd "$bad_depends_value_dir" && "$binary" config >/tmp/apple-compose-bad-depends-value.out 2>&1); then
  echo "expected invalid depends_on mapping value to be rejected" >&2
  exit 1
fi
grep -F "depends_on.db must be a mapping" /tmp/apple-compose-bad-depends-value.out >/dev/null

bad_depends_missing_condition_dir="$tmpdir/bad-depends-missing-condition"
mkdir -p "$bad_depends_missing_condition_dir"
cat > "$bad_depends_missing_condition_dir/compose.yaml" <<'YAML'
services:
  db:
    image: example/db
  web:
    image: example/web
    depends_on:
      db:
        required: true
YAML
if (cd "$bad_depends_missing_condition_dir" && "$binary" config >/tmp/apple-compose-bad-depends-missing-condition.out 2>&1); then
  echo "expected long-form depends_on without condition to be rejected" >&2
  exit 1
fi
grep -F "depends_on.db.condition is required" /tmp/apple-compose-bad-depends-missing-condition.out >/dev/null

bad_depends_scalar_dir="$tmpdir/bad-depends-scalar"
mkdir -p "$bad_depends_scalar_dir"
cat > "$bad_depends_scalar_dir/compose.yaml" <<'YAML'
services:
  db:
    image: example/db
  web:
    image: example/web
    depends_on:
      - db
      - true
YAML
if (cd "$bad_depends_scalar_dir" && "$binary" config >/tmp/apple-compose-bad-depends-scalar.out 2>&1); then
  echo "expected non-string depends_on list entry to be rejected" >&2
  exit 1
fi
grep -F "depends_on[1] must be a service name" /tmp/apple-compose-bad-depends-scalar.out >/dev/null

bad_depends_identifier_dir="$tmpdir/bad-depends-identifier"
mkdir -p "$bad_depends_identifier_dir"
cat > "$bad_depends_identifier_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/web
    depends_on:
      "bad/service":
        condition: service_started
YAML
if (cd "$bad_depends_identifier_dir" && "$binary" config >/tmp/apple-compose-bad-depends-identifier.out 2>&1); then
  echo "expected invalid depends_on identifiers to be rejected" >&2
  exit 1
fi
grep -F "Dependency name 'bad/service' must match [a-zA-Z0-9._-]+" /tmp/apple-compose-bad-depends-identifier.out >/dev/null

bad_service_name_dir="$tmpdir/bad-service-name"
mkdir -p "$bad_service_name_dir"
cat > "$bad_service_name_dir/compose.yaml" <<'YAML'
services:
  "bad service":
    image: nginx
YAML
if (cd "$bad_service_name_dir" && "$binary" config >/tmp/apple-compose-bad-service-name.out 2>&1); then
  echo "expected invalid service identifiers to be rejected" >&2
  exit 1
fi
grep -F "Service name 'bad service' must match [a-zA-Z0-9._-]+" /tmp/apple-compose-bad-service-name.out >/dev/null

bad_service_key_dir="$tmpdir/bad-service-key"
mkdir -p "$bad_service_key_dir"
cat > "$bad_service_key_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    typo_restart_policy: always
YAML
if (cd "$bad_service_key_dir" && "$binary" config >/tmp/apple-compose-bad-service-key.out 2>&1); then
  echo "expected unsupported service keys to be rejected" >&2
  exit 1
fi
grep -F "Service 'web' contains unsupported key 'typo_restart_policy'" /tmp/apple-compose-bad-service-key.out >/dev/null

bad_depends_bool_dir="$tmpdir/bad-depends-bool"
mkdir -p "$bad_depends_bool_dir"
cat > "$bad_depends_bool_dir/compose.yaml" <<'YAML'
services:
  db:
    image: example/db
  web:
    image: example/web
    depends_on:
      db:
        condition: service_started
        required:
          nested: invalid
YAML
if (cd "$bad_depends_bool_dir" && "$binary" config >/tmp/apple-compose-bad-depends-bool.out 2>&1); then
  echo "expected invalid depends_on boolean field to be rejected" >&2
  exit 1
fi
grep -F "depends_on.db.required must be a boolean value" /tmp/apple-compose-bad-depends-bool.out >/dev/null

bad_service_scalar_dir="$tmpdir/bad-service-scalar"
mkdir -p "$bad_service_scalar_dir"
cat > "$bad_service_scalar_dir/compose.yaml" <<'YAML'
services:
  web:
    image:
      name: nginx
YAML
if (cd "$bad_service_scalar_dir" && "$binary" config >/tmp/apple-compose-bad-service-scalar.out 2>&1); then
  echo "expected invalid service scalar field to be rejected" >&2
  exit 1
fi
grep -F "Service 'web' image must be a string" /tmp/apple-compose-bad-service-scalar.out >/dev/null

bad_service_bool_dir="$tmpdir/bad-service-bool"
mkdir -p "$bad_service_bool_dir"
cat > "$bad_service_bool_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    init:
      enabled: true
YAML
if (cd "$bad_service_bool_dir" && "$binary" config >/tmp/apple-compose-bad-service-bool.out 2>&1); then
  echo "expected invalid service boolean field to be rejected" >&2
  exit 1
fi
grep -F "Service 'web' init must be a boolean value or boolean string" /tmp/apple-compose-bad-service-bool.out >/dev/null

bad_scale_shape_dir="$tmpdir/bad-scale-shape"
mkdir -p "$bad_scale_shape_dir"
cat > "$bad_scale_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    scale: 1.5
YAML
if (cd "$bad_scale_shape_dir" && "$binary" config >/tmp/apple-compose-bad-scale-shape.out 2>&1); then
  echo "expected non-integer scale to be rejected" >&2
  exit 1
fi
grep -F "Service 'web' scale must be an integer value" /tmp/apple-compose-bad-scale-shape.out >/dev/null

negative_scale_shape_dir="$tmpdir/negative-scale-shape"
mkdir -p "$negative_scale_shape_dir"
cat > "$negative_scale_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    scale: -1
YAML
if (cd "$negative_scale_shape_dir" && "$binary" config >/tmp/apple-compose-negative-scale-shape.out 2>&1); then
  echo "expected negative scale to be rejected" >&2
  exit 1
fi
grep -F "Service 'web' scale must be zero or a positive integer" /tmp/apple-compose-negative-scale-shape.out >/dev/null

negative_deploy_replicas_shape_dir="$tmpdir/negative-deploy-replicas-shape"
mkdir -p "$negative_deploy_replicas_shape_dir"
cat > "$negative_deploy_replicas_shape_dir/compose.yaml" <<'YAML'
services:
  worker:
    image: nginx
    deploy:
      replicas: -2
YAML
if (cd "$negative_deploy_replicas_shape_dir" && "$binary" config >/tmp/apple-compose-negative-deploy-replicas-shape.out 2>&1); then
  echo "expected negative deploy.replicas to be rejected" >&2
  exit 1
fi
grep -F "Service 'worker' deploy.replicas must be zero or a positive integer" /tmp/apple-compose-negative-deploy-replicas-shape.out >/dev/null

bad_build_context_shape_dir="$tmpdir/bad-build-context-shape"
mkdir -p "$bad_build_context_shape_dir"
cat > "$bad_build_context_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    build:
      context:
        - .
YAML
if (cd "$bad_build_context_shape_dir" && "$binary" config >/tmp/apple-compose-bad-build-context-shape.out 2>&1); then
  echo "expected invalid build.context shape to be rejected" >&2
  exit 1
fi
grep -F "Service 'web' build.context must be a string" /tmp/apple-compose-bad-build-context-shape.out >/dev/null

bad_links_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$extends_dir" "$include_dir" "$envvars_dir" "$disabled_env_dir" "$selection_dir" "$bad_depends_shape_dir" "$bad_depends_value_dir" "$bad_links_dir"' EXIT
cat > "$bad_links_dir/compose.yaml" <<'YAML'
services:
  db:
    image: example/db
  web:
    image: example/web
    links:
      - db:database
YAML
if (cd "$bad_links_dir" && "$binary" up --dry-run >/tmp/apple-compose-bad-links.out 2>&1); then
  echo "expected strict up to reject link aliases" >&2
  exit 1
fi
grep -F "services.web.links[0]: alias" /tmp/apple-compose-bad-links.out >/dev/null

bad_link_empty_alias_dir="$tmpdir/bad-link-empty-alias"
mkdir -p "$bad_link_empty_alias_dir"
cat > "$bad_link_empty_alias_dir/compose.yaml" <<'YAML'
services:
  db:
    image: example/db
  web:
    image: example/web
    links:
      - "db:"
YAML
if (cd "$bad_link_empty_alias_dir" && "$binary" config >/tmp/apple-compose-bad-link-empty-alias.out 2>&1); then
  echo "expected empty link aliases to be rejected" >&2
  exit 1
fi
grep -F "Service 'web' links alias must not be empty" /tmp/apple-compose-bad-link-empty-alias.out >/dev/null

missing_link_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$extends_dir" "$include_dir" "$envvars_dir" "$disabled_env_dir" "$selection_dir" "$bad_links_dir" "$missing_link_dir"' EXIT
cat > "$missing_link_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/web
    links:
      - missing
YAML
if (cd "$missing_link_dir" && "$binary" up --dry-run >/tmp/apple-compose-missing-link.out 2>&1); then
  echo "expected strict up to reject missing linked services" >&2
  exit 1
fi
grep -F "Service 'web' depends on service 'missing'" /tmp/apple-compose-missing-link.out >/dev/null

bad_network_shape_dir="$tmpdir/bad-network-shape"
mkdir -p "$bad_network_shape_dir"
cat > "$bad_network_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    networks:
      - default
      - name: invalid
YAML
if (cd "$bad_network_shape_dir" && "$binary" config >/tmp/apple-compose-bad-network-shape.out 2>&1); then
  echo "expected invalid service networks list entry to be rejected" >&2
  exit 1
fi
grep -F "networks[1] must be a network name" /tmp/apple-compose-bad-network-shape.out >/dev/null

bad_network_value_dir="$tmpdir/bad-network-value"
mkdir -p "$bad_network_value_dir"
cat > "$bad_network_value_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    networks:
      default: invalid
YAML
if (cd "$bad_network_value_dir" && "$binary" config >/tmp/apple-compose-bad-network-value.out 2>&1); then
  echo "expected invalid service networks mapping value to be rejected" >&2
  exit 1
fi
grep -F "networks.default must be a mapping" /tmp/apple-compose-bad-network-value.out >/dev/null

bad_network_key_dir="$tmpdir/bad-network-key"
mkdir -p "$bad_network_key_dir"
cat > "$bad_network_key_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    networks:
      default:
        gateway: 172.16.238.1
YAML
if (cd "$bad_network_key_dir" && "$binary" config >/tmp/apple-compose-bad-network-key.out 2>&1); then
  echo "expected unsupported network attachment keys to be rejected" >&2
  exit 1
fi
grep -F "Service 'web' networks.default contains unsupported key 'gateway'" /tmp/apple-compose-bad-network-key.out >/dev/null

bad_network_alias_shape_dir="$tmpdir/bad-network-alias-shape"
mkdir -p "$bad_network_alias_shape_dir"
cat > "$bad_network_alias_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    networks:
      default:
        aliases:
          - name: invalid
YAML
if (cd "$bad_network_alias_shape_dir" && "$binary" config >/tmp/apple-compose-bad-network-alias-shape.out 2>&1); then
  echo "expected invalid network aliases list entry to be rejected" >&2
  exit 1
fi
grep -F "networks.default.aliases[0] must be a non-empty string" /tmp/apple-compose-bad-network-alias-shape.out >/dev/null

bad_network_ip_shape_dir="$tmpdir/bad-network-ip-shape"
mkdir -p "$bad_network_ip_shape_dir"
cat > "$bad_network_ip_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    networks:
      default:
        ipv4_address:
          address: 172.16.238.10
YAML
if (cd "$bad_network_ip_shape_dir" && "$binary" config >/tmp/apple-compose-bad-network-ip-shape.out 2>&1); then
  echo "expected invalid network static IP shape to be rejected" >&2
  exit 1
fi
grep -F "networks.default.ipv4_address must be a string" /tmp/apple-compose-bad-network-ip-shape.out >/dev/null

bad_network_ipv4_value_dir="$tmpdir/bad-network-ipv4-value"
mkdir -p "$bad_network_ipv4_value_dir"
cat > "$bad_network_ipv4_value_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    networks:
      default:
        ipv4_address: 172.16.999.10
YAML
if (cd "$bad_network_ipv4_value_dir" && "$binary" config >/tmp/apple-compose-bad-network-ipv4-value.out 2>&1); then
  echo "expected invalid network ipv4_address values to be rejected" >&2
  exit 1
fi
grep -F "networks.default.ipv4_address must be a valid IPv4 address" /tmp/apple-compose-bad-network-ipv4-value.out >/dev/null

bad_network_ipv6_value_dir="$tmpdir/bad-network-ipv6-value"
mkdir -p "$bad_network_ipv6_value_dir"
cat > "$bad_network_ipv6_value_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    networks:
      default:
        ipv6_address: 2001:db8:::10
YAML
if (cd "$bad_network_ipv6_value_dir" && "$binary" config >/tmp/apple-compose-bad-network-ipv6-value.out 2>&1); then
  echo "expected invalid network ipv6_address values to be rejected" >&2
  exit 1
fi
grep -F "networks.default.ipv6_address must be a valid IPv6 address" /tmp/apple-compose-bad-network-ipv6-value.out >/dev/null

bad_network_link_local_value_dir="$tmpdir/bad-network-link-local-value"
mkdir -p "$bad_network_link_local_value_dir"
cat > "$bad_network_link_local_value_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    networks:
      default:
        link_local_ips:
          - fe80::1
          - invalid-ip
YAML
if (cd "$bad_network_link_local_value_dir" && "$binary" config >/tmp/apple-compose-bad-network-link-local-value.out 2>&1); then
  echo "expected invalid network link_local_ips values to be rejected" >&2
  exit 1
fi
grep -F "networks.default.link_local_ips[1] must be a valid IPv4 or IPv6 address" /tmp/apple-compose-bad-network-link-local-value.out >/dev/null

bad_service_mac_dir="$tmpdir/bad-service-mac"
mkdir -p "$bad_service_mac_dir"
cat > "$bad_service_mac_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    mac_address: 02:00:00:00:00
YAML
if (cd "$bad_service_mac_dir" && "$binary" config >/tmp/apple-compose-bad-service-mac.out 2>&1); then
  echo "expected invalid service mac_address values to be rejected" >&2
  exit 1
fi
grep -F "Service 'web' mac_address must use six hexadecimal octets separated by ':'" /tmp/apple-compose-bad-service-mac.out >/dev/null

bad_network_mac_dir="$tmpdir/bad-network-mac"
mkdir -p "$bad_network_mac_dir"
cat > "$bad_network_mac_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    networks:
      default:
        mac_address: 02:00:00:00:00:gg
YAML
if (cd "$bad_network_mac_dir" && "$binary" config >/tmp/apple-compose-bad-network-mac.out 2>&1); then
  echo "expected invalid network mac_address values to be rejected" >&2
  exit 1
fi
grep -F "networks.default.mac_address must use six hexadecimal octets separated by ':'" /tmp/apple-compose-bad-network-mac.out >/dev/null

network_numeric_priority_dir="$tmpdir/network-numeric-priority"
mkdir -p "$network_numeric_priority_dir"
cat > "$network_numeric_priority_dir/compose.yaml" <<'YAML'
name: network_numeric_priority
services:
  web:
    image: nginx
    mac_address: "02:00:00:00:00:10"
    networks:
      front:
        priority: 10.5
      back:
        priority: 10.25
networks:
  front: {}
  back: {}
YAML
network_numeric_priority_plan="$(cd "$network_numeric_priority_dir" && "$binary" plan)"
grep -F -- "--network network_numeric_priority_front,mac=02:00:00:00:00:10 --network network_numeric_priority_back" <<<"$network_numeric_priority_plan" >/dev/null
if grep -F -- "--network network_numeric_priority_back,mac=" <<<"$network_numeric_priority_plan" >/dev/null; then
  echo "expected fractional priority to select only the highest-priority network for service-level mac_address" >&2
  exit 1
fi

bad_network_priority_shape_dir="$tmpdir/bad-network-priority-shape"
mkdir -p "$bad_network_priority_shape_dir"
cat > "$bad_network_priority_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    networks:
      default:
        priority:
          - 100
YAML
if (cd "$bad_network_priority_shape_dir" && "$binary" config >/tmp/apple-compose-bad-network-priority-shape.out 2>&1); then
  echo "expected invalid network priority shape to be rejected" >&2
  exit 1
fi
grep -F "networks.default.priority must be a number" /tmp/apple-compose-bad-network-priority-shape.out >/dev/null

bad_network_priority_string_dir="$tmpdir/bad-network-priority-string"
mkdir -p "$bad_network_priority_string_dir"
cat > "$bad_network_priority_string_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    networks:
      default:
        priority: "100"
YAML
if (cd "$bad_network_priority_string_dir" && "$binary" config >/tmp/apple-compose-bad-network-priority-string.out 2>&1); then
  echo "expected string network priority to be rejected" >&2
  exit 1
fi
grep -F "networks.default.priority must be a number" /tmp/apple-compose-bad-network-priority-string.out >/dev/null

bad_network_interface_shape_dir="$tmpdir/bad-network-interface-shape"
mkdir -p "$bad_network_interface_shape_dir"
cat > "$bad_network_interface_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    networks:
      default:
        interface_name:
          name: eth0
YAML
if (cd "$bad_network_interface_shape_dir" && "$binary" config >/tmp/apple-compose-bad-network-interface-shape.out 2>&1); then
  echo "expected invalid network interface_name shape to be rejected" >&2
  exit 1
fi
grep -F "networks.default.interface_name must be a string" /tmp/apple-compose-bad-network-interface-shape.out >/dev/null

network_advanced_options_dir="$tmpdir/network-advanced-options"
mkdir -p "$network_advanced_options_dir"
cat > "$network_advanced_options_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    networks:
      front:
        interface_name: eth0
      back:
        gw_priority: 1
        link_local_ips:
          - fe80::10
networks:
  front: {}
  back: {}
YAML
if (cd "$network_advanced_options_dir" && "$binary" up --dry-run >/tmp/apple-compose-network-advanced-options.out 2>&1); then
  echo "expected strict up to reject advanced network attachment options" >&2
  exit 1
fi
grep -F "services.web.networks.front: advanced attachment options" /tmp/apple-compose-network-advanced-options.out >/dev/null
grep -F "services.web.networks.back: advanced attachment options" /tmp/apple-compose-network-advanced-options.out >/dev/null
grep -F "interface_name, gw_priority, or link_local_ips" /tmp/apple-compose-network-advanced-options.out >/dev/null

bad_environment_shape_dir="$tmpdir/bad-environment-shape"
mkdir -p "$bad_environment_shape_dir"
cat > "$bad_environment_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    environment:
      - GOOD=value
      - BAD:
          nested: invalid
YAML
if (cd "$bad_environment_shape_dir" && "$binary" config >/tmp/apple-compose-bad-environment-shape.out 2>&1); then
  echo "expected invalid environment list entry to be rejected" >&2
  exit 1
fi
grep -F "environment[1] must be a non-empty KEY or KEY=VALUE string" /tmp/apple-compose-bad-environment-shape.out >/dev/null

bad_label_shape_dir="$tmpdir/bad-label-shape"
mkdir -p "$bad_label_shape_dir"
cat > "$bad_label_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    labels:
      com.example.valid: ok
      com.example.bad:
        nested: invalid
YAML
if (cd "$bad_label_shape_dir" && "$binary" config >/tmp/apple-compose-bad-label-shape.out 2>&1); then
  echo "expected invalid labels map value to be rejected" >&2
  exit 1
fi
grep -F "labels.com.example.bad must be a scalar value or null" /tmp/apple-compose-bad-label-shape.out >/dev/null

bad_label_key_dir="$tmpdir/bad-label-key"
mkdir -p "$bad_label_key_dir"
cat > "$bad_label_key_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    labels:
      "": empty
YAML
if (cd "$bad_label_key_dir" && "$binary" config >/tmp/apple-compose-bad-label-key.out 2>&1); then
  echo "expected empty label keys to be rejected" >&2
  exit 1
fi
grep -F "Service 'web' labels keys must not be empty" /tmp/apple-compose-bad-label-key.out >/dev/null

bad_build_arg_shape_dir="$tmpdir/bad-build-arg-shape"
mkdir -p "$bad_build_arg_shape_dir"
cat > "$bad_build_arg_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/web
    build:
      context: .
      args:
        VALID: ok
        BAD:
          nested: invalid
YAML
if (cd "$bad_build_arg_shape_dir" && "$binary" config >/tmp/apple-compose-bad-build-arg-shape.out 2>&1); then
  echo "expected invalid build args map value to be rejected" >&2
  exit 1
fi
grep -F "build.args.BAD must be a scalar value or null" /tmp/apple-compose-bad-build-arg-shape.out >/dev/null

bad_driver_opts_shape_dir="$tmpdir/bad-driver-opts-shape"
mkdir -p "$bad_driver_opts_shape_dir"
cat > "$bad_driver_opts_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    driver_opts:
      mtu:
        nested: invalid
YAML
if (cd "$bad_driver_opts_shape_dir" && "$binary" config >/tmp/apple-compose-bad-driver-opts-shape.out 2>&1); then
  echo "expected invalid service driver_opts map value to be rejected" >&2
  exit 1
fi
grep -F "driver_opts.mtu must be a string or number" /tmp/apple-compose-bad-driver-opts-shape.out >/dev/null

bad_driver_opts_bool_dir="$tmpdir/bad-driver-opts-bool"
mkdir -p "$bad_driver_opts_bool_dir"
cat > "$bad_driver_opts_bool_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    driver_opts:
      mtu: true
YAML
if (cd "$bad_driver_opts_bool_dir" && "$binary" config >/tmp/apple-compose-bad-driver-opts-bool.out 2>&1); then
  echo "expected boolean service driver_opts map value to be rejected" >&2
  exit 1
fi
grep -F "driver_opts.mtu must be a string or number" /tmp/apple-compose-bad-driver-opts-bool.out >/dev/null

bad_network_attachment_driver_opts_bool_dir="$tmpdir/bad-network-attachment-driver-opts-bool"
mkdir -p "$bad_network_attachment_driver_opts_bool_dir"
cat > "$bad_network_attachment_driver_opts_bool_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    networks:
      default:
        driver_opts:
          foo: false
YAML
if (cd "$bad_network_attachment_driver_opts_bool_dir" && "$binary" config >/tmp/apple-compose-bad-network-attachment-driver-opts-bool.out 2>&1); then
  echo "expected boolean network attachment driver_opts value to be rejected" >&2
  exit 1
fi
grep -F "networks.default.driver_opts.foo must be a string or number" /tmp/apple-compose-bad-network-attachment-driver-opts-bool.out >/dev/null

bad_network_driver_opts_bool_dir="$tmpdir/bad-network-driver-opts-bool"
mkdir -p "$bad_network_driver_opts_bool_dir"
cat > "$bad_network_driver_opts_bool_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    networks:
      - appnet
networks:
  appnet:
    driver_opts:
      encrypted: true
YAML
if (cd "$bad_network_driver_opts_bool_dir" && "$binary" config >/tmp/apple-compose-bad-network-driver-opts-bool.out 2>&1); then
  echo "expected boolean top-level network driver_opts value to be rejected" >&2
  exit 1
fi
grep -F "networks.appnet.driver_opts.encrypted must be a string or number" /tmp/apple-compose-bad-network-driver-opts-bool.out >/dev/null

bad_volume_driver_opts_bool_dir="$tmpdir/bad-volume-driver-opts-bool"
mkdir -p "$bad_volume_driver_opts_bool_dir"
cat > "$bad_volume_driver_opts_bool_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    volumes:
      - data:/data
volumes:
  data:
    driver_opts:
      size: false
YAML
if (cd "$bad_volume_driver_opts_bool_dir" && "$binary" config >/tmp/apple-compose-bad-volume-driver-opts-bool.out 2>&1); then
  echo "expected boolean top-level volume driver_opts value to be rejected" >&2
  exit 1
fi
grep -F "volumes.data.driver_opts.size must be a string or number" /tmp/apple-compose-bad-volume-driver-opts-bool.out >/dev/null

bad_secret_driver_opts_bool_dir="$tmpdir/bad-secret-driver-opts-bool"
mkdir -p "$bad_secret_driver_opts_bool_dir"
cat > "$bad_secret_driver_opts_bool_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    secrets:
      - app_secret
secrets:
  app_secret:
    driver: vault
    driver_opts:
      enabled: true
YAML
if (cd "$bad_secret_driver_opts_bool_dir" && "$binary" config >/tmp/apple-compose-bad-secret-driver-opts-bool.out 2>&1); then
  echo "expected boolean top-level secret driver_opts value to be rejected" >&2
  exit 1
fi
grep -F "secrets.app_secret.driver_opts.enabled must be a string or number" /tmp/apple-compose-bad-secret-driver-opts-bool.out >/dev/null

pull_policy_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$extends_dir" "$include_dir" "$envvars_dir" "$disabled_env_dir" "$selection_dir" "$bad_links_dir" "$missing_link_dir" "$bad_network_shape_dir" "$bad_network_value_dir" "$bad_network_alias_shape_dir" "$bad_network_ip_shape_dir" "$bad_network_priority_shape_dir" "$bad_network_interface_shape_dir" "$bad_environment_shape_dir" "$bad_label_shape_dir" "$bad_build_arg_shape_dir" "$bad_driver_opts_shape_dir" "$pull_policy_dir"' EXIT
cat > "$pull_policy_dir/compose.yaml" <<'YAML'
services:
  cached:
    image: example/cached:latest
    pull_policy: never
    environment:
      - INHERITED_ENV
      - UNRESOLVED_ENV
    labels:
      - com.example.cached-label
YAML
pull_policy_plan="$(cd "$pull_policy_dir" && INHERITED_ENV=from-shell "$binary" plan)"
grep -F "container image inspect example/cached:latest" <<<"$pull_policy_plan" >/dev/null
grep -F "container run --detach" <<<"$pull_policy_plan" >/dev/null
grep -F -- "--env INHERITED_ENV=from-shell" <<<"$pull_policy_plan" >/dev/null
grep -F -- "--label com.example.cached-label=" <<<"$pull_policy_plan" >/dev/null
if grep -F "UNRESOLVED_ENV" <<<"$pull_policy_plan" >/dev/null; then
  echo "expected unresolved valueless environment entry to be omitted" >&2
  exit 1
fi
if grep -F "container image pull" <<<"$pull_policy_plan" >/dev/null; then
  echo "expected pull_policy never to avoid image pull commands" >&2
  exit 1
fi

latest_pull_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$extends_dir" "$include_dir" "$envvars_dir" "$disabled_env_dir" "$selection_dir" "$pull_policy_dir" "$latest_pull_dir"' EXIT
cat > "$latest_pull_dir/compose.yaml" <<'YAML'
services:
  latest:
    image: example/latest:latest
  implicit_latest:
    image: example/implicit
  pinned:
    image: example/pinned:1.0
  explicit_missing:
    image: example/explicit-missing:2.0
    pull_policy: missing
  if_not_present:
    image: example/if-not-present:3.0
    pull_policy: if_not_present
  fallback_build:
    image: example/fallback-build:latest
    build:
      context: .
      dockerfile_inline: |
        FROM busybox
  pull_build:
    image: example/pull-build:latest
    pull_policy: always
    build:
      context: https://github.com/example/project.git#main:app
      ssh:
        - default
  cached_build:
    image: example/cached-build:latest
    pull_policy: never
    build:
      context: https://github.com/example/project.git#main:app
      secrets:
        - missing_build_secret
  build_policy:
    image: example/build-policy:latest
    pull_policy: build
    build:
      context: .
      dockerfile_inline: |
        FROM busybox
YAML
latest_pull_plan="$(cd "$latest_pull_dir" && "$binary" plan)"
grep -F "container image pull example/latest:latest" <<<"$latest_pull_plan" >/dev/null
grep -F "container image pull example/implicit" <<<"$latest_pull_plan" >/dev/null
grep -F '"$container_bin" image inspect "$image"' <<<"$latest_pull_plan" >/dev/null
grep -F "apple-compose-missing-pull example/pinned:1.0 container container image pull example/pinned:1.0" <<<"$latest_pull_plan" >/dev/null
grep -F "apple-compose-missing-pull example/explicit-missing:2.0 container container image pull example/explicit-missing:2.0" <<<"$latest_pull_plan" >/dev/null
grep -F "apple-compose-missing-pull example/if-not-present:3.0 container container image pull example/if-not-present:3.0" <<<"$latest_pull_plan" >/dev/null
grep -F "apple-compose-build-fallback example/fallback-build:latest" <<<"$latest_pull_plan" >/dev/null
grep -F "container build --tag example/fallback-build:latest" <<<"$latest_pull_plan" >/dev/null
grep -F "container image pull example/pull-build:latest" <<<"$latest_pull_plan" >/dev/null
grep -F "container image inspect example/cached-build:latest" <<<"$latest_pull_plan" >/dev/null
grep -F "container build --tag example/build-policy:latest" <<<"$latest_pull_plan" >/dev/null
if grep -F "services.fallback_build: image + build" <<<"$latest_pull_plan" >/dev/null; then
  echo "expected image+build fallback to be represented without a compatibility warning" >&2
  exit 1
fi
if grep -F "container build --tag example/pull-build:latest" <<<"$latest_pull_plan" >/dev/null; then
  echo "expected pull_policy always image+build service to pull instead of build" >&2
  exit 1
fi
if grep -F "container build --tag example/cached-build:latest" <<<"$latest_pull_plan" >/dev/null; then
  echo "expected pull_policy never image+build service to inspect instead of build" >&2
  exit 1
fi
if grep -F "services.pull_build: image + build" <<<"$latest_pull_plan" >/dev/null; then
  echo "expected pull_policy always to avoid image+build fallback warning" >&2
  exit 1
fi
if grep -F "services.cached_build: image + build" <<<"$latest_pull_plan" >/dev/null; then
  echo "expected pull_policy never to avoid image+build fallback warning" >&2
  exit 1
fi
if grep -F "Remote/Git build contexts" <<<"$latest_pull_plan" >/dev/null; then
  echo "expected skipped pull_policy always/never builds not to report remote build context errors" >&2
  exit 1
fi
if grep -F "missing_build_secret" <<<"$latest_pull_plan" >/dev/null; then
  echo "expected skipped pull_policy never build secrets not to require top-level definitions" >&2
  exit 1
fi
if grep -F "services.pull_build.build: ssh" <<<"$latest_pull_plan" >/dev/null; then
  echo "expected skipped pull_policy always build options not to report unsupported build ssh" >&2
  exit 1
fi
if grep -F "container image pull example/build-policy:latest" <<<"$latest_pull_plan" >/dev/null; then
  echo "expected pull_policy build service to avoid runtime image pulls" >&2
  exit 1
fi
if grep -F "services.build_policy: image + build" <<<"$latest_pull_plan" >/dev/null; then
  echo "expected pull_policy build to avoid image+build pull fallback warning" >&2
  exit 1
fi

bad_build_pull_policy_dir="$tmpdir/bad-build-pull-policy"
mkdir -p "$bad_build_pull_policy_dir"
cat > "$bad_build_pull_policy_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    pull_policy: build
YAML
if (cd "$bad_build_pull_policy_dir" && "$binary" up --dry-run >/tmp/apple-compose-bad-build-pull-policy.out 2>&1); then
  echo "expected strict up to reject pull_policy build without build section" >&2
  exit 1
fi

grep -F "pull_policy=build requires a build section" /tmp/apple-compose-bad-build-pull-policy.out >/dev/null

build_args_dir="$tmpdir/build-args"
mkdir -p "$build_args_dir"
cat > "$build_args_dir/.env" <<'EOF'
RESOLVED_ARG=from-dotenv
EOF
cat > "$build_args_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/build-args
    build:
      context: .
      dockerfile_inline: |
        FROM busybox
      args:
        EXPLICIT_ARG: explicit
        RESOLVED_ARG:
        UNRESOLVED_ARG:
YAML
build_args_plan="$(cd "$build_args_dir" && "$binary" plan)"
grep -F -- "--build-arg EXPLICIT_ARG=explicit" <<<"$build_args_plan" >/dev/null
grep -F -- "--build-arg RESOLVED_ARG=from-dotenv" <<<"$build_args_plan" >/dev/null
if grep -F "UNRESOLVED_ARG" <<<"$build_args_plan" >/dev/null; then
  echo "expected unresolved valueless build arg to be omitted" >&2
  exit 1
fi

time_pull_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$extends_dir" "$include_dir" "$envvars_dir" "$disabled_env_dir" "$selection_dir" "$pull_policy_dir" "$latest_pull_dir" "$time_pull_dir"' EXIT
cat > "$time_pull_dir/compose.yaml" <<'YAML'
name: time_pull
services:
  web:
    image: nginx
    pull_policy: daily
  worker:
    image: example/worker:1.0
    pull_policy: weekly
  api:
    image: example/api:1.0
    platform: linux/arm64
    pull_policy: every_1w2d3h4m5s
  immediate:
    image: example/immediate:1.0
    pull_policy: every_0s
  refresher:
    image: example/refresher:1.0
    pull_policy: refresh
    pull_refresh_after: 2h30m
  refresh_default:
    image: example/refresh-default:1.0
    pull_policy: refresh
YAML
if ! (cd "$time_pull_dir" && "$binary" up --dry-run >/tmp/apple-compose-pull-policy.out 2>&1); then
  cat /tmp/apple-compose-pull-policy.out >&2
  echo "expected strict up to support time-based pull policies" >&2
  exit 1
fi

grep -F ".apple-compose/time_pull/pull-state" /tmp/apple-compose-pull-policy.out >/dev/null
grep -F "86400 nginx container image pull nginx" /tmp/apple-compose-pull-policy.out >/dev/null
grep -F "604800 example/worker:1.0 container image pull example/worker:1.0" /tmp/apple-compose-pull-policy.out >/dev/null
grep -F "788645 example/api:1.0 container image pull --platform linux/arm64 example/api:1.0" /tmp/apple-compose-pull-policy.out >/dev/null
grep -F "0 example/immediate:1.0 container image pull example/immediate:1.0" /tmp/apple-compose-pull-policy.out >/dev/null
grep -F "9000 example/refresher:1.0 container image pull example/refresher:1.0" /tmp/apple-compose-pull-policy.out >/dev/null
grep -F "0 example/refresh-default:1.0 container image pull example/refresh-default:1.0" /tmp/apple-compose-pull-policy.out >/dev/null

bad_time_pull_dir="$tmpdir/bad-time-pull-policy"
mkdir -p "$bad_time_pull_dir"
cat > "$bad_time_pull_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    pull_policy: every_soon
YAML
if (cd "$bad_time_pull_dir" && "$binary" config >/tmp/apple-compose-bad-time-pull-policy.out 2>&1); then
  echo "expected config to reject malformed time-based pull policy" >&2
  exit 1
fi

grep -F "pull_policy" /tmp/apple-compose-bad-time-pull-policy.out >/dev/null
grep -F "every_soon" /tmp/apple-compose-bad-time-pull-policy.out >/dev/null
grep -F "must use a duration with w, d, h, m, or s units" /tmp/apple-compose-bad-time-pull-policy.out >/dev/null

bad_refresh_duration_dir="$tmpdir/bad-refresh-duration"
mkdir -p "$bad_refresh_duration_dir"
cat > "$bad_refresh_duration_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    pull_policy: refresh
    pull_refresh_after: soon
YAML
if (cd "$bad_refresh_duration_dir" && "$binary" config >/tmp/apple-compose-bad-refresh-duration.out 2>&1); then
  echo "expected config to reject malformed pull_refresh_after duration" >&2
  exit 1
fi
grep -F "pull_refresh_after" /tmp/apple-compose-bad-refresh-duration.out >/dev/null
grep -F "must use a duration with w, d, h, m, or s units" /tmp/apple-compose-bad-refresh-duration.out >/dev/null

bad_unknown_pull_dir="$tmpdir/bad-unknown-pull-policy"
mkdir -p "$bad_unknown_pull_dir"
cat > "$bad_unknown_pull_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    pull_policy: sometimes
YAML
if (cd "$bad_unknown_pull_dir" && "$binary" config >/tmp/apple-compose-bad-unknown-pull-policy.out 2>&1); then
  echo "expected config to reject unknown pull policy" >&2
  exit 1
fi
grep -F "pull_policy must be one of: always, build, daily, every_<duration>, if_not_present, missing, never, refresh, weekly" /tmp/apple-compose-bad-unknown-pull-policy.out >/dev/null

bad_env_shape_dir="$tmpdir/bad-env-shape"
mkdir -p "$bad_env_shape_dir"
cat > "$bad_env_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    env_file:
      - path: app.env
      - required: false
YAML
if (cd "$bad_env_shape_dir" && "$binary" config >/tmp/apple-compose-bad-env-shape.out 2>&1); then
  echo "expected env_file long syntax without path to be rejected" >&2
  exit 1
fi
grep -F "env_file[1].path is required" /tmp/apple-compose-bad-env-shape.out >/dev/null

bad_env_scalar_dir="$tmpdir/bad-env-scalar"
mkdir -p "$bad_env_scalar_dir"
cat > "$bad_env_scalar_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    env_file:
      - app.env
      - [other.env]
YAML
if (cd "$bad_env_scalar_dir" && "$binary" config >/tmp/apple-compose-bad-env-scalar.out 2>&1); then
  echo "expected invalid env_file list entry to be rejected" >&2
  exit 1
fi
grep -F "env_file[1] must be a file path or mapping" /tmp/apple-compose-bad-env-scalar.out >/dev/null

bad_env_required_dir="$tmpdir/bad-env-required"
mkdir -p "$bad_env_required_dir"
cat > "$bad_env_required_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    env_file:
      - path: app.env
        required: "maybe"
YAML
if (cd "$bad_env_required_dir" && "$binary" config >/tmp/apple-compose-bad-env-required.out 2>&1); then
  echo "expected invalid env_file.required string to be rejected" >&2
  exit 1
fi
grep -F "env_file[0].required must be a boolean value or boolean string" /tmp/apple-compose-bad-env-required.out >/dev/null

bad_env_key_dir="$tmpdir/bad-env-key"
mkdir -p "$bad_env_key_dir"
cat > "$bad_env_key_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    env_file:
      - path: app.env
        mode: raw
YAML
if (cd "$bad_env_key_dir" && "$binary" config >/tmp/apple-compose-bad-env-key.out 2>&1); then
  echo "expected unsupported env_file long syntax keys to be rejected" >&2
  exit 1
fi
grep -F "Service 'web' env_file[0] contains unsupported key 'mode'" /tmp/apple-compose-bad-env-key.out >/dev/null

bad_env_path_shape_dir="$tmpdir/bad-env-path-shape"
mkdir -p "$bad_env_path_shape_dir"
cat > "$bad_env_path_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    env_file:
      - path:
          - app.env
YAML
if (cd "$bad_env_path_shape_dir" && "$binary" config >/tmp/apple-compose-bad-env-path-shape.out 2>&1); then
  echo "expected invalid env_file.path shape to be rejected" >&2
  exit 1
fi
grep -F "env_file[0].path must be a string" /tmp/apple-compose-bad-env-path-shape.out >/dev/null

bad_env_format_shape_dir="$tmpdir/bad-env-format-shape"
mkdir -p "$bad_env_format_shape_dir"
cat > "$bad_env_format_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    env_file:
      - path: app.env
        format:
          raw: true
YAML
if (cd "$bad_env_format_shape_dir" && "$binary" config >/tmp/apple-compose-bad-env-format-shape.out 2>&1); then
  echo "expected invalid env_file.format shape to be rejected" >&2
  exit 1
fi
grep -F "env_file[0].format must be a string" /tmp/apple-compose-bad-env-format-shape.out >/dev/null

bad_env_format_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$extends_dir" "$include_dir" "$envvars_dir" "$disabled_env_dir" "$project_name_dir" "$selection_dir" "$pull_policy_dir" "$time_pull_dir" "$bad_env_format_dir"' EXIT
cat > "$bad_env_format_dir/app.env" <<'EOF'
APP=ok
EOF
cat > "$bad_env_format_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    env_file:
      - path: app.env
        format: json
YAML
if (cd "$bad_env_format_dir" && "$binary" config >/tmp/apple-compose-env-format.out 2>&1); then
  echo "expected config to reject unknown env_file format" >&2
  exit 1
fi

grep -F "env_file[0].format must be raw or compose" /tmp/apple-compose-env-format.out >/dev/null
grep -F "json" /tmp/apple-compose-env-format.out >/dev/null

remote_build_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$extends_dir" "$include_dir" "$envvars_dir" "$disabled_env_dir" "$project_name_dir" "$selection_dir" "$pull_policy_dir" "$time_pull_dir" "$bad_env_format_dir" "$remote_build_dir"' EXIT
cat > "$remote_build_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/web
    build:
      context: https://github.com/example/project.git#main:app
      dockerfile: Dockerfile
YAML
remote_config="$(cd "$remote_build_dir" && "$binary" config)"
grep -F "https://github.com/example/project.git#main:app" <<<"$remote_config" >/dev/null
if grep -F "$remote_build_dir/https:" <<<"$remote_config" >/dev/null; then
  echo "expected remote build context not to be normalized as a local path" >&2
  exit 1
fi
if (cd "$remote_build_dir" && "$binary" up --dry-run >/tmp/apple-compose-remote-build.out 2>&1); then
  echo "expected strict up to reject remote build contexts" >&2
  exit 1
fi
grep -F "Remote/Git build contexts" /tmp/apple-compose-remote-build.out >/dev/null

bad_build_dockerfile_conflict_dir="$tmpdir/bad-build-dockerfile-conflict"
mkdir -p "$bad_build_dockerfile_conflict_dir"
cat > "$bad_build_dockerfile_conflict_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/web
    build:
      context: .
      dockerfile: Dockerfile
      dockerfile_inline: |
        FROM busybox
YAML
if (cd "$bad_build_dockerfile_conflict_dir" && "$binary" config >/tmp/apple-compose-bad-build-dockerfile-conflict.out 2>&1); then
  echo "expected build dockerfile/dockerfile_inline conflicts to be rejected" >&2
  exit 1
fi
grep -F "build must not set both dockerfile and dockerfile_inline" /tmp/apple-compose-bad-build-dockerfile-conflict.out >/dev/null

build_platform_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$extends_dir" "$include_dir" "$envvars_dir" "$disabled_env_dir" "$project_name_dir" "$selection_dir" "$pull_policy_dir" "$time_pull_dir" "$bad_env_format_dir" "$remote_build_dir" "$build_platform_dir"' EXIT
cat > "$build_platform_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/web
    build:
      context: .
      platforms:
        - linux/amd64
        - linux/arm64
YAML
if (cd "$build_platform_dir" && "$binary" up --dry-run >/tmp/apple-compose-build-platform.out 2>&1); then
  echo "expected strict up to reject ambiguous multi-platform builds" >&2
  exit 1
fi

grep -F "build.platforms" /tmp/apple-compose-build-platform.out >/dev/null
grep -F "set service platform" /tmp/apple-compose-build-platform.out >/dev/null

single_build_platform_dir="$tmpdir/single-build-platform"
mkdir -p "$single_build_platform_dir"
cat > "$single_build_platform_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/web
    build:
      context: .
      dockerfile_inline: |
        FROM busybox
      platforms:
        - linux/amd64
YAML
single_build_platform_plan="$(cd "$single_build_platform_dir" && "$binary" plan)"
grep -F "container build --tag example/web" <<<"$single_build_platform_plan" | grep -F -- "--platform linux/amd64" >/dev/null
grep -F "container run --detach" <<<"$single_build_platform_plan" | grep -F -- "--platform linux/amd64" >/dev/null
grep -F "container run --detach" <<<"$single_build_platform_plan" | grep -F -- "--rosetta" >/dev/null

platform_os_only_dir="$tmpdir/platform-os-only"
mkdir -p "$platform_os_only_dir"
cat > "$platform_os_only_dir/compose.yaml" <<'YAML'
name: platform_os_only
services:
  pulled:
    image: nginx
    platform: linux
    pull_policy: always
  built:
    image: example/built
    platform: linux
    build:
      context: .
YAML
platform_os_only_plan="$(cd "$platform_os_only_dir" && "$binary" plan)"
grep -F "container image pull --os linux nginx" <<<"$platform_os_only_plan" >/dev/null
grep -F "container build --tag example/built --os linux" <<<"$platform_os_only_plan" >/dev/null
grep -F "platform_os_only-pulled-1" <<<"$platform_os_only_plan" | grep -F -- "--os linux" >/dev/null
grep -F "platform_os_only-built-1" <<<"$platform_os_only_plan" | grep -F -- "--os linux" >/dev/null
if grep -F -- "--platform linux " <<<"$platform_os_only_plan" >/dev/null; then
  echo "expected OS-only platforms to map to --os instead of --platform" >&2
  exit 1
fi

build_platform_mismatch_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$extends_dir" "$include_dir" "$envvars_dir" "$disabled_env_dir" "$project_name_dir" "$selection_dir" "$pull_policy_dir" "$time_pull_dir" "$bad_env_format_dir" "$build_platform_dir" "$single_build_platform_dir" "$build_platform_mismatch_dir"' EXIT
cat > "$build_platform_mismatch_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/web
    platform: linux/arm64
    build:
      context: .
      platforms:
        - linux/amd64
YAML
if (cd "$build_platform_mismatch_dir" && "$binary" up --dry-run >/tmp/apple-compose-build-platform-mismatch.out 2>&1); then
  echo "expected strict up to reject service platform not listed in build.platforms" >&2
  exit 1
fi

grep -F "linux/arm64" /tmp/apple-compose-build-platform-mismatch.out >/dev/null
grep -F "not listed in build.platforms" /tmp/apple-compose-build-platform-mismatch.out >/dev/null

bad_build_platform_shape_dir="$tmpdir/bad-build-platform-shape"
mkdir -p "$bad_build_platform_shape_dir"
cat > "$bad_build_platform_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/web
    build:
      context: .
      platforms: linux/amd64
YAML
if (cd "$bad_build_platform_shape_dir" && "$binary" config >/tmp/apple-compose-bad-build-platform-shape.out 2>&1); then
  echo "expected scalar build.platforms to be rejected" >&2
  exit 1
fi
grep -F "build.platforms must be a list of strings" /tmp/apple-compose-bad-build-platform-shape.out >/dev/null

bad_build_platform_entry_shape_dir="$tmpdir/bad-build-platform-entry-shape"
mkdir -p "$bad_build_platform_entry_shape_dir"
cat > "$bad_build_platform_entry_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/web
    build:
      context: .
      platforms:
        - 123
YAML
if (cd "$bad_build_platform_entry_shape_dir" && "$binary" config >/tmp/apple-compose-bad-build-platform-entry-shape.out 2>&1); then
  echo "expected non-string build.platforms entries to be rejected" >&2
  exit 1
fi
grep -F "build.platforms[0] must be a non-empty string" /tmp/apple-compose-bad-build-platform-entry-shape.out >/dev/null

bad_service_platform_value_dir="$tmpdir/bad-service-platform-value"
mkdir -p "$bad_service_platform_value_dir"
cat > "$bad_service_platform_value_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    platform: linux//amd64
YAML
if (cd "$bad_service_platform_value_dir" && "$binary" config >/tmp/apple-compose-bad-service-platform-value.out 2>&1); then
  echo "expected malformed service platform values to be rejected" >&2
  exit 1
fi
grep -F "Service 'web' platform must use os[/arch[/variant]] syntax" /tmp/apple-compose-bad-service-platform-value.out >/dev/null

bad_build_platform_value_dir="$tmpdir/bad-build-platform-value"
mkdir -p "$bad_build_platform_value_dir"
cat > "$bad_build_platform_value_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/web
    build:
      context: .
      platforms:
        - linux/amd64/v8/extra
YAML
if (cd "$bad_build_platform_value_dir" && "$binary" config >/tmp/apple-compose-bad-build-platform-value.out 2>&1); then
  echo "expected malformed build.platforms entries to be rejected" >&2
  exit 1
fi
grep -F "Service 'web' build.platforms[0] must use os[/arch[/variant]] syntax" /tmp/apple-compose-bad-build-platform-value.out >/dev/null

random_port_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$extends_dir" "$include_dir" "$envvars_dir" "$disabled_env_dir" "$project_name_dir" "$selection_dir" "$pull_policy_dir" "$time_pull_dir" "$bad_env_format_dir" "$build_platform_dir" "$build_platform_mismatch_dir" "$random_port_dir"' EXIT
cat > "$random_port_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    ports:
      - "3000"
      - "3001-3002/udp"
YAML
random_port_plan="$(cd "$random_port_dir" && "$binary" plan)"
grep -F "ports[0]: published" <<<"$random_port_plan" >/dev/null
grep -F "ports[1]: published" <<<"$random_port_plan" >/dev/null
if grep -F -- "--publish 3000" <<<"$random_port_plan" >/dev/null; then
  echo "expected target-only host ports to be omitted from the Apple publish plan" >&2
  exit 1
fi
if grep -F -- "--publish 3001-3002/udp" <<<"$random_port_plan" >/dev/null; then
  echo "expected target-only port ranges to be omitted from the Apple publish plan" >&2
  exit 1
fi
if (cd "$random_port_dir" && "$binary" up --dry-run >/tmp/apple-compose-random-port.out 2>&1); then
  echo "expected strict up to reject target-only port allocation" >&2
  exit 1
fi
grep -F "ports[0]: published" /tmp/apple-compose-random-port.out >/dev/null

port_host_ip_dir="$tmpdir/port-host-ip"
mkdir -p "$port_host_ip_dir"
cat > "$port_host_ip_dir/compose.yaml" <<'YAML'
name: port_host_ip
services:
  web:
    image: nginx
    ports:
      - "127.0.0.1:8080:80"
      - "::1:8081:81"
      - "[::1]:8082:82/udp"
      - target: 83
        published: "8083"
        host_ip: "::1"
YAML
port_host_ip_plan="$(cd "$port_host_ip_dir" && "$binary" plan)"
grep -F -- "--publish 127.0.0.1:8080:80" <<<"$port_host_ip_plan" >/dev/null
grep -F -- "[::1]:8081:81" <<<"$port_host_ip_plan" >/dev/null
grep -F -- "[::1]:8082:82/udp" <<<"$port_host_ip_plan" >/dev/null
grep -F -- "[::1]:8083:83" <<<"$port_host_ip_plan" >/dev/null

bad_port_shape_dir="$tmpdir/bad-port-shape"
mkdir -p "$bad_port_shape_dir"
cat > "$bad_port_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    ports:
      - [8080]
YAML
if (cd "$bad_port_shape_dir" && "$binary" config >/tmp/apple-compose-bad-port-shape.out 2>&1); then
  echo "expected invalid port entry shape to be rejected" >&2
  exit 1
fi
grep -F "ports[0] must be a port string or mapping" /tmp/apple-compose-bad-port-shape.out >/dev/null

bad_port_target_dir="$tmpdir/bad-port-target"
mkdir -p "$bad_port_target_dir"
cat > "$bad_port_target_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    ports:
      - published: "8080"
YAML
if (cd "$bad_port_target_dir" && "$binary" config >/tmp/apple-compose-bad-port-target.out 2>&1); then
  echo "expected long-form port without target to be rejected" >&2
  exit 1
fi
grep -F "ports[0].target is required" /tmp/apple-compose-bad-port-target.out >/dev/null

bad_port_key_dir="$tmpdir/bad-port-key"
mkdir -p "$bad_port_key_dir"
cat > "$bad_port_key_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    ports:
      - target: 80
        published: "8080"
        weight: 10
YAML
if (cd "$bad_port_key_dir" && "$binary" config >/tmp/apple-compose-bad-port-key.out 2>&1); then
  echo "expected unsupported long-form port keys to be rejected" >&2
  exit 1
fi
grep -F "Service 'web' ports[0] contains unsupported key 'weight'" /tmp/apple-compose-bad-port-key.out >/dev/null

bad_port_target_shape_dir="$tmpdir/bad-port-target-shape"
mkdir -p "$bad_port_target_shape_dir"
cat > "$bad_port_target_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    ports:
      - target:
          - 80
YAML
if (cd "$bad_port_target_shape_dir" && "$binary" config >/tmp/apple-compose-bad-port-target-shape.out 2>&1); then
  echo "expected invalid long-form port target shape to be rejected" >&2
  exit 1
fi
grep -F "ports[0].target must be a string or integer value" /tmp/apple-compose-bad-port-target-shape.out >/dev/null

bad_port_published_shape_dir="$tmpdir/bad-port-published-shape"
mkdir -p "$bad_port_published_shape_dir"
cat > "$bad_port_published_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    ports:
      - target: 80
        published:
          port: 8080
YAML
if (cd "$bad_port_published_shape_dir" && "$binary" config >/tmp/apple-compose-bad-port-published-shape.out 2>&1); then
  echo "expected invalid long-form port published shape to be rejected" >&2
  exit 1
fi
grep -F "ports[0].published must be a string or integer value" /tmp/apple-compose-bad-port-published-shape.out >/dev/null

bad_port_host_ip_value_dir="$tmpdir/bad-port-host-ip-value"
mkdir -p "$bad_port_host_ip_value_dir"
cat > "$bad_port_host_ip_value_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    ports:
      - target: 80
        published: "8080"
        host_ip: not-an-ip
YAML
if (cd "$bad_port_host_ip_value_dir" && "$binary" config >/tmp/apple-compose-bad-port-host-ip-value.out 2>&1); then
  echo "expected invalid long-form port host_ip values to be rejected" >&2
  exit 1
fi
grep -F "ports[0].host_ip must be a valid IPv4 or IPv6 address" /tmp/apple-compose-bad-port-host-ip-value.out >/dev/null

bad_port_mode_shape_dir="$tmpdir/bad-port-mode-shape"
mkdir -p "$bad_port_mode_shape_dir"
cat > "$bad_port_mode_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    ports:
      - target: 80
        mode: true
YAML
if (cd "$bad_port_mode_shape_dir" && "$binary" config >/tmp/apple-compose-bad-port-mode-shape.out 2>&1); then
  echo "expected invalid long-form port mode shape to be rejected" >&2
  exit 1
fi
grep -F "ports[0].mode must be a string" /tmp/apple-compose-bad-port-mode-shape.out >/dev/null

port_custom_mode_dir="$tmpdir/port-custom-mode"
mkdir -p "$port_custom_mode_dir"
cat > "$port_custom_mode_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    ports:
      - target: 80
        published: "8080"
        mode: mesh
YAML
(cd "$port_custom_mode_dir" && "$binary" config >/tmp/apple-compose-port-custom-mode-config.out)
if (cd "$port_custom_mode_dir" && "$binary" up --dry-run >/tmp/apple-compose-port-custom-mode.out 2>&1); then
  echo "expected strict up to reject custom port publishing mode" >&2
  exit 1
fi
grep -F "services.web.ports[0]: mode" /tmp/apple-compose-port-custom-mode.out >/dev/null
grep -F "mode=mesh cannot be mapped exactly" /tmp/apple-compose-port-custom-mode.out >/dev/null

port_ingress_mode_dir="$tmpdir/port-ingress-mode"
mkdir -p "$port_ingress_mode_dir"
cat > "$port_ingress_mode_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    ports:
      - target: 80
        published: "8080"
        mode: ingress
YAML
if (cd "$port_ingress_mode_dir" && "$binary" up --dry-run >/tmp/apple-compose-port-ingress-mode.out 2>&1); then
  echo "expected strict up to reject ingress port publishing mode" >&2
  exit 1
fi
grep -F "services.web.ports[0]: mode" /tmp/apple-compose-port-ingress-mode.out >/dev/null
grep -F "mode=ingress cannot be mapped exactly" /tmp/apple-compose-port-ingress-mode.out >/dev/null

port_sctp_protocol_dir="$tmpdir/port-sctp-protocol"
mkdir -p "$port_sctp_protocol_dir"
cat > "$port_sctp_protocol_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    ports:
      - target: 80
        published: "8080"
        protocol: sctp
YAML
(cd "$port_sctp_protocol_dir" && "$binary" config >/tmp/apple-compose-port-sctp-protocol-config.out)
if (cd "$port_sctp_protocol_dir" && "$binary" up --dry-run >/tmp/apple-compose-port-sctp-protocol.out 2>&1); then
  echo "expected strict up to reject SCTP port publishing" >&2
  exit 1
fi
grep -F "services.web.ports[0]: protocol" /tmp/apple-compose-port-sctp-protocol.out >/dev/null
grep -F "protocol 'sctp' cannot be applied" /tmp/apple-compose-port-sctp-protocol.out >/dev/null

short_port_sctp_protocol_dir="$tmpdir/short-port-sctp-protocol"
mkdir -p "$short_port_sctp_protocol_dir"
cat > "$short_port_sctp_protocol_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    ports:
      - "8080:80/sctp"
YAML
(cd "$short_port_sctp_protocol_dir" && "$binary" config >/tmp/apple-compose-short-port-sctp-protocol-config.out)
if (cd "$short_port_sctp_protocol_dir" && "$binary" up --dry-run >/tmp/apple-compose-short-port-sctp-protocol.out 2>&1); then
  echo "expected strict up to reject short-form SCTP port publishing" >&2
  exit 1
fi
grep -F "services.web.ports[0]: protocol" /tmp/apple-compose-short-port-sctp-protocol.out >/dev/null
grep -F "protocol 'sctp' cannot be applied" /tmp/apple-compose-short-port-sctp-protocol.out >/dev/null

bad_short_port_protocol_value_dir="$tmpdir/bad-short-port-protocol-value"
mkdir -p "$bad_short_port_protocol_value_dir"
cat > "$bad_short_port_protocol_value_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    ports:
      - "8080:80/foo"
YAML
if (cd "$bad_short_port_protocol_value_dir" && "$binary" config >/tmp/apple-compose-bad-short-port-protocol-value.out 2>&1); then
  echo "expected invalid short-form custom port protocol values to be rejected" >&2
  exit 1
fi
grep -F "ports[0] protocol must be tcp, udp, or sctp" /tmp/apple-compose-bad-short-port-protocol-value.out >/dev/null

bad_short_port_host_ip_value_dir="$tmpdir/bad-short-port-host-ip-value"
mkdir -p "$bad_short_port_host_ip_value_dir"
cat > "$bad_short_port_host_ip_value_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    ports:
      - "not-an-ip:8080:80"
YAML
if (cd "$bad_short_port_host_ip_value_dir" && "$binary" config >/tmp/apple-compose-bad-short-port-host-ip-value.out 2>&1); then
  echo "expected invalid short-form port host IP values to be rejected" >&2
  exit 1
fi
grep -F "ports[0].host_ip must be a valid IPv4 or IPv6 address" /tmp/apple-compose-bad-short-port-host-ip-value.out >/dev/null

bad_port_target_syntax_dir="$tmpdir/bad-port-target-syntax"
mkdir -p "$bad_port_target_syntax_dir"
cat > "$bad_port_target_syntax_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    ports:
      - "http"
YAML
if (cd "$bad_port_target_syntax_dir" && "$binary" config >/tmp/apple-compose-bad-port-target-syntax.out 2>&1); then
  echo "expected nonnumeric short port target to be rejected" >&2
  exit 1
fi
grep -F "ports[0] target must be a numeric port or range" /tmp/apple-compose-bad-port-target-syntax.out >/dev/null

bad_port_range_order_dir="$tmpdir/bad-port-range-order"
mkdir -p "$bad_port_range_order_dir"
cat > "$bad_port_range_order_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    ports:
      - "9001-9000"
YAML
if (cd "$bad_port_range_order_dir" && "$binary" config >/tmp/apple-compose-bad-port-range-order.out 2>&1); then
  echo "expected descending short port ranges to be rejected" >&2
  exit 1
fi
grep -F "ports[0] target range start must be less than or equal to the end" /tmp/apple-compose-bad-port-range-order.out >/dev/null

bad_port_published_syntax_dir="$tmpdir/bad-port-published-syntax"
mkdir -p "$bad_port_published_syntax_dir"
cat > "$bad_port_published_syntax_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    ports:
      - target: 80
        published: http
YAML
if (cd "$bad_port_published_syntax_dir" && "$binary" config >/tmp/apple-compose-bad-port-published-syntax.out 2>&1); then
  echo "expected nonnumeric long-form published ports to be rejected" >&2
  exit 1
fi
grep -F "ports[0].published must be a numeric port or range" /tmp/apple-compose-bad-port-published-syntax.out >/dev/null

bad_tmpfs_shape_dir="$tmpdir/bad-tmpfs-shape"
mkdir -p "$bad_tmpfs_shape_dir"
cat > "$bad_tmpfs_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    tmpfs:
      - target: /run
YAML
if (cd "$bad_tmpfs_shape_dir" && "$binary" config >/tmp/apple-compose-bad-tmpfs-shape.out 2>&1); then
  echo "expected invalid tmpfs entry shape to be rejected" >&2
  exit 1
fi
grep -F "tmpfs[0] must be a non-empty string" /tmp/apple-compose-bad-tmpfs-shape.out >/dev/null

bad_tmpfs_option_dir="$tmpdir/bad-tmpfs-option"
mkdir -p "$bad_tmpfs_option_dir"
cat > "$bad_tmpfs_option_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    tmpfs:
      - /run:size=1m
YAML
if (cd "$bad_tmpfs_option_dir" && "$binary" config >/tmp/apple-compose-bad-tmpfs-option.out 2>&1); then
  echo "expected unsupported tmpfs option keys to be rejected" >&2
  exit 1
fi
grep -F "tmpfs[0] option 'size' must be one of: gid, mode, uid" /tmp/apple-compose-bad-tmpfs-option.out >/dev/null

bad_tmpfs_option_syntax_dir="$tmpdir/bad-tmpfs-option-syntax"
mkdir -p "$bad_tmpfs_option_syntax_dir"
cat > "$bad_tmpfs_option_syntax_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    tmpfs:
      - /run:mode
YAML
if (cd "$bad_tmpfs_option_syntax_dir" && "$binary" config >/tmp/apple-compose-bad-tmpfs-option-syntax.out 2>&1); then
  echo "expected malformed tmpfs options to be rejected" >&2
  exit 1
fi
grep -F "tmpfs[0] options must use mode=...,uid=...,gid=... syntax" /tmp/apple-compose-bad-tmpfs-option-syntax.out >/dev/null

tmpfs_option_gap_dir="$tmpdir/tmpfs-option-gap"
mkdir -p "$tmpfs_option_gap_dir"
cat > "$tmpfs_option_gap_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    tmpfs:
      - /run:mode=755
YAML
if (cd "$tmpfs_option_gap_dir" && "$binary" up --dry-run >/tmp/apple-compose-tmpfs-option-gap.out 2>&1); then
  echo "expected strict up to reject service tmpfs options" >&2
  exit 1
fi
grep -F "services.web.tmpfs[/run]: options" /tmp/apple-compose-tmpfs-option-gap.out >/dev/null
grep -F "tmpfs options cannot be applied" /tmp/apple-compose-tmpfs-option-gap.out >/dev/null

long_volume_tmpfs_option_gap_dir="$tmpdir/long-volume-tmpfs-option-gap"
mkdir -p "$long_volume_tmpfs_option_gap_dir"
cat > "$long_volume_tmpfs_option_gap_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    volumes:
      - type: tmpfs
        target: /cache
        tmpfs:
          size: 64M
          mode: 1777.0
YAML
if (cd "$long_volume_tmpfs_option_gap_dir" && "$binary" up --dry-run >/tmp/apple-compose-long-volume-tmpfs-option-gap.out 2>&1); then
  echo "expected strict up to reject long-form tmpfs options" >&2
  exit 1
fi
grep -F "services.web.volumes[/cache]: tmpfs" /tmp/apple-compose-long-volume-tmpfs-option-gap.out >/dev/null
grep -F "tmpfs mode and size cannot be applied" /tmp/apple-compose-long-volume-tmpfs-option-gap.out >/dev/null

bad_service_ulimit_dir="$tmpdir/bad-service-ulimit"
mkdir -p "$bad_service_ulimit_dir"
cat > "$bad_service_ulimit_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    ulimits:
      - nofile=1024
YAML
if (cd "$bad_service_ulimit_dir" && "$binary" config >/tmp/apple-compose-bad-service-ulimit.out 2>&1); then
  echo "expected invalid service ulimits shape to be rejected" >&2
  exit 1
fi
grep -F "Service 'web' ulimits must be a mapping" /tmp/apple-compose-bad-service-ulimit.out >/dev/null

bad_service_ulimit_bool_dir="$tmpdir/bad-service-ulimit-bool"
mkdir -p "$bad_service_ulimit_bool_dir"
cat > "$bad_service_ulimit_bool_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    ulimits:
      nofile: true
YAML
if (cd "$bad_service_ulimit_bool_dir" && "$binary" config >/tmp/apple-compose-bad-service-ulimit-bool.out 2>&1); then
  echo "expected boolean service ulimit value to be rejected" >&2
  exit 1
fi
grep -F "Service 'web' ulimits.nofile must be a string or integer value" /tmp/apple-compose-bad-service-ulimit-bool.out >/dev/null

bad_service_ulimit_key_dir="$tmpdir/bad-service-ulimit-key"
mkdir -p "$bad_service_ulimit_key_dir"
cat > "$bad_service_ulimit_key_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    ulimits:
      nofile:
        soft: 1024
        hard: 2048
        unit: files
YAML
if (cd "$bad_service_ulimit_key_dir" && "$binary" config >/tmp/apple-compose-bad-service-ulimit-key.out 2>&1); then
  echo "expected unsupported service ulimit keys to be rejected" >&2
  exit 1
fi
grep -F "Service 'web' ulimits.nofile contains unsupported key 'unit'" /tmp/apple-compose-bad-service-ulimit-key.out >/dev/null

bad_build_ulimit_dir="$tmpdir/bad-build-ulimit"
mkdir -p "$bad_build_ulimit_dir"
cat > "$bad_build_ulimit_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/web
    build:
      context: .
      ulimits:
        nofile:
          hard: 1024
YAML
if (cd "$bad_build_ulimit_dir" && "$binary" config >/tmp/apple-compose-bad-build-ulimit.out 2>&1); then
  echo "expected invalid build ulimit mapping to be rejected" >&2
  exit 1
fi
grep -F "Service 'web' build.ulimits.nofile.soft is required" /tmp/apple-compose-bad-build-ulimit.out >/dev/null

bad_build_ulimit_missing_hard_dir="$tmpdir/bad-build-ulimit-missing-hard"
mkdir -p "$bad_build_ulimit_missing_hard_dir"
cat > "$bad_build_ulimit_missing_hard_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/web
    build:
      context: .
      ulimits:
        nofile:
          soft: 1024
YAML
if (cd "$bad_build_ulimit_missing_hard_dir" && "$binary" config >/tmp/apple-compose-bad-build-ulimit-missing-hard.out 2>&1); then
  echo "expected build ulimit mappings without hard to be rejected" >&2
  exit 1
fi
grep -F "Service 'web' build.ulimits.nofile.hard is required" /tmp/apple-compose-bad-build-ulimit-missing-hard.out >/dev/null

bad_build_ulimit_hard_dir="$tmpdir/bad-build-ulimit-hard"
mkdir -p "$bad_build_ulimit_hard_dir"
cat > "$bad_build_ulimit_hard_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/web
    build:
      context: .
      ulimits:
        nofile:
          soft: 1024
          hard:
            limit: 2048
YAML
if (cd "$bad_build_ulimit_hard_dir" && "$binary" config >/tmp/apple-compose-bad-build-ulimit-hard.out 2>&1); then
  echo "expected invalid build ulimit hard value to be rejected" >&2
  exit 1
fi
grep -F "Service 'web' build.ulimits.nofile.hard must be a string or integer value" /tmp/apple-compose-bad-build-ulimit-hard.out >/dev/null

build_ulimit_gap_dir="$tmpdir/build-ulimit-gap"
mkdir -p "$build_ulimit_gap_dir"
cat > "$build_ulimit_gap_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/web
    build:
      context: .
      ulimits:
        nofile: 1024
YAML
if (cd "$build_ulimit_gap_dir" && "$binary" up --dry-run >/tmp/apple-compose-build-ulimit-gap.out 2>&1); then
  echo "expected strict up to reject build ulimits Apple gap" >&2
  exit 1
fi
grep -F "services.web.build: ulimits" /tmp/apple-compose-build-ulimit-gap.out >/dev/null
grep -F "Compose build ulimits are not exposed" /tmp/apple-compose-build-ulimit-gap.out >/dev/null

port_range_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$extends_dir" "$include_dir" "$envvars_dir" "$disabled_env_dir" "$project_name_dir" "$selection_dir" "$pull_policy_dir" "$time_pull_dir" "$bad_env_format_dir" "$build_platform_dir" "$build_platform_mismatch_dir" "$random_port_dir" "$bad_port_shape_dir" "$bad_port_target_dir" "$bad_port_target_shape_dir" "$bad_port_published_shape_dir" "$bad_port_mode_shape_dir" "$port_range_dir"' EXIT
cat > "$port_range_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    ports:
      - target: 80
        published: "8080-8090"
YAML
if (cd "$port_range_dir" && "$binary" up --dry-run >/tmp/apple-compose-port-range.out 2>&1); then
  echo "expected strict up to reject random allocation from host port ranges" >&2
  exit 1
fi

grep -F "ports[0]" /tmp/apple-compose-port-range.out >/dev/null
grep -F "fixed ranges of equal length" /tmp/apple-compose-port-range.out >/dev/null

scaled_port_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$extends_dir" "$include_dir" "$envvars_dir" "$disabled_env_dir" "$project_name_dir" "$selection_dir" "$pull_policy_dir" "$time_pull_dir" "$bad_env_format_dir" "$build_platform_dir" "$build_platform_mismatch_dir" "$random_port_dir" "$port_range_dir" "$scaled_port_dir"' EXIT
cat > "$scaled_port_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    scale: 2
    ports:
      - target: 80
        published: "8080"
YAML
if (cd "$scaled_port_dir" && "$binary" up --dry-run >/tmp/apple-compose-scaled-port.out 2>&1); then
  echo "expected strict up to reject replicas with fixed host ports" >&2
  exit 1
fi

grep -F "replicas + fixed ports" /tmp/apple-compose-scaled-port.out >/dev/null

scale_zero_dir="$tmpdir/scale-zero"
mkdir -p "$scale_zero_dir"
printf 'IDLE_VALUE=unused\n' > "$scale_zero_dir/idle.env"
cat > "$scale_zero_dir/compose.yaml" <<'YAML'
name: scale_zero
services:
  idle:
    image: example/idle:1.0
    build:
      context: .
      dockerfile_inline: |
        FROM busybox
    scale: 0
    env_file:
      - idle.env
    networks:
      - idle-net
    volumes:
      - ./idle-data:/idle-data
      - idle-volume:/idle-volume
  cached:
    image: example/cached:latest
    scale: 0
  local:
    image: example/local:1.0
    pull_policy: never
    scale: 0
  worker:
    image: example/worker:1.0
networks:
  idle-net: {}
volumes:
  idle-volume: {}
YAML
scale_zero_plan="$(cd "$scale_zero_dir" && "$binary" plan)"
grep -F "scale_zero-worker-1" <<<"$scale_zero_plan" >/dev/null
if grep -F "scale_zero-idle-1" <<<"$scale_zero_plan" >/dev/null; then
  echo "expected scale=0 service not to create a container" >&2
  exit 1
fi
if grep -F "container run --detach --name scale_zero-idle" <<<"$scale_zero_plan" >/dev/null; then
  echo "expected scale=0 service not to run a container" >&2
  exit 1
fi
if grep -F "container build --tag example/idle:1.0" <<<"$scale_zero_plan" >/dev/null; then
  echo "expected scale=0 service not to build an unused image" >&2
  exit 1
fi
if grep -F "container image pull example/cached:latest" <<<"$scale_zero_plan" >/dev/null; then
  echo "expected scale=0 service not to pull an unused image" >&2
  exit 1
fi
if grep -F "container image inspect example/local:1.0" <<<"$scale_zero_plan" >/dev/null; then
  echo "expected scale=0 service not to inspect an unused image" >&2
  exit 1
fi
if grep -F ".apple-compose/scale_zero/build/idle.Dockerfile" <<<"$scale_zero_plan" >/dev/null; then
  echo "expected scale=0 service not to write unused build artifacts" >&2
  exit 1
fi
if grep -F "/bin/mkdir -p" <<<"$scale_zero_plan" | grep -F "/idle-data" >/dev/null; then
  echo "expected scale=0 service not to create unused bind host paths" >&2
  exit 1
fi
if grep -F "container network create" <<<"$scale_zero_plan" | grep -F "scale_zero_idle-net" >/dev/null; then
  echo "expected scale=0 service not to create unused networks" >&2
  exit 1
fi
if grep -F "container volume create" <<<"$scale_zero_plan" | grep -F "scale_zero_idle-volume" >/dev/null; then
  echo "expected scale=0 service not to create unused volumes" >&2
  exit 1
fi

bad_scale_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$extends_dir" "$include_dir" "$envvars_dir" "$disabled_env_dir" "$project_name_dir" "$selection_dir" "$pull_policy_dir" "$time_pull_dir" "$bad_env_format_dir" "$build_platform_dir" "$build_platform_mismatch_dir" "$random_port_dir" "$port_range_dir" "$scaled_port_dir" "$bad_scale_dir"' EXIT
cat > "$bad_scale_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    scale: 2
    deploy:
      replicas: 3
YAML
if (cd "$bad_scale_dir" && "$binary" config >/tmp/apple-compose-bad-scale.out 2>&1); then
  echo "expected config to reject inconsistent scale and deploy.replicas" >&2
  exit 1
fi

grep -F "Service 'web' scale must be consistent with deploy.replicas when both are set" /tmp/apple-compose-bad-scale.out >/dev/null

bad_resource_quantity_shape_dir="$tmpdir/bad-resource-quantity-shape"
mkdir -p "$bad_resource_quantity_shape_dir"
cat > "$bad_resource_quantity_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    cpus: true
YAML
if (cd "$bad_resource_quantity_shape_dir" && "$binary" config >/tmp/apple-compose-bad-resource-quantity-shape.out 2>&1); then
  echo "expected boolean resource quantities to be rejected" >&2
  exit 1
fi
grep -F "Service 'web' cpus must be a non-negative CPU number" /tmp/apple-compose-bad-resource-quantity-shape.out >/dev/null

bad_cpu_quantity_value_dir="$tmpdir/bad-cpu-quantity-value"
mkdir -p "$bad_cpu_quantity_value_dir"
cat > "$bad_cpu_quantity_value_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    cpus: soon
YAML
if (cd "$bad_cpu_quantity_value_dir" && "$binary" config >/tmp/apple-compose-bad-cpu-quantity-value.out 2>&1); then
  echo "expected invalid CPU quantity strings to be rejected" >&2
  exit 1
fi
grep -F "Service 'web' cpus must be a non-negative CPU number" /tmp/apple-compose-bad-cpu-quantity-value.out >/dev/null

bad_cpu_count_value_dir="$tmpdir/bad-cpu-count-value"
mkdir -p "$bad_cpu_count_value_dir"
cat > "$bad_cpu_count_value_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    cpu_count: 1.5
YAML
if (cd "$bad_cpu_count_value_dir" && "$binary" config >/tmp/apple-compose-bad-cpu-count-value.out 2>&1); then
  echo "expected non-integer cpu_count values to be rejected" >&2
  exit 1
fi
grep -F "Service 'web' cpu_count must be a non-negative integer CPU count" /tmp/apple-compose-bad-cpu-count-value.out >/dev/null

bad_deploy_cpu_quantity_value_dir="$tmpdir/bad-deploy-cpu-quantity-value"
mkdir -p "$bad_deploy_cpu_quantity_value_dir"
cat > "$bad_deploy_cpu_quantity_value_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    deploy:
      resources:
        limits:
          cpus: many
YAML
if (cd "$bad_deploy_cpu_quantity_value_dir" && "$binary" config >/tmp/apple-compose-bad-deploy-cpu-quantity-value.out 2>&1); then
  echo "expected invalid deploy CPU quantity strings to be rejected" >&2
  exit 1
fi
grep -F "deploy.resources.limits.cpus must be a non-negative CPU number" /tmp/apple-compose-bad-deploy-cpu-quantity-value.out >/dev/null

bad_service_memory_value_dir="$tmpdir/bad-service-memory-value"
mkdir -p "$bad_service_memory_value_dir"
cat > "$bad_service_memory_value_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    mem_limit: roomy
YAML
if (cd "$bad_service_memory_value_dir" && "$binary" config >/tmp/apple-compose-bad-service-memory-value.out 2>&1); then
  echo "expected invalid service memory byte values to be rejected" >&2
  exit 1
fi
grep -F "Service 'web' mem_limit must be a valid byte value" /tmp/apple-compose-bad-service-memory-value.out >/dev/null

bad_build_shm_shape_dir="$tmpdir/bad-build-shm-shape"
mkdir -p "$bad_build_shm_shape_dir"
cat > "$bad_build_shm_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    build:
      context: .
      shm_size: false
YAML
if (cd "$bad_build_shm_shape_dir" && "$binary" config >/tmp/apple-compose-bad-build-shm-shape.out 2>&1); then
  echo "expected boolean build shm_size values to be rejected" >&2
  exit 1
fi
grep -F "Service 'web' build.shm_size must be a string or number" /tmp/apple-compose-bad-build-shm-shape.out >/dev/null

bad_build_shm_value_dir="$tmpdir/bad-build-shm-value"
mkdir -p "$bad_build_shm_value_dir"
cat > "$bad_build_shm_value_dir/compose.yaml" <<'YAML'
services:
  web:
    build:
      context: .
      shm_size: 1ki
YAML
if (cd "$bad_build_shm_value_dir" && "$binary" config >/tmp/apple-compose-bad-build-shm-value.out 2>&1); then
  echo "expected invalid build shm_size byte values to be rejected" >&2
  exit 1
fi
grep -F "Service 'web' build.shm_size must be a valid byte value" /tmp/apple-compose-bad-build-shm-value.out >/dev/null

build_shm_tb_dir="$tmpdir/build-shm-tb"
mkdir -p "$build_shm_tb_dir"
cat > "$build_shm_tb_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/web
    build:
      context: .
      shm_size: 1tb
YAML
(cd "$build_shm_tb_dir" && "$binary" config >/tmp/apple-compose-build-shm-tb.out)
grep -F "shm_size: 1tb" /tmp/apple-compose-build-shm-tb.out >/dev/null

build_shm_zero_dir="$tmpdir/build-shm-zero"
mkdir -p "$build_shm_zero_dir"
cat > "$build_shm_zero_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/web
    build:
      context: .
      shm_size: 0
YAML
build_shm_zero_plan="$(cd "$build_shm_zero_dir" && "$binary" plan)"
grep -F "container build --tag example/web" <<<"$build_shm_zero_plan" >/dev/null
if grep -F "services.web.build: shm_size" <<<"$build_shm_zero_plan" >/dev/null; then
  echo "expected build.shm_size=0 to be accepted as default behavior" >&2
  exit 1
fi

build_shm_gap_dir="$tmpdir/build-shm-gap"
mkdir -p "$build_shm_gap_dir"
cat > "$build_shm_gap_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/web
    build:
      context: .
      shm_size: 128M
YAML
if (cd "$build_shm_gap_dir" && "$binary" up --dry-run >/tmp/apple-compose-build-shm-gap.out 2>&1); then
  echo "expected strict up to reject build shm_size Apple gap" >&2
  exit 1
fi
grep -F "services.web.build: shm_size" /tmp/apple-compose-build-shm-gap.out >/dev/null
grep -F "Compose build shared memory sizing is not exposed" /tmp/apple-compose-build-shm-gap.out >/dev/null

stop_signal_empty_dir="$tmpdir/stop-signal-empty"
mkdir -p "$stop_signal_empty_dir"
cat > "$stop_signal_empty_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    stop_signal: ""
YAML
stop_signal_empty_plan="$(cd "$stop_signal_empty_dir" && "$binary" plan --action down)"
grep -F "container stop --time 10" <<<"$stop_signal_empty_plan" >/dev/null
if grep -F -- "--signal" <<<"$stop_signal_empty_plan" >/dev/null; then
  echo "expected empty stop_signal to be treated as unset" >&2
  exit 1
fi

stop_signal_whitespace_dir="$tmpdir/stop-signal-whitespace"
mkdir -p "$stop_signal_whitespace_dir"
cat > "$stop_signal_whitespace_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    stop_signal: "   "
YAML
(cd "$stop_signal_whitespace_dir" && "$binary" config >/tmp/apple-compose-stop-signal-whitespace.out)
grep -F "stop_signal: '   '" /tmp/apple-compose-stop-signal-whitespace.out >/dev/null

bad_stop_signal_null_dir="$tmpdir/bad-stop-signal-null"
mkdir -p "$bad_stop_signal_null_dir"
cat > "$bad_stop_signal_null_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    stop_signal:
YAML
if (cd "$bad_stop_signal_null_dir" && "$binary" config >/tmp/apple-compose-bad-stop-signal-null.out 2>&1); then
  echo "expected null stop_signal to be rejected" >&2
  exit 1
fi
grep -F "stop_signal must be a string" /tmp/apple-compose-bad-stop-signal-null.out >/dev/null

bad_stop_signal_number_dir="$tmpdir/bad-stop-signal-number"
mkdir -p "$bad_stop_signal_number_dir"
cat > "$bad_stop_signal_number_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    stop_signal: 9
YAML
if (cd "$bad_stop_signal_number_dir" && "$binary" config >/tmp/apple-compose-bad-stop-signal-number.out 2>&1); then
  echo "expected numeric stop_signal to be rejected" >&2
  exit 1
fi
grep -F "stop_signal must be a string" /tmp/apple-compose-bad-stop-signal-number.out >/dev/null

bad_duration_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$extends_dir" "$include_dir" "$envvars_dir" "$disabled_env_dir" "$project_name_dir" "$selection_dir" "$pull_policy_dir" "$time_pull_dir" "$bad_env_format_dir" "$build_platform_dir" "$build_platform_mismatch_dir" "$random_port_dir" "$port_range_dir" "$scaled_port_dir" "$bad_scale_dir" "$bad_duration_dir"' EXIT
cat > "$bad_duration_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    stop_grace_period: 1d
YAML
if (cd "$bad_duration_dir" && "$binary" config >/tmp/apple-compose-bad-duration.out 2>&1); then
  echo "expected config to reject invalid stop_grace_period duration" >&2
  exit 1
fi

grep -F "stop_grace_period" /tmp/apple-compose-bad-duration.out >/dev/null
grep -F "must be a valid Compose duration" /tmp/apple-compose-bad-duration.out >/dev/null

consistent_resource_dir="$tmpdir/consistent-resource-limits"
mkdir -p "$consistent_resource_dir"
cat > "$consistent_resource_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    cpus: "0.5"
    mem_limit: 128M
    deploy:
      resources:
        limits:
          cpus: "0.50"
          memory: 128M
  count:
    image: nginx
    cpu_count: 2
YAML
consistent_resource_plan="$(cd "$consistent_resource_dir" && "$binary" plan)"
grep -F -- "--cpus 0.5" <<<"$consistent_resource_plan" >/dev/null
grep -F "consistent-resource-limits-count-1" <<<"$consistent_resource_plan" | grep -F -- "--cpus 2" >/dev/null
grep -F -- "--memory 134217728" <<<"$consistent_resource_plan" >/dev/null
if grep -F "services.count: cpu_count" <<<"$consistent_resource_plan" >/dev/null; then
  echo "expected cpu_count to map to Apple --cpus" >&2
  exit 1
fi
if grep -F "deploy.resources.limits.cpus" <<<"$consistent_resource_plan" >/dev/null; then
  echo "expected numerically equal cpus/deploy limits to be accepted" >&2
  exit 1
fi
if grep -F "deploy.resources.limits.memory" <<<"$consistent_resource_plan" >/dev/null; then
  echo "expected matching mem_limit/deploy memory to be accepted" >&2
  exit 1
fi

zero_resource_dir="$tmpdir/zero-resource-limits"
mkdir -p "$zero_resource_dir"
cat > "$zero_resource_dir/compose.yaml" <<'YAML'
name: zero_resource_limits
services:
  service_zero:
    image: nginx
    cpus: "0"
    cpu_count: 0
    mem_limit: "0"
  deploy_zero:
    image: nginx
    deploy:
      resources:
        limits:
          cpus: "0"
          memory: "0"
        reservations:
          cpus: "0"
          memory: "0"
  deploy_selected:
    image: nginx
    cpus: "0"
    mem_limit: "0"
    mem_reservation: "0"
    pids_limit: 0
    deploy:
      resources:
        limits:
          cpus: "0.75"
          memory: 192M
          pids: -1
        reservations:
          cpus: "0"
          memory: "0"
YAML
zero_resource_plan="$(cd "$zero_resource_dir" && "$binary" up --dry-run)"
grep -F "zero_resource_limits-service_zero-1" <<<"$zero_resource_plan" >/dev/null
grep -F "zero_resource_limits-deploy_zero-1" <<<"$zero_resource_plan" >/dev/null
grep -F "zero_resource_limits-deploy_selected-1" <<<"$zero_resource_plan" | grep -F -- "--cpus 0.75" | grep -F -- "--memory 201326592" >/dev/null
if grep -F "zero_resource_limits-service_zero-1" <<<"$zero_resource_plan" | grep -F -- "--cpus" >/dev/null; then
  echo "expected service cpus/cpu_count zero values not to emit --cpus" >&2
  exit 1
fi
if grep -F "zero_resource_limits-service_zero-1" <<<"$zero_resource_plan" | grep -F -- "--memory" >/dev/null; then
  echo "expected service mem_limit zero not to emit --memory" >&2
  exit 1
fi
if grep -F "zero_resource_limits-deploy_zero-1" <<<"$zero_resource_plan" | grep -E -- "--cpus|--memory" >/dev/null; then
  echo "expected deploy zero CPU/memory limits not to emit resource flags" >&2
  exit 1
fi
if grep -F "[error]" <<<"$zero_resource_plan" >/dev/null; then
  echo "expected zero service/deploy resource values to be accepted as no-ops" >&2
  exit 1
fi

decimal_memory_dir="$tmpdir/decimal-memory"
mkdir -p "$decimal_memory_dir"
cat > "$decimal_memory_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    mem_limit: 1.5gb
    deploy:
      resources:
        limits:
          memory: 1536m
YAML
decimal_memory_plan="$(cd "$decimal_memory_dir" && "$binary" plan)"
grep -F -- "--memory 1610612736" <<<"$decimal_memory_plan" >/dev/null
if grep -F "deploy.resources.limits.memory" <<<"$decimal_memory_plan" >/dev/null; then
  echo "expected equivalent decimal byte values to be accepted" >&2
  exit 1
fi

bad_deploy_memory_value_dir="$tmpdir/bad-deploy-memory-value"
mkdir -p "$bad_deploy_memory_value_dir"
cat > "$bad_deploy_memory_value_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    deploy:
      resources:
        limits:
          memory: 128mi
YAML
if (cd "$bad_deploy_memory_value_dir" && "$binary" config >/tmp/apple-compose-bad-deploy-memory-value.out 2>&1); then
  echo "expected invalid deploy memory byte values to be rejected" >&2
  exit 1
fi
grep -F "deploy.resources.limits.memory must be a valid byte value" /tmp/apple-compose-bad-deploy-memory-value.out >/dev/null

bad_resource_consistency_dir="$tmpdir/bad-resource-consistency"
mkdir -p "$bad_resource_consistency_dir"
cat > "$bad_resource_consistency_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    cpus: "1.0"
    deploy:
      resources:
        limits:
          cpus: "0.5"
YAML
if (cd "$bad_resource_consistency_dir" && "$binary" config >/tmp/apple-compose-bad-resource-consistency.out 2>&1); then
  echo "expected config to reject inconsistent CPU limits" >&2
  exit 1
fi
grep -F "cannot set distinct values for cpus and deploy.resources.limits.cpus" /tmp/apple-compose-bad-resource-consistency.out >/dev/null

bad_memory_consistency_dir="$tmpdir/bad-memory-consistency"
mkdir -p "$bad_memory_consistency_dir"
cat > "$bad_memory_consistency_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    mem_limit: 256M
    deploy:
      resources:
        limits:
          memory: 128M
YAML
if (cd "$bad_memory_consistency_dir" && "$binary" config >/tmp/apple-compose-bad-memory-consistency.out 2>&1); then
  echo "expected config to reject inconsistent memory limits" >&2
  exit 1
fi
grep -F "cannot set distinct values for mem_limit and deploy.resources.limits.memory" /tmp/apple-compose-bad-memory-consistency.out >/dev/null

bad_memory_reservation_consistency_dir="$tmpdir/bad-memory-reservation-consistency"
mkdir -p "$bad_memory_reservation_consistency_dir"
cat > "$bad_memory_reservation_consistency_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    mem_reservation: 128M
    deploy:
      resources:
        reservations:
          memory: 64M
YAML
if (cd "$bad_memory_reservation_consistency_dir" && "$binary" config >/tmp/apple-compose-bad-memory-reservation-consistency.out 2>&1); then
  echo "expected config to reject inconsistent memory reservations" >&2
  exit 1
fi
grep -F "cannot set distinct values for mem_reservation and deploy.resources.reservations.memory" /tmp/apple-compose-bad-memory-reservation-consistency.out >/dev/null

bad_pids_consistency_dir="$tmpdir/bad-pids-consistency"
mkdir -p "$bad_pids_consistency_dir"
cat > "$bad_pids_consistency_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    pids_limit: 10.5
    deploy:
      resources:
        limits:
          pids: 11
YAML
if (cd "$bad_pids_consistency_dir" && "$binary" config >/tmp/apple-compose-bad-pids-consistency.out 2>&1); then
  echo "expected config to reject inconsistent PID limits" >&2
  exit 1
fi
grep -F "cannot set distinct values for pids_limit and deploy.resources.limits.pids" /tmp/apple-compose-bad-pids-consistency.out >/dev/null

bad_deploy_resources_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$extends_dir" "$include_dir" "$envvars_dir" "$disabled_env_dir" "$project_name_dir" "$selection_dir" "$pull_policy_dir" "$time_pull_dir" "$bad_env_format_dir" "$build_platform_dir" "$build_platform_mismatch_dir" "$random_port_dir" "$port_range_dir" "$scaled_port_dir" "$bad_scale_dir" "$bad_duration_dir" "$bad_deploy_resources_dir"' EXIT
cat > "$bad_deploy_resources_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    deploy:
      resources:
        limits:
          cpus: "0.50"
          memory: 128M
          pids: 10
YAML
if (cd "$bad_deploy_resources_dir" && "$binary" up --dry-run >/tmp/apple-compose-bad-deploy-resources.out 2>&1); then
  echo "expected strict up to reject unsupported deploy resource limits" >&2
  exit 1
fi

grep -F "deploy.resources.limits" /tmp/apple-compose-bad-deploy-resources.out >/dev/null
grep -F "pids" /tmp/apple-compose-bad-deploy-resources.out >/dev/null

deploy_reservation_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$extends_dir" "$include_dir" "$envvars_dir" "$disabled_env_dir" "$project_name_dir" "$selection_dir" "$pull_policy_dir" "$time_pull_dir" "$bad_env_format_dir" "$build_platform_dir" "$build_platform_mismatch_dir" "$random_port_dir" "$port_range_dir" "$scaled_port_dir" "$bad_scale_dir" "$bad_duration_dir" "$bad_deploy_resources_dir" "$deploy_reservation_dir"' EXIT
cat > "$deploy_reservation_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    deploy:
      resources:
        reservations:
          memory: 64M
YAML
deploy_reservation_plan="$(cd "$deploy_reservation_dir" && "$binary" plan)"
grep -F "deploy.resources.reservations" <<<"$deploy_reservation_plan" >/dev/null
grep -F "scheduler guarantees" <<<"$deploy_reservation_plan" >/dev/null
if (cd "$deploy_reservation_dir" && "$binary" up --dry-run >/tmp/apple-compose-deploy-reservation.out 2>&1); then
  echo "expected strict up to reject deploy resource reservations" >&2
  exit 1
fi
grep -F "deploy.resources.reservations" /tmp/apple-compose-deploy-reservation.out >/dev/null

deploy_generic_resource_dir="$tmpdir/deploy-generic-resource"
mkdir -p "$deploy_generic_resource_dir"
cat > "$deploy_generic_resource_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    deploy:
      resources:
        reservations:
          generic_resources:
            - discrete_resource_spec:
                kind: GPU
                value: 2
YAML
(cd "$deploy_generic_resource_dir" && "$binary" config >/tmp/apple-compose-deploy-generic-resource.out)
grep -F "generic_resources:" /tmp/apple-compose-deploy-generic-resource.out >/dev/null
if (cd "$deploy_generic_resource_dir" && "$binary" up --dry-run >/tmp/apple-compose-deploy-generic-resource-gap.out 2>&1); then
  echo "expected strict up to reject deploy generic resource reservations" >&2
  exit 1
fi
grep -F "deploy.resources.reservations: generic_resources" /tmp/apple-compose-deploy-generic-resource-gap.out >/dev/null
grep -F "Generic resource reservations" /tmp/apple-compose-deploy-generic-resource-gap.out >/dev/null

bad_deploy_generic_resource_key_dir="$tmpdir/bad-deploy-generic-resource-key"
mkdir -p "$bad_deploy_generic_resource_key_dir"
cat > "$bad_deploy_generic_resource_key_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    deploy:
      resources:
        reservations:
          generic_resources:
            - discrete_resource_spec:
                kind: GPU
                count: 2
YAML
if (cd "$bad_deploy_generic_resource_key_dir" && "$binary" config >/tmp/apple-compose-bad-deploy-generic-resource-key.out 2>&1); then
  echo "expected unsupported deploy generic resource key to be rejected" >&2
  exit 1
fi
grep -F "deploy.resources.reservations.generic_resources[0].discrete_resource_spec contains unsupported key 'count'" /tmp/apple-compose-bad-deploy-generic-resource-key.out >/dev/null

bad_deploy_generic_resource_value_dir="$tmpdir/bad-deploy-generic-resource-value"
mkdir -p "$bad_deploy_generic_resource_value_dir"
cat > "$bad_deploy_generic_resource_value_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    deploy:
      resources:
        reservations:
          generic_resources:
            - discrete_resource_spec:
                kind: GPU
                value:
                  amount: 2
YAML
if (cd "$bad_deploy_generic_resource_value_dir" && "$binary" config >/tmp/apple-compose-bad-deploy-generic-resource-value.out 2>&1); then
  echo "expected invalid deploy generic resource value shape to be rejected" >&2
  exit 1
fi
grep -F "deploy.resources.reservations.generic_resources[0].discrete_resource_spec.value must be a string or number" /tmp/apple-compose-bad-deploy-generic-resource-value.out >/dev/null

deploy_metadata_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$extends_dir" "$include_dir" "$envvars_dir" "$disabled_env_dir" "$project_name_dir" "$selection_dir" "$pull_policy_dir" "$time_pull_dir" "$bad_env_format_dir" "$build_platform_dir" "$build_platform_mismatch_dir" "$random_port_dir" "$port_range_dir" "$scaled_port_dir" "$bad_scale_dir" "$bad_duration_dir" "$bad_deploy_resources_dir" "$deploy_reservation_dir" "$deploy_metadata_dir"' EXIT
cat > "$deploy_metadata_dir/compose.yaml" <<'YAML'
name: deploy_metadata
services:
  web:
    image: nginx
    deploy:
      mode: replicated
      labels:
        com.example.service-label: web
      replicas: 2
YAML
deploy_metadata_plan="$(cd "$deploy_metadata_dir" && "$binary" plan)"
grep -F "deploy: labels" <<<"$deploy_metadata_plan" >/dev/null
grep -F "service metadata and are not inherited by containers" <<<"$deploy_metadata_plan" >/dev/null
grep -F "deploy_metadata-web-1" <<<"$deploy_metadata_plan" >/dev/null
grep -F "deploy_metadata-web-2" <<<"$deploy_metadata_plan" >/dev/null
if grep -F "deploy: mode" <<<"$deploy_metadata_plan" >/dev/null; then
  echo "expected replicated deploy mode to be accepted" >&2
  exit 1
fi
if (cd "$deploy_metadata_dir" && "$binary" up --dry-run >/tmp/apple-compose-deploy-labels.out 2>&1); then
  echo "expected strict up to reject deploy labels" >&2
  exit 1
fi
grep -F "services.web.deploy: labels" /tmp/apple-compose-deploy-labels.out >/dev/null
grep -F "service object to label" /tmp/apple-compose-deploy-labels.out >/dev/null

deploy_empty_orchestration_dir="$tmpdir/deploy-empty-orchestration"
mkdir -p "$deploy_empty_orchestration_dir"
cat > "$deploy_empty_orchestration_dir/compose.yaml" <<'YAML'
name: deploy_empty_orchestration
services:
  web:
    image: nginx
    deploy:
      labels: {}
      mode: ""
      endpoint_mode: ""
      placement: {}
      update_config: {}
      rollback_config: {}
YAML
deploy_empty_orchestration_plan="$(cd "$deploy_empty_orchestration_dir" && "$binary" plan)"
grep -F "deploy_empty_orchestration-web-1" <<<"$deploy_empty_orchestration_plan" >/dev/null
if grep -F "[error]" <<<"$deploy_empty_orchestration_plan" >/dev/null; then
  echo "expected empty deploy orchestration settings to be accepted as no-ops" >&2
  exit 1
fi

bad_deploy_mode_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$extends_dir" "$include_dir" "$envvars_dir" "$disabled_env_dir" "$project_name_dir" "$selection_dir" "$pull_policy_dir" "$time_pull_dir" "$bad_env_format_dir" "$build_platform_dir" "$build_platform_mismatch_dir" "$random_port_dir" "$port_range_dir" "$scaled_port_dir" "$bad_scale_dir" "$bad_duration_dir" "$bad_deploy_resources_dir" "$deploy_reservation_dir" "$deploy_metadata_dir" "$bad_deploy_mode_dir"' EXIT
cat > "$bad_deploy_mode_dir/compose.yaml" <<'YAML'
name: bad_deploy_mode
services:
  web:
    image: nginx
    deploy:
      mode: global
YAML
if (cd "$bad_deploy_mode_dir" && "$binary" up --dry-run >/tmp/apple-compose-bad-deploy-mode.out 2>&1); then
  echo "expected strict up to reject non-replicated deploy mode" >&2
  exit 1
fi

grep -F "deploy: mode" /tmp/apple-compose-bad-deploy-mode.out >/dev/null
grep -F "global" /tmp/apple-compose-bad-deploy-mode.out >/dev/null

bad_deploy_rollout_dir="$tmpdir/bad-deploy-rollout"
mkdir -p "$bad_deploy_rollout_dir"
cat > "$bad_deploy_rollout_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    deploy:
      endpoint_mode: vip
      update_config:
        parallelism: 1
      rollback_config:
        parallelism: 1
YAML
if (cd "$bad_deploy_rollout_dir" && "$binary" up --dry-run >/tmp/apple-compose-bad-deploy-rollout.out 2>&1); then
  echo "expected strict up to reject active deploy rollout configs" >&2
  exit 1
fi
grep -F "services.web.deploy: endpoint_mode" /tmp/apple-compose-bad-deploy-rollout.out >/dev/null
grep -F "services.web.deploy: update_config" /tmp/apple-compose-bad-deploy-rollout.out >/dev/null
grep -F "services.web.deploy: rollback_config" /tmp/apple-compose-bad-deploy-rollout.out >/dev/null

bad_deploy_mode_shape_dir="$tmpdir/bad-deploy-mode-shape"
mkdir -p "$bad_deploy_mode_shape_dir"
cat > "$bad_deploy_mode_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    deploy:
      mode:
        name: replicated
YAML
if (cd "$bad_deploy_mode_shape_dir" && "$binary" config >/tmp/apple-compose-bad-deploy-mode-shape.out 2>&1); then
  echo "expected invalid deploy.mode shape to be rejected" >&2
  exit 1
fi
grep -F "deploy.mode must be a string" /tmp/apple-compose-bad-deploy-mode-shape.out >/dev/null

bad_deploy_mode_value_dir="$tmpdir/bad-deploy-mode-value"
mkdir -p "$bad_deploy_mode_value_dir"
cat > "$bad_deploy_mode_value_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    deploy:
      mode: swarmy
YAML
if (cd "$bad_deploy_mode_value_dir" && "$binary" config >/tmp/apple-compose-bad-deploy-mode-value.out 2>&1); then
  echo "expected invalid deploy.mode value to be rejected" >&2
  exit 1
fi
grep -F "deploy.mode must be one of: global, global-job, replicated, replicated-job" /tmp/apple-compose-bad-deploy-mode-value.out >/dev/null

deploy_extensions_dir="$tmpdir/deploy-extensions"
mkdir -p "$deploy_extensions_dir"
cat > "$deploy_extensions_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    deploy:
      x-note: ignored
      resources:
        x-note: ignored
        limits:
          cpus: "0.50"
          x-note: ignored
YAML
deploy_extensions_plan="$(cd "$deploy_extensions_dir" && "$binary" plan)"
if grep -F "x-note" <<<"$deploy_extensions_plan" >/dev/null; then
  echo "expected deploy x-* extension keys to be ignored" >&2
  exit 1
fi

bad_deploy_key_dir="$tmpdir/bad-deploy-key"
mkdir -p "$bad_deploy_key_dir"
cat > "$bad_deploy_key_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    deploy:
      rollback: true
YAML
if (cd "$bad_deploy_key_dir" && "$binary" config >/tmp/apple-compose-bad-deploy-key.out 2>&1); then
  echo "expected unsupported deploy key to be rejected" >&2
  exit 1
fi
grep -F "Service 'web' deploy contains unsupported key 'rollback'" /tmp/apple-compose-bad-deploy-key.out >/dev/null

bad_deploy_labels_shape_dir="$tmpdir/bad-deploy-labels-shape"
mkdir -p "$bad_deploy_labels_shape_dir"
cat > "$bad_deploy_labels_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    deploy:
      labels:
        - ["com.example.bad=true"]
YAML
if (cd "$bad_deploy_labels_shape_dir" && "$binary" config >/tmp/apple-compose-bad-deploy-labels-shape.out 2>&1); then
  echo "expected invalid deploy.labels shape to be rejected" >&2
  exit 1
fi
grep -F "deploy.labels[0] must be a non-empty KEY or KEY=VALUE string" /tmp/apple-compose-bad-deploy-labels-shape.out >/dev/null

bad_deploy_reservations_shape_dir="$tmpdir/bad-deploy-reservations-shape"
mkdir -p "$bad_deploy_reservations_shape_dir"
cat > "$bad_deploy_reservations_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    deploy:
      resources:
        reservations:
          - memory: 64M
YAML
if (cd "$bad_deploy_reservations_shape_dir" && "$binary" config >/tmp/apple-compose-bad-deploy-reservations-shape.out 2>&1); then
  echo "expected invalid deploy reservations shape to be rejected" >&2
  exit 1
fi
grep -F "deploy.resources.reservations must be a mapping" /tmp/apple-compose-bad-deploy-reservations-shape.out >/dev/null

bad_deploy_reservations_pids_dir="$tmpdir/bad-deploy-reservations-pids"
mkdir -p "$bad_deploy_reservations_pids_dir"
cat > "$bad_deploy_reservations_pids_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    deploy:
      resources:
        reservations:
          pids: 10
YAML
if (cd "$bad_deploy_reservations_pids_dir" && "$binary" config >/tmp/apple-compose-bad-deploy-reservations-pids.out 2>&1); then
  echo "expected unsupported deploy reservations pids key to be rejected" >&2
  exit 1
fi
grep -F "Service 'web' deploy.resources.reservations contains unsupported key 'pids'" /tmp/apple-compose-bad-deploy-reservations-pids.out >/dev/null

bad_deploy_resource_key_dir="$tmpdir/bad-deploy-resource-key"
mkdir -p "$bad_deploy_resource_key_dir"
cat > "$bad_deploy_resource_key_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    deploy:
      resources:
        limits:
          cpus: "0.50"
          shares: 1024
YAML
if (cd "$bad_deploy_resource_key_dir" && "$binary" config >/tmp/apple-compose-bad-deploy-resource-key.out 2>&1); then
  echo "expected unsupported deploy resource key to be rejected" >&2
  exit 1
fi
grep -F "Service 'web' deploy.resources.limits contains unsupported key 'shares'" /tmp/apple-compose-bad-deploy-resource-key.out >/dev/null

bad_deploy_endpoint_shape_dir="$tmpdir/bad-deploy-endpoint-shape"
mkdir -p "$bad_deploy_endpoint_shape_dir"
cat > "$bad_deploy_endpoint_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    deploy:
      endpoint_mode: false
YAML
if (cd "$bad_deploy_endpoint_shape_dir" && "$binary" config >/tmp/apple-compose-bad-deploy-endpoint-shape.out 2>&1); then
  echo "expected invalid deploy.endpoint_mode shape to be rejected" >&2
  exit 1
fi
grep -F "deploy.endpoint_mode must be a string" /tmp/apple-compose-bad-deploy-endpoint-shape.out >/dev/null

bad_deploy_endpoint_value_dir="$tmpdir/bad-deploy-endpoint-value"
mkdir -p "$bad_deploy_endpoint_value_dir"
cat > "$bad_deploy_endpoint_value_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    deploy:
      endpoint_mode: mesh
YAML
if (cd "$bad_deploy_endpoint_value_dir" && "$binary" config >/tmp/apple-compose-bad-deploy-endpoint-value.out 2>&1); then
  echo "expected invalid deploy.endpoint_mode value to be rejected" >&2
  exit 1
fi
grep -F "deploy.endpoint_mode must be one of: dnsrr, vip" /tmp/apple-compose-bad-deploy-endpoint-value.out >/dev/null

deploy_placement_max_dir="$tmpdir/deploy-placement-max"
mkdir -p "$deploy_placement_max_dir"
cat > "$deploy_placement_max_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    deploy:
      placement:
        max_replicas_per_node: "2"
YAML
(cd "$deploy_placement_max_dir" && "$binary" config >/tmp/apple-compose-deploy-placement-max.out)
grep -F "max_replicas_per_node: '2'" /tmp/apple-compose-deploy-placement-max.out >/dev/null
if (cd "$deploy_placement_max_dir" && "$binary" up --dry-run >/tmp/apple-compose-deploy-placement-max-gap.out 2>&1); then
  echo "expected strict up to reject deploy placement max_replicas_per_node" >&2
  exit 1
fi
grep -F "services.web.deploy: placement" /tmp/apple-compose-deploy-placement-max-gap.out >/dev/null
grep -F "Swarm orchestrator" /tmp/apple-compose-deploy-placement-max-gap.out >/dev/null

bad_deploy_placement_max_shape_dir="$tmpdir/bad-deploy-placement-max-shape"
mkdir -p "$bad_deploy_placement_max_shape_dir"
cat > "$bad_deploy_placement_max_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    deploy:
      placement:
        max_replicas_per_node: many
YAML
if (cd "$bad_deploy_placement_max_shape_dir" && "$binary" config >/tmp/apple-compose-bad-deploy-placement-max-shape.out 2>&1); then
  echo "expected invalid deploy placement max_replicas_per_node shape to be rejected" >&2
  exit 1
fi
grep -F "deploy.placement.max_replicas_per_node must be an integer value" /tmp/apple-compose-bad-deploy-placement-max-shape.out >/dev/null

bad_deploy_placement_max_negative_dir="$tmpdir/bad-deploy-placement-max-negative"
mkdir -p "$bad_deploy_placement_max_negative_dir"
cat > "$bad_deploy_placement_max_negative_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    deploy:
      placement:
        max_replicas_per_node: -1
YAML
if (cd "$bad_deploy_placement_max_negative_dir" && "$binary" config >/tmp/apple-compose-bad-deploy-placement-max-negative.out 2>&1); then
  echo "expected negative deploy placement max_replicas_per_node to be rejected" >&2
  exit 1
fi
grep -F "deploy.placement.max_replicas_per_node must be a non-negative integer value" /tmp/apple-compose-bad-deploy-placement-max-negative.out >/dev/null

bad_deploy_placement_shape_dir="$tmpdir/bad-deploy-placement-shape"
mkdir -p "$bad_deploy_placement_shape_dir"
cat > "$bad_deploy_placement_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    deploy:
      placement:
        constraints:
          node.role: manager
YAML
if (cd "$bad_deploy_placement_shape_dir" && "$binary" config >/tmp/apple-compose-bad-deploy-placement-shape.out 2>&1); then
  echo "expected invalid deploy placement constraints shape to be rejected" >&2
  exit 1
fi
grep -F "deploy.placement.constraints must be a list of strings" /tmp/apple-compose-bad-deploy-placement-shape.out >/dev/null

bad_deploy_placement_key_dir="$tmpdir/bad-deploy-placement-key"
mkdir -p "$bad_deploy_placement_key_dir"
cat > "$bad_deploy_placement_key_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    deploy:
      placement:
        preferences:
          - spread: node.labels.zone
            weight: 1
YAML
if (cd "$bad_deploy_placement_key_dir" && "$binary" config >/tmp/apple-compose-bad-deploy-placement-key.out 2>&1); then
  echo "expected unsupported deploy placement preference key to be rejected" >&2
  exit 1
fi
grep -F "Service 'web' deploy.placement.preferences[0] contains unsupported key 'weight'" /tmp/apple-compose-bad-deploy-placement-key.out >/dev/null

deploy_restart_policy_none_dir="$tmpdir/deploy-restart-policy-none"
mkdir -p "$deploy_restart_policy_none_dir"
cat > "$deploy_restart_policy_none_dir/compose.yaml" <<'YAML'
name: deploy_restart_none
services:
  web:
    image: nginx
    deploy:
      restart_policy:
        condition: none
YAML
deploy_restart_policy_none_plan="$(cd "$deploy_restart_policy_none_dir" && "$binary" up --dry-run)"
grep -F "deploy_restart_none-web-1" <<<"$deploy_restart_policy_none_plan" >/dev/null
if grep -F "[error]" <<<"$deploy_restart_policy_none_plan" >/dev/null; then
  echo "expected deploy.restart_policy.condition none to be accepted as a no-op" >&2
  exit 1
fi

bad_deploy_restart_policy_active_dir="$tmpdir/bad-deploy-restart-policy-active"
mkdir -p "$bad_deploy_restart_policy_active_dir"
cat > "$bad_deploy_restart_policy_active_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    deploy:
      restart_policy:
        condition: on-failure
YAML
if (cd "$bad_deploy_restart_policy_active_dir" && "$binary" up --dry-run >/tmp/apple-compose-bad-deploy-restart-policy-active.out 2>&1); then
  echo "expected active deploy restart policies to be rejected" >&2
  exit 1
fi
grep -F "services.web.deploy.restart_policy: condition" /tmp/apple-compose-bad-deploy-restart-policy-active.out >/dev/null
grep -F "Active restart policies are not exposed" /tmp/apple-compose-bad-deploy-restart-policy-active.out >/dev/null

bad_deploy_restart_policy_shape_dir="$tmpdir/bad-deploy-restart-policy-shape"
mkdir -p "$bad_deploy_restart_policy_shape_dir"
cat > "$bad_deploy_restart_policy_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    deploy:
      restart_policy:
        max_attempts: true
YAML
if (cd "$bad_deploy_restart_policy_shape_dir" && "$binary" config >/tmp/apple-compose-bad-deploy-restart-policy-shape.out 2>&1); then
  echo "expected invalid deploy restart_policy shape to be rejected" >&2
  exit 1
fi
grep -F "deploy.restart_policy.max_attempts must be an integer value" /tmp/apple-compose-bad-deploy-restart-policy-shape.out >/dev/null

bad_deploy_restart_policy_negative_dir="$tmpdir/bad-deploy-restart-policy-negative"
mkdir -p "$bad_deploy_restart_policy_negative_dir"
cat > "$bad_deploy_restart_policy_negative_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    deploy:
      restart_policy:
        max_attempts: -1
YAML
if (cd "$bad_deploy_restart_policy_negative_dir" && "$binary" config >/tmp/apple-compose-bad-deploy-restart-policy-negative.out 2>&1); then
  echo "expected negative deploy.restart_policy.max_attempts to be rejected" >&2
  exit 1
fi
grep -F "deploy.restart_policy.max_attempts must be a non-negative integer value" /tmp/apple-compose-bad-deploy-restart-policy-negative.out >/dev/null

bad_deploy_restart_policy_value_dir="$tmpdir/bad-deploy-restart-policy-value"
mkdir -p "$bad_deploy_restart_policy_value_dir"
cat > "$bad_deploy_restart_policy_value_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    deploy:
      restart_policy:
        condition: sometimes
YAML
if (cd "$bad_deploy_restart_policy_value_dir" && "$binary" config >/tmp/apple-compose-bad-deploy-restart-policy-value.out 2>&1); then
  echo "expected invalid deploy.restart_policy.condition value to be rejected" >&2
  exit 1
fi
grep -F "deploy.restart_policy.condition must be one of: any, none, on-failure" /tmp/apple-compose-bad-deploy-restart-policy-value.out >/dev/null

bad_deploy_restart_policy_duration_dir="$tmpdir/bad-deploy-restart-policy-duration"
mkdir -p "$bad_deploy_restart_policy_duration_dir"
cat > "$bad_deploy_restart_policy_duration_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    deploy:
      restart_policy:
        delay: 1d
YAML
if (cd "$bad_deploy_restart_policy_duration_dir" && "$binary" config >/tmp/apple-compose-bad-deploy-restart-policy-duration.out 2>&1); then
  echo "expected invalid deploy.restart_policy duration to be rejected" >&2
  exit 1
fi
grep -F "deploy.restart_policy.delay must be a valid Compose duration" /tmp/apple-compose-bad-deploy-restart-policy-duration.out >/dev/null

bad_deploy_update_config_shape_dir="$tmpdir/bad-deploy-update-config-shape"
mkdir -p "$bad_deploy_update_config_shape_dir"
cat > "$bad_deploy_update_config_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    deploy:
      update_config:
        parallelism: many
YAML
if (cd "$bad_deploy_update_config_shape_dir" && "$binary" config >/tmp/apple-compose-bad-deploy-update-config-shape.out 2>&1); then
  echo "expected invalid deploy update_config shape to be rejected" >&2
  exit 1
fi
grep -F "deploy.update_config.parallelism must be an integer value" /tmp/apple-compose-bad-deploy-update-config-shape.out >/dev/null

bad_deploy_update_config_parallelism_negative_dir="$tmpdir/bad-deploy-update-config-parallelism-negative"
mkdir -p "$bad_deploy_update_config_parallelism_negative_dir"
cat > "$bad_deploy_update_config_parallelism_negative_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    deploy:
      update_config:
        parallelism: -1
YAML
if (cd "$bad_deploy_update_config_parallelism_negative_dir" && "$binary" config >/tmp/apple-compose-bad-deploy-update-config-parallelism-negative.out 2>&1); then
  echo "expected negative deploy.update_config.parallelism to be rejected" >&2
  exit 1
fi
grep -F "deploy.update_config.parallelism must be a non-negative integer value" /tmp/apple-compose-bad-deploy-update-config-parallelism-negative.out >/dev/null

bad_deploy_update_config_value_dir="$tmpdir/bad-deploy-update-config-value"
mkdir -p "$bad_deploy_update_config_value_dir"
cat > "$bad_deploy_update_config_value_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    deploy:
      update_config:
        failure_action: restart
YAML
if (cd "$bad_deploy_update_config_value_dir" && "$binary" config >/tmp/apple-compose-bad-deploy-update-config-value.out 2>&1); then
  echo "expected invalid deploy.update_config.failure_action value to be rejected" >&2
  exit 1
fi
grep -F "deploy.update_config.failure_action must be one of: continue, pause, rollback" /tmp/apple-compose-bad-deploy-update-config-value.out >/dev/null

bad_deploy_update_config_ratio_dir="$tmpdir/bad-deploy-update-config-ratio"
mkdir -p "$bad_deploy_update_config_ratio_dir"
cat > "$bad_deploy_update_config_ratio_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    deploy:
      update_config:
        max_failure_ratio: 1.5
YAML
if (cd "$bad_deploy_update_config_ratio_dir" && "$binary" config >/tmp/apple-compose-bad-deploy-update-config-ratio.out 2>&1); then
  echo "expected out-of-range deploy.update_config.max_failure_ratio to be rejected" >&2
  exit 1
fi
grep -F "deploy.update_config.max_failure_ratio must be a failure ratio between 0 and 1" /tmp/apple-compose-bad-deploy-update-config-ratio.out >/dev/null

bad_deploy_rollback_config_value_dir="$tmpdir/bad-deploy-rollback-config-value"
mkdir -p "$bad_deploy_rollback_config_value_dir"
cat > "$bad_deploy_rollback_config_value_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    deploy:
      rollback_config:
        failure_action: rollback
YAML
if (cd "$bad_deploy_rollback_config_value_dir" && "$binary" config >/tmp/apple-compose-bad-deploy-rollback-config-value.out 2>&1); then
  echo "expected invalid deploy.rollback_config.failure_action value to be rejected" >&2
  exit 1
fi
grep -F "deploy.rollback_config.failure_action must be one of: continue, pause" /tmp/apple-compose-bad-deploy-rollback-config-value.out >/dev/null

bad_deploy_rollback_config_ratio_dir="$tmpdir/bad-deploy-rollback-config-ratio"
mkdir -p "$bad_deploy_rollback_config_ratio_dir"
cat > "$bad_deploy_rollback_config_ratio_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    deploy:
      rollback_config:
        max_failure_ratio: -0.1
YAML
if (cd "$bad_deploy_rollback_config_ratio_dir" && "$binary" config >/tmp/apple-compose-bad-deploy-rollback-config-ratio.out 2>&1); then
  echo "expected negative deploy.rollback_config.max_failure_ratio to be rejected" >&2
  exit 1
fi
grep -F "deploy.rollback_config.max_failure_ratio must be a failure ratio between 0 and 1" /tmp/apple-compose-bad-deploy-rollback-config-ratio.out >/dev/null

bad_deploy_update_config_duration_dir="$tmpdir/bad-deploy-update-config-duration"
mkdir -p "$bad_deploy_update_config_duration_dir"
cat > "$bad_deploy_update_config_duration_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    deploy:
      update_config:
        monitor: -1s
YAML
if (cd "$bad_deploy_update_config_duration_dir" && "$binary" config >/tmp/apple-compose-bad-deploy-update-config-duration.out 2>&1); then
  echo "expected invalid deploy.update_config duration to be rejected" >&2
  exit 1
fi
grep -F "deploy.update_config.monitor must be a valid Compose duration" /tmp/apple-compose-bad-deploy-update-config-duration.out >/dev/null

deploy_limit_pids_noop_dir="$tmpdir/deploy-limit-pids-noop"
mkdir -p "$deploy_limit_pids_noop_dir"
cat > "$deploy_limit_pids_noop_dir/compose.yaml" <<'YAML'
name: deploy_limit_pids_noop
services:
  defaulted:
    image: nginx
    deploy:
      resources:
        limits:
          pids: 0
  unlimited:
    image: nginx
    deploy:
      resources:
        limits:
          pids: -1
YAML
deploy_limit_pids_noop_plan="$(cd "$deploy_limit_pids_noop_dir" && "$binary" up --dry-run)"
grep -F "deploy_limit_pids_noop-defaulted-1" <<<"$deploy_limit_pids_noop_plan" >/dev/null
grep -F "deploy_limit_pids_noop-unlimited-1" <<<"$deploy_limit_pids_noop_plan" >/dev/null
if grep -F "[error]" <<<"$deploy_limit_pids_noop_plan" >/dev/null; then
  echo "expected deploy.resources.limits.pids 0 and -1 to be accepted as no-ops" >&2
  exit 1
fi

bad_deploy_limit_pids_active_dir="$tmpdir/bad-deploy-limit-pids-active"
mkdir -p "$bad_deploy_limit_pids_active_dir"
cat > "$bad_deploy_limit_pids_active_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    deploy:
      resources:
        limits:
          pids: 10
YAML
if (cd "$bad_deploy_limit_pids_active_dir" && "$binary" up --dry-run >/tmp/apple-compose-bad-deploy-limit-pids-active.out 2>&1); then
  echo "expected active deploy resource pids limit to be rejected" >&2
  exit 1
fi
grep -F "services.web.deploy.resources.limits: pids" /tmp/apple-compose-bad-deploy-limit-pids-active.out >/dev/null
grep -F "PID limits are not exposed" /tmp/apple-compose-bad-deploy-limit-pids-active.out >/dev/null

bad_deploy_limit_pids_shape_dir="$tmpdir/bad-deploy-limit-pids-shape"
mkdir -p "$bad_deploy_limit_pids_shape_dir"
cat > "$bad_deploy_limit_pids_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    deploy:
      resources:
        limits:
          pids: many
YAML
if (cd "$bad_deploy_limit_pids_shape_dir" && "$binary" config >/tmp/apple-compose-bad-deploy-limit-pids-shape.out 2>&1); then
  echo "expected invalid deploy resource pids shape to be rejected" >&2
  exit 1
fi
grep -F "deploy.resources.limits.pids must be an integer value" /tmp/apple-compose-bad-deploy-limit-pids-shape.out >/dev/null

valid_deploy_device_reservation_options_dir="$tmpdir/valid-deploy-device-reservation-options"
mkdir -p "$valid_deploy_device_reservation_options_dir"
cat > "$valid_deploy_device_reservation_options_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    deploy:
      resources:
        reservations:
          devices:
            - capabilities: ["gpu"]
              driver: nvidia
              options:
                virtualization: false
                profile:
            - capabilities: ["gpu"]
              options:
                - profile=compute
                - mode=fast
YAML
(cd "$valid_deploy_device_reservation_options_dir" && "$binary" config >/tmp/apple-compose-valid-deploy-device-reservation-options.out)

bad_deploy_device_reservation_options_nested_dir="$tmpdir/bad-deploy-device-reservation-options-nested"
mkdir -p "$bad_deploy_device_reservation_options_nested_dir"
cat > "$bad_deploy_device_reservation_options_nested_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    deploy:
      resources:
        reservations:
          devices:
            - capabilities: ["gpu"]
              options:
                nested:
                  bad: value
YAML
if (cd "$bad_deploy_device_reservation_options_nested_dir" && "$binary" config >/tmp/apple-compose-bad-deploy-device-reservation-options-nested.out 2>&1); then
  echo "expected nested deploy device reservation options to be rejected" >&2
  exit 1
fi
grep -F "deploy.resources.reservations.devices[0].options.nested must be a string, number, boolean, or null value" /tmp/apple-compose-bad-deploy-device-reservation-options-nested.out >/dev/null

bad_deploy_device_reservation_key_dir="$tmpdir/bad-deploy-device-reservation-key"
mkdir -p "$bad_deploy_device_reservation_key_dir"
cat > "$bad_deploy_device_reservation_key_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    deploy:
      resources:
        reservations:
          devices:
            - capabilities: ["gpu"]
              vendor: nvidia
YAML
if (cd "$bad_deploy_device_reservation_key_dir" && "$binary" config >/tmp/apple-compose-bad-deploy-device-reservation-key.out 2>&1); then
  echo "expected unsupported deploy device reservation key to be rejected" >&2
  exit 1
fi
grep -F "Service 'web' deploy.resources.reservations.devices[0] contains unsupported key 'vendor'" /tmp/apple-compose-bad-deploy-device-reservation-key.out >/dev/null

bad_deploy_device_reservation_shape_dir="$tmpdir/bad-deploy-device-reservation-shape"
mkdir -p "$bad_deploy_device_reservation_shape_dir"
cat > "$bad_deploy_device_reservation_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
YAML
if (cd "$bad_deploy_device_reservation_shape_dir" && "$binary" config >/tmp/apple-compose-bad-deploy-device-reservation-shape.out 2>&1); then
  echo "expected invalid deploy device reservation shape to be rejected" >&2
  exit 1
fi
grep -F "deploy.resources.reservations.devices[0].capabilities is required" /tmp/apple-compose-bad-deploy-device-reservation-shape.out >/dev/null

bad_volume_option_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$extends_dir" "$include_dir" "$envvars_dir" "$disabled_env_dir" "$project_name_dir" "$selection_dir" "$pull_policy_dir" "$time_pull_dir" "$bad_env_format_dir" "$build_platform_dir" "$build_platform_mismatch_dir" "$random_port_dir" "$port_range_dir" "$scaled_port_dir" "$bad_scale_dir" "$bad_duration_dir" "$bad_deploy_resources_dir" "$deploy_reservation_dir" "$deploy_metadata_dir" "$bad_deploy_mode_dir" "$bad_volume_option_dir"' EXIT
mkdir -p "$bad_volume_option_dir/data"
cat > "$bad_volume_option_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    volumes:
      - ./data:/data:madeup
YAML
if (cd "$bad_volume_option_dir" && "$binary" up --dry-run >/tmp/apple-compose-bad-volume-option.out 2>&1); then
  echo "expected strict up to reject unknown short volume access mode" >&2
  exit 1
fi

grep -F "madeup" /tmp/apple-compose-bad-volume-option.out >/dev/null
grep -F "short-syntax volume access mode" /tmp/apple-compose-bad-volume-option.out >/dev/null

bad_volume_cache_type_dir="$tmpdir/bad-volume-cache-type"
mkdir -p "$bad_volume_cache_type_dir"
cat > "$bad_volume_cache_type_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    volumes:
      - type: cache
        source: build-cache
        target: /cache
YAML
if (cd "$bad_volume_cache_type_dir" && "$binary" config >/tmp/apple-compose-bad-volume-cache-type.out 2>&1); then
  echo "expected config to reject unknown volume mount type" >&2
  exit 1
fi
grep -F "volumes[0].type must be one of: bind, cluster, image, npipe, tmpfs, volume" /tmp/apple-compose-bad-volume-cache-type.out >/dev/null

bad_long_volume_missing_type_dir="$tmpdir/bad-long-volume-missing-type"
mkdir -p "$bad_long_volume_missing_type_dir"
cat > "$bad_long_volume_missing_type_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    volumes:
      - source: ./data
        target: /data
YAML
if (cd "$bad_long_volume_missing_type_dir" && "$binary" config >/tmp/apple-compose-bad-long-volume-missing-type.out 2>&1); then
  echo "expected long-form volumes without type to be rejected" >&2
  exit 1
fi
grep -F "volumes[0].type is required" /tmp/apple-compose-bad-long-volume-missing-type.out >/dev/null

bad_long_volume_cluster_options_dir="$tmpdir/bad-long-volume-cluster-options"
mkdir -p "$bad_long_volume_cluster_options_dir"
cat > "$bad_long_volume_cluster_options_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    volumes:
      - type: cluster
        source: clustered-data
        target: /data
        cluster:
          required: true
YAML
if (cd "$bad_long_volume_cluster_options_dir" && "$binary" config >/tmp/apple-compose-bad-long-volume-cluster-options.out 2>&1); then
  echo "expected schema-invalid cluster volume options to be rejected" >&2
  exit 1
fi
grep -F "volumes[0] contains unsupported key 'cluster'" /tmp/apple-compose-bad-long-volume-cluster-options.out >/dev/null

long_volume_cluster_type_gap_dir="$tmpdir/long-volume-cluster-type-gap"
mkdir -p "$long_volume_cluster_type_gap_dir"
cat > "$long_volume_cluster_type_gap_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    volumes:
      - type: cluster
        source: clustered-data
        target: /data
YAML
if (cd "$long_volume_cluster_type_gap_dir" && "$binary" up --dry-run >/tmp/apple-compose-long-volume-cluster-type-gap.out 2>&1); then
  echo "expected strict up to reject cluster volume mount type" >&2
  exit 1
fi
grep -F "services.web.volumes[/data]: type" /tmp/apple-compose-long-volume-cluster-type-gap.out >/dev/null
grep -F "Mount type 'cluster' is not supported by Apple container CLI" /tmp/apple-compose-long-volume-cluster-type-gap.out >/dev/null

bad_long_volume_target_dir="$tmpdir/bad-long-volume-target"
mkdir -p "$bad_long_volume_target_dir"
cat > "$bad_long_volume_target_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    volumes:
      - type: bind
        source: ./data
        target:
          - /data
YAML
if (cd "$bad_long_volume_target_dir" && "$binary" config >/tmp/apple-compose-bad-long-volume-target.out 2>&1); then
  echo "expected invalid long volume target shape to be rejected" >&2
  exit 1
fi
grep -F "volumes[0].target must be a string" /tmp/apple-compose-bad-long-volume-target.out >/dev/null

bad_long_volume_bool_dir="$tmpdir/bad-long-volume-bool"
mkdir -p "$bad_long_volume_bool_dir"
cat > "$bad_long_volume_bool_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    volumes:
      - type: bind
        source: ./data
        target: /data
        read_only: "maybe"
YAML
if (cd "$bad_long_volume_bool_dir" && "$binary" config >/tmp/apple-compose-bad-long-volume-bool.out 2>&1); then
  echo "expected invalid long volume read_only string to be rejected" >&2
  exit 1
fi
grep -F "volumes[0].read_only must be a boolean value or boolean string" /tmp/apple-compose-bad-long-volume-bool.out >/dev/null

bad_long_volume_bind_dir="$tmpdir/bad-long-volume-bind"
mkdir -p "$bad_long_volume_bind_dir"
cat > "$bad_long_volume_bind_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    volumes:
      - type: bind
        source: ./data
        target: /data
        bind: invalid
YAML
if (cd "$bad_long_volume_bind_dir" && "$binary" config >/tmp/apple-compose-bad-long-volume-bind.out 2>&1); then
  echo "expected invalid long volume bind options to be rejected" >&2
  exit 1
fi
grep -F "volumes[0].bind must be a mapping" /tmp/apple-compose-bad-long-volume-bind.out >/dev/null

bad_long_volume_bind_key_dir="$tmpdir/bad-long-volume-bind-key"
mkdir -p "$bad_long_volume_bind_key_dir"
cat > "$bad_long_volume_bind_key_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    volumes:
      - type: bind
        source: ./data
        target: /data
        bind:
          options: shared
YAML
if (cd "$bad_long_volume_bind_key_dir" && "$binary" config >/tmp/apple-compose-bad-long-volume-bind-key.out 2>&1); then
  echo "expected unsupported bind option keys to be rejected" >&2
  exit 1
fi
grep -F "Service 'web' volumes[0].bind contains unsupported key 'options'" /tmp/apple-compose-bad-long-volume-bind-key.out >/dev/null

bad_long_volume_create_host_dir="$tmpdir/bad-long-volume-create-host"
mkdir -p "$bad_long_volume_create_host_dir"
cat > "$bad_long_volume_create_host_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    volumes:
      - type: bind
        source: ./data
        target: /data
        bind:
          create_host_path: "maybe"
YAML
if (cd "$bad_long_volume_create_host_dir" && "$binary" config >/tmp/apple-compose-bad-long-volume-create-host.out 2>&1); then
  echo "expected invalid bind.create_host_path string to be rejected" >&2
  exit 1
fi
grep -F "volumes[0].bind.create_host_path must be a boolean value or boolean string" /tmp/apple-compose-bad-long-volume-create-host.out >/dev/null

bad_long_volume_bind_missing_source_dir="$tmpdir/bad-long-volume-bind-missing-source"
mkdir -p "$bad_long_volume_bind_missing_source_dir"
cat > "$bad_long_volume_bind_missing_source_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    volumes:
      - type: bind
        target: /data
YAML
if (cd "$bad_long_volume_bind_missing_source_dir" && "$binary" config >/tmp/apple-compose-bad-long-volume-bind-missing-source.out 2>&1); then
  echo "expected bind mounts without a source to be rejected" >&2
  exit 1
fi
grep -F "volumes[0].source is required for bind mounts" /tmp/apple-compose-bad-long-volume-bind-missing-source.out >/dev/null

empty_long_volume_bind_source_dir="$tmpdir/empty-long-volume-bind-source"
mkdir -p "$empty_long_volume_bind_source_dir"
cat > "$empty_long_volume_bind_source_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    volumes:
      - type: bind
        source: ""
        target: /workspace
YAML
empty_long_volume_bind_source_plan="$(cd "$empty_long_volume_bind_source_dir" && "$binary" plan)"
grep -F -- "--mount type=bind,source=$empty_long_volume_bind_source_dir,target=/workspace" <<<"$empty_long_volume_bind_source_plan" >/dev/null

bad_short_volume_empty_source_dir="$tmpdir/bad-short-volume-empty-source"
mkdir -p "$bad_short_volume_empty_source_dir"
cat > "$bad_short_volume_empty_source_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    volumes:
      - :/data
YAML
if (cd "$bad_short_volume_empty_source_dir" && "$binary" config >/tmp/apple-compose-bad-short-volume-empty-source.out 2>&1); then
  echo "expected short volume syntax with empty source to be rejected" >&2
  exit 1
fi
grep -F "volumes[0] source must not be empty" /tmp/apple-compose-bad-short-volume-empty-source.out >/dev/null

bad_short_volume_empty_target_dir="$tmpdir/bad-short-volume-empty-target"
mkdir -p "$bad_short_volume_empty_target_dir"
cat > "$bad_short_volume_empty_target_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    volumes:
      - "./data:"
YAML
if (cd "$bad_short_volume_empty_target_dir" && "$binary" config >/tmp/apple-compose-bad-short-volume-empty-target.out 2>&1); then
  echo "expected short volume syntax with empty target to be rejected" >&2
  exit 1
fi
grep -F "volumes[0] target must not be empty" /tmp/apple-compose-bad-short-volume-empty-target.out >/dev/null

long_volume_bind_propagation_gap_dir="$tmpdir/long-volume-bind-propagation-gap"
mkdir -p "$long_volume_bind_propagation_gap_dir/data"
cat > "$long_volume_bind_propagation_gap_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    volumes:
      - type: bind
        source: ./data
        target: /data
        bind:
          propagation: rshared
YAML
if (cd "$long_volume_bind_propagation_gap_dir" && "$binary" up --dry-run >/tmp/apple-compose-long-volume-bind-propagation-gap.out 2>&1); then
  echo "expected strict up to reject bind propagation options" >&2
  exit 1
fi
grep -F "services.web.volumes[/data]: bind.propagation" /tmp/apple-compose-long-volume-bind-propagation-gap.out >/dev/null
grep -F "bind propagation modes" /tmp/apple-compose-long-volume-bind-propagation-gap.out >/dev/null

bad_long_volume_recursive_dir="$tmpdir/bad-long-volume-recursive"
mkdir -p "$bad_long_volume_recursive_dir"
cat > "$bad_long_volume_recursive_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    volumes:
      - type: bind
        source: ./data
        target: /data
        bind:
          recursive: sometimes
YAML
if (cd "$bad_long_volume_recursive_dir" && "$binary" config >/tmp/apple-compose-bad-long-volume-recursive.out 2>&1); then
  echo "expected invalid bind.recursive values to be rejected" >&2
  exit 1
fi
grep -F "volumes[0].bind.recursive must be one of: disabled, enabled, readonly, writable" /tmp/apple-compose-bad-long-volume-recursive.out >/dev/null

long_volume_bind_recursive_gap_dir="$tmpdir/long-volume-bind-recursive-gap"
mkdir -p "$long_volume_bind_recursive_gap_dir/data"
cat > "$long_volume_bind_recursive_gap_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    volumes:
      - type: bind
        source: ./data
        target: /data
        bind:
          recursive: readonly
YAML
if (cd "$long_volume_bind_recursive_gap_dir" && "$binary" up --dry-run >/tmp/apple-compose-long-volume-bind-recursive-gap.out 2>&1); then
  echo "expected strict up to reject non-default bind recursive modes" >&2
  exit 1
fi
grep -F "services.web.volumes[/data]: bind.recursive" /tmp/apple-compose-long-volume-bind-recursive-gap.out >/dev/null
grep -F "bind recursive modes" /tmp/apple-compose-long-volume-bind-recursive-gap.out >/dev/null

long_volume_bind_recursive_default_dir="$tmpdir/long-volume-bind-recursive-default"
mkdir -p "$long_volume_bind_recursive_default_dir/data"
cat > "$long_volume_bind_recursive_default_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    volumes:
      - type: bind
        source: ./data
        target: /data
        bind:
          recursive: enabled
YAML
long_volume_bind_recursive_default_plan="$(cd "$long_volume_bind_recursive_default_dir" && "$binary" plan)"
grep -F "container run --detach" <<<"$long_volume_bind_recursive_default_plan" >/dev/null
if grep -F "bind.recursive" <<<"$long_volume_bind_recursive_default_plan" >/dev/null; then
  echo "expected bind.recursive=enabled to be accepted as default behavior" >&2
  exit 1
fi

bad_long_volume_selinux_dir="$tmpdir/bad-long-volume-selinux"
mkdir -p "$bad_long_volume_selinux_dir"
cat > "$bad_long_volume_selinux_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    volumes:
      - type: bind
        source: ./data
        target: /data
        bind:
          selinux: shared
YAML
if (cd "$bad_long_volume_selinux_dir" && "$binary" config >/tmp/apple-compose-bad-long-volume-selinux.out 2>&1); then
  echo "expected invalid bind selinux values to be rejected" >&2
  exit 1
fi
grep -F "volumes[0].bind.selinux must be one of: Z, z" /tmp/apple-compose-bad-long-volume-selinux.out >/dev/null

bad_long_volume_nocopy_dir="$tmpdir/bad-long-volume-nocopy"
mkdir -p "$bad_long_volume_nocopy_dir"
cat > "$bad_long_volume_nocopy_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    volumes:
      - type: volume
        source: data
        target: /data
        volume:
          nocopy: "maybe"
YAML
if (cd "$bad_long_volume_nocopy_dir" && "$binary" config >/tmp/apple-compose-bad-long-volume-nocopy.out 2>&1); then
  echo "expected invalid volume.nocopy string to be rejected" >&2
  exit 1
fi
grep -F "volumes[0].volume.nocopy must be a boolean value or boolean string" /tmp/apple-compose-bad-long-volume-nocopy.out >/dev/null

bad_long_volume_option_key_dir="$tmpdir/bad-long-volume-option-key"
mkdir -p "$bad_long_volume_option_key_dir"
cat > "$bad_long_volume_option_key_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    volumes:
      - type: volume
        source: data
        target: /data
        volume:
          copy: false
YAML
if (cd "$bad_long_volume_option_key_dir" && "$binary" config >/tmp/apple-compose-bad-long-volume-option-key.out 2>&1); then
  echo "expected unsupported named volume option keys to be rejected" >&2
  exit 1
fi
grep -F "Service 'web' volumes[0].volume contains unsupported key 'copy'" /tmp/apple-compose-bad-long-volume-option-key.out >/dev/null

long_volume_labels_dir="$tmpdir/long-volume-labels"
mkdir -p "$long_volume_labels_dir"
cat > "$long_volume_labels_dir/compose.yaml" <<'YAML'
name: long_volume_labels
services:
  web:
    image: nginx
    volumes:
      - type: volume
        source: data
        target: /data
        volume:
          labels:
            com.example.mount: web
volumes:
  data:
    labels:
      com.example.top: data
YAML
long_volume_labels_plan="$(cd "$long_volume_labels_dir" && "$binary" plan)"
grep -F "container volume create" <<<"$long_volume_labels_plan" | grep -F -- "--label com.example.mount=web" >/dev/null
grep -F "container volume create" <<<"$long_volume_labels_plan" | grep -F -- "--label com.example.top=data" >/dev/null

bad_long_volume_labels_shape_dir="$tmpdir/bad-long-volume-labels-shape"
mkdir -p "$bad_long_volume_labels_shape_dir"
cat > "$bad_long_volume_labels_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    volumes:
      - type: volume
        source: data
        target: /data
        volume:
          labels:
            com.example.bad:
              - value
YAML
if (cd "$bad_long_volume_labels_shape_dir" && "$binary" config >/tmp/apple-compose-bad-long-volume-labels-shape.out 2>&1); then
  echo "expected invalid volume.labels shape to be rejected" >&2
  exit 1
fi
grep -F "volume.labels.com.example.bad must be a scalar value or null" /tmp/apple-compose-bad-long-volume-labels-shape.out >/dev/null

bad_long_volume_reserved_label_dir="$tmpdir/bad-long-volume-reserved-label"
mkdir -p "$bad_long_volume_reserved_label_dir"
cat > "$bad_long_volume_reserved_label_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    volumes:
      - type: volume
        source: data
        target: /data
        volume:
          labels:
            com.docker.compose.volume: data
volumes:
  data: {}
YAML
if (cd "$bad_long_volume_reserved_label_dir" && "$binary" up --dry-run >/tmp/apple-compose-bad-long-volume-reserved-label.out 2>&1); then
  echo "expected strict up to reject reserved service volume labels" >&2
  exit 1
fi
grep -F "services.web.volumes[/data].volume: labels" /tmp/apple-compose-bad-long-volume-reserved-label.out >/dev/null
grep -F "com.docker.compose" /tmp/apple-compose-bad-long-volume-reserved-label.out >/dev/null

bad_external_volume_labels_dir="$tmpdir/bad-external-volume-labels"
mkdir -p "$bad_external_volume_labels_dir"
cat > "$bad_external_volume_labels_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    volumes:
      - type: volume
        source: data
        target: /data
        volume:
          labels:
            com.example.mount: web
volumes:
  data:
    external: true
YAML
if (cd "$bad_external_volume_labels_dir" && "$binary" up --dry-run >/tmp/apple-compose-bad-external-volume-labels.out 2>&1); then
  echo "expected strict up to reject service labels on external volumes" >&2
  exit 1
fi
grep -F "Service-level volume labels cannot be applied to an external volume" /tmp/apple-compose-bad-external-volume-labels.out >/dev/null

long_volume_option_gap_dir="$tmpdir/long-volume-option-gap"
mkdir -p "$long_volume_option_gap_dir"
cat > "$long_volume_option_gap_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    volumes:
      - type: volume
        source: data
        target: /data
        volume:
          nocopy: true
          subpath: nested
volumes:
  data: {}
YAML
if (cd "$long_volume_option_gap_dir" && "$binary" up --dry-run >/tmp/apple-compose-long-volume-option-gap.out 2>&1); then
  echo "expected strict up to reject named volume nocopy/subpath options" >&2
  exit 1
fi
grep -F "services.web.volumes[/data]: volume" /tmp/apple-compose-long-volume-option-gap.out >/dev/null
grep -F "volume nocopy or subpath options" /tmp/apple-compose-long-volume-option-gap.out >/dev/null

bad_long_volume_tmpfs_size_dir="$tmpdir/bad-long-volume-tmpfs-size"
mkdir -p "$bad_long_volume_tmpfs_size_dir"
cat > "$bad_long_volume_tmpfs_size_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    volumes:
      - type: tmpfs
        target: /cache
        tmpfs:
          size:
            bytes: 1024
YAML
if (cd "$bad_long_volume_tmpfs_size_dir" && "$binary" config >/tmp/apple-compose-bad-long-volume-tmpfs-size.out 2>&1); then
  echo "expected invalid tmpfs.size shape to be rejected" >&2
  exit 1
fi
grep -F "volumes[0].tmpfs.size must be a string or number byte value" /tmp/apple-compose-bad-long-volume-tmpfs-size.out >/dev/null

bad_long_volume_tmpfs_size_value_dir="$tmpdir/bad-long-volume-tmpfs-size-value"
mkdir -p "$bad_long_volume_tmpfs_size_value_dir"
cat > "$bad_long_volume_tmpfs_size_value_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    volumes:
      - type: tmpfs
        target: /cache
        tmpfs:
          size: 1ki
YAML
if (cd "$bad_long_volume_tmpfs_size_value_dir" && "$binary" config >/tmp/apple-compose-bad-long-volume-tmpfs-size-value.out 2>&1); then
  echo "expected invalid tmpfs.size byte values to be rejected" >&2
  exit 1
fi
grep -F "volumes[0].tmpfs.size must be a valid byte value" /tmp/apple-compose-bad-long-volume-tmpfs-size-value.out >/dev/null

bad_long_volume_tmpfs_mode_dir="$tmpdir/bad-long-volume-tmpfs-mode"
mkdir -p "$bad_long_volume_tmpfs_mode_dir"
cat > "$bad_long_volume_tmpfs_mode_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    volumes:
      - type: tmpfs
        target: /cache
        tmpfs:
          mode:
            octal: 1777
YAML
if (cd "$bad_long_volume_tmpfs_mode_dir" && "$binary" config >/tmp/apple-compose-bad-long-volume-tmpfs-mode.out 2>&1); then
  echo "expected invalid tmpfs.mode shape to be rejected" >&2
  exit 1
fi
grep -F "volumes[0].tmpfs.mode must be a string or number" /tmp/apple-compose-bad-long-volume-tmpfs-mode.out >/dev/null

bad_long_volume_tmpfs_key_dir="$tmpdir/bad-long-volume-tmpfs-key"
mkdir -p "$bad_long_volume_tmpfs_key_dir"
cat > "$bad_long_volume_tmpfs_key_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    volumes:
      - type: tmpfs
        target: /cache
        tmpfs:
          uid: "1000"
YAML
if (cd "$bad_long_volume_tmpfs_key_dir" && "$binary" config >/tmp/apple-compose-bad-long-volume-tmpfs-key.out 2>&1); then
  echo "expected unsupported tmpfs volume option keys to be rejected" >&2
  exit 1
fi
grep -F "Service 'web' volumes[0].tmpfs contains unsupported key 'uid'" /tmp/apple-compose-bad-long-volume-tmpfs-key.out >/dev/null

bad_long_volume_image_subpath_dir="$tmpdir/bad-long-volume-image-subpath"
mkdir -p "$bad_long_volume_image_subpath_dir"
cat > "$bad_long_volume_image_subpath_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    volumes:
      - type: image
        source: alpine
        target: /image
        image:
          subpath:
            - usr
YAML
if (cd "$bad_long_volume_image_subpath_dir" && "$binary" config >/tmp/apple-compose-bad-long-volume-image-subpath.out 2>&1); then
  echo "expected invalid image.subpath shape to be rejected" >&2
  exit 1
fi
grep -F "volumes[0].image.subpath must be a string" /tmp/apple-compose-bad-long-volume-image-subpath.out >/dev/null

bad_long_volume_image_key_dir="$tmpdir/bad-long-volume-image-key"
mkdir -p "$bad_long_volume_image_key_dir"
cat > "$bad_long_volume_image_key_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    volumes:
      - type: image
        source: alpine
        target: /image
        image:
          path: usr
YAML
if (cd "$bad_long_volume_image_key_dir" && "$binary" config >/tmp/apple-compose-bad-long-volume-image-key.out 2>&1); then
  echo "expected unsupported image volume option keys to be rejected" >&2
  exit 1
fi
grep -F "Service 'web' volumes[0].image contains unsupported key 'path'" /tmp/apple-compose-bad-long-volume-image-key.out >/dev/null

bad_secret_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$extends_dir" "$include_dir" "$envvars_dir" "$disabled_env_dir" "$project_name_dir" "$selection_dir" "$pull_policy_dir" "$time_pull_dir" "$bad_env_format_dir" "$build_platform_dir" "$build_platform_mismatch_dir" "$random_port_dir" "$port_range_dir" "$scaled_port_dir" "$bad_scale_dir" "$bad_volume_option_dir" "$bad_secret_dir"' EXIT
cat > "$bad_secret_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    secrets:
      - missing_secret
YAML
if (cd "$bad_secret_dir" && "$binary" up --dry-run >/tmp/apple-compose-bad-secret.out 2>&1); then
  echo "expected strict up to reject undefined service secret grants" >&2
  exit 1
fi

grep -F "Service 'web' refers to undefined secret 'missing_secret'" /tmp/apple-compose-bad-secret.out >/dev/null

bad_secret_label_shape_dir="$tmpdir/bad-secret-label-shape"
mkdir -p "$bad_secret_label_shape_dir"
cat > "$bad_secret_label_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
secrets:
  app_secret:
    environment: APP_SECRET
    labels:
      com.example.bad:
        - value
YAML
if (cd "$bad_secret_label_shape_dir" && "$binary" config >/tmp/apple-compose-bad-secret-label-shape.out 2>&1); then
  echo "expected invalid secret label shape to be rejected" >&2
  exit 1
fi
grep -F "secrets.app_secret.labels.com.example.bad must be a scalar value or null" /tmp/apple-compose-bad-secret-label-shape.out >/dev/null

secret_labels_gap_dir="$tmpdir/secret-labels-gap"
mkdir -p "$secret_labels_gap_dir"
cat > "$secret_labels_gap_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    secrets:
      - app_secret
secrets:
  app_secret:
    environment: APP_SECRET
    labels:
      com.example.secret: app
YAML
if (cd "$secret_labels_gap_dir" && APP_SECRET=secret "$binary" up --dry-run >/tmp/apple-compose-secret-labels-gap.out 2>&1); then
  echo "expected strict up to reject secret resource labels" >&2
  exit 1
fi
grep -F "secrets.app_secret: labels" /tmp/apple-compose-secret-labels-gap.out >/dev/null
grep -F "secret resource label API" /tmp/apple-compose-secret-labels-gap.out >/dev/null

bad_secret_driver_source_dir="$tmpdir/bad-secret-driver-source"
mkdir -p "$bad_secret_driver_source_dir"
cat > "$bad_secret_driver_source_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    secrets:
      - app_secret
secrets:
  app_secret:
    driver: vault
    driver_opts:
      path: secret/app
    template_driver: golang
YAML
if (cd "$bad_secret_driver_source_dir" && "$binary" config >/tmp/apple-compose-bad-secret-driver-source.out 2>&1); then
  echo "expected config to reject secret driver-only sources" >&2
  exit 1
fi
grep -F "secrets.app_secret must define file, environment, or external" /tmp/apple-compose-bad-secret-driver-source.out >/dev/null

secret_driver_gap_dir="$tmpdir/secret-driver-gap"
mkdir -p "$secret_driver_gap_dir"
cat > "$secret_driver_gap_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    secrets:
      - app_secret
secrets:
  app_secret:
    environment: APP_SECRET
    driver: vault
    driver_opts:
      path: secret/app
    template_driver: golang
YAML
if (cd "$secret_driver_gap_dir" && APP_SECRET=secret "$binary" up --dry-run >/tmp/apple-compose-secret-driver-gap.out 2>&1); then
  echo "expected strict up to reject secret drivers/options and template drivers" >&2
  exit 1
fi
grep -F "secrets.app_secret: driver" /tmp/apple-compose-secret-driver-gap.out >/dev/null
grep -F "Secret drivers are not exposed" /tmp/apple-compose-secret-driver-gap.out >/dev/null
grep -F "secrets.app_secret: driver_opts" /tmp/apple-compose-secret-driver-gap.out >/dev/null
grep -F "secrets.app_secret: template_driver" /tmp/apple-compose-secret-driver-gap.out >/dev/null

empty_secret_config_metadata_dir="$tmpdir/empty-secret-config-metadata"
mkdir -p "$empty_secret_config_metadata_dir"
cat > "$empty_secret_config_metadata_dir/compose.yaml" <<'YAML'
name: empty_secret_config_metadata
services:
  web:
    image: nginx
    secrets:
      - app_secret
    configs:
      - app_config
secrets:
  app_secret:
    environment: APP_SECRET
    driver: ""
    driver_opts: {}
    template_driver: ""
configs:
  app_config:
    content: ok
    template_driver: ""
YAML
empty_secret_config_metadata_config="$(cd "$empty_secret_config_metadata_dir" && APP_SECRET=secret "$binary" config)"
grep -F "app_secret:" <<<"$empty_secret_config_metadata_config" >/dev/null
grep -F "app_config:" <<<"$empty_secret_config_metadata_config" >/dev/null
if grep -F 'driver: ""' <<<"$empty_secret_config_metadata_config" >/dev/null; then
  echo "expected empty secret driver metadata to be omitted from normalized config" >&2
  exit 1
fi
if grep -F 'template_driver: ""' <<<"$empty_secret_config_metadata_config" >/dev/null; then
  echo "expected empty template driver metadata to be omitted from normalized config" >&2
  exit 1
fi
empty_secret_config_metadata_plan="$(cd "$empty_secret_config_metadata_dir" && APP_SECRET=secret "$binary" plan)"
grep -F "empty_secret_config_metadata-web-1" <<<"$empty_secret_config_metadata_plan" >/dev/null
if grep -F "[error]" <<<"$empty_secret_config_metadata_plan" >/dev/null; then
  echo "expected empty secret/config driver metadata to be accepted as defaults" >&2
  exit 1
fi

config_labels_gap_dir="$tmpdir/config-labels-gap"
mkdir -p "$config_labels_gap_dir"
cat > "$config_labels_gap_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    configs:
      - app_config
configs:
  app_config:
    content: ok
    labels:
      com.example.config: app
YAML
if (cd "$config_labels_gap_dir" && "$binary" up --dry-run >/tmp/apple-compose-config-labels-gap.out 2>&1); then
  echo "expected strict up to reject config resource labels" >&2
  exit 1
fi
grep -F "configs.app_config: labels" /tmp/apple-compose-config-labels-gap.out >/dev/null
grep -F "config resource label API" /tmp/apple-compose-config-labels-gap.out >/dev/null

config_template_driver_gap_dir="$tmpdir/config-template-driver-gap"
mkdir -p "$config_template_driver_gap_dir"
cat > "$config_template_driver_gap_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    configs:
      - app_config
configs:
  app_config:
    content: "{{ .Env.APP_CONFIG }}"
    template_driver: golang
YAML
if (cd "$config_template_driver_gap_dir" && "$binary" up --dry-run >/tmp/apple-compose-config-template-driver-gap.out 2>&1); then
  echo "expected strict up to reject config template drivers" >&2
  exit 1
fi
grep -F "configs.app_config: template_driver" /tmp/apple-compose-config-template-driver-gap.out >/dev/null
grep -F "Config template drivers are not exposed" /tmp/apple-compose-config-template-driver-gap.out >/dev/null

bad_build_secret_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$extends_dir" "$include_dir" "$envvars_dir" "$disabled_env_dir" "$project_name_dir" "$selection_dir" "$pull_policy_dir" "$time_pull_dir" "$bad_env_format_dir" "$build_platform_dir" "$build_platform_mismatch_dir" "$random_port_dir" "$port_range_dir" "$scaled_port_dir" "$bad_scale_dir" "$bad_volume_option_dir" "$bad_secret_dir" "$bad_build_secret_dir"' EXIT
cat > "$bad_build_secret_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/web
    build:
      context: .
      secrets:
        - missing_build_secret
YAML
if (cd "$bad_build_secret_dir" && "$binary" up --dry-run >/tmp/apple-compose-bad-build-secret.out 2>&1); then
  echo "expected strict up to reject undefined build secret grants" >&2
  exit 1
fi

grep -F "Service 'web' build refers to undefined secret 'missing_build_secret'" /tmp/apple-compose-bad-build-secret.out >/dev/null

bad_build_grant_shape_dir="$tmpdir/bad-build-grant-shape"
mkdir -p "$bad_build_grant_shape_dir"
cat > "$bad_build_grant_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/web
    build:
      context: .
      secrets:
        - [missing_build_secret]
YAML
if (cd "$bad_build_grant_shape_dir" && "$binary" config >/tmp/apple-compose-bad-build-grant-shape.out 2>&1); then
  echo "expected invalid build secret grant shape to be rejected" >&2
  exit 1
fi

grep -F "build.secrets[0] source must be a string" /tmp/apple-compose-bad-build-grant-shape.out >/dev/null

bad_build_grant_scalar_dir="$tmpdir/bad-build-grant-scalar"
mkdir -p "$bad_build_grant_scalar_dir"
cat > "$bad_build_grant_scalar_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/web
    build:
      context: .
      secrets: missing_build_secret
YAML
if (cd "$bad_build_grant_scalar_dir" && "$binary" config >/tmp/apple-compose-bad-build-grant-scalar.out 2>&1); then
  echo "expected scalar build secret grants to be rejected" >&2
  exit 1
fi

grep -F "build.secrets must be a list of source names or mappings" /tmp/apple-compose-bad-build-grant-scalar.out >/dev/null

bad_config_source_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$extends_dir" "$include_dir" "$envvars_dir" "$disabled_env_dir" "$project_name_dir" "$selection_dir" "$pull_policy_dir" "$time_pull_dir" "$bad_env_format_dir" "$build_platform_dir" "$build_platform_mismatch_dir" "$random_port_dir" "$port_range_dir" "$scaled_port_dir" "$bad_scale_dir" "$bad_volume_option_dir" "$bad_secret_dir" "$bad_build_secret_dir" "$bad_build_grant_shape_dir" "$bad_build_grant_scalar_dir" "$bad_config_source_dir"' EXIT
cat > "$bad_config_source_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    configs:
      - app_config
configs:
  app_config: {}
YAML
if (cd "$bad_config_source_dir" && "$binary" config >/tmp/apple-compose-bad-config-source.out 2>&1); then
  echo "expected config to reject configs without a source" >&2
  exit 1
fi

grep -F "configs.app_config" /tmp/apple-compose-bad-config-source.out >/dev/null
grep -F "file, content, environment, or external" /tmp/apple-compose-bad-config-source.out >/dev/null

bad_config_multiple_sources_dir="$tmpdir/bad-config-multiple-sources"
mkdir -p "$bad_config_multiple_sources_dir"
cat > "$bad_config_multiple_sources_dir/compose.yaml" <<'YAML'
configs:
  app_config:
    file: ./app.conf
    content: inline
services:
  web:
    image: nginx
YAML
if (cd "$bad_config_multiple_sources_dir" && "$binary" config >/tmp/apple-compose-bad-config-multiple-sources.out 2>&1); then
  echo "expected config to reject configs with multiple source types" >&2
  exit 1
fi
grep -F "configs.app_config can only define one config source type: content, file" /tmp/apple-compose-bad-config-multiple-sources.out >/dev/null

bad_secret_source_dir="$tmpdir/bad-secret-source"
mkdir -p "$bad_secret_source_dir"
cat > "$bad_secret_source_dir/compose.yaml" <<'YAML'
secrets:
  app_secret: {}
services:
  web:
    image: nginx
YAML
if (cd "$bad_secret_source_dir" && "$binary" config >/tmp/apple-compose-bad-secret-source.out 2>&1); then
  echo "expected config to reject secrets without a source" >&2
  exit 1
fi
grep -F "secrets.app_secret must define file, environment, or external" /tmp/apple-compose-bad-secret-source.out >/dev/null

bad_secret_multiple_sources_dir="$tmpdir/bad-secret-multiple-sources"
mkdir -p "$bad_secret_multiple_sources_dir"
cat > "$bad_secret_multiple_sources_dir/compose.yaml" <<'YAML'
secrets:
  app_secret:
    file: ./secret.txt
    environment: APP_SECRET
services:
  web:
    image: nginx
YAML
if (cd "$bad_secret_multiple_sources_dir" && "$binary" config >/tmp/apple-compose-bad-secret-multiple-sources.out 2>&1); then
  echo "expected config to reject secrets with multiple source types" >&2
  exit 1
fi
grep -F "secrets.app_secret can only define one secret source type: environment, file" /tmp/apple-compose-bad-secret-multiple-sources.out >/dev/null

bad_external_config_source_dir="$tmpdir/bad-external-config-source"
mkdir -p "$bad_external_config_source_dir"
cat > "$bad_external_config_source_dir/compose.yaml" <<'YAML'
configs:
  app_config:
    external: true
    content: inline
services:
  web:
    image: nginx
YAML
if (cd "$bad_external_config_source_dir" && "$binary" config >/tmp/apple-compose-bad-external-config-source.out 2>&1); then
  echo "expected config to reject local source on external config" >&2
  exit 1
fi
grep -F "configs.app_config is external and can only specify external/name, not content" /tmp/apple-compose-bad-external-config-source.out >/dev/null

bad_grant_source_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$extends_dir" "$include_dir" "$envvars_dir" "$disabled_env_dir" "$project_name_dir" "$selection_dir" "$pull_policy_dir" "$time_pull_dir" "$bad_env_format_dir" "$build_platform_dir" "$build_platform_mismatch_dir" "$random_port_dir" "$port_range_dir" "$scaled_port_dir" "$bad_scale_dir" "$bad_volume_option_dir" "$bad_secret_dir" "$bad_build_secret_dir" "$bad_config_source_dir" "$bad_grant_source_dir"' EXIT
cat > "$bad_grant_source_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    secrets:
      - target: /run/secrets/app
secrets:
  app_secret:
    file: ./secret.txt
YAML
printf 'secret' > "$bad_grant_source_dir/secret.txt"
if (cd "$bad_grant_source_dir" && "$binary" config >/tmp/apple-compose-bad-grant-source.out 2>&1); then
  echo "expected long-form secret grant without source to be rejected" >&2
  exit 1
fi

grep -F "secrets[0].source is required" /tmp/apple-compose-bad-grant-source.out >/dev/null

bad_grant_scalar_dir="$tmpdir/bad-grant-scalar"
mkdir -p "$bad_grant_scalar_dir"
cat > "$bad_grant_scalar_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    configs: app_config
configs:
  app_config:
    content: ok
YAML
if (cd "$bad_grant_scalar_dir" && "$binary" config >/tmp/apple-compose-bad-grant-scalar.out 2>&1); then
  echo "expected scalar service config grants to be rejected" >&2
  exit 1
fi

grep -F "configs must be a list of source names or mappings" /tmp/apple-compose-bad-grant-scalar.out >/dev/null

bad_grant_target_shape_dir="$tmpdir/bad-grant-target-shape"
mkdir -p "$bad_grant_target_shape_dir"
cat > "$bad_grant_target_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    configs:
      - source: app_config
        target:
          path: /etc/app.conf
configs:
  app_config:
    content: ok
YAML
if (cd "$bad_grant_target_shape_dir" && "$binary" config >/tmp/apple-compose-bad-grant-target-shape.out 2>&1); then
  echo "expected invalid config grant target shape to be rejected" >&2
  exit 1
fi

grep -F "configs[0].target must be a string" /tmp/apple-compose-bad-grant-target-shape.out >/dev/null

bad_grant_mode_shape_dir="$tmpdir/bad-grant-mode-shape"
mkdir -p "$bad_grant_mode_shape_dir"
cat > "$bad_grant_mode_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    secrets:
      - source: app_secret
        mode:
          octal: 0440
secrets:
  app_secret:
    environment: APP_SECRET
YAML
if (cd "$bad_grant_mode_shape_dir" && "$binary" config >/tmp/apple-compose-bad-grant-mode-shape.out 2>&1); then
  echo "expected invalid secret grant mode shape to be rejected" >&2
  exit 1
fi

grep -F "secrets[0].mode must be a string or integer value" /tmp/apple-compose-bad-grant-mode-shape.out >/dev/null

bad_grant_mode_float_dir="$tmpdir/bad-grant-mode-float"
mkdir -p "$bad_grant_mode_float_dir"
cat > "$bad_grant_mode_float_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    configs:
      - source: app_config
        mode: 440.0
configs:
  app_config:
    content: ok
YAML
if (cd "$bad_grant_mode_float_dir" && "$binary" config >/tmp/apple-compose-bad-grant-mode-float.out 2>&1); then
  echo "expected float config grant mode to be rejected" >&2
  exit 1
fi

grep -F "configs[0].mode must be a string or integer value" /tmp/apple-compose-bad-grant-mode-float.out >/dev/null

bad_grant_uid_shape_dir="$tmpdir/bad-grant-uid-shape"
mkdir -p "$bad_grant_uid_shape_dir"
cat > "$bad_grant_uid_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    secrets:
      - source: app_secret
        uid: 103
secrets:
  app_secret:
    environment: APP_SECRET
YAML
if (cd "$bad_grant_uid_shape_dir" && "$binary" config >/tmp/apple-compose-bad-grant-uid-shape.out 2>&1); then
  echo "expected numeric secret grant uid to be rejected" >&2
  exit 1
fi

grep -F "secrets[0].uid must be a string" /tmp/apple-compose-bad-grant-uid-shape.out >/dev/null

bad_grant_unknown_key_dir="$tmpdir/bad-grant-unknown-key"
mkdir -p "$bad_grant_unknown_key_dir"
cat > "$bad_grant_unknown_key_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    configs:
      - source: app_config
        target: /etc/app.conf
        template_driver: default
configs:
  app_config:
    content: ok
YAML
if (cd "$bad_grant_unknown_key_dir" && "$binary" config >/tmp/apple-compose-bad-grant-unknown-key.out 2>&1); then
  echo "expected unknown config grant keys to be rejected" >&2
  exit 1
fi
grep -F "Service 'web' configs[0] contains unsupported key 'template_driver'" /tmp/apple-compose-bad-grant-unknown-key.out >/dev/null

secret_mode_dir="$tmpdir/secret-mode"
mkdir -p "$secret_mode_dir"
cat > "$secret_mode_dir/compose.yaml" <<'YAML'
name: secret_mode
services:
  web:
    image: nginx
    secrets:
      - source: app_secret
        mode: 0440
secrets:
  app_secret:
    environment: APP_SECRET
YAML
if ! (cd "$secret_mode_dir" && APP_SECRET=secret "$binary" up --dry-run >/tmp/apple-compose-secret-mode.out 2>&1); then
  echo "expected generated secret mode to be supported" >&2
  exit 1
fi
grep -F ".apple-compose/secret_mode/secrets/app_secret mode 440" /tmp/apple-compose-secret-mode.out >/dev/null
grep -F "target=/run/secrets/app_secret,readonly" /tmp/apple-compose-secret-mode.out >/dev/null
if grep -F "uid/gid" /tmp/apple-compose-secret-mode.out >/dev/null; then
  echo "expected generated secret mode alone not to warn as unsupported ownership" >&2
  exit 1
fi

secret_uid_gap_dir="$tmpdir/secret-uid-gap"
mkdir -p "$secret_uid_gap_dir"
cat > "$secret_uid_gap_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    secrets:
      - source: app_secret
        uid: "103"
        gid: "103"
secrets:
  app_secret:
    environment: APP_SECRET
YAML
if (cd "$secret_uid_gap_dir" && APP_SECRET=secret "$binary" up --dry-run >/tmp/apple-compose-secret-uid-gap.out 2>&1); then
  echo "expected strict up to reject generated secret uid/gid ownership options" >&2
  exit 1
fi
grep -F "services.web.secrets.app_secret: uid/gid" /tmp/apple-compose-secret-uid-gap.out >/dev/null
grep -F "ownership remapping" /tmp/apple-compose-secret-uid-gap.out >/dev/null

file_secret_options_dir="$tmpdir/file-secret-options"
mkdir -p "$file_secret_options_dir"
printf 'secret' > "$file_secret_options_dir/secret.txt"
cat > "$file_secret_options_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    secrets:
      - source: app_secret
        uid: "103"
        gid: "103"
        mode: 0440
secrets:
  app_secret:
    file: ./secret.txt
YAML
if ! (cd "$file_secret_options_dir" && "$binary" up --dry-run >/tmp/apple-compose-file-secret-options.out 2>&1); then
  echo "expected file-backed secret uid/gid/mode options to follow Docker Compose ignore behavior" >&2
  exit 1
fi
grep -F "secret.txt,target=/run/secrets/app_secret,readonly" /tmp/apple-compose-file-secret-options.out >/dev/null
if grep -F "uid/gid" /tmp/apple-compose-file-secret-options.out >/dev/null; then
  echo "expected file-backed secret uid/gid/mode options not to be reported as Apple gaps" >&2
  exit 1
fi

config_mode_dir="$tmpdir/config-mode"
mkdir -p "$config_mode_dir"
cat > "$config_mode_dir/compose.yaml" <<'YAML'
name: config_mode
services:
  web:
    image: nginx
    configs:
      - source: app_config
        target: /etc/app.conf
        mode: 440
configs:
  app_config:
    content: ok
YAML
if ! (cd "$config_mode_dir" && "$binary" up --dry-run >/tmp/apple-compose-config-mode.out 2>&1); then
  echo "expected generated config mode to be supported" >&2
  exit 1
fi
grep -F ".apple-compose/config_mode/configs/app_config mode 440" /tmp/apple-compose-config-mode.out >/dev/null
grep -F "target=/etc/app.conf,readonly" /tmp/apple-compose-config-mode.out >/dev/null
if grep -F "uid/gid" /tmp/apple-compose-config-mode.out >/dev/null; then
  echo "expected generated config mode alone not to warn as unsupported ownership" >&2
  exit 1
fi

config_uid_gap_dir="$tmpdir/config-uid-gap"
mkdir -p "$config_uid_gap_dir"
cat > "$config_uid_gap_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    configs:
      - source: app_config
        uid: "103"
        gid: "103"
configs:
  app_config:
    content: ok
YAML
if (cd "$config_uid_gap_dir" && "$binary" up --dry-run >/tmp/apple-compose-config-uid-gap.out 2>&1); then
  echo "expected strict up to reject generated config uid/gid ownership options" >&2
  exit 1
fi
grep -F "services.web.configs.app_config: uid/gid" /tmp/apple-compose-config-uid-gap.out >/dev/null
grep -F "ownership remapping" /tmp/apple-compose-config-uid-gap.out >/dev/null

file_config_mode_gap_dir="$tmpdir/file-config-mode-gap"
mkdir -p "$file_config_mode_gap_dir"
printf 'config' > "$file_config_mode_gap_dir/app.conf"
cat > "$file_config_mode_gap_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    configs:
      - source: app_config
        mode: 0440
configs:
  app_config:
    file: ./app.conf
YAML
if (cd "$file_config_mode_gap_dir" && "$binary" up --dry-run >/tmp/apple-compose-file-config-mode-gap.out 2>&1); then
  echo "expected strict up to reject file-backed config mode options" >&2
  exit 1
fi
grep -F "services.web.configs.app_config: mode" /tmp/apple-compose-file-config-mode-gap.out >/dev/null
grep -F "file-backed configs directly" /tmp/apple-compose-file-config-mode-gap.out >/dev/null

bad_build_grant_uid_shape_dir="$tmpdir/bad-build-grant-uid-shape"
mkdir -p "$bad_build_grant_uid_shape_dir"
cat > "$bad_build_grant_uid_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/web
    build:
      context: .
      secrets:
        - source: app_secret
          uid:
            id: 103
secrets:
  app_secret:
    environment: APP_SECRET
YAML
if (cd "$bad_build_grant_uid_shape_dir" && "$binary" config >/tmp/apple-compose-bad-build-grant-uid-shape.out 2>&1); then
  echo "expected invalid build secret uid shape to be rejected" >&2
  exit 1
fi

grep -F "build.secrets[0].uid must be a string" /tmp/apple-compose-bad-build-grant-uid-shape.out >/dev/null

bad_build_grant_numeric_uid_dir="$tmpdir/bad-build-grant-numeric-uid"
mkdir -p "$bad_build_grant_numeric_uid_dir"
cat > "$bad_build_grant_numeric_uid_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/web
    build:
      context: .
      secrets:
        - source: app_secret
          uid: 103
secrets:
  app_secret:
    environment: APP_SECRET
YAML
if (cd "$bad_build_grant_numeric_uid_dir" && "$binary" config >/tmp/apple-compose-bad-build-grant-numeric-uid.out 2>&1); then
  echo "expected numeric build secret uid to be rejected" >&2
  exit 1
fi

grep -F "build.secrets[0].uid must be a string" /tmp/apple-compose-bad-build-grant-numeric-uid.out >/dev/null

bad_build_grant_unknown_key_dir="$tmpdir/bad-build-grant-unknown-key"
mkdir -p "$bad_build_grant_unknown_key_dir"
cat > "$bad_build_grant_unknown_key_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/web
    build:
      context: .
      secrets:
        - source: app_secret
          target: cert
          sharing: locked
secrets:
  app_secret:
    environment: APP_SECRET
YAML
if (cd "$bad_build_grant_unknown_key_dir" && "$binary" config >/tmp/apple-compose-bad-build-grant-unknown-key.out 2>&1); then
  echo "expected unknown build secret grant keys to be rejected" >&2
  exit 1
fi
grep -F "Service 'web' build.secrets[0] contains unsupported key 'sharing'" /tmp/apple-compose-bad-build-grant-unknown-key.out >/dev/null

build_secret_options_gap_dir="$tmpdir/build-secret-options-gap"
mkdir -p "$build_secret_options_gap_dir"
cat > "$build_secret_options_gap_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/web
    build:
      context: .
      secrets:
        - source: app_secret
          target: cert
          uid: "103"
          gid: "103"
          mode: 0440
secrets:
  app_secret:
    environment: APP_SECRET
YAML
if (cd "$build_secret_options_gap_dir" && APP_SECRET=secret "$binary" up --dry-run >/tmp/apple-compose-build-secret-options-gap.out 2>&1); then
  echo "expected strict up to reject build secret uid/gid/mode options" >&2
  exit 1
fi

grep -F "services.web.build.secrets.app_secret: uid/gid/mode" /tmp/apple-compose-build-secret-options-gap.out >/dev/null
grep -F "only exposes id/env/src" /tmp/apple-compose-build-secret-options-gap.out >/dev/null

bad_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$extends_dir" "$include_dir" "$envvars_dir" "$disabled_env_dir" "$project_name_dir" "$selection_dir" "$pull_policy_dir" "$time_pull_dir" "$bad_env_format_dir" "$build_platform_dir" "$build_platform_mismatch_dir" "$random_port_dir" "$port_range_dir" "$scaled_port_dir" "$bad_volume_option_dir" "$bad_secret_dir" "$bad_build_secret_dir" "$bad_config_source_dir" "$bad_grant_source_dir" "$bad_grant_target_shape_dir" "$bad_grant_mode_shape_dir" "$secret_mode_dir" "$secret_uid_gap_dir" "$file_secret_options_dir" "$config_mode_dir" "$config_uid_gap_dir" "$file_config_mode_gap_dir" "$bad_build_grant_uid_shape_dir" "$build_secret_options_gap_dir" "$bad_dir"' EXIT
cat > "$bad_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    healthcheck:
      test: ["CMD", "true"]
YAML

if (cd "$bad_dir" && "$binary" up --dry-run >/tmp/apple-compose-bad.out 2>&1); then
  echo "expected strict up to reject unsupported healthcheck" >&2
  exit 1
fi

grep -F "healthcheck" /tmp/apple-compose-bad.out >/dev/null

bad_healthcheck_disable_shape_dir="$tmpdir/bad-healthcheck-disable-shape"
mkdir -p "$bad_healthcheck_disable_shape_dir"
cat > "$bad_healthcheck_disable_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    healthcheck:
      disable: "maybe"
YAML
if (cd "$bad_healthcheck_disable_shape_dir" && "$binary" config >/tmp/apple-compose-bad-healthcheck-disable-shape.out 2>&1); then
  echo "expected invalid healthcheck.disable string to be rejected" >&2
  exit 1
fi
grep -F "healthcheck.disable must be a boolean value or boolean string" /tmp/apple-compose-bad-healthcheck-disable-shape.out >/dev/null

bad_healthcheck_test_shape_dir="$tmpdir/bad-healthcheck-test-shape"
mkdir -p "$bad_healthcheck_test_shape_dir"
cat > "$bad_healthcheck_test_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    healthcheck:
      test: ["CMD", 123]
YAML
if (cd "$bad_healthcheck_test_shape_dir" && "$binary" config >/tmp/apple-compose-bad-healthcheck-test-shape.out 2>&1); then
  echo "expected non-string healthcheck.test entries to be rejected" >&2
  exit 1
fi
grep -F "healthcheck.test[1] must be a non-empty string" /tmp/apple-compose-bad-healthcheck-test-shape.out >/dev/null

bad_healthcheck_test_command_dir="$tmpdir/bad-healthcheck-test-command"
mkdir -p "$bad_healthcheck_test_command_dir"
cat > "$bad_healthcheck_test_command_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    healthcheck:
      test: ["RUN", "curl", "-f", "http://localhost"]
YAML
if (cd "$bad_healthcheck_test_command_dir" && "$binary" config >/tmp/apple-compose-bad-healthcheck-test-command.out 2>&1); then
  echo "expected invalid healthcheck.test command forms to be rejected" >&2
  exit 1
fi
grep -F "healthcheck.test[0] must be NONE, CMD, or CMD-SHELL" /tmp/apple-compose-bad-healthcheck-test-command.out >/dev/null

bad_healthcheck_duration_dir="$tmpdir/bad-healthcheck-duration"
mkdir -p "$bad_healthcheck_duration_dir"
cat > "$bad_healthcheck_duration_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    healthcheck:
      test: ["CMD", "true"]
      interval: 1d
YAML
if (cd "$bad_healthcheck_duration_dir" && "$binary" config >/tmp/apple-compose-bad-healthcheck-duration.out 2>&1); then
  echo "expected invalid healthcheck duration to be rejected" >&2
  exit 1
fi
grep -F "healthcheck.interval must be a valid Compose duration" /tmp/apple-compose-bad-healthcheck-duration.out >/dev/null

bad_healthcheck_retries_dir="$tmpdir/bad-healthcheck-retries"
mkdir -p "$bad_healthcheck_retries_dir"
cat > "$bad_healthcheck_retries_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    healthcheck:
      test: ["CMD", "true"]
      retries: -1
YAML
if (cd "$bad_healthcheck_retries_dir" && "$binary" config >/tmp/apple-compose-bad-healthcheck-retries.out 2>&1); then
  echo "expected negative healthcheck retries to be rejected" >&2
  exit 1
fi
grep -F "healthcheck.retries must be a non-negative integer value" /tmp/apple-compose-bad-healthcheck-retries.out >/dev/null

bad_healthcheck_unknown_dir="$tmpdir/bad-healthcheck-unknown"
mkdir -p "$bad_healthcheck_unknown_dir"
cat > "$bad_healthcheck_unknown_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    healthcheck:
      disable: true
      unexpected: true
YAML
if (cd "$bad_healthcheck_unknown_dir" && "$binary" config >/tmp/apple-compose-bad-healthcheck-unknown.out 2>&1); then
  echo "expected unknown healthcheck keys to be rejected during config parsing" >&2
  exit 1
fi
grep -F "Service 'web' healthcheck contains unsupported key 'unexpected'" /tmp/apple-compose-bad-healthcheck-unknown.out >/dev/null

disabled_healthcheck_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$extends_dir" "$include_dir" "$envvars_dir" "$disabled_env_dir" "$project_name_dir" "$selection_dir" "$pull_policy_dir" "$time_pull_dir" "$bad_env_format_dir" "$build_platform_dir" "$build_platform_mismatch_dir" "$random_port_dir" "$port_range_dir" "$scaled_port_dir" "$bad_volume_option_dir" "$bad_secret_dir" "$bad_build_secret_dir" "$bad_config_source_dir" "$bad_grant_source_dir" "$bad_dir" "$disabled_healthcheck_dir"' EXIT
cat > "$disabled_healthcheck_dir/compose.yaml" <<'YAML'
name: disabled_healthcheck
services:
  disabled_flag:
    image: nginx
    healthcheck:
      disable: "true"
  disabled_test:
    image: nginx
    healthcheck:
      test: ["NONE"]
YAML
disabled_healthcheck_plan="$(cd "$disabled_healthcheck_dir" && "$binary" plan)"
grep -F "disabled_healthcheck-disabled_flag-1" <<<"$disabled_healthcheck_plan" >/dev/null
grep -F "disabled_healthcheck-disabled_test-1" <<<"$disabled_healthcheck_plan" >/dev/null
if grep -F "healthcheck API" <<<"$disabled_healthcheck_plan" >/dev/null; then
  echo "expected disabled healthcheck forms to be accepted" >&2
  exit 1
fi

restart_no_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$extends_dir" "$bad_dir" "$disabled_healthcheck_dir" "$restart_no_dir"' EXIT
cat > "$restart_no_dir/compose.yaml" <<'YAML'
name: restart_no
services:
  web:
    image: nginx
    restart: "no"
YAML
restart_no_plan="$(cd "$restart_no_dir" && "$binary" plan)"
grep -F "restart_no-web-1" <<<"$restart_no_plan" >/dev/null
if grep -F "restart policies" <<<"$restart_no_plan" >/dev/null; then
  echo "expected restart no to be accepted as Compose default behavior" >&2
  exit 1
fi

bad_restart_false_dir="$tmpdir/bad-restart-false"
mkdir -p "$bad_restart_false_dir"
cat > "$bad_restart_false_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    restart: false
YAML
if (cd "$bad_restart_false_dir" && "$binary" config >/tmp/apple-compose-bad-restart-false.out 2>&1); then
  echo "expected boolean false restart policy to be rejected" >&2
  exit 1
fi
grep -F "restart must be a string" /tmp/apple-compose-bad-restart-false.out >/dev/null

bad_restart_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$extends_dir" "$bad_dir" "$disabled_healthcheck_dir" "$restart_no_dir" "$bad_restart_dir"' EXIT
cat > "$bad_restart_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    restart: unless-stopped
  retry:
    image: nginx
    restart: on-failure:3
YAML
if (cd "$bad_restart_dir" && "$binary" up --dry-run >/tmp/apple-compose-bad-restart.out 2>&1); then
  echo "expected strict up to reject active restart policies" >&2
  exit 1
fi

grep -F "restart" /tmp/apple-compose-bad-restart.out >/dev/null
grep -F "restart policies" /tmp/apple-compose-bad-restart.out >/dev/null

restart_string_dir="$tmpdir/restart-string"
mkdir -p "$restart_string_dir"
cat > "$restart_string_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    restart: sometimes
  retry:
    image: nginx
    restart: on-failure:many
YAML
(cd "$restart_string_dir" && "$binary" config >/tmp/apple-compose-restart-string.out)
grep -F "restart: sometimes" /tmp/apple-compose-restart-string.out >/dev/null
grep -F "restart: on-failure:many" /tmp/apple-compose-restart-string.out >/dev/null
if (cd "$restart_string_dir" && "$binary" up --dry-run >/tmp/apple-compose-restart-string-gap.out 2>&1); then
  echo "expected strict up to reject active arbitrary restart strings" >&2
  exit 1
fi
grep -F "services.web: restart" /tmp/apple-compose-restart-string-gap.out >/dev/null
grep -F "services.retry: restart" /tmp/apple-compose-restart-string-gap.out >/dev/null

restart_empty_dir="$tmpdir/restart-empty"
mkdir -p "$restart_empty_dir"
cat > "$restart_empty_dir/compose.yaml" <<'YAML'
name: restart_empty
services:
  web:
    image: nginx
    restart: ""
YAML
restart_empty_plan="$(cd "$restart_empty_dir" && "$binary" plan)"
grep -F "restart_empty-web-1" <<<"$restart_empty_plan" >/dev/null
if grep -F "restart policies" <<<"$restart_empty_plan" >/dev/null; then
  echo "expected empty restart string to be accepted as unset/default behavior" >&2
  exit 1
fi

bad_restart_shape_dir="$tmpdir/bad-restart-shape"
mkdir -p "$bad_restart_shape_dir"
cat > "$bad_restart_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    restart: true
YAML
if (cd "$bad_restart_shape_dir" && "$binary" config >/tmp/apple-compose-bad-restart-shape.out 2>&1); then
  echo "expected boolean true restart policy to be rejected" >&2
  exit 1
fi
grep -F "restart must be a string" /tmp/apple-compose-bad-restart-shape.out >/dev/null

privileged_false_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$extends_dir" "$bad_dir" "$disabled_healthcheck_dir" "$restart_no_dir" "$bad_restart_dir" "$privileged_false_dir"' EXIT
cat > "$privileged_false_dir/compose.yaml" <<'YAML'
name: privileged_false
services:
  web:
    image: nginx
    privileged: "false"
  builder:
    image: example/builder
    build:
      context: .
      dockerfile_inline: |
        FROM busybox
      privileged: "false"
YAML
privileged_false_plan="$(cd "$privileged_false_dir" && "$binary" plan)"
grep -F "privileged_false-web-1" <<<"$privileged_false_plan" >/dev/null
grep -F "container build --tag example/builder" <<<"$privileged_false_plan" >/dev/null
if grep -F "privileged" <<<"$privileged_false_plan" | grep -F "no Apple" >/dev/null; then
  echo "expected privileged=false to be accepted as default behavior" >&2
  exit 1
fi

bad_service_privileged_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$extends_dir" "$bad_dir" "$disabled_healthcheck_dir" "$restart_no_dir" "$bad_restart_dir" "$privileged_false_dir" "$bad_service_privileged_dir"' EXIT
cat > "$bad_service_privileged_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    privileged: true
YAML
if (cd "$bad_service_privileged_dir" && "$binary" up --dry-run >/tmp/apple-compose-bad-service-privileged.out 2>&1); then
  echo "expected strict up to reject privileged service containers" >&2
  exit 1
fi

grep -F "services.web: privileged" /tmp/apple-compose-bad-service-privileged.out >/dev/null

bad_build_privileged_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$extends_dir" "$bad_dir" "$disabled_healthcheck_dir" "$restart_no_dir" "$bad_restart_dir" "$privileged_false_dir" "$bad_service_privileged_dir" "$bad_build_privileged_dir"' EXIT
cat > "$bad_build_privileged_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/web
    build:
      context: .
      dockerfile_inline: |
        FROM busybox
      privileged: true
YAML
if (cd "$bad_build_privileged_dir" && "$binary" up --dry-run >/tmp/apple-compose-bad-build-privileged.out 2>&1); then
  echo "expected strict up to reject privileged image builds" >&2
  exit 1
fi

grep -F "services.web.build: privileged" /tmp/apple-compose-bad-build-privileged.out >/dev/null

bad_build_privileged_shape_dir="$tmpdir/bad-build-privileged-shape"
mkdir -p "$bad_build_privileged_shape_dir"
cat > "$bad_build_privileged_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/web
    build:
      context: .
      privileged: "maybe"
YAML
if (cd "$bad_build_privileged_shape_dir" && "$binary" config >/tmp/apple-compose-bad-build-privileged-shape.out 2>&1); then
  echo "expected invalid build privileged string values to be rejected" >&2
  exit 1
fi
grep -F "build.privileged must be a boolean value or boolean string" /tmp/apple-compose-bad-build-privileged-shape.out >/dev/null

attestation_false_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$extends_dir" "$bad_dir" "$disabled_healthcheck_dir" "$restart_no_dir" "$bad_restart_dir" "$privileged_false_dir" "$bad_service_privileged_dir" "$bad_build_privileged_dir" "$attestation_false_dir"' EXIT
cat > "$attestation_false_dir/compose.yaml" <<'YAML'
name: attestation_false
services:
  web:
    image: example/attest
    build:
      context: .
      dockerfile_inline: |
        FROM busybox
      provenance: "false"
      sbom: "false"
YAML
attestation_false_plan="$(cd "$attestation_false_dir" && "$binary" plan)"
grep -F "container build --tag example/attest" <<<"$attestation_false_plan" >/dev/null
if grep -F "attestations are not exposed" <<<"$attestation_false_plan" >/dev/null; then
  echo "expected disabled build attestations to be accepted as default behavior" >&2
  exit 1
fi

attestation_empty_dir="$tmpdir/attestation-empty"
mkdir -p "$attestation_empty_dir"
cat > "$attestation_empty_dir/compose.yaml" <<'YAML'
name: attestation_empty
services:
  web:
    image: example/attest-empty
    build:
      context: .
      dockerfile_inline: |
        FROM busybox
      provenance: ""
      sbom: ""
YAML
attestation_empty_plan="$(cd "$attestation_empty_dir" && "$binary" plan)"
grep -F "container build --tag example/attest-empty" <<<"$attestation_empty_plan" >/dev/null
if grep -F "attestations are not exposed" <<<"$attestation_empty_plan" >/dev/null; then
  echo "expected empty build attestations to be accepted as default behavior" >&2
  exit 1
fi

bad_attestation_shape_dir="$tmpdir/bad-attestation-shape"
mkdir -p "$bad_attestation_shape_dir"
cat > "$bad_attestation_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/attest
    build:
      context: .
      provenance:
        enabled: true
YAML
if (cd "$bad_attestation_shape_dir" && "$binary" config >/tmp/apple-compose-bad-attestation-shape.out 2>&1); then
  echo "expected invalid provenance shape to be rejected" >&2
  exit 1
fi
grep -F "build.provenance must be a boolean value or non-empty string" /tmp/apple-compose-bad-attestation-shape.out >/dev/null

attestation_string_dir="$tmpdir/attestation-string"
mkdir -p "$attestation_string_dir"
cat > "$attestation_string_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/attest
    build:
      context: .
      provenance: max
      sbom: maybe
YAML
(cd "$attestation_string_dir" && "$binary" config >/tmp/apple-compose-attestation-string.out)
grep -F "provenance: max" /tmp/apple-compose-attestation-string.out >/dev/null
grep -F "sbom: maybe" /tmp/apple-compose-attestation-string.out >/dev/null
if (cd "$attestation_string_dir" && "$binary" up --dry-run >/tmp/apple-compose-attestation-string-gap.out 2>&1); then
  echo "expected strict up to reject configured build attestation strings" >&2
  exit 1
fi
grep -F "services.web.build: provenance" /tmp/apple-compose-attestation-string-gap.out >/dev/null
grep -F "services.web.build: sbom" /tmp/apple-compose-attestation-string-gap.out >/dev/null

build_cache_dir="$tmpdir/build-cache"
mkdir -p "$build_cache_dir"
cat > "$build_cache_dir/compose.yaml" <<'YAML'
name: build_cache
services:
  web:
    image: example/cache
    build:
      context: .
      dockerfile_inline: |
        FROM busybox
      cache_from:
        - type=registry,ref=example/cache:buildcache
      cache_to:
        - type=local,dest=.build-cache
YAML
if ! (cd "$build_cache_dir" && "$binary" up --dry-run >/tmp/apple-compose-build-cache.out 2>&1); then
  cat /tmp/apple-compose-build-cache.out >&2
  echo "expected strict up to accept unsupported Compose build cache hints as ignored warnings" >&2
  exit 1
fi

grep -F "services.web.build: cache_from" /tmp/apple-compose-build-cache.out >/dev/null
grep -F "services.web.build: cache_to" /tmp/apple-compose-build-cache.out >/dev/null
grep -F "permits unsupported cache sources to be ignored" /tmp/apple-compose-build-cache.out >/dev/null
grep -F "container build --tag example/cache" /tmp/apple-compose-build-cache.out >/dev/null
if grep -F -- "--cache" /tmp/apple-compose-build-cache.out >/dev/null; then
  echo "expected Apple build command not to include unsupported cache flags" >&2
  exit 1
fi

empty_build_cache_dir="$tmpdir/empty-build-cache"
mkdir -p "$empty_build_cache_dir"
cat > "$empty_build_cache_dir/compose.yaml" <<'YAML'
name: empty_build_cache
services:
  web:
    image: example/cache
    build:
      context: .
      dockerfile_inline: |
        FROM busybox
      cache_from: []
      cache_to: []
YAML
empty_build_cache_plan="$(cd "$empty_build_cache_dir" && "$binary" plan)"
grep -F "empty_build_cache-web-1" <<<"$empty_build_cache_plan" >/dev/null
if grep -F "services.web.build: cache_from" <<<"$empty_build_cache_plan" >/dev/null; then
  echo "expected empty cache_from to be accepted as a no-op" >&2
  exit 1
fi
if grep -F "services.web.build: cache_to" <<<"$empty_build_cache_plan" >/dev/null; then
  echo "expected empty cache_to to be accepted as a no-op" >&2
  exit 1
fi

bad_build_additional_contexts_shape_dir="$tmpdir/bad-build-additional-contexts-shape"
mkdir -p "$bad_build_additional_contexts_shape_dir"
cat > "$bad_build_additional_contexts_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/web
    build:
      context: .
      additional_contexts: true
YAML
if (cd "$bad_build_additional_contexts_shape_dir" && "$binary" config >/tmp/apple-compose-bad-build-additional-contexts-shape.out 2>&1); then
  echo "expected invalid build.additional_contexts shape to be rejected" >&2
  exit 1
fi
grep -F "build.additional_contexts must be a mapping or list of NAME=VALUE strings" /tmp/apple-compose-bad-build-additional-contexts-shape.out >/dev/null

build_additional_contexts_dir="$tmpdir/build-additional-contexts"
mkdir -p "$build_additional_contexts_dir"
cat > "$build_additional_contexts_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/web
    build:
      context: .
      additional_contexts:
        - resources=/path/to/resources
        - app=docker-image://my-app:latest
YAML
if (cd "$build_additional_contexts_dir" && "$binary" up --dry-run >/tmp/apple-compose-build-additional-contexts.out 2>&1); then
  echo "expected strict up to reject unsupported build.additional_contexts" >&2
  exit 1
fi
grep -F "services.web.build: additional_contexts" /tmp/apple-compose-build-additional-contexts.out >/dev/null
grep -F "BuildKit additional contexts" /tmp/apple-compose-build-additional-contexts.out >/dev/null

bad_build_additional_contexts_key_dir="$tmpdir/bad-build-additional-contexts-key"
mkdir -p "$bad_build_additional_contexts_key_dir"
cat > "$bad_build_additional_contexts_key_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/web
    build:
      context: .
      additional_contexts:
        "": /path/to/resources
YAML
if (cd "$bad_build_additional_contexts_key_dir" && "$binary" config >/tmp/apple-compose-bad-build-additional-contexts-key.out 2>&1); then
  echo "expected empty build.additional_contexts names to be rejected" >&2
  exit 1
fi
grep -F "build.additional_contexts keys must not be empty" /tmp/apple-compose-bad-build-additional-contexts-key.out >/dev/null

bad_build_additional_contexts_syntax_dir="$tmpdir/bad-build-additional-contexts-syntax"
mkdir -p "$bad_build_additional_contexts_syntax_dir"
cat > "$bad_build_additional_contexts_syntax_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/web
    build:
      context: .
      additional_contexts:
        - resources
YAML
if (cd "$bad_build_additional_contexts_syntax_dir" && "$binary" config >/tmp/apple-compose-bad-build-additional-contexts-syntax.out 2>&1); then
  echo "expected malformed build.additional_contexts entries to be rejected" >&2
  exit 1
fi
grep -F "build.additional_contexts[0] must use NAME=VALUE syntax" /tmp/apple-compose-bad-build-additional-contexts-syntax.out >/dev/null

bad_build_cache_shape_dir="$tmpdir/bad-build-cache-shape"
mkdir -p "$bad_build_cache_shape_dir"
cat > "$bad_build_cache_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/web
    build:
      context: .
      cache_from: type=gha
YAML
if (cd "$bad_build_cache_shape_dir" && "$binary" config >/tmp/apple-compose-bad-build-cache-shape.out 2>&1); then
  echo "expected scalar build.cache_from to be rejected" >&2
  exit 1
fi
grep -F "build.cache_from must be a list of strings" /tmp/apple-compose-bad-build-cache-shape.out >/dev/null

bad_build_extra_hosts_shape_dir="$tmpdir/bad-build-extra-hosts-shape"
mkdir -p "$bad_build_extra_hosts_shape_dir"
cat > "$bad_build_extra_hosts_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/web
    build:
      context: .
      extra_hosts: false
YAML
if (cd "$bad_build_extra_hosts_shape_dir" && "$binary" config >/tmp/apple-compose-bad-build-extra-hosts-shape.out 2>&1); then
  echo "expected invalid build.extra_hosts shape to be rejected" >&2
  exit 1
fi
grep -F "build.extra_hosts must be a mapping or list of strings" /tmp/apple-compose-bad-build-extra-hosts-shape.out >/dev/null

build_extra_hosts_dir="$tmpdir/build-extra-hosts"
mkdir -p "$build_extra_hosts_dir"
cat > "$build_extra_hosts_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/web
    build:
      context: .
      extra_hosts:
        - somehost=162.242.195.82
        - myhostv6=[::1]
YAML
if (cd "$build_extra_hosts_dir" && "$binary" up --dry-run >/tmp/apple-compose-build-extra-hosts.out 2>&1); then
  echo "expected strict up to reject unsupported build.extra_hosts" >&2
  exit 1
fi
grep -F "services.web.build: extra_hosts" /tmp/apple-compose-build-extra-hosts.out >/dev/null
grep -F "Build extra_hosts are not exposed" /tmp/apple-compose-build-extra-hosts.out >/dev/null

bad_build_extra_hosts_syntax_dir="$tmpdir/bad-build-extra-hosts-syntax"
mkdir -p "$bad_build_extra_hosts_syntax_dir"
cat > "$bad_build_extra_hosts_syntax_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/web
    build:
      context: .
      extra_hosts:
        - somehost
YAML
if (cd "$bad_build_extra_hosts_syntax_dir" && "$binary" config >/tmp/apple-compose-bad-build-extra-hosts-syntax.out 2>&1); then
  echo "expected malformed build.extra_hosts entries to be rejected" >&2
  exit 1
fi
grep -F "build.extra_hosts[0] must use HOSTNAME=IP or HOSTNAME:IP syntax" /tmp/apple-compose-bad-build-extra-hosts-syntax.out >/dev/null

bad_build_extra_hosts_ip_dir="$tmpdir/bad-build-extra-hosts-ip"
mkdir -p "$bad_build_extra_hosts_ip_dir"
cat > "$bad_build_extra_hosts_ip_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/web
    build:
      context: .
      extra_hosts:
        somehost: not-an-ip
YAML
if (cd "$bad_build_extra_hosts_ip_dir" && "$binary" config >/tmp/apple-compose-bad-build-extra-hosts-ip.out 2>&1); then
  echo "expected invalid build.extra_hosts IP values to be rejected" >&2
  exit 1
fi
grep -F "build.extra_hosts.somehost must be a valid IPv4 or IPv6 address" /tmp/apple-compose-bad-build-extra-hosts-ip.out >/dev/null

build_ssh_scalar_dir="$tmpdir/build-ssh-scalar"
mkdir -p "$build_ssh_scalar_dir"
cat > "$build_ssh_scalar_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/web
    build:
      context: .
      ssh: default
YAML
if (cd "$build_ssh_scalar_dir" && "$binary" up --dry-run >/tmp/apple-compose-build-ssh-scalar.out 2>&1); then
  echo "expected strict up to reject unsupported scalar build.ssh" >&2
  exit 1
fi
grep -F "services.web.build: ssh" /tmp/apple-compose-build-ssh-scalar.out >/dev/null
grep -F "Build SSH mounts are not exposed" /tmp/apple-compose-build-ssh-scalar.out >/dev/null

build_ssh_list_dir="$tmpdir/build-ssh-list"
mkdir -p "$build_ssh_list_dir"
cat > "$build_ssh_list_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/web
    build:
      context: .
      ssh:
        - default
        - myproject=~/.ssh/myproject.pem
YAML
if (cd "$build_ssh_list_dir" && "$binary" up --dry-run >/tmp/apple-compose-build-ssh-list.out 2>&1); then
  echo "expected strict up to reject unsupported build.ssh list syntax after validation" >&2
  exit 1
fi
grep -F "services.web.build: ssh" /tmp/apple-compose-build-ssh-list.out >/dev/null
grep -F "Build SSH mounts are not exposed" /tmp/apple-compose-build-ssh-list.out >/dev/null

build_ssh_map_dir="$tmpdir/build-ssh-map"
mkdir -p "$build_ssh_map_dir"
cat > "$build_ssh_map_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/web
    build:
      context: .
      ssh:
        default:
        myproject: ~/.ssh/myproject.pem
YAML
if (cd "$build_ssh_map_dir" && "$binary" up --dry-run >/tmp/apple-compose-build-ssh-map.out 2>&1); then
  echo "expected strict up to reject unsupported build.ssh map syntax after validation" >&2
  exit 1
fi
grep -F "services.web.build: ssh" /tmp/apple-compose-build-ssh-map.out >/dev/null
grep -F "Build SSH mounts are not exposed" /tmp/apple-compose-build-ssh-map.out >/dev/null

bad_build_ssh_syntax_dir="$tmpdir/bad-build-ssh-syntax"
mkdir -p "$bad_build_ssh_syntax_dir"
cat > "$bad_build_ssh_syntax_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/web
    build:
      context: .
      ssh:
        - myproject=
YAML
if (cd "$bad_build_ssh_syntax_dir" && "$binary" config >/tmp/apple-compose-bad-build-ssh-syntax.out 2>&1); then
  echo "expected malformed build.ssh syntax to be rejected" >&2
  exit 1
fi
grep -F "build.ssh[0] must be 'default' or use ID=path syntax" /tmp/apple-compose-bad-build-ssh-syntax.out >/dev/null

bad_build_ssh_map_value_dir="$tmpdir/bad-build-ssh-map-value"
mkdir -p "$bad_build_ssh_map_value_dir"
cat > "$bad_build_ssh_map_value_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/web
    build:
      context: .
      ssh:
        myproject:
YAML
if (cd "$bad_build_ssh_map_value_dir" && "$binary" config >/tmp/apple-compose-bad-build-ssh-map-value.out 2>&1); then
  echo "expected build.ssh map entries without non-default paths to be rejected" >&2
  exit 1
fi
grep -F "build.ssh.myproject must be a non-empty SSH key path" /tmp/apple-compose-bad-build-ssh-map-value.out >/dev/null

bad_build_ssh_shape_dir="$tmpdir/bad-build-ssh-shape"
mkdir -p "$bad_build_ssh_shape_dir"
cat > "$bad_build_ssh_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/web
    build:
      context: .
      ssh:
        - true
YAML
if (cd "$bad_build_ssh_shape_dir" && "$binary" config >/tmp/apple-compose-bad-build-ssh-shape.out 2>&1); then
  echo "expected invalid build.ssh entries to be rejected" >&2
  exit 1
fi
grep -F "build.ssh[0] must be a non-empty string" /tmp/apple-compose-bad-build-ssh-shape.out >/dev/null

bad_build_unknown_key_dir="$tmpdir/bad-build-unknown-key"
mkdir -p "$bad_build_unknown_key_dir"
cat > "$bad_build_unknown_key_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/web
    build:
      context: .
      outputs:
        - type=docker
YAML
if (cd "$bad_build_unknown_key_dir" && "$binary" config >/tmp/apple-compose-bad-build-unknown-key.out 2>&1); then
  echo "expected unsupported build keys to be rejected" >&2
  exit 1
fi
grep -F "Service 'web' build contains unsupported key 'outputs'" /tmp/apple-compose-bad-build-unknown-key.out >/dev/null

bad_build_isolation_shape_dir="$tmpdir/bad-build-isolation-shape"
mkdir -p "$bad_build_isolation_shape_dir"
cat > "$bad_build_isolation_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/web
    build:
      context: .
      isolation:
        mode: default
YAML
if (cd "$bad_build_isolation_shape_dir" && "$binary" config >/tmp/apple-compose-bad-build-isolation-shape.out 2>&1); then
  echo "expected invalid build.isolation shape to be rejected" >&2
  exit 1
fi
grep -F "build.isolation must be a string" /tmp/apple-compose-bad-build-isolation-shape.out >/dev/null

build_network_default_dir="$tmpdir/build-network-default"
mkdir -p "$build_network_default_dir"
cat > "$build_network_default_dir/compose.yaml" <<'YAML'
name: build_network_default
services:
  web:
    image: example/web
    build:
      context: .
      dockerfile_inline: |
        FROM busybox
      network: default
YAML
build_network_default_plan="$(cd "$build_network_default_dir" && "$binary" plan)"
grep -F "container build --tag example/web" <<<"$build_network_default_plan" >/dev/null
if grep -F "services.web.build: network" <<<"$build_network_default_plan" >/dev/null; then
  echo "expected build.network=default to be accepted as default behavior" >&2
  exit 1
fi

bad_build_network_dir="$tmpdir/bad-build-network"
mkdir -p "$bad_build_network_dir"
cat > "$bad_build_network_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/web
    build:
      context: .
      dockerfile_inline: |
        FROM busybox
      network: none
YAML
if (cd "$bad_build_network_dir" && "$binary" up --dry-run >/tmp/apple-compose-bad-build-network.out 2>&1); then
  echo "expected strict up to reject active build network modes" >&2
  exit 1
fi

grep -F "services.web.build: network" /tmp/apple-compose-bad-build-network.out >/dev/null
grep -F "default build network" /tmp/apple-compose-bad-build-network.out >/dev/null

bad_build_network_shape_dir="$tmpdir/bad-build-network-shape"
mkdir -p "$bad_build_network_shape_dir"
cat > "$bad_build_network_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/web
    build:
      context: .
      network:
        name: default
YAML
if (cd "$bad_build_network_shape_dir" && "$binary" config >/tmp/apple-compose-bad-build-network-shape.out 2>&1); then
  echo "expected invalid build.network shape to be rejected" >&2
  exit 1
fi
grep -F "build.network must be a string" /tmp/apple-compose-bad-build-network-shape.out >/dev/null

bad_attestation_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$extends_dir" "$bad_dir" "$disabled_healthcheck_dir" "$restart_no_dir" "$bad_restart_dir" "$privileged_false_dir" "$bad_service_privileged_dir" "$bad_build_privileged_dir" "$attestation_false_dir" "$bad_attestation_dir"' EXIT
cat > "$bad_attestation_dir/compose.yaml" <<'YAML'
services:
  web:
    image: example/attest
    build:
      context: .
      dockerfile_inline: |
        FROM busybox
      provenance: true
      sbom: generator=docker/scout-sbom-indexer:latest
YAML
if (cd "$bad_attestation_dir" && "$binary" up --dry-run >/tmp/apple-compose-bad-attestation.out 2>&1); then
  echo "expected strict up to reject enabled build attestations" >&2
  exit 1
fi

grep -F "services.web.build: provenance" /tmp/apple-compose-bad-attestation.out >/dev/null
grep -F "services.web.build: sbom" /tmp/apple-compose-bad-attestation.out >/dev/null

cpu_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$extends_dir" "$bad_dir" "$disabled_healthcheck_dir" "$restart_no_dir" "$bad_restart_dir" "$privileged_false_dir" "$bad_service_privileged_dir" "$bad_build_privileged_dir" "$attestation_false_dir" "$bad_attestation_dir" "$cpu_dir"' EXIT
cat > "$cpu_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    cpu_shares: 128
YAML

if (cd "$cpu_dir" && "$binary" up --dry-run >/tmp/apple-compose-cpu.out 2>&1); then
  echo "expected strict up to reject unsupported cpu_shares" >&2
  exit 1
fi

grep -F "cpu_shares" /tmp/apple-compose-cpu.out >/dev/null

privileged_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$extends_dir" "$bad_dir" "$cpu_dir" "$privileged_dir"' EXIT
cat > "$privileged_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    post_start:
      - command: echo nope
        privileged: true
YAML

if (cd "$privileged_dir" && "$binary" up --dry-run >/tmp/apple-compose-privileged.out 2>&1); then
  echo "expected strict up to reject privileged lifecycle hook" >&2
  exit 1
fi

grep -F "privileged lifecycle hook" /tmp/apple-compose-privileged.out >/dev/null

bad_top_name_shape_dir="$tmpdir/bad-top-name-shape"
mkdir -p "$bad_top_name_shape_dir"
cat > "$bad_top_name_shape_dir/compose.yaml" <<'YAML'
name: true
services:
  web:
    image: nginx
YAML

if (cd "$bad_top_name_shape_dir" && "$binary" config >/tmp/apple-compose-bad-top-name-shape.out 2>&1); then
  echo "expected non-string top-level name to be rejected" >&2
  exit 1
fi
grep -F "Top-level name must be a string" /tmp/apple-compose-bad-top-name-shape.out >/dev/null

bad_top_version_shape_dir="$tmpdir/bad-top-version-shape"
mkdir -p "$bad_top_version_shape_dir"
cat > "$bad_top_version_shape_dir/compose.yaml" <<'YAML'
version: 3.9
services:
  web:
    image: nginx
YAML

if (cd "$bad_top_version_shape_dir" && "$binary" config >/tmp/apple-compose-bad-top-version-shape.out 2>&1); then
  echo "expected non-string top-level version to be rejected" >&2
  exit 1
fi
grep -F "Top-level version must be a string" /tmp/apple-compose-bad-top-version-shape.out >/dev/null

unknown_top_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$extends_dir" "$bad_dir" "$cpu_dir" "$privileged_dir" "$unknown_top_dir"' EXIT
cat > "$unknown_top_dir/compose.yaml" <<'YAML'
x-template:
  image: nginx
services:
  web:
    image: nginx
not_a_compose_section:
  web: true
YAML

if (cd "$unknown_top_dir" && "$binary" up --dry-run >/tmp/apple-compose-unknown-top.out 2>&1); then
  echo "expected strict up to reject unknown top-level Compose fields" >&2
  exit 1
fi

grep -F "not_a_compose_section" /tmp/apple-compose-unknown-top.out >/dev/null

bad_network_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$extends_dir" "$bad_dir" "$cpu_dir" "$privileged_dir" "$unknown_top_dir" "$bad_network_dir"' EXIT
cat > "$bad_network_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    networks:
      - app
networks:
  app:
    attachable: true
YAML

if (cd "$bad_network_dir" && "$binary" up --dry-run >/tmp/apple-compose-bad-network.out 2>&1); then
  echo "expected strict up to reject unsupported network attachable flag" >&2
  exit 1
fi

grep -F "attachable" /tmp/apple-compose-bad-network.out >/dev/null

nested_unknown_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$extends_dir" "$bad_dir" "$cpu_dir" "$privileged_dir" "$unknown_top_dir" "$bad_network_dir" "$nested_unknown_dir"' EXIT
cat > "$nested_unknown_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    ports:
      - target: 80
        published: "8080"
        x-note: allowed
        unexpected_port_option: true
YAML

if (cd "$nested_unknown_dir" && "$binary" up --dry-run >/tmp/apple-compose-nested-unknown.out 2>&1); then
  echo "expected strict up to reject unknown nested Compose fields" >&2
  exit 1
fi

grep -F "unexpected_port_option" /tmp/apple-compose-nested-unknown.out >/dev/null

nested_warning_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$extends_dir" "$bad_dir" "$cpu_dir" "$privileged_dir" "$unknown_top_dir" "$bad_network_dir" "$nested_unknown_dir" "$nested_warning_dir"' EXIT
cat > "$nested_warning_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    ports:
      - target: 80
        published: "8080"
        mode: host
    volumes:
      - type: bind
        source: ./data
        target: /data
        bind:
          create_host_path: true
YAML

nested_warning_plan="$(cd "$nested_warning_dir" && "$binary" plan)"
if grep -F "ports[0]: mode" <<<"$nested_warning_plan" >/dev/null; then
  echo "expected long-form port mode=host to be accepted without a compatibility warning" >&2
  exit 1
fi
grep -F "/bin/mkdir -p" <<<"$nested_warning_plan" | grep -F "/data" >/dev/null

bad_command_shape_dir="$tmpdir/bad-command-shape"
mkdir -p "$bad_command_shape_dir"
cat > "$bad_command_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    command:
      - echo
      - args:
          nested: invalid
YAML

if (cd "$bad_command_shape_dir" && "$binary" config >/tmp/apple-compose-bad-command-shape.out 2>&1); then
  echo "expected invalid command list entries to be rejected" >&2
  exit 1
fi
grep -F "command[1] must be a command argument string" /tmp/apple-compose-bad-command-shape.out >/dev/null

bad_command_scalar_shape_dir="$tmpdir/bad-command-scalar-shape"
mkdir -p "$bad_command_scalar_shape_dir"
cat > "$bad_command_scalar_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    command: true
YAML

if (cd "$bad_command_scalar_shape_dir" && "$binary" config >/tmp/apple-compose-bad-command-scalar-shape.out 2>&1); then
  echo "expected non-string command scalar values to be rejected" >&2
  exit 1
fi
grep -F "command must be a string" /tmp/apple-compose-bad-command-scalar-shape.out >/dev/null

bad_entrypoint_arg_shape_dir="$tmpdir/bad-entrypoint-arg-shape"
mkdir -p "$bad_entrypoint_arg_shape_dir"
cat > "$bad_entrypoint_arg_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    entrypoint:
      - 123
YAML

if (cd "$bad_entrypoint_arg_shape_dir" && "$binary" config >/tmp/apple-compose-bad-entrypoint-arg-shape.out 2>&1); then
  echo "expected non-string entrypoint list entries to be rejected" >&2
  exit 1
fi
grep -F "entrypoint[0] must be a command argument string" /tmp/apple-compose-bad-entrypoint-arg-shape.out >/dev/null

bad_hook_command_shape_dir="$tmpdir/bad-hook-command-shape"
mkdir -p "$bad_hook_command_shape_dir"
cat > "$bad_hook_command_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    post_start:
      - command:
          - echo
          - [nested]
YAML

if (cd "$bad_hook_command_shape_dir" && "$binary" config >/tmp/apple-compose-bad-hook-command-shape.out 2>&1); then
  echo "expected invalid lifecycle hook command list entries to be rejected" >&2
  exit 1
fi
grep -F "post_start[0].command[1] must be a command argument string" /tmp/apple-compose-bad-hook-command-shape.out >/dev/null

bad_hook_shape_dir="$tmpdir/bad-hook-shape"
mkdir -p "$bad_hook_shape_dir"
cat > "$bad_hook_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    post_start: echo started
YAML

if (cd "$bad_hook_shape_dir" && "$binary" config >/tmp/apple-compose-bad-hook-shape.out 2>&1); then
  echo "expected scalar lifecycle hooks to be rejected" >&2
  exit 1
fi
grep -F "post_start must be a list of hook mappings" /tmp/apple-compose-bad-hook-shape.out >/dev/null

bad_hook_item_shape_dir="$tmpdir/bad-hook-item-shape"
mkdir -p "$bad_hook_item_shape_dir"
cat > "$bad_hook_item_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    pre_stop:
      - ["echo", "stopping"]
YAML

if (cd "$bad_hook_item_shape_dir" && "$binary" config >/tmp/apple-compose-bad-hook-item-shape.out 2>&1); then
  echo "expected non-mapping lifecycle hook entries to be rejected" >&2
  exit 1
fi
grep -F "pre_stop[0] must be a mapping" /tmp/apple-compose-bad-hook-item-shape.out >/dev/null

bad_hook_missing_command_dir="$tmpdir/bad-hook-missing-command"
mkdir -p "$bad_hook_missing_command_dir"
cat > "$bad_hook_missing_command_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    post_start:
      - user: root
YAML

if (cd "$bad_hook_missing_command_dir" && "$binary" config >/tmp/apple-compose-bad-hook-missing-command.out 2>&1); then
  echo "expected lifecycle hooks without command to be rejected" >&2
  exit 1
fi
grep -F "post_start[0].command is required" /tmp/apple-compose-bad-hook-missing-command.out >/dev/null

bad_hook_privileged_shape_dir="$tmpdir/bad-hook-privileged-shape"
mkdir -p "$bad_hook_privileged_shape_dir"
cat > "$bad_hook_privileged_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    post_start:
      - command: echo ok
        privileged: "maybe"
YAML

if (cd "$bad_hook_privileged_shape_dir" && "$binary" config >/tmp/apple-compose-bad-hook-privileged-shape.out 2>&1); then
  echo "expected invalid lifecycle hook privileged string to be rejected" >&2
  exit 1
fi
grep -F "post_start[0].privileged must be a boolean value or boolean string" /tmp/apple-compose-bad-hook-privileged-shape.out >/dev/null

bad_hook_unknown_key_dir="$tmpdir/bad-hook-unknown-key"
mkdir -p "$bad_hook_unknown_key_dir"
cat > "$bad_hook_unknown_key_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    pre_stop:
      - command: echo stopping
        timeout: 1s
YAML

if (cd "$bad_hook_unknown_key_dir" && "$binary" config >/tmp/apple-compose-bad-hook-unknown-key.out 2>&1); then
  echo "expected unsupported lifecycle hook keys to be rejected" >&2
  exit 1
fi
grep -F "pre_stop[0] contains unsupported key 'timeout'" /tmp/apple-compose-bad-hook-unknown-key.out >/dev/null

bad_hook_workdir_shape_dir="$tmpdir/bad-hook-workdir-shape"
mkdir -p "$bad_hook_workdir_shape_dir"
cat > "$bad_hook_workdir_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    pre_stop:
      - command: echo ok
        working_dir:
          - /srv
YAML

if (cd "$bad_hook_workdir_shape_dir" && "$binary" config >/tmp/apple-compose-bad-hook-workdir-shape.out 2>&1); then
  echo "expected invalid lifecycle hook working_dir shape to be rejected" >&2
  exit 1
fi
grep -F "pre_stop[0].working_dir must be a string" /tmp/apple-compose-bad-hook-workdir-shape.out >/dev/null

bad_hook_user_shape_dir="$tmpdir/bad-hook-user-shape"
mkdir -p "$bad_hook_user_shape_dir"
cat > "$bad_hook_user_shape_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    post_start:
      - command: echo ok
        user:
          name: root
YAML

if (cd "$bad_hook_user_shape_dir" && "$binary" config >/tmp/apple-compose-bad-hook-user-shape.out 2>&1); then
  echo "expected invalid lifecycle hook user shape to be rejected" >&2
  exit 1
fi
grep -F "post_start[0].user must be a string" /tmp/apple-compose-bad-hook-user-shape.out >/dev/null

bad_hook_numeric_user_dir="$tmpdir/bad-hook-numeric-user"
mkdir -p "$bad_hook_numeric_user_dir"
cat > "$bad_hook_numeric_user_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    post_start:
      - command: echo ok
        user: 1000
YAML

if (cd "$bad_hook_numeric_user_dir" && "$binary" config >/tmp/apple-compose-bad-hook-numeric-user.out 2>&1); then
  echo "expected numeric lifecycle hook user to be rejected" >&2
  exit 1
fi
grep -F "post_start[0].user must be a string" /tmp/apple-compose-bad-hook-numeric-user.out >/dev/null

empty_command_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$extends_dir" "$bad_dir" "$cpu_dir" "$privileged_dir" "$unknown_top_dir" "$bad_network_dir" "$nested_unknown_dir" "$nested_warning_dir" "$bad_command_shape_dir" "$bad_hook_command_shape_dir" "$empty_command_dir"' EXIT
cat > "$empty_command_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    command: []
YAML

if (cd "$empty_command_dir" && "$binary" up --dry-run >/tmp/apple-compose-empty-command.out 2>&1); then
  echo "expected strict up to reject empty command overrides" >&2
  exit 1
fi

grep -F "command" /tmp/apple-compose-empty-command.out >/dev/null
grep -F "clear the image command" /tmp/apple-compose-empty-command.out >/dev/null

empty_entrypoint_dir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$reset_dir" "$extends_dir" "$bad_dir" "$cpu_dir" "$privileged_dir" "$unknown_top_dir" "$bad_network_dir" "$nested_unknown_dir" "$nested_warning_dir" "$empty_command_dir" "$empty_entrypoint_dir"' EXIT
cat > "$empty_entrypoint_dir/compose.yaml" <<'YAML'
services:
  web:
    image: nginx
    entrypoint: ''
YAML

if (cd "$empty_entrypoint_dir" && "$binary" up --dry-run >/tmp/apple-compose-empty-entrypoint.out 2>&1); then
  echo "expected strict up to reject empty entrypoint overrides" >&2
  exit 1
fi

grep -F "entrypoint" /tmp/apple-compose-empty-entrypoint.out >/dev/null
grep -F "clear the image entrypoint" /tmp/apple-compose-empty-entrypoint.out >/dev/null
echo "smoke tests passed"
