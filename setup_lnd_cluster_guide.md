# Setting up a highly available LND cluster (manually)

# Step 1: Setup a bitcoind node

Setup a Debian instance called "bitcoind" with the following ports allowed in the firewall:
- 8332 (Bitcoin RPC)
- 8333/18333/38333/18444 (Bitcoin Mainnet/Testnet/Signet/Regtest)
- 29000 (ZeroMQ block hash publisher)
- 29001 (ZeroMQ transaction publisher)
- 29002 (ZeroMQ block publisher)

Place the bitcoind and bitcoin-cli binaries into /usr/bin/ and make the binaries executable.

Create a system user called "bitcoin" without a home directory and without a shell.

```console
root@bitcoind:~$ useradd --system --no-create-home --home /nonexistent --shell /usr/sbin/nologin bitcoin
```

Put the following contents into the /etc/bitcoin/bitcoin.conf file:

```ini
mainnet=1

[mainnet]
server=1
txindex=1
disablewallet=0
rpcuser=user
rpcpassword=password
rpcallowip=0.0.0.0/0
rpcbind=0.0.0.0:8332
zmqpubhashblock=tcp://0.0.0.0:29000
zmqpubrawtx=tcp://0.0.0.0:29001
zmqpubrawblock=tcp://0.0.0.0:29002
listen=1
```

Change each occurrence of `mainnet` to the network which this should run on.

Adjust the ownership and permissions of the config file and directory.

```console
root@bitcoind:~$ chmod 0710 /etc/bitcoin
root@bitcoind:~$ chmod 0640 /etc/bitcoin/bitcoin.conf
root@bitcoind:~$ chown -R bitcoin:bitcoin /etc/bitcoin
```

Setup a systemd service for bitcoind by putting the following contents into the /usr/lib/systemd/system/bitcoind.service file:

```ini
[Unit]
Description=Bitcoin daemon

After=network-online.target
Wants=network-online.target

[Service]
Environment='MALLOC_ARENA_MAX=1'
ExecStart=/usr/bin/bitcoind -pid=/run/bitcoind/bitcoind.pid \
                            -conf=/etc/bitcoin/bitcoin.conf \
                            -datadir=/var/lib/bitcoind \
                            -startupnotify='systemd-notify --ready' \
                            -shutdownnotify='systemd-notify --stopping'

Type=notify
NotifyAccess=all
PIDFile=/run/bitcoind/bitcoind.pid

Restart=on-failure
TimeoutStartSec=infinity
TimeoutStopSec=600

User=bitcoin
Group=bitcoin

# /run/bitcoind
RuntimeDirectory=bitcoind
RuntimeDirectoryMode=0710

# /etc/bitcoin
ConfigurationDirectory=bitcoin
ConfigurationDirectoryMode=0710

# /var/lib/bitcoind
StateDirectory=bitcoind
StateDirectoryMode=0710

PrivateTmp=true
ProtectSystem=full
ProtectHome=true
NoNewPrivileges=true
PrivateDevices=true
MemoryDenyWriteExecute=true
SystemCallArchitectures=native

[Install]
WantedBy=multi-user.target
```

Update the running systemd configuration.

```console
root@bitcoind:~$ systemctl daemon-reload
```

Start bitcoind.

```console
root@bitcoind:~$ systemctl start bitcoind.service
```

Enable the bitcoind.service so it automatically starts up when the instance is started.

```console
root@bitcoind:~$ systemctl enable bitcoind.service
```

To be able to use bitcoin-cli without having to manually specify `-rpcuser` and `-rpcpassword`, put the following contents into ~/.bitcoin/bitcoin.conf:

```
rpcuser=user
rpcpassword=password
```

### The following three commands only apply to a regtest setup

Create a wallet (the name does not matter) that will be loaded on startup.

```console
root@bitcoind:~$ bitcoin-cli -named createwallet wallet_name=main load_on_startup=true
```

Generate 101 blocks with the reward going to the created wallet.

```console
root@bitcoind:~$ bitcoin-cli -generate 101
```

The wallet should now have a balance of 50 BTC

```console
root@bitcoind:~$ bitcoin-cli getbalance
```

