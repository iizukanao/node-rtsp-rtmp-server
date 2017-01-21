#!/bin/bash
set -e

# Boot any servers you need to
bash -l -c "coffee /app/server.coffee &"


# Spawn bash if we're booting in console mode
if [ "$1" = 'bash' ]; then
    /bin/bash
    exit
fi

# This line keeps the container alive
tail -f /var/log/dmesg
