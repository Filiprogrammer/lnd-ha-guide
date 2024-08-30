#!/bin/sh

createuser lnd
psql <<EOF
ALTER USER lnd WITH PASSWORD '{POSTGRES_LND_PASSWORD}';
EOF
createdb -O lnd lnd
