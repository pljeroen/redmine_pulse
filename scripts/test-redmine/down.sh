#!/usr/bin/env bash
# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

# down.sh — Tear down the isolated pulse_test_* stack.
# Idempotent: safe to run if stack is partially or fully down.
# SAFETY: ONLY touches pulse_test_* resources. NEVER touches any other containers.
set -euo pipefail

RM_CONTAINER="pulse_test_redmine"
PG_CONTAINER="pulse_test_pg"
VOLUME="pulse_test_pgdata"
NETWORK="pulse_test_net"

echo "==> [pulse-test] Stopping + removing containers..."

for c in "${RM_CONTAINER}" "${PG_CONTAINER}"; do
  if podman inspect "${c}" &>/dev/null; then
    echo "    Stopping ${c}..."
    podman stop "${c}" --time 10 2>/dev/null || true
    echo "    Removing ${c}..."
    podman rm -f "${c}" 2>/dev/null || true
  else
    echo "    ${c} not found — skipping."
  fi
done

echo "==> [pulse-test] Removing volume: ${VOLUME}"
if podman volume inspect "${VOLUME}" &>/dev/null; then
  podman volume rm "${VOLUME}" 2>/dev/null || true
  echo "    Volume ${VOLUME} removed."
else
  echo "    Volume ${VOLUME} not found — skipping."
fi

echo "==> [pulse-test] Removing network: ${NETWORK}"
if podman network inspect "${NETWORK}" &>/dev/null; then
  podman network rm "${NETWORK}" 2>/dev/null || true
  echo "    Network ${NETWORK} removed."
else
  echo "    Network ${NETWORK} not found — skipping."
fi

echo ""
echo "==> [pulse-test] Stack is DOWN. All pulse_test_* resources removed."
