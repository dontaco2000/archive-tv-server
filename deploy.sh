#!/bin/bash
# Build Archive TV Server and deploy it to a Linux x64 box over SSH (keeps <install dir>/data = pools, days, dead links).
#
#   ./deploy.sh [ssh-target] [install-dir]
#   ATV_HOST=me@my-server ATV_DIR=/opt/archivetv-server ./deploy.sh
#
# Defaults: ssh-target = archivetv-server (an entry in ~/.ssh/config), install-dir = /opt/archivetv-server.
# The remote user needs passwordless sudo for `systemctl restart archivetv-server` (or restart it by hand).
# Rollback: the previous binary is kept as <install-dir>/archivetv-server.prev
# Note: config/ is shipped too, but an existing config/settings.txt on the server is never overwritten
# (it is not in the repo; the server writes it with defaults on first start).
set -e
HOST="${1:-${ATV_HOST:-archivetv-server}}"
DIR="${2:-${ATV_DIR:-/opt/archivetv-server}}"
cd "$(dirname "$0")/server"
dart pub get
dart test
mkdir -p build
dart compile exe bin/server.dart --target-os linux --target-arch x64 -o build/archivetv-server
tar czf build/deploy-bin.tgz -C build archivetv-server -C .. config
scp -q build/deploy-bin.tgz "$HOST:/tmp/archivetv-deploy.tgz"
ssh "$HOST" "set -e; cd '$DIR'; [ -f archivetv-server ] && cp -f archivetv-server archivetv-server.prev; tar xzf /tmp/archivetv-deploy.tgz; chmod +x archivetv-server; rm /tmp/archivetv-deploy.tgz; sudo systemctl restart archivetv-server; sleep 3; systemctl is-active archivetv-server"
