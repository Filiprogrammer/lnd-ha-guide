#!/bin/sh

#eval "$(ssh-agent -s)"
#ssh-add $BITCOIND_SSH_KEY $LNDETCDPG1_SSH_KEY $LNDETCDPG2_SSH_KEY $LNDETCDPG3_SSH_KEY

set -e

if [ $# -ne 9 ]; then
    printf "\033[1;31mError\033[0m: Expected 9 arguments, got $#\n"
    echo "Usage: $0 <bitcoind_ip> <lndetcdpg1_ip> <lndetcdpg2_ip> <lndetcdpg3_ip> <floating_ip> <mainnet|testnet|signet|regtest> <bitcoindrpcuser> <bitcoindrpcpass> <lndwalletpass>"
    exit 1
fi

BITCOIND_IP=$1
LNDETCDPG1_IP=$2
LNDETCDPG2_IP=$3
LNDETCDPG3_IP=$4
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
sed -e "s/{NETWORK}/$NETWORK/g" \
    -e "s/{BITCOIND_RPCUSER}/$BITCOIND_RPCUSER/g" \
    -e "s/{BITCOIND_RPCPASS}/$BITCOIND_RPCPASS/g" \
    config/bitcoin.conf | $SSH_CMD "cat > /etc/bitcoin/bitcoin.conf"
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
openssl req -x509 -noenc -newkey ec -pkeyopt ec_paramgen_curve:P-256 -keyout ca.key -out ca.crt -days 3650 -subj "/CN=lndetcdpg-ca"
for i in `seq 1 3`; do
    eval IP=\$LNDETCDPG${i}_IP
    openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -keyout etcd$i.key -out etcd$i.csr -noenc -subj "/CN=etcd$i" -addext "subjectAltName=IP:$IP,IP:127.0.0.1"
    openssl req -x509 -in etcd$i.csr -CA ca.crt -CAkey ca.key -out etcd$i.crt -days 3650 -copy_extensions copy
    openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -keyout patroni$i.key -out patroni$i.csr -noenc -subj "/CN=patroni$i" -addext "subjectAltName=IP:$IP,IP:127.0.0.1"
    openssl req -x509 -in patroni$i.csr -CA ca.crt -CAkey ca.key -out patroni$i.crt -days 3650 -copy_extensions copy
done
openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -keyout etcdclient.key -out etcdclient.csr -noenc -subj "/CN=etcdclient"
openssl req -x509 -in etcdclient.csr -CA ca.crt -CAkey ca.key -out etcdclient.crt -days 3650 -copy_extensions copy
openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -keyout patroniclient.key -out patroniclient.csr -noenc -subj "/CN=patroniclient"
openssl req -x509 -in patroniclient.csr -CA ca.crt -CAkey ca.key -out patroniclient.crt -days 3650 -copy_extensions copy
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
) | sed -E 's/(...)/\\\1/g') | base64 -w0)
printf "\033[1;32mDone generating hidden service private key\033[0m\n"

POSTGRES_SUPERUSER_PASSWORD=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 16)
POSTGRES_REPLICATION_PASSWORD=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 16)
POSTGRES_REWIND_PASSWORD=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 16)
POSTGRES_LND_PASSWORD=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 16)