# Step 2: Setup an lnd cluster

## Step 2.1: Generate TLS certificates

Install openssl on a local system if not already installed.

```console
root@local:~$ apt install openssl
```

This tool is going to be used to generate TLS certificates.

First initialize a certificate authority.

```console
user@local:~$ openssl req -x509 -noenc -newkey ec -pkeyopt ec_paramgen_curve:P-256 -keyout ca.key -out ca.crt -days 3650 -subj "/CN=lndetcd-ca"
```

Generate the certificates for the etcd nodes.

Perform the following steps for each etcd node:

```console
user@local:~$ openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -keyout etcd1.key -out etcd1.csr -noenc -subj "/CN=etcd1" -addext "subjectAltName=IP:${IP_OF_LNDETCD1},IP:127.0.0.1"

user@local:~$ openssl req -x509 -in etcd1.csr -CA ca.crt -CAkey ca.key -out etcd1.crt -days 3650 -copy_extensions copy
```

Lastly generate a client certificate.

```console
user@local:~$ openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -keyout client.key -out client.csr -noenc -subj "/CN=client"

user@local:~$ openssl req -x509 -in client.csr -CA ca.crt -CAkey ca.key -out client.crt -days 3650 -copy_extensions copy
```

If a PostgreSQL database is planned, also generate TLS certificates for Patroni.

Perform the following steps for each Patroni instance:

```console
user@local:~$ openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -keyout patroni1.key -out patroni1.csr -noenc -subj "/CN=patroni1" -addext "subjectAltName=IP:${IP_OF_LNDETCDPG1},IP:127.0.0.1"

user@local:~$ openssl req -x509 -in patroni1.csr -CA ca.crt -CAkey ca.key -out patroni1.crt -days 3650 -copy_extensions copy
```

Also generate a client certificate for Patroni.

```console
user@local:~$ openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -keyout patroniclient.key -out patroniclient.csr -noenc -subj "/CN=patroniclient"

user@local:~$ openssl req -x509 -in patroniclient.csr -CA ca.crt -CAkey ca.key -out patroniclient.crt -days 3650 -copy_extensions copy
```

## Step 2.2: Setup an etcd cluster

Setup three Debian instances with ECC memory called "lndetcd1", "lndetcd2" and "lndetcd3" with the following ports allowed in the firewall on each of them:
- 2379 (etcd client communication)
- 2380 (etcd peer communication)
- 9735 (Lightning)

If a PostgreSQL database is planned, also allow the following ports:

- 5432 (PostgreSQL)
- 8008 (Patroni REST API)

Create a system user called "bitcoin" with a home directory and set a password on each instance.

```console
root@lndetcdx:~$ useradd --system --create-home --shell /bin/bash bitcoin
root@lndetcdx:~$ passwd bitcoin
```

Install etcd and etcdctl on all three instances.

```console
root@lndetcdx:~$ apt update
root@lndetcdx:~$ apt install etcd-server etcd-client
```

Since the etcd.service is started automatically during installation, stop it for now and delete the data directory of etcd on every instance to start fresh.

```console
root@lndetcdx:~$ systemctl stop etcd.service
root@lndetcdx:~$ rm -r /var/lib/etcd/default
```

To ensure that the lnd.service does not fail to start because of a dependency problem when the etcd.service times out during startup, configure `RestartMode=direct` on the etcd.service. This `RestartMode=direct` was only introduced in systemd 254, so systemd has to be upgraded to that version.

Start with adding the bookworm-backports repository to apt, by adding the following line to /etc/apt/sources.list on each instance:

```
deb http://deb.debian.org/debian bookworm-backports main
```

Then update the package lists on each instance.

```console
root@lndetcdx:~$ apt update
```

And install systemd 254 from the bookworm-backports repository on each instance.

```console
root@lndetcdx:~$ apt install systemd/stable-backports
```

With systemd upgraded, add `RestartMode=direct` to the `[Service]` section of the `/usr/lib/systemd/system/etcd.service` file on each instance.

Finally update the running systemd configuration on each instance.

```console
root@lndetcdx:~$ systemctl daemon-reload
```

