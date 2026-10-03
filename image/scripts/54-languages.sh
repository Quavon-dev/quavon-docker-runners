#!/usr/bin/env bash
# flavors: full
# Ruby, PHP + Composer, C/C++ (clang), Fortran, Perl, database clients.
source "$(dirname "$0")/lib.sh"

log "Ruby, PHP, clang, gfortran, db clients"
apt_install \
  ruby-full \
  php-cli php-bcmath php-curl php-gd php-intl php-mbstring php-mysql \
  php-pgsql php-sqlite3 php-xml php-zip \
  clang clang-format clang-tidy lld lldb gfortran \
  default-mysql-client postgresql-client \
  imagemagick libmagickcore-dev libmagickwand-dev libmagic-dev libgsl-dev

gem install --no-document bundler

log "Composer"
curl -fsSL https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