for i in `seq 1 3`; do
    printf "\033[1;36mDeploying lndetcdpg$i...\033[0m\n"
    eval IP=\$LNDETCDPG${i}_IP
    eval "SSH_CMD=\"ssh root@$IP\""
    scp bin/lnd bin/lncli "root@$IP:/usr/bin/"
    $SSH_CMD chmod +x /usr/bin/lnd /usr/bin/lncli
    $SSH_CMD useradd --system --create-home --shell /bin/bash bitcoin
    $SSH_CMD "echo \"deb http://deb.debian.org/debian bookworm-backports main\" >> /etc/apt/sources.list"
    $SSH_CMD apt update
    $SSH_CMD apt install --no-install-recommends -y systemd/stable-backports etcd-server etcd-client tor arping postgresql patroni
    $SSH_CMD systemctl stop etcd.service
    $SSH_CMD systemctl stop tor.service
    $SSH_CMD systemctl stop postgresql.service
    $SSH_CMD systemctl stop 'postgresql@*.service'
    $SSH_CMD systemctl stop patroni.service
    $SSH_CMD systemctl disable postgresql.service
    $SSH_CMD systemctl disable postgresql@.service
    $SSH_CMD systemctl mask postgresql.service
    $SSH_CMD systemctl mask postgresql@.service
    $SSH_CMD rm -r /var/lib/etcd/default
    $SSH_CMD rm -r /var/lib/postgresql/15/main
    $SSH_CMD sed -i "'/\[Service\]/a RestartMode=direct'" /usr/lib/systemd/system/etcd.service
    $SSH_CMD mkdir /etc/etcd
    scp certs/ca.crt certs/etcd$i.crt certs/etcd$i.key "root@$IP:/etc/etcd/"
    scp certs/etcdclient.crt "root@$IP:/etc/etcd/client.crt"
    scp certs/etcdclient.key "root@$IP:/etc/etcd/client.key"
    scp certs/patroni$i.crt certs/patroni$i.key "root@$IP:/etc/patroni"
    scp certs/patroniclient.crt "root@$IP:/etc/patroni/client.crt"
    scp certs/patroniclient.key "root@$IP:/etc/patroni/client.key"
    $SSH_CMD chown etcd:etcd "/etc/etcd/*"
    $SSH_CMD chmod 400 /etc/etcd/etcd$i.key /etc/etcd/etcd$i.crt
    $SSH_CMD chmod 440 /etc/etcd/ca.crt /etc/etcd/client.crt /etc/etcd/client.key
    $SSH_CMD chown postgres:postgres /etc/patroni/patroni$i.crt /etc/patroni/patroni$i.key /etc/patroni/client.crt /etc/patroni/client.key
    $SSH_CMD chmod 400 /etc/patroni/patroni$i.crt /etc/patroni/patroni$i.key /etc/patroni/client.crt /etc/patroni/client.key
    sed -e "s/{i}/$i/g" \
        -e "s/{LNDETCD1_IP}/$LNDETCDPG1_IP/g" \
        -e "s/{LNDETCD2_IP}/$LNDETCDPG2_IP/g" \
        -e "s/{LNDETCD3_IP}/$LNDETCDPG3_IP/g" \
        -e "s/{IP}/$IP/g" \
        config/etcd | $SSH_CMD "cat > /etc/default/etcd"
    NETWORK_INTERFACE="$($SSH_CMD ip route get 1.1.1.1 | sed -n 's/.* dev \([^\ ]*\) .*/\1/p')"
    NETWORK_BITS="$($SSH_CMD ip -o address show $NETWORK_INTERFACE | awk '{print $4}' | grep $IP | cut -d/ -f2)"
    MASK_INT=$(( 0xFFFFFFFF << (32 - $NETWORK_BITS) ))
    IFS=. read -r i1 i2 i3 i4 <<EOF