Create a directory at /etc/etcd on all three instances.

```console
root@lndetcdx:~$ mkdir /etc/etcd
```

Copy ca.crt, etcd1.crt, etcd1.key, client.crt and client.key from the local system into /etc/etcd on "lndetcd1", "lndetcd2" and "lndetcd3".

Restrict the access rights of the certificates and keys to only the etcd user and group.

```console
root@lndetcdx:~$ chown etcd:etcd /etc/etcd/*
root@lndetcdx:~$ chmod 400 /etc/etcd/etcd1.key /etc/etcd/etcd1.crt
root@lndetcdx:~$ chmod 440 /etc/etcd/ca.crt /etc/etcd/client.crt /etc/etcd/client.key
```

Add the bitcoin user to the etcd group, to allow lnd to access the etcd client certificate and key.

```console
root@lndetcdx:~$ /sbin/usermod -a -G etcd bitcoin
```

Put the following contents into the /etc/default/etcd file:

```
ETCD_NAME=etcd1
ETCD_INITIAL_CLUSTER="etcd1=https://${IP_OF_LNDETCD1}:2380,etcd2=https://${IP_OF_LNDETCD2}:2380,etcd3=https://${IP_OF_LNDETCD3}:2380"
ETCD_ADVERTISE_CLIENT_URLS=https://${OWN_IP}:2379
ETCD_LISTEN_CLIENT_URLS=https://0.0.0.0:2379
ETCD_LISTEN_PEER_URLS=https://0.0.0.0:2380
ETCD_INITIAL_ADVERTISE_PEER_URLS=https://${OWN_IP}:2380
ETCD_MAX_TXN_OPS=16384

ETCD_CERT_FILE=/etc/etcd/etcd1.crt
ETCD_KEY_FILE=/etc/etcd/etcd1.key
ETCD_TRUSTED_CA_FILE=/etc/etcd/ca.crt
ETCD_PEER_CERT_FILE=/etc/etcd/etcd1.crt
ETCD_PEER_KEY_FILE=/etc/etcd/etcd1.key
ETCD_PEER_TRUSTED_CA_FILE=/etc/etcd/ca.crt
ETCD_PEER_CLIENT_CERT_AUTH=true
ETCD_CLIENT_CERT_AUTH=true
```

Repeat that for "lndetcd2" and "lndetcd3" with ETCD_NAME, $OWN_IP and the certificate files changed respectively.

Then start etcd on each instance.

```console
root@lndetcdx:~$ systemctl start etcd.service
```

Then list the members of the cluster on any of the instances and make sure that all members are listed.

```console
root@lndetcdx:~$ export ETCDCTL_CACERT=/etc/etcd/ca.crt
root@lndetcdx:~$ export ETCDCTL_CERT=/etc/etcd/client.crt
root@lndetcdx:~$ export ETCDCTL_KEY=/etc/etcd/client.key
root@lndetcdx:~$ etcdctl member list --write-out=table
```

Check whether the cluster is healthy.

```console
root@lndetcdx:~$ etcdctl endpoint health --cluster
```

Check the status of each endpoint in the cluster.

```console
root@lndetcdx:~$ etcdctl endpoint status --cluster --write-out=table
```

Enable the etcd.service on each instance so it automatically starts up when the instance is started.

```console
root@lndetcdx:~$ systemctl enable etcd.service
```

## Step 2.3: Setup PostgreSQL + Patroni

Skip this step if a PostgreSQL database is not planned.

Start by installing PostgreSQL and Patroni on all three instances.

```console
root@lndetcdpgx:~$ apt install postgresql patroni
```

Stop the postgresql.service and the patroni.service which might have been started automatically during installation, and delete the PostgreSQL data directory on each instance to start fresh.

```console
root@lndetcdpgx:~$ systemctl stop postgresql.service
root@lndetcdpgx:~$ systemctl stop 'postgresql@*.service'
root@lndetcdpgx:~$ systemctl stop patroni.service
root@lndetcdpgx:~$ rm -r /var/lib/postgresql/15/main
```

