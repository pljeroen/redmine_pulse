# redmine_pulse — portfolio / project-health cockpit for Redmine.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

# Dockerfile — build a test-capable Redmine checkout from an official release
# tarball, for Redmine versions that have NO official Docker image (e.g. 7.0.x).
# The newest official docker.io/library/redmine image is 6.1.3; anything newer is
# built here from https://www.redmine.org/releases/redmine-<ver>.tar.gz.
#
# Both PostgreSQL (libpq-dev) and MySQL (default-libmysqlclient-dev) client libs
# are installed so a single image can serve either DB. The gem set is
# DB-dependent, so we deliberately DO NOT `bundle install` at build time — up.sh
# writes the per-combo database.yml and bundles at runtime.

ARG RUBY_IMAGE=ruby:3.4-slim-bookworm
FROM ${RUBY_IMAGE}

# Redmine release version to fetch from redmine.org (e.g. 7.0.0). Required.
ARG REDMINE_VERSION

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential \
        pkg-config \
        libpq-dev \
        default-libmysqlclient-dev \
        libxml2-dev \
        libxslt1-dev \
        zlib1g-dev \
        libyaml-dev \
        libffi-dev \
        libmagickwand-dev \
        imagemagick \
        git \
        curl \
        ca-certificates \
        tzdata; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    test -n "${REDMINE_VERSION}"; \
    mkdir -p /usr/src/redmine; \
    curl -fsSL "https://www.redmine.org/releases/redmine-${REDMINE_VERSION}.tar.gz" \
        | tar -xz --strip-components=1 -C /usr/src/redmine

WORKDIR /usr/src/redmine

# Keep the container alive so up.sh / run-tests.sh can exec into it. The gem set
# is DB-dependent and installed at runtime by up.sh (bundle without development).
CMD ["tail", "-f", "/dev/null"]
