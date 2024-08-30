#!/bin/sh

#eval "$(ssh-agent -s)"
#ssh-add $BITCOIND_SSH_KEY $LNDETCD1_SSH_KEY $LNDETCD2_SSH_KEY $LNDETCD3_SSH_KEY

set -e

if [ $# -ne 9 ]; then
    printf "\033[1;31mError\033[0m: Expected 9 arguments, got $#\n"
    echo "Usage: $0 <bitcoind_ip> <lndetcd1_ip> <lndetcd2_ip> <lndetcd3_ip> <floating_ip> <mainnet|testnet|signet|regtest> <bitcoindrpcuser> <bitcoindrpcpass> <lndwalletpass>"
    exit 1
fi

BITCOIND_IP=$1
LNDETCD1_IP=$2
LNDETCD2_IP=$3
LNDETCD3_IP=$4
FLOATING_IP=$5
NETWORK=$6
BITCOIND_RPCUSER=$7
BITCOIND_RPCPASS=$8
LND_WALLET_PASSWORD=$9

case "$NETWORK" in
    mainnet|testnet|signet|regtest) ;;
    *) printf "\033[1;31mError\033[0m: Invalid network parameter\n" ; exit 1 ;;
esac

cd "$(dirname "$(readlink -f "$0")")"

printf "\033[1;36mChecking for binaries...\033[0m\n"
test -f bin/bitcoind
test -f bin/bitcoin-cli
test -f bin/lnd
test -f bin/lncli

printf "\033[1;36mDeploying bitcoind...\033[0m\n"
SSH_CMD="ssh root@$BITCOIND_IP"
scp bin/bitcoind bin/bitcoin-cli "root@$BITCOIND_IP:/usr/bin/"
$SSH_CMD chmod +x /usr/bin/bitcoind /usr/bin/bitcoin-cli
$SSH_CMD useradd --system --no-create-home --home /nonexistent --shell /usr/sbin/nologin bitcoin
$SSH_CMD mkdir /etc/bitcoin
echo "$NETWORK=1

[$NETWORK]
server=1
txindex=1
disablewallet=0
rpcuser=$BITCOIND_RPCUSER
rpcpassword=$BITCOIND_RPCPASS
rpcallowip=0.0.0.0/0
rpcbind=0.0.0.0:8332
zmqpubhashblock=tcp://0.0.0.0:29000
zmqpubrawtx=tcp://0.0.0.0:29001
zmqpubrawblock=tcp://0.0.0.0:29002
listen=1" | $SSH_CMD "cat > /etc/bitcoin/bitcoin.conf"
$SSH_CMD chmod 0710 /etc/bitcoin
$SSH_CMD chmod 0640 /etc/bitcoin/bitcoin.conf
$SSH_CMD chown -R bitcoin:bitcoin /etc/bitcoin
scp services/bitcoind.service "root@$BITCOIND_IP:/usr/lib/systemd/system/"
$SSH_CMD systemctl daemon-reload
$SSH_CMD systemctl enable bitcoind.service
$SSH_CMD mkdir /root/.bitcoin
echo "rpcuser=$BITCOIND_RPCUSER
rpcpassword=$BITCOIND_RPCPASS" | $SSH_CMD "cat > /root/.bitcoin/bitcoin.conf"
printf "\033[1;32mDone deploying bitcoind\033[0m\n"

printf "\033[1;36mStarting bitcoind.service\033[0m\n"
$SSH_CMD systemctl start bitcoind.service
if [ $NETWORK = regtest ]; then
    $SSH_CMD bitcoin-cli -named createwallet wallet_name=main load_on_startup=true
fi

printf "\033[1;36mGenerating certificates...\033[0m\n"
mkdir -p certs
cd certs
openssl req -x509 -noenc -newkey ec -pkeyopt ec_paramgen_curve:P-256 -keyout ca.key -out ca.crt -days 3650 -subj "/CN=lndetcd-ca"
for i in `seq 1 3`; do
    eval IP=\$LNDETCD${i}_IP
    openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -keyout etcd$i.key -out etcd$i.csr -noenc -subj "/CN=etcd$i" -addext "subjectAltName=IP:$IP,IP:127.0.0.1"
    openssl req -x509 -in etcd$i.csr -CA ca.crt -CAkey ca.key -out etcd$i.crt -days 3650 -copy_extensions copy
done
openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -keyout client.key -out client.csr -noenc -subj "/CN=client"
openssl req -x509 -in client.csr -CA ca.crt -CAkey ca.key -out client.crt -days 3650 -copy_extensions copy
cd ..
printf "\033[1;32mDone generating certificates\033[0m\n"