Since PostgreSQL is not intended to be started by systemd, but will instead be started by Patroni, disable and mask the postgresql.service so that it cannot be started directly by systemd.

```console
root@lndetcdpgx:~$ systemctl disable postgresql.service
root@lndetcdpgx:~$ systemctl disable postgresql@.service
root@lndetcdpgx:~$ systemctl mask postgresql.service
root@lndetcdpgx:~$ systemctl mask postgresql@.service
```

Copy patroni1.crt, patroni1.key, patroniclient.crt and patroniclient.key from the local system into /etc/patroni on "lndetcdpg1", "lndetcdpg2" and "lndetcdpg3". Rename patroniclient.crt and patroniclient.key to client.crt and client.key.

Restrict access to the certificates and keys to the postgres user and group only.

```console
root@lndetcdpgx:~$ chown postgres:postgres /etc/patroni/patroni1.crt /etc/patroni/patroni1.key /etc/patroni/client.crt /etc/patroni/client.key
root@lndetcdpgx:~$ chmod 400 /etc/patroni/patroni1.crt /etc/patroni/patroni1.key /etc/patroni/client.crt /etc/patroni/client.key
```

Put the following contents into the /etc/patroni/config.yml file:

```yaml
name: postgres1
scope: postgres

etcd3:
  protocol: https
  hosts:
  - ${LNDETCDPG1_IP}:2379
  - ${LNDETCDPG2_IP}:2379
  - ${LNDETCDPG3_IP}:2379
  cacert: /etc/etcd/ca.crt
  cert: /etc/etcd/client.crt
  key: /etc/etcd/client.key

restapi:
  listen: 0.0.0.0:8008
  connect_address: ${OWN_IP}:8008
  certfile: /etc/patroni/patroni1.crt
  keyfile: /etc/patroni/patroni1.key
  cafile: /etc/etcd/ca.crt
  verify_client: required

ctl:
  certfile: /etc/patroni/client.crt
  keyfile: /etc/patroni/client.key

bootstrap:
  dcs:
    maximum_lag_on_failover: 1048576
    synchronous_mode: true
    postgresql:
      use_pg_rewind: true
      parameters:
        wal_level: replica
        synchronous_commit: remote_apply
        max_wal_senders: 10
        synchronous_standby_names: '*'
        hot_standby: on
      pg_hba:
      - local   all             all                                           peer
      - host    all             all             127.0.0.1/32                  md5
      - host    all             all             ::1/128                       md5
      - host    all             all             ${IP_NETWORK}/${NETWORK_BITS} md5
      - local   replication     all                                           peer
      - host    replication     all             127.0.0.1/32                  md5
      - host    replication     all             ::1/128                       md5
      - host    replication     all             ${IP_NETWORK}/${NETWORK_BITS} md5
  post_init: /etc/patroni/post_init.sh

postgresql:
  authentication:
    superuser:
      username: postgres
      password: POSTGRES_SUPERUSER_PASSWORD
    replication:
      username: replicator
      password: POSTGRES_REPLICATION_PASSWORD
    rewind:
      username: rewinder
      password: POSTGRES_REWIND_PASSWORD
  listen: '*:5432'
  connect_address: ${OWN_IP}:5432
  data_dir: /var/lib/postgresql/15/main
  bin_dir: /usr/lib/postgresql/15/bin
  config_dir: /etc/postgresql/15/main
  pgpass: /var/lib/postgresql/15-main.pgpass
```

Repeat that for "lndetcdpg2" and "lndetcdpg3" with name, $OWN_IP and the certificate files changed respectively.

Restrict access to /etc/patroni/config.yml to the postgres user only.

```console
root@lndetcdpgx:~$ chown postgres:postgres /etc/patroni/config.yml
root@lndetcdpgx:~$ chmod 400 /etc/patroni/config.yml
```

Put the following contents into the /etc/patroni/post_init.sh file:

```sh
#!/bin/sh

createuser lnd
psql <<EOF
ALTER USER lnd WITH PASSWORD 'POSTGRES_LND_PASSWORD';
EOF
createdb -O lnd lnd
```

Make the file executable only by the postgres user.

