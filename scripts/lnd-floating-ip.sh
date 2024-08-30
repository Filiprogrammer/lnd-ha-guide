#!/bin/sh

FLOATING_IP="{FLOATING_IP}"
SUBNET_MASK="{SUBNET_MASK}"
INTERFACE="{NETWORK_INTERFACE}"

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
