#!/usr/bin/env bash
# flavors: full-plus
# Pinned backend / CI toolchain on top of 'full': the exact versions a
# workflow would otherwise download or `go install` on every run.
# Bump a version together with its digests; a different version is not a
# substitute for a pinned one.
source "$(dirname "$0")/lib.sh"

BIN=/usr/local/bin

BUN_VERSION=1.3.14
VALKEY_VERSION=8.1.10
NATS_VERSION=v2.14.6
OPENFGA_VERSION=v1.19.0
GOOSE_VERSION=v3.27.3
OPENBAO_VERSION=2.1.0
TEMPORAL_VERSION=1.8.2
TIGERBEETLE_VERSION=0.16.78
TYPST_VERSION=0.15.1
BUF_VERSION=v1.47.2
PROTOC_GEN_GO_VERSION=v1.36.12
PROTOC_GEN_CONNECT_GO_VERSION=v1.20.0
GOLANGCI_LINT_VERSION=v2.12.2
GOSEC_VERSION=v2.29.0
GITLEAKS_VERSION=8.30.1
ACTIONLINT_VERSION=1.7.12
KUBECONFORM_VERSION=0.8.0

# Published digests (release checksum files or GitHub's per-asset digest),
# indexed by Debian architecture.
declare -A SHA_BUN=(
  [amd64]=951ee2aee855f08595aeec6225226a298d3fea83a3dcd6465c09cbccdf7e848f
  [arm64]=a27ffb63a8310375836e0d6f668ae17fa8d8d18b88c37c821c65331973a19a3b)
declare -A SHA_VALKEY=(
  [amd64]=89f4293b3dd56bb326380136b2bf08933fa84e501e19f69a7e75534932076378
  [arm64]=e98ff87d23b7f9ad2e6626008fbbffb7664c5c8dd9978faa01955d79859bcdfa)
declare -A SHA_OPENBAO=(
  [amd64]=7fc88b534fb77aa68aa46fe3d85d892887c5d5d594f6e00adf5fb9264908308d
  [arm64]=c7aee5cf556a77f64bab0cfd136329debc2e22245eacddf60452cddbd95a2b6c)
declare -A SHA_TEMPORAL=(
  [amd64]=d8421bda989e6514b4bdb4d63a9012a8a05a806892e881a5aad8510496349a94
  [arm64]=83600a8fac6e3da54093e5da6918d399f501532b9f1172235603f9606f4ac6e4)
declare -A SHA_TIGERBEETLE=(
  [amd64]=d32d7ce6aefd76559eff93efc17e74585243581059d47d988155458e4aaa2beb
  [arm64]=31cf0cbb4b7ca42d7afa125779cf0bd1b667081a393efae278a720d78c600402)
declare -A SHA_TYPST=(
  [amd64]=a6d077d0a95eed5a2eba715b2dae06be954f624ccbf85758a03f389ded33118c
  [arm64]=5aa8d74a3d906e60ea12a66ac2f37f8eef1b14cbad7182a745e393a10c23dcee)
declare -A SHA_GITLEAKS=(
  [amd64]=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb
  [arm64]=e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080)
declare -A SHA_ACTIONLINT=(
  [amd64]=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8
  [arm64]=325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6)
declare -A SHA_KUBECONFORM=(
  [amd64]=9bc2bffbf71f261128533edaf912153948b7ff238f9a531ae6d34466ec287883
  [arm64]=1f53fc8e81258197a35e8603054162a5af1de8c5af13746c71ab680d9534ed87)

arch="$(arch_deb)"
work="$(mktemp -d)"

# fetch <url> <sha256> -> path of the verified download
fetch() {
  local out
  out="${work}/$(basename "$1")"
  curl -fsSL --retry 4 --retry-all-errors -o "$out" "$1"
  echo "$2  $out" | sha256sum -c --quiet - || die "checksum mismatch: $1"
  echo "$out"
}

# install_from_tar <archive> <member path inside archive> <installed name>
install_from_tar() {
  local dir="${work}/x-$3"
  mkdir -p "$dir"
  tar -xf "$1" -C "$dir" "$2"
  install -m 0755 "${dir}/$2" "${BIN}/$3"
}

# Platform tokens per publisher.
case "$arch" in
  amd64) bun_p=x64 bao_p=Linux_x86_64 tb_p=x86_64-linux typst_p=x86_64-unknown-linux-musl gl_p=x64 vk_p=x86_64 ;;
  arm64) bun_p=aarch64 bao_p=Linux_arm64 tb_p=aarch64-linux typst_p=aarch64-unknown-linux-musl gl_p=arm64 vk_p=arm64 ;;
  *) die "unsupported architecture: $arch" ;;
esac

log "lsof"
apt_install lsof

log "bun ${BUN_VERSION}"
f="$(fetch "https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/bun-linux-${bun_p}.zip" "${SHA_BUN[$arch]}")"
unzip -q -o "$f" -d "$work"
install -m 0755 "${work}/bun-linux-${bun_p}/bun" "${BIN}/bun"
ln -sf bun "${BIN}/bunx"