```console
root@lndetcdpgx:~$ chown postgres:postgres /etc/patroni/post_init.sh
root@lndetcdpgx:~$ chmod 500 /etc/patroni/post_init.sh
```

Finally, add the postgres user to the etcd group so that it can access the etcd client certificate and key.

```console
root@lndetcdpgx:~$ /sbin/usermod -a -G etcd postgres
```

Then start Patroni on each instance.

```console
root@lndetcdpgx:~$ systemctl start patroni.service
```

List the members of the Patroni cluster and make sure that all three members are listed. There should be exactly one "Leader", one "Sync Standby", and one "Replica". The result should look something like this:

```console
root@lndetcdpgx:~$ patronictl -c /etc/patroni/config.yml list
+ Cluster: postgres ----------+--------------+---------+----+-----------+
| Member    | Host            | Role         | State   | TL | Lag in MB |
+-----------+-----------------+--------------+---------+----+-----------+
| postgres1 | 192.168.122.101 | Sync Standby | running |  1 |         0 |
| postgres2 | 192.168.122.102 | Leader       | running |  1 |           |
| postgres3 | 192.168.122.103 | Replica      | running |  1 |         0 |
+-----------+-----------------+--------------+---------+----+-----------+
```

Enable the patroni.service on each instance so that it starts automatically when the instance is started.

```console
root@lndetcdpgx:~$ systemctl enable patroni.service
```

## Step 2.4: Setup tor

Install tor on each instance.

```console
root@lndetcdx:~$ apt install tor
```

Replace the contents of the /etc/tor/torrc file with the following on each instance:

```
ExitPolicy reject *:*
SOCKSPort 9050
ControlPort 9051
CookieAuthentication 1
```

Restart tor to apply the new configuration

```console
root@lndetcdx:~$ systemctl restart tor.service
```

Add the bitcoin user to the debian-tor group on each instance.

```console
root@lndetcdx:~$ /sbin/usermod -a -G debian-tor bitcoin
```

## Step 2.5: Setup lnd

Place the lnd and lncli binaries into /usr/bin/ on each instance and make the binaries executable. Make sure that lnd is at least on version v0.18.3-beta or that it at least has the following patch applied: https://github.com/lightningnetwork/lnd/pull/8938 Also make sure that lnd was compiled with the "kvdb_etcd" build tag.

Put the following contents into the /home/bitcoin/.lnd/lnd.conf file on each instance but change the cluster.id accordingly:

```ini
[Application Options]
listen=0.0.0.0:9735
alias=lndetcd

[Bitcoin]
bitcoin.regtest=true
bitcoin.node=bitcoind

[Bitcoind]
bitcoind.rpcuser=user
bitcoind.rpcpass=password
bitcoind.rpchost=${IP_OF_BITCOIND}:8332
bitcoind.zmqpubrawtx=tcp://${IP_OF_BITCOIND}:29001
bitcoind.zmqpubrawblock=tcp://${IP_OF_BITCOIND}:29002
bitcoind.estimatemode=ECONOMICAL

[tor]
tor.active=true
tor.v3=true
tor.skip-proxy-for-clearnet-targets=true

[wtclient]
wtclient.active=true

[healthcheck]
healthcheck.leader.interval=60s

[db]
db.backend=etcd

[etcd]
db.etcd.host=127.0.0.1:2379
db.etcd.cert_file=/etc/etcd/client.crt
db.etcd.key_file=/etc/etcd/client.key
db.etcd.insecure_skip_verify=1

[cluster]
cluster.enable-leader-election=1
cluster.leader-elector=etcd
cluster.etcd-election-prefix=cluster-leader
cluster.id=lndetcd1
cluster.leader-session-ttl=100
```

If a PostgreSQL setup is planned, put the following in the `[db]` section instead:

```ini
db.backend=postgres
db.postgres.dsn=postgresql://lnd:POSTGRES_LND_PASSWORD@127.0.0.1:5432/lnd
db.postgres.timeout=0
db.use-native-sql=true
```

Make sure that the bitcoin user and bitcoin group own the /home/bitcoin/.lnd directory on each instance.

