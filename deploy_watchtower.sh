#!/bin/sh

#eval "$(ssh-agent -s)"
#ssh-add $LNDETCD1_SSH_KEY $LNDETCD2_SSH_KEY $LNDETCD3_SSH_KEY $LNDWT_SSH_KEY

set -e

if [ $# -lt 3 ]; then
    printf "\033[1;31mError\033[0m: Expected 3 arguments, got $#\n"
    echo "Usage: $0 <lndwt_ip> <floating_ip> <mainnet|testnet|signet|regtest> [bitcoind_ip]"
    exit 1
fi

LNDWT_IP=$1
FLOATING_IP=$2
NETWORK=$3
BITCOIND_IP=$4

case "$NETWORK" in
    mainnet) NETWORK_DIR="" ;;
    testnet) NETWORK_DIR="testnet3/" ;;
    signet) NETWORK_DIR="signet/" ;;
    regtest)
        NETWORK_DIR="regtest/"
        if [ -z "$BITCOIND_IP" ]; then
            printf "\033[1;31mError\033[0m: Missing 4th argument when network is regtest\n"
            exit 1
        fi ;;
    *) printf "\033[1;31mError\033[0m: Invalid network parameter\n" ; exit 1 ;;
esac

cd "$(dirname "$(readlink -f "$0")")"

printf "\033[1;36mChecking for binaries...\033[0m\n"
test -f bin/bitcoind
test -f bin/bitcoin-cli
test -f bin/lnd
test -f bin/lncli

printf "\033[1;36mDeploying lndwt...\033[0m\n"
SSH_CMD="ssh root@$LNDWT_IP"
scp bin/bitcoind bin/bitcoin-cli bin/lnd bin/lncli "root@$LNDWT_IP:/usr/bin/"
$SSH_CMD chmod +x /usr/bin/bitcoind /usr/bin/bitcoin-cli /usr/bin/lnd /usr/bin/lncli
$SSH_CMD useradd --system --create-home --shell /bin/bash bitcoin
$SSH_CMD mkdir /etc/bitcoin
echo "$NETWORK=1

[$NETWORK]
server=1
prune=8064
disablewallet=1
rpcallowip=127.0.0.1
rpcbind=127.0.0.1:8332
zmqpubrawtx=tcp://127.0.0.1:29001
zmqpubrawblock=tcp://127.0.0.1:29002
listen=1" | $SSH_CMD "cat > /etc/bitcoin/bitcoin.conf"

if [ $NETWORK = regtest ]; then
    echo "addnode=$BITCOIND_IP" | $SSH_CMD "cat >> /etc/bitcoin/bitcoin.conf"
fi

$SSH_CMD chmod 0710 /etc/bitcoin
$SSH_CMD chmod 0640 /etc/bitcoin/bitcoin.conf
$SSH_CMD chown -R bitcoin:bitcoin /etc/bitcoin
$SSH_CMD mkdir /root/.bitcoin
echo "rpccookiefile=/var/lib/bitcoind/$NETWORK_DIR.cookie" | $SSH_CMD "cat > /root/.bitcoin/bitcoin.conf"
scp services/bitcoind.service "root@$LNDWT_IP:/usr/lib/systemd/system/"
$SSH_CMD mkdir /home/bitcoin/.lnd
echo "[Application Options]

[Bitcoin]
bitcoin.$NETWORK=true
bitcoin.node=bitcoind

[Bitcoind]
bitcoind.rpchost=127.0.0.1:8332
bitcoind.rpccookie=/var/lib/bitcoind/$NETWORK_DIR.cookie
bitcoind.zmqpubrawtx=tcp://127.0.0.1:29001
bitcoind.zmqpubrawblock=tcp://127.0.0.1:29002
bitcoind.estimatemode=ECONOMICAL

[watchtower]
watchtower.active=true
watchtower.listen=0.0.0.0:9911" | $SSH_CMD "cat > /home/bitcoin/.lnd/lnd.conf"
$SSH_CMD chown -R bitcoin:bitcoin /home/bitcoin/.lnd
echo -n "password" | $SSH_CMD "cat > /home/bitcoin/lnd_pwd"
$SSH_CMD chown bitcoin:bitcoin /home/bitcoin/lnd_pwd
$SSH_CMD chmod 660 /home/bitcoin/lnd_pwd
echo "[Unit]
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
WantedBy=multi-user.target" | $SSH_CMD "cat > /usr/lib/systemd/system/lnd.service"
$SSH_CMD systemctl daemon-reload
$SSH_CMD systemctl enable bitcoind.service
$SSH_CMD systemctl enable lnd.service
printf "\033[1;32mDone deploying lndwt\033[0m\n"

printf "\033[1;36mStarting services on lndwt\033[0m\n"
$SSH_CMD systemctl start bitcoind.service
$SSH_CMD systemctl start lnd.service
printf "\033[1;36mCreating lnd wallet...\033[0m\n"
$SSH_CMD 'printf "password\npassword\nn\n\n" | script -q -c "lncli --lnddir /home/bitcoin/.lnd create" /dev/null'
$SSH_CMD sed -i "'/\[Application Options\]/a wallet-unlock-password-file=/home/bitcoin/lnd_pwd'" /home/bitcoin/.lnd/lnd.conf
printf "\033[1;32mCreated lnd wallet\033[0m\n"

if [ $NETWORK = regtest ]; then
    ssh root@$BITCOIND_IP bitcoin-cli -generate 1
fi

printf "\033[1;36mConnecting lndetcd to watchtower...\033[0m\n"
while ! $SSH_CMD lncli --lnddir /home/bitcoin/.lnd state | grep -q -E 'RPC_ACTIVE|SERVER_ACTIVE'; do sleep 2; done
WATCHTOWER_PUBKEY=$($SSH_CMD lncli --lnddir /home/bitcoin/.lnd -n $NETWORK tower info | grep -o '"pubkey": *"[^"]*' | awk -F'"' '{print $4}')
printf "\033[1;36mWatchtower pubkey: $WATCHTOWER_PUBKEY\033[0m\n"
ssh root@$FLOATING_IP lncli --lnddir /home/bitcoin/.lnd -n $NETWORK wtclient add $WATCHTOWER_PUBKEY@$LNDWT_IP:9911
printf "\033[1;32mConnected to watchtower\033[0m\n"