log "Valkey ${VALKEY_VERSION} (redis-server/redis-cli point to it)"
f="$(fetch "https://download.valkey.io/releases/valkey-${VALKEY_VERSION}-noble-${vk_p}.tar.gz" "${SHA_VALKEY[$arch]}")"
tar -xzf "$f" -C "$work"
for b in valkey-server valkey-cli valkey-benchmark valkey-check-aof valkey-check-rdb valkey-sentinel; do
  install -m 0755 "${work}/valkey-${VALKEY_VERSION}-noble-${vk_p}/bin/${b}" "${BIN}/${b}"
done
ln -sf valkey-server "${BIN}/redis-server"
ln -sf valkey-cli "${BIN}/redis-cli"

log "OpenBao ${OPENBAO_VERSION}"
f="$(fetch "https://github.com/openbao/openbao/releases/download/v${OPENBAO_VERSION}/bao_${OPENBAO_VERSION}_${bao_p}.tar.gz" "${SHA_OPENBAO[$arch]}")"
install_from_tar "$f" bao bao

log "Temporal CLI ${TEMPORAL_VERSION}"
f="$(fetch "https://github.com/temporalio/cli/releases/download/v${TEMPORAL_VERSION}/temporal_cli_${TEMPORAL_VERSION}_linux_${arch}.tar.gz" "${SHA_TEMPORAL[$arch]}")"
install_from_tar "$f" temporal temporal

log "TigerBeetle ${TIGERBEETLE_VERSION}"
f="$(fetch "https://github.com/tigerbeetle/tigerbeetle/releases/download/${TIGERBEETLE_VERSION}/tigerbeetle-${tb_p}.zip" "${SHA_TIGERBEETLE[$arch]}")"
unzip -q -o "$f" tigerbeetle -d "$work"
install -m 0755 "${work}/tigerbeetle" "${BIN}/tigerbeetle"

log "typst ${TYPST_VERSION}"
f="$(fetch "https://github.com/typst/typst/releases/download/v${TYPST_VERSION}/typst-${typst_p}.tar.xz" "${SHA_TYPST[$arch]}")"
install_from_tar "$f" "typst-${typst_p}/typst" typst

log "gitleaks ${GITLEAKS_VERSION}"
f="$(fetch "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_${gl_p}.tar.gz" "${SHA_GITLEAKS[$arch]}")"
install_from_tar "$f" gitleaks gitleaks

log "actionlint ${ACTIONLINT_VERSION}"
f="$(fetch "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_${arch}.tar.gz" "${SHA_ACTIONLINT[$arch]}")"
install_from_tar "$f" actionlint actionlint

log "kubeconform ${KUBECONFORM_VERSION}"
f="$(fetch "https://github.com/yannh/kubeconform/releases/download/v${KUBECONFORM_VERSION}/kubeconform-linux-${arch}.tar.gz" "${SHA_KUBECONFORM[$arch]}")"
install_from_tar "$f" kubeconform kubeconform

# Built with `go install`, exactly as the workflows do; the Go checksum
# database verifies every module. Throwaway caches keep the image small.
log "Go tools: nats-server, openfga, goose, buf, protoc-gen-go, protoc-gen-connect-go, golangci-lint, gosec"
export PATH="/usr/local/go/bin:${PATH}"
command -v go >/dev/null || die "Go is missing - this step needs 50-go"
for pkg in \
  "github.com/nats-io/nats-server/v2@${NATS_VERSION}" \
  "github.com/openfga/openfga/cmd/openfga@${OPENFGA_VERSION}" \
  "github.com/pressly/goose/v3/cmd/goose@${GOOSE_VERSION}" \
  "github.com/bufbuild/buf/cmd/buf@${BUF_VERSION}" \
  "google.golang.org/protobuf/cmd/protoc-gen-go@${PROTOC_GEN_GO_VERSION}" \
  "connectrpc.com/connect/cmd/protoc-gen-connect-go@${PROTOC_GEN_CONNECT_GO_VERSION}" \
  "github.com/golangci/golangci-lint/v2/cmd/golangci-lint@${GOLANGCI_LINT_VERSION}" \
  "github.com/securego/gosec/v2/cmd/gosec@${GOSEC_VERSION}"; do
  GOBIN="$BIN" GOPATH="${work}/gopath" GOCACHE="${work}/gocache" GOFLAGS=-modcacherw go install "$pkg"
done

rm -rf "$work"

log "Versions"
bun --version
valkey-server --version
bao version
temporal --version
tigerbeetle version
typst --version
gitleaks version
actionlint -version | head -n1
kubeconform -v
nats-server --version
openfga version 2>&1 | head -n1
goose --version
buf --version
golangci-lint version
gosec -version | head -n1
lsof -v 2>&1 | sed -n 's/^ *revision: */lsof /p'