```console
root@lndetcdx:~$ chown -R bitcoin:bitcoin /home/bitcoin/.lnd
```

Setup a systemd service for lnd on each instance by putting the following contents into /usr/lib/systemd/system/lnd.service:

```ini
[Unit]
Description=LND Lightning Daemon
After=etcd.service
BindsTo=etcd.service
After=tor.service
Wants=tor.service

[Service]
ExecStart=/usr/bin/lnd

User=bitcoin
Group=bitcoin

Restart=always
RestartSec=30

Type=notify

TimeoutStartSec=infinity
TimeoutStopSec=1800

ProtectSystem=full
NoNewPrivileges=true
PrivateDevices=true
MemoryDenyWriteExecute=true

[Install]
WantedBy=multi-user.target
```

If a PostgreSQL setup is planned, add the following to the `[Unit]` section:

```ini
After=patroni.service
BindsTo=patroni.service
```

Update the running systemd configuration on each instance.

```console
root@lndetcdx:~$ systemctl daemon-reload
```

Start LND on only one instance. If a PostgreSQL setup is planned, the choice of the instance cannot be arbitrary. LND has to be started on the instance of the PostgreSQL primary. The primary can be found with `patronictl -c /etc/patroni/config.yml list`.

```console
root@lndetcdx:~$ systemctl start lnd.service
```

Switch to the bitcoin user and create a wallet.

```console
root@lndetcdx:~$ su bitcoin
bitcoin@lndetcdx:~$ lncli create
bitcoin@lndetcdx:~$ exit
```

Once the wallet is created, create a file at /home/bitcoin/lnd_pwd containing the wallet unlock password on each instance while making sure that only the bitcoin user and bitcoin group have access to that file.

```console
root@lndetcdx:~$ echo $(read -sp "Password: ";echo $REPLY) > /home/bitcoin/lnd_pwd
root@lndetcdx:~$ chown bitcoin:bitcoin /home/bitcoin/lnd_pwd
root@lndetcdx:~$ chmod 660 /home/bitcoin/lnd_pwd
```

Then add the following line to the [Application Options] section in /home/bitcoin/.lnd/lnd.conf on each instance:

```
wallet-unlock-password-file=/home/bitcoin/lnd_pwd
```

Copy /home/bitcoin/.lnd/v3_onion_private_key to the other instances that do not have lnd running yet. This ensures that all nodes in the cluster will be reachable via the same onion hostname. Keep in mind though, that during failover it can take up to 10 minutes for the new leader node to be accessible through the tor hidden service.

Now start lnd on the other instances that do not have lnd running yet.

```console
root@lndetcdx:~$ systemctl start lnd.service
```

The lnd services should now have a message similar to this in their log output:

```
LTND: Starting leadership campaign (lndetcd2)
```

Enable the service on each instance, to make sure that lnd is started automatically.

```console
root@lndetcdx:~$ systemctl enable lnd.service
```

## Step 2.6: Setup a floating IP address

To make the active leader always accessible via the same IP address, use a floating IP address that is always assigned to the currently active leader.

Create an sh script with the following contents at /usr/local/bin/lnd-floating-ip.sh on each instance:

```sh
#!/bin/sh

FLOATING_IP="192.168.0.100" # Replace this
SUBNET_MASK="24" # Replace this
INTERFACE="eth0" # Replace this

while true; do
    sleep 20
    lncli --lnddir /home/bitcoin/.lnd state | grep -q -E 'NON_EXISTING|LOCKED|UNLOCKED|RPC_ACTIVE|SERVER_ACTIVE'
    IS_LEADER=$?

    ip addr show $INTERFACE | grep -q $FLOATING_IP
    IP_ASSIGNED=$?

    if [ $IS_LEADER -eq 0 ] && [ $IP_ASSIGNED -ne 0 ]; then
        echo "Assigning the floating IP address to this node since it is the leader"
        ip addr add $FLOATING_IP/$SUBNET_MASK dev $INTERFACE
        arping -c 1 -I $INTERFACE $FLOATING_IP
    elif [ $IS_LEADER -ne 0 ] && [ $IP_ASSIGNED -eq 0 ]; then
        echo "Removing the floating IP address since this node is no longer the leader"
        ip addr del $FLOATING_IP/$SUBNET_MASK dev $INTERFACE
    fi
done
```