printf "\033[1;36mGenerating hidden service private key...\033[0m\n"
SHA512_OCT=$(openssl rand 32 | openssl sha512 -binary | od -An -v -t o1 | tr -d ' \n')
BYTE0_OCT=$(printf '%03o' $((0$(head -c3 <<EOF
$SHA512_OCT
EOF
) & 248)))
BYTE31_OCT=$(printf '%o' $((0$(cut -c94-96 <<EOF
$SHA512_OCT
EOF
) & 127 | 64)))
TOR_PRIV_KEY_BASE64=$(printf $(echo -n $BYTE0_OCT$(cut -c4-93 <<EOF
$SHA512_OCT
EOF
)$BYTE31_OCT$(tail -c97 <<EOF
$SHA512_OCT
EOF
) | sed -r 's/(...)/\\\1/g') | base64 -w0)
printf "\033[1;32mDone generating hidden service private key\033[0m\n"

for i in `seq 1 3`; do
    printf "\033[1;36mDeploying lndetcd$i...\033[0m\n"
    eval IP=\$LNDETCD${i}_IP
    eval "SSH_CMD=\"ssh root@$IP\""
    scp bin/lnd bin/lncli "root@$IP:/usr/bin/"
    $SSH_CMD chmod +x /usr/bin/lnd /usr/bin/lncli
    $SSH_CMD useradd --system --create-home --shell /bin/bash bitcoin
    $SSH_CMD "echo \"deb http://deb.debian.org/debian bookworm-backports main\" >> /etc/apt/sources.list"
    $SSH_CMD apt update
    $SSH_CMD apt install -y systemd/stable-backports etcd-server etcd-client tor arping
    $SSH_CMD systemctl stop etcd.service
    $SSH_CMD systemctl stop tor.service
    $SSH_CMD rm -r /var/lib/etcd/default
    $SSH_CMD sed -i "'/\[Service\]/a RestartMode=direct'" /usr/lib/systemd/system/etcd.service
    $SSH_CMD mkdir /etc/etcd
    scp certs/ca.crt certs/etcd$i.crt certs/etcd$i.key "root@$IP:/etc/etcd/"
    $SSH_CMD chown etcd:etcd "/etc/etcd/*"
    $SSH_CMD chmod 440 "/etc/etcd/*"
    echo "ETCD_NAME=etcd$i
ETCD_INITIAL_CLUSTER="etcd1=https://$LNDETCD1_IP:2380,etcd2=https://$LNDETCD2_IP:2380,etcd3=https://$LNDETCD3_IP:2380"
ETCD_ADVERTISE_CLIENT_URLS=https://$IP:2379
ETCD_LISTEN_CLIENT_URLS=https://0.0.0.0:2379
ETCD_LISTEN_PEER_URLS=https://0.0.0.0:2380
ETCD_INITIAL_ADVERTISE_PEER_URLS=https://$IP:2380
ETCD_MAX_TXN_OPS=16384

ETCD_CERT_FILE=/etc/etcd/etcd$i.crt
ETCD_KEY_FILE=/etc/etcd/etcd$i.key
ETCD_TRUSTED_CA_FILE=/etc/etcd/ca.crt
ETCD_PEER_CERT_FILE=/etc/etcd/etcd$i.crt
ETCD_PEER_KEY_FILE=/etc/etcd/etcd$i.key
ETCD_PEER_TRUSTED_CA_FILE=/etc/etcd/ca.crt
ETCD_PEER_CLIENT_CERT_AUTH=true
ETCD_CLIENT_CERT_AUTH=true" | $SSH_CMD "cat > /etc/default/etcd"
    echo "ExitPolicy reject *:*
SOCKSPort 9050
ControlPort 9051
CookieAuthentication 1" | $SSH_CMD "cat > /etc/tor/torrc"
    $SSH_CMD /sbin/usermod -a -G debian-tor bitcoin
    scp certs/client.crt certs/client.key "root@$IP:/home/bitcoin/"
    $SSH_CMD chown bitcoin:bitcoin /home/bitcoin/client.crt /home/bitcoin/client.key
    $SSH_CMD chmod 440 /home/bitcoin/client.crt /home/bitcoin/client.key
    $SSH_CMD mkdir /home/bitcoin/.lnd
    echo "[Application Options]
listen=0.0.0.0:9735
alias=lndetcd
wallet-unlock-password-file=/home/bitcoin/lnd_pwd

[Bitcoin]
bitcoin.$NETWORK=true
bitcoin.node=bitcoind

[Bitcoind]
bitcoind.rpcuser=$BITCOIND_RPCUSER
bitcoind.rpcpass=$BITCOIND_RPCPASS
bitcoind.rpchost=$BITCOIND_IP:8332
bitcoind.zmqpubrawtx=tcp://$BITCOIND_IP:29001
bitcoind.zmqpubrawblock=tcp://$BITCOIND_IP:29002
bitcoind.estimatemode=ECONOMICAL

[tor]
tor.active=true
tor.v3=true

[wtclient]
wtclient.active=true

[healthcheck]
healthcheck.leader.interval=60s

[db]
db.backend=etcd

[etcd]
db.etcd.host=127.0.0.1:2379
db.etcd.cert_file=/home/bitcoin/client.crt
db.etcd.key_file=/home/bitcoin/client.key
db.etcd.insecure_skip_verify=1

