#!/usr/bin/env bash
# flavors: full
# Google Chrome + chromedriver, Firefox + geckodriver (for E2E / Playwright / Selenium).
source "$(dirname "$0")/lib.sh"

if ! is_amd64; then
  echo "Chrome is amd64-only, skipping browsers"
  exit 0
fi

log "Google Chrome"
add_apt_repo google-chrome https://dl.google.com/linux/linux_signing_key.pub \
  "https://dl.google.com/linux/chrome/deb/ stable main"
# Chrome depends on the virtual "libasound2". On Ubuntu 24.04 apt may pick the
# provider liboss4-salsa-asound2, which conflicts ("pkgProblemResolver ...
# generated breaks"). Name the real provider explicitly.
apt_install libasound2t64 google-chrome-stable

log "chromedriver (matching Chrome)"
chrome_version="$(google-chrome --version | grep -oE '[0-9]+(\.[0-9]+){3}')"
url="$(curl -fsSL https://googlechromelabs.github.io/chrome-for-testing/known-good-versions-with-downloads.json \
  | jq -r --arg v "$chrome_version" '.versions[] | select(.version==$v) | .downloads.chromedriver[]? | select(.platform=="linux64") | .url')"
if [[ -z "$url" ]]; then
  url="$(curl -fsSL https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json \
    | jq -r '.channels.Stable.downloads.chromedriver[] | select(.platform=="linux64") | .url')"
fi
curl -fsSL "$url" -o /tmp/chromedriver.zip
unzip -q /tmp/chromedriver.zip -d /usr/local/share
ln -sf /usr/local/share/chromedriver-linux64/chromedriver /usr/bin/chromedriver
add_env CHROMEWEBDRIVER /usr/local/share/chromedriver-linux64

log "Firefox (Mozilla apt repo, not snap)"
add_apt_repo mozilla https://packages.mozilla.org/apt/repo-signing-key.gpg \
  "https://packages.mozilla.org/apt mozilla main"
printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' >/etc/apt/preferences.d/mozilla
apt_install libasound2t64 firefox

log "geckodriver"
tag="$(gh_latest_tag mozilla/geckodriver)"
install -d /usr/local/share/gecko_driver
curl -fsSL "https://github.com/mozilla/geckodriver/releases/download/${tag}/geckodriver-${tag}-linux64.tar.gz" \
  | tar -xz -C /usr/local/share/gecko_driver
ln -sf /usr/local/share/gecko_driver/geckodriver /usr/bin/geckodriver
add_env GECKOWEBDRIVER /usr/local/share/gecko_driver