$IP
EOF
    IP_INT=$(( ($i1 << 24) + ($i2 << 16) + ($i3 << 8) + $i4 ))
    NETWORK_INT=$(( $IP_INT & $MASK_INT ))
    IP_NETWORK="$(( $NETWORK_INT >> 24 )).$(( ($NETWORK_INT >> 16) & 255 )).$(( ($NETWORK_INT >> 8) & 255 )).$(( $NETWORK_INT & 255 ))"
    sed -e "s/{i}/$i/g" \
        -e "s/{LNDETCDPG1_IP}/$LNDETCDPG1_IP/g" \
        -e "s/{LNDETCDPG2_IP}/$LNDETCDPG2_IP/g" \
        -e "s/{LNDETCDPG3_IP}/$LNDETCDPG3_IP/g" \
        -e "s/{IP}/$IP/g" \
        -e "s/{IP_NETWORK}/$IP_NETWORK/g" \
        -e "s/{NETWORK_BITS}/$NETWORK_BITS/g" \
        -e "s/{POSTGRES_SUPERUSER_PASSWORD}/$POSTGRES_SUPERUSER_PASSWORD/g" \
        -e "s/{POSTGRES_REPLICATION_PASSWORD}/$POSTGRES_REPLICATION_PASSWORD/g" \
        -e "s/{POSTGRES_REWIND_PASSWORD}/$POSTGRES_REWIND_PASSWORD/g" \
        config/patroni_config.yml | $SSH_CMD "cat > /etc/patroni/config.yml"
    $SSH_CMD chown postgres:postgres /etc/patroni/config.yml
    $SSH_CMD chmod 400 /etc/patroni/config.yml
    sed -e "s/{POSTGRES_LND_PASSWORD}/$POSTGRES_LND_PASSWORD/g" scripts/patroni_post_init.sh | $SSH_CMD "cat > /etc/patroni/post_init.sh"
    $SSH_CMD chown postgres:postgres /etc/patroni/post_init.sh
    $SSH_CMD chmod 500 /etc/patroni/post_init.sh
    $SSH_CMD /sbin/usermod -a -G etcd postgres
    scp config/torrc "root@$IP:/etc/tor/torrc"
    $SSH_CMD /sbin/usermod -a -G debian-tor bitcoin
    $SSH_CMD /sbin/usermod -a -G etcd bitcoin
    $SSH_CMD mkdir /home/bitcoin/.lnd
    sed -e "s/{i}/$i/g" \
        -e "s/{NETWORK}/$NETWORK/g" \
        -e "s/{BITCOIND_RPCUSER}/$BITCOIND_RPCUSER/g" \
        -e "s/{BITCOIND_RPCPASS}/$BITCOIND_RPCPASS/g" \
        -e "s/{BITCOIND_IP}/$BITCOIND_IP/g" \
        -e "s/{POSTGRES_LND_PASSWORD}/$POSTGRES_LND_PASSWORD/g" \
        config/lnd.conf_postgres | $SSH_CMD "cat > /home/bitcoin/.lnd/lnd.conf"
    echo -n "ED25519-V3:$TOR_PRIV_KEY_BASE64" | $SSH_CMD "cat > /home/bitcoin/.lnd/v3_onion_private_key"
    $SSH_CMD chmod 600 /home/bitcoin/.lnd/v3_onion_private_key
    $SSH_CMD chown -R bitcoin:bitcoin /home/bitcoin/.lnd
    scp services/lnd.service_postgres "root@$IP:/usr/lib/systemd/system/lnd.service"
    echo -n "$LND_WALLET_PASSWORD" | $SSH_CMD "cat > /home/bitcoin/lnd_pwd"
    $SSH_CMD chown bitcoin:bitcoin /home/bitcoin/lnd_pwd
    $SSH_CMD chmod 660 /home/bitcoin/lnd_pwd
    sed -e "s/{FLOATING_IP}/$FLOATING_IP/g" \
        -e "s/{SUBNET_MASK}/$NETWORK_BITS/g" \
        -e "s/{NETWORK_INTERFACE}/$NETWORK_INTERFACE/g" \
        scripts/lnd-floating-ip.sh | $SSH_CMD "cat > /usr/local/bin/lnd-floating-ip.sh"
    $SSH_CMD chmod +x /usr/local/bin/lnd-floating-ip.sh
    scp services/lnd-floating-ip.service "root@$IP:/usr/lib/systemd/system/"
    $SSH_CMD systemctl daemon-reload
    $SSH_CMD systemctl enable lnd.service
    $SSH_CMD systemctl enable lnd-floating-ip.service
    $SSH_CMD install -D -m 600 /root/.ssh/authorized_keys /home/bitcoin/.ssh/authorized_keys
    $SSH_CMD chown -R bitcoin:bitcoin /home/bitcoin/.ssh
    $SSH_CMD chmod 700 /home/bitcoin/.ssh
    printf "\033[1;32mDone deploying lndetcdpg$i\033[0m\n"
done

for i in `seq 1 3`; do
    printf "\033[1;36mStarting etcd and patroni on lndetcdpg$i\033[0m\n"
    eval IP=\$LNDETCDPG${i}_IP
    eval "SSH_CMD=\"ssh root@$IP\""
    $SSH_CMD systemctl start --no-block etcd.service
    $SSH_CMD systemctl start patroni.service
done

printf "\033[1;36mCreating lnd wallet... (Press Enter when you are done)\033[0m\n"
while true; do
    sleep 1
    echo "Looking for leader..."
    PATRONI_CLUSTER_JSON=$(curl --cacert certs/ca.crt --cert certs/patroniclient.crt --key certs/patroniclient.key https://$LNDETCDPG1_IP:8008/cluster) || continue
    i=$(echo "$PATRONI_CLUSTER_JSON" | jq -j '.members[] | select(.role == "leader") | .name' | tail -c 1)
    if [ ! -z "$i" ]; then
        eval IP=\$LNDETCDPG${i}_IP
        eval "SSH_CMD=\"ssh root@$IP\""
        break
    fi
done
echo "Leader found: $IP"
$SSH_CMD sed -i /wallet-unlock-password-file/s/^/#/g /home/bitcoin/.lnd/lnd.conf
$SSH_CMD systemctl start lnd.service
$SSH_CMD '{ sleep 2; echo "'$LND_WALLET_PASSWORD'"; sleep 1; echo "'$LND_WALLET_PASSWORD'"; cat; } | script -q -c "lncli --lnddir /home/bitcoin/.lnd create" /dev/null'
$SSH_CMD sed -i /wallet-unlock-password-file/s/^#//g /home/bitcoin/.lnd/lnd.conf
printf "\033[1;32mCreated lnd wallet\033[0m\n"

for i in `seq 1 3`; do
    printf "\033[1;36mStarting services on lndetcdpg$i\033[0m\n"
    eval IP=\$LNDETCDPG${i}_IP
    eval "SSH_CMD=\"ssh root@$IP\""
    $SSH_CMD systemctl start --no-block lnd-floating-ip.service
done