[cluster]
cluster.enable-leader-election=1
cluster.leader-elector=etcd
cluster.etcd-election-prefix=cluster-leader
cluster.id=lndetcd$i
cluster.leader-session-ttl=100" | $SSH_CMD "cat > /home/bitcoin/.lnd/lnd.conf"
    echo -n "ED25519-V3:$TOR_PRIV_KEY_BASE64" | $SSH_CMD "cat > /home/bitcoin/.lnd/v3_onion_private_key"
    $SSH_CMD chmod 600 /home/bitcoin/.lnd/v3_onion_private_key
    $SSH_CMD chown -R bitcoin:bitcoin /home/bitcoin/.lnd
    scp services/lnd.service "root@$IP:/usr/lib/systemd/system/"
    echo -n "$LND_WALLET_PASSWORD" | $SSH_CMD "cat > /home/bitcoin/lnd_pwd"
    $SSH_CMD chown bitcoin:bitcoin /home/bitcoin/lnd_pwd
    $SSH_CMD chmod 660 /home/bitcoin/lnd_pwd
    NETWORK_INTERFACE="$($SSH_CMD ip route get 1.1.1.1 | sed -n 's/.* dev \([^\ ]*\) .*/\1/p')"
    SUBNET_MASK="$($SSH_CMD ip -o address show $NETWORK_INTERFACE | awk '{print $4}' | grep $IP | cut -d/ -f2)"
    echo "#!/bin/sh

FLOATING_IP=\"$FLOATING_IP\"
SUBNET_MASK=\"$SUBNET_MASK\"
INTERFACE=\"$NETWORK_INTERFACE\"

while true; do
    sleep 20
    lncli --lnddir /home/bitcoin/.lnd state | grep -q -E 'NON_EXISTING|LOCKED|UNLOCKED|RPC_ACTIVE|SERVER_ACTIVE'
    IS_LEADER=\$?

    ip addr show \$INTERFACE | grep -q \$FLOATING_IP
    IP_ASSIGNED=\$?

    if [ \$IS_LEADER -eq 0 ] && [ \$IP_ASSIGNED -ne 0 ]; then
        echo \"Assigning the floating IP address to this node since it is the leader\"
        ip addr add \$FLOATING_IP/\$SUBNET_MASK dev \$INTERFACE
        arping -c 1 -I \$INTERFACE \$FLOATING_IP
    elif [ \$IS_LEADER -ne 0 ] && [ \$IP_ASSIGNED -eq 0 ]; then
        echo \"Removing the floating IP address since this node is no longer the leader\"
        ip addr del \$FLOATING_IP/\$SUBNET_MASK dev \$INTERFACE
    fi
done" | $SSH_CMD "cat > /usr/local/bin/lnd-floating-ip.sh"
    $SSH_CMD chmod +x /usr/local/bin/lnd-floating-ip.sh
    scp services/lnd-floating-ip.service "root@$IP:/usr/lib/systemd/system/"
    $SSH_CMD systemctl daemon-reload
    $SSH_CMD systemctl enable lnd.service
    $SSH_CMD systemctl enable lnd-floating-ip.service
    $SSH_CMD install -D -m 600 /root/.ssh/authorized_keys /home/bitcoin/.ssh/authorized_keys
    $SSH_CMD chown -R bitcoin:bitcoin /home/bitcoin/.ssh
    $SSH_CMD chmod 700 /home/bitcoin/.ssh
    printf "\033[1;32mDone deploying lndetcd$i\033[0m\n"
done

for i in `seq 1 3`; do
    printf "\033[1;36mStarting etcd on lndetcd$i\033[0m\n"
    eval IP=\$LNDETCD${i}_IP
    eval "SSH_CMD=\"ssh root@$IP\""
    $SSH_CMD systemctl start --no-block etcd.service
done

printf "\033[1;36mCreating lnd wallet... (Press Enter when you are done)\033[0m\n"
SSH_CMD="ssh root@$LNDETCD1_IP"
$SSH_CMD sed -i /wallet-unlock-password-file/s/^/#/g /home/bitcoin/.lnd/lnd.conf
$SSH_CMD systemctl start lnd.service
$SSH_CMD '{ sleep 2; echo "'$LND_WALLET_PASSWORD'"; sleep 1; echo "'$LND_WALLET_PASSWORD'"; cat; } | script -q -c "lncli --lnddir /home/bitcoin/.lnd create" /dev/null'
$SSH_CMD sed -i /wallet-unlock-password-file/s/^#//g /home/bitcoin/.lnd/lnd.conf
printf "\033[1;32mCreated lnd wallet\033[0m\n"

for i in `seq 1 3`; do
    printf "\033[1;36mStarting services on lndetcd$i\033[0m\n"
    eval IP=\$LNDETCD${i}_IP
    eval "SSH_CMD=\"ssh root@$IP\""
    $SSH_CMD systemctl start --no-block lnd-floating-ip.service
done