Set `FLOATING_IP` to the floating IP address to use for the active LND leader node. Set `INTERFACE` to the network interface that the floating IP address should be assigned to. (Can be the same interface as for the regular IP address of the instance) Set `SUBNET_MASK` to the subnet mask of `INTERFACE`.

Make the script executable:

```console
root@lndetcdx:~$ chmod +x /usr/local/bin/lnd-floating-ip.sh
```

In order for the script to work, install arping on all instances:

```console
root@lndetcdx:~$ apt install arping
```

Setup a systemd service for lnd-floating-ip on each instance by putting the following contents into /usr/lib/systemd/system/lnd-floating-ip.service:

```ini
[Unit]
Description=LND Floating IP
After=lnd.service
Wants=lnd.service

[Service]
ExecStart=/usr/local/bin/lnd-floating-ip.sh

Restart=always

Type=exec

ProtectSystem=full
NoNewPrivileges=true
PrivateDevices=true
MemoryDenyWriteExecute=true

[Install]
WantedBy=multi-user.target
```

Update the running systemd configuration on each instance.

```console
root@lndetcdx:~$ systemctl daemon-reload
```

Start and enable lnd-floating-ip on all instances.

```console
root@lndetcdx:~$ systemctl start lnd-floating-ip.service
root@lndetcdx:~$ systemctl enable lnd-floating-ip.service
```

## Testing High Availability

To check whether the lnd cluster works properly, stop the currently active lnd node and another node in the cluster should automatically take over.

Another test one can do is to disconnect one of the lnd nodes from the network. The disconnected node should automatically resign from the leader role and a different node should take over.

# Step 3: Setup a watchtower

Setup a Debian instance called "lndwt" on an offsite location with the following ports allowed in the firewall:
- 8333/18333/38333/18444 (Bitcoin Mainnet/Testnet/Signet/Regtest)
- 9911 (LND watchtower)

Place the bitcoind, bitcoin-cli, lnd and lncli binaries into /usr/bin/ and make them executable. Make sure that these lnd and lncli binaries where compiled with the "watchtowerrpc" build tag.

Create a system user called "bitcoin" with a home directory and set a password.

```console
root@lndwt:~$ useradd --system --create-home --shell /bin/bash bitcoin
root@lndwt:~$ passwd bitcoin
```

Put the following contents into the /etc/bitcoin/bitcoin.conf file:

```ini
regtest=1

[regtest]
server=1
prune=8064
disablewallet=1
rpcallowip=127.0.0.1
rpcbind=127.0.0.1:8332
zmqpubrawtx=tcp://127.0.0.1:29001
zmqpubrawblock=tcp://127.0.0.1:29002
listen=1
```

This will configure a pruned bitcoind node. A watchtower does not need a full node.

Adjust the ownership and permissions of the config file and directory.

```console
root@lndwt:~$ chmod 0710 /etc/bitcoin
root@lndwt:~$ chmod 0640 /etc/bitcoin/bitcoin.conf
root@lndwt:~$ chown -R bitcoin:bitcoin /etc/bitcoin
```

Setup a systemd service for bitcoind by putting the following contents into the /usr/lib/systemd/system/bitcoind.service file:

```ini
[Unit]
Description=Bitcoin daemon

After=network-online.target
Wants=network-online.target

[Service]
Environment='MALLOC_ARENA_MAX=1'
ExecStart=/usr/bin/bitcoind -pid=/run/bitcoind/bitcoind.pid \
                            -conf=/etc/bitcoin/bitcoin.conf \
                            -datadir=/var/lib/bitcoind \
                            -startupnotify='systemd-notify --ready' \
                            -shutdownnotify='systemd-notify --stopping'

Type=notify
NotifyAccess=all
PIDFile=/run/bitcoind/bitcoind.pid

Restart=on-failure
TimeoutStartSec=infinity
TimeoutStopSec=600

User=bitcoin
Group=bitcoin

# /run/bitcoind
RuntimeDirectory=bitcoind
RuntimeDirectoryMode=0710

# /etc/bitcoin
ConfigurationDirectory=bitcoin
ConfigurationDirectoryMode=0710

# /var/lib/bitcoind
StateDirectory=bitcoind
StateDirectoryMode=0710

PrivateTmp=true
ProtectSystem=full
ProtectHome=true
NoNewPrivileges=true
PrivateDevices=true
MemoryDenyWriteExecute=true
SystemCallArchitectures=native

[Install]
WantedBy=multi-user.target
```

