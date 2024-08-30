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
) | sed -E 's/(...)/\\\1/g') | base64 -w0)
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
    $SSH_CMD apt install --no-install-recommends -y systemd/stable-backports etcd-server etcd-client tor arping
    $SSH_CMD systemctl stop etcd.service
    $SSH_CMD systemctl stop tor.service
    $SSH_CMD rm -r /var/lib/etcd/default
    $SSH_CMD sed -i "'/\[Service\]/a RestartMode=direct'" /usr/lib/systemd/system/etcd.service
    $SSH_CMD mkdir /etc/etcd
    scp certs/ca.crt certs/etcd$i.crt certs/etcd$i.key certs/client.crt certs/client.key "root@$IP:/etc/etcd/"
    $SSH_CMD chown etcd:etcd "/etc/etcd/*"
    $SSH_CMD chmod 400 /etc/etcd/etcd$i.key /etc/etcd/etcd$i.crt
    $SSH_CMD chmod 440 /etc/etcd/ca.crt /etc/etcd/client.crt /etc/etcd/client.key
    sed -e "s/{i}/$i/g" \
        -e "s/{LNDETCD1_IP}/$LNDETCD1_IP/g" \
        -e "s/{LNDETCD2_IP}/$LNDETCD2_IP/g" \
        -e "s/{LNDETCD3_IP}/$LNDETCD3_IP/g" \
        -e "s/{IP}/$IP/g" \
        config/etcd | $SSH_CMD "cat > /etc/default/etcd"
    scp config/torrc "root@$IP:/etc/tor/torrc"
    $SSH_CMD /sbin/usermod -a -G debian-tor bitcoin
    $SSH_CMD /sbin/usermod -a -G etcd bitcoin
    $SSH_CMD mkdir /home/bitcoin/.lnd
    sed -e "s/{i}/$i/g" \
        -e "s/{NETWORK}/$NETWORK/g" \
        -e "s/{BITCOIND_RPCUSER}/$BITCOIND_RPCUSER/g" \
        -e "s/{BITCOIND_RPCPASS}/$BITCOIND_RPCPASS/g" \
        -e "s/{BITCOIND_IP}/$BITCOIND_IP/g" \
        config/lnd.conf_etcd | $SSH_CMD "cat > /home/bitcoin/.lnd/lnd.conf"
    echo -n "ED25519-V3:$TOR_PRIV_KEY_BASE64" | $SSH_CMD "cat > /home/bitcoin/.lnd/v3_onion_private_key"
    $SSH_CMD chmod 600 /home/bitcoin/.lnd/v3_onion_private_key
    $SSH_CMD chown -R bitcoin:bitcoin /home/bitcoin/.lnd
    scp services/lnd.service "root@$IP:/usr/lib/systemd/system/"
    echo -n "$LND_WALLET_PASSWORD" | $SSH_CMD "cat > /home/bitcoin/lnd_pwd"
    $SSH_CMD chown bitcoin:bitcoin /home/bitcoin/lnd_pwd
    $SSH_CMD chmod 660 /home/bitcoin/lnd_pwd
    NETWORK_INTERFACE="$($SSH_CMD ip route get 1.1.1.1 | sed -n 's/.* dev \([^\ ]*\) .*/\1/p')"
    SUBNET_MASK="$($SSH_CMD ip -o address show $NETWORK_INTERFACE | awk '{print $4}' | grep $IP | cut -d/ -f2)"
    sed -e "s/{FLOATING_IP}/$FLOATING_IP/g" \
        -e "s/{SUBNET_MASK}/$SUBNET_MASK/g" \
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
