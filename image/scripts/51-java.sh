#!/usr/bin/env bash
# flavors: full full-plus
# Eclipse Temurin 11/17/21/25 (default 17, like hosted), Maven, Gradle, Ant.
source "$(dirname "$0")/lib.sh"

JAVA_VERSIONS=(11 17 21 25)
JAVA_DEFAULT=17

log "Temurin JDKs: ${JAVA_VERSIONS[*]}"
add_apt_repo adoptium https://packages.adoptium.net/artifactory/api/gpg/key/public \
  "https://packages.adoptium.net/artifactory/deb $(. /etc/os-release && echo "$VERSION_CODENAME") main"
pkgs=()
for v in "${JAVA_VERSIONS[@]}"; do pkgs+=("temurin-${v}-jdk"); done
apt_install "${pkgs[@]}" ant maven

for v in "${JAVA_VERSIONS[@]}"; do
  add_env "JAVA_HOME_${v}_$(arch_alt | tr '[:lower:]' '[:upper:]')" "/usr/lib/jvm/temurin-${v}-jdk-$(arch_deb)"
done
default_home="/usr/lib/jvm/temurin-${JAVA_DEFAULT}-jdk-$(arch_deb)"
update-java-alternatives -s "temurin-${JAVA_DEFAULT}-jdk-$(arch_deb)" || true
add_env JAVA_HOME "$default_home"

log "Gradle (latest)"
gradle_version="$(curl -fsSL https://services.gradle.org/versions/current | jq -r .version)"
curl -fsSL "https://services.gradle.org/distributions/gradle-${gradle_version}-bin.zip" -o /tmp/gradle.zip
unzip -q /tmp/gradle.zip -d /usr/share
ln -sf "/usr/share/gradle-${gradle_version}/bin/gradle" /usr/bin/gradle
add_env GRADLE_HOME "/usr/share/gradle-${gradle_version}"