Put the following contents into the /home/bitcoin/.lnd/lnd.conf file:

```ini
[Application Options]

[Bitcoin]
bitcoin.regtest=true
bitcoin.node=bitcoind

[Bitcoind]
bitcoind.rpchost=127.0.0.1:8332
bitcoind.rpccookie=/var/lib/bitcoind/regtest/.cookie
bitcoind.zmqpubrawtx=tcp://127.0.0.1:29001
bitcoind.zmqpubrawblock=tcp://127.0.0.1:29002
bitcoind.estimatemode=ECONOMICAL

[watchtower]
watchtower.active=true
watchtower.listen=0.0.0.0:9911
```

Make the .lnd directory owned by the bitcoin user and group.

```console
root@lndwt:~$ chown -R bitcoin:bitcoin /home/bitcoin/.lnd
```

Setup a systemd service for lnd by putting the following contents into /usr/lib/systemd/system/lnd.service:

```ini
[Unit]
Description=LND Lightning Daemon
After=bitcoind.service
Wants=bitcoind.service

[Service]
ExecStart=/usr/bin/lnd

User=bitcoin
Group=bitcoin

Restart=always
RestartSec=30

Type=notify

TimeoutStartSec=infinity
TimeoutStopSec=1800

ProtectSystem=full
NoNewPrivileges=true
PrivateDevices=true
MemoryDenyWriteExecute=true

[Install]
WantedBy=multi-user.target
```

Update the running systemd configuration.

```console
root@lndwt:~$ systemctl daemon-reload
```

Start bitcoind & lnd.

```console
root@lndwt:~$ systemctl start bitcoind.service
root@lndwt:~$ systemctl start lnd.service
```

Enable the bitcoind.service & lnd.service so they automatically start up when the instance is started.

```console
root@lndwt:~$ systemctl enable bitcoind.service
root@lndwt:~$ systemctl enable lnd.service
```

Switch to the bitcoin user.

```console
root@lndwt:~$ su bitcoin
```

Create a file at /home/bitcoin/.bitcoin/bitcoin.conf containing the path to the bitcoind RPC cookie file:

```
rpccookiefile=/var/lib/bitcoind/regtest/.cookie
```

If this is running on regtest, add the first bitcoin node as a peer, so that they are synced together. (Not necessary on mainnet, testnet or signet)

```console
bitcoin@lndwt:~$ bitcoin-cli addnode ${IP_OF_FIRST_BITCOIND_NODE} add
```

Create an lnd wallet. This wallet will not serve any purpose and is only needed because lnd expects a wallet to exist. So there is no need to backup this wallet and the password does not have to be strong.

```console
bitcoin@lndwt:~$ lncli create
```

Once the wallet is created, create a file at /home/bitcoin/lnd_pwd containing the wallet unlock password.

Then add the following line to the [Application Options] section in /home/bitcoin/.lnd/lnd.conf:

```
wallet-unlock-password-file=/home/bitcoin/lnd_pwd
```

Get the public key of the watchtower.

```console
bitcoin@lndwt:~$ lncli tower info
```

This returns a JSON response. The public key can be found under the "pubkey" key.

Add the watchtower to the watchtower client of the currently active lnd node in the cluster. This change will automatically replicate to all other nodes in the cluster.

```console
bitcoin@lndetcdx:~$ lncli wtclient add ${WATCHTOWER_PUBKEY}@${WATCHTOWER_IP}:9911
```

Check that the watchtower is added and that "active_session_candidate" is true.

```console
bitcoin@lndetcdx:~$ lncli wtclient towers
```
