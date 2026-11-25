#!/bin/sh
# Wrapper script for packaged RigForge installations.
# Sets RIGFORGE_LIB and RIGFORGE_STATE before delegating to rigforge.sh.
set -e
exec /usr/lib/rigforge/rigforge.sh "$@"
