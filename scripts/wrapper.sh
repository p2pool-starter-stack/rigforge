#!/bin/sh
set -e
export RIGFORGE_LIB="/usr/lib/rigforge"
export RIGFORGE_STATE="/var/lib/rigforge"
exec "$RIGFORGE_LIB/rigforge.sh" "$@"
