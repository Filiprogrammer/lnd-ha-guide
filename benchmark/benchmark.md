# Benchmarking LND payments

The `benchmark_receive.py` and `benchmark_send.py` scripts measure the time it takes to receive or send a multi-part payment. This assumes that a direct channel is established between the node that is to be benchmarked and another node that idealy has its database stored on a local ramfs to minimize its impact on the benchmark results.

## Prerequisites

Install Python 3.9 or newer.

Create a Python virtual environment

```shell
python3 -m venv lnd
```

Activate the virtual environment

```shell
source lnd/bin/activate
```

Install dependencies

```shell
pip install grpcio-tools
```

Copy the `lightning.proto` and `router.proto` files from the `lnd` repository or download them

```shell
curl -o lightning.proto -s https://raw.githubusercontent.com/lightningnetwork/lnd/master/lnrpc/lightning.proto
curl -o router.proto -s https://raw.githubusercontent.com/lightningnetwork/lnd/master/lnrpc/routerrpc/router.proto
```

Compile the proto files

```shell
python -m grpc_tools.protoc --proto_path=.  --python_out=. --grpc_python_out=. lightning.proto
python -m grpc_tools.protoc --proto_path=.  --python_out=. --grpc_python_out=. router.proto
```

## Configure the benchmark

Create a file called `benchmark.ini` with the following contents:

```ini
[Common]
NUMBER_OF_SHARDS = 100
AMOUNT = 100
CHANNEL_ID = 113249697726465

[Target]
TARGET_IPPORT = 192.168.0.100:10009
TARGET_MACAROON = admin_alice.macaroon
TARGET_TLS_CERT = tls_alice.cert
TARGET_PUBKEY = 02fc8b1dea7f00153be3bd449cedaabe73fda8761c9fe568f4c3e035b766530161

[Peer]
PEER_IPPORT = 192.168.0.200:10009
PEER_MACAROON = admin_bob.macaroon
PEER_TLS_CERT = tls_bob.cert
PEER_PUBKEY = 02155577dea6afd9eb20471ac3e9a82fd4893e06b4ff7b22a3b706d381faca3eff
```

Adjust the configuration parameters according to the following explanation:

* `NUMBER_OF_SHARDS`: The number of parts a payment should be split into. The more parts, the longer it takes to settle the payment.
* `AMOUNT`: The number of sats per payment. This value must be divisible by `NUMBER_OF_SHARDS`. Changing the amount does not impact performance. It is recommended to set this to the same value as `NUMBER_OF_SHARDS`. (resulting in 1 satoshi per shard)
* `CHANNEL_ID`: The id of the direct channel between the two nodes. Obtain it by running `lncli listchannels | grep chan_id` on either node.
* `TARGET_IPPORT`: The IP address and port of the gRPC API of the node that is to be benchmarked. To expose the gRPC API externally, set `rpclisten=0.0.0.0:10009` in the `lnd.conf` file of the node.
* `TARGET_MACAROON`: The path to the `admin.macaroon` file, of the node that is to be benchmarked, found at `.lnd/data/chain/bitcoin/<network>/admin.macaroon`
* `TARGET_TLS_CERT`: The path to the `tls.cert` file, of the node that is to be benchmarked, found at `.lnd/tls.cert`
* `TARGET_PUBKEY`: The identity public key of the node that is to be benchmarked. It can be obtained by running `lncli getinfo | grep identity_pubkey` on the node that is to be benchmarked.
* `PEER_IPPORT`: The IP address and port of the gRPC API of the peer node. To expose the gRPC API externally, set `rpclisten=0.0.0.0:10009` in the `lnd.conf` file of the node.
* `PEER_MACAROON`: The path to the `admin.macaroon` file of the peer node found at `.lnd/data/chain/bitcoin/<network>/admin.macaroon`
* `PEER_TLS_CERT`: The path to the `tls.cert` file of the peer node found at `.lnd/tls.cert`
* `PEER_PUBKEY`: The identity public key of the peer node. It can be obtained by running `lncli getinfo | grep identity_pubkey` on the peer node.

## Run the benchmarks

To run one iteration of the receiving benchmark simply run the `benchmark_receive.py` script.

```shell
./benchmark_receive.py
```

When completed successfully, this appends the time in seconds it took for all HTLCs to settle to a file called `benchmark_receive.log`. Note that the time taken to write preimages to the peer node's database is not included, as it is not relevant to the benchmark.

To run multiple iterations of the benchmark, simply call the script in a loop:

```shell
while true; do ./benchmark_receive.py; done
```

This can be interrupted anytime with <kbd>Ctrl</kbd> + <kbd>C</kbd>.

To benchmark the sending performance, run the `benchmark_send.py` script.

```shell
while true; do ./benchmark_send.py; done
```

This measures the time from payment initiation until all preimages are successfully written to the database. The time in seconds is appended to a file called `benchmark_send.log`.
