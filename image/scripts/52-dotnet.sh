#!/usr/bin/env bash
# flavors: full full-plus
# .NET SDKs 8, 9, 10 in /usr/share/dotnet (same location as hosted).
source "$(dirname "$0")/lib.sh"

log ".NET SDKs"
curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
for channel in 8.0 9.0 10.0; do
  bash /tmp/dotnet-install.sh --channel "$channel" --install-dir /usr/share/dotnet --no-path
done
ln -sf /usr/share/dotnet/dotnet /usr/bin/dotnet
add_env DOTNET_ROOT /usr/share/dotnet
add_env DOTNET_SKIP_FIRST_TIME_EXPERIENCE 1
add_env DOTNET_NOLOGO 1
add_env DOTNET_MULTILEVEL_LOOKUP 0
add_path /home/runner/.dotnet/tools
