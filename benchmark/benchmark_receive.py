#!/usr/bin/env python3

import codecs
import configparser
import grpc
import lightning_pb2 as lnrpc
import lightning_pb2_grpc as lightningstub
import router_pb2 as routerrpc
import router_pb2_grpc as routerstub
import os
from threading import Thread

config_schema = {
    "Common": ["NUMBER_OF_SHARDS", "AMOUNT", "CHANNEL_ID"],
    "Target": ["TARGET_IPPORT", "TARGET_MACAROON", "TARGET_TLS_CERT", "TARGET_PUBKEY"],
    "Peer": ["PEER_IPPORT", "PEER_MACAROON", "PEER_TLS_CERT"]
}

config = configparser.ConfigParser()
config.read("benchmark.ini")

for section, keys in config_schema.items():
    if section not in config:
        raise SystemExit(f"Missing config section: {section}")
    for key in keys:
        if key not in config[section]:
            raise SystemExit(f"Missing config key: {key} in section: {section}")

NUMBER_OF_SHARDS = config["Common"].getint("NUMBER_OF_SHARDS")
AMOUNT = config["Common"].getint("AMOUNT")
CHANNEL_ID = config["Common"].getint("CHANNEL_ID")

SENDER_IPPORT = config["Peer"]["PEER_IPPORT"]
SENDER_MACAROON = config["Peer"]["PEER_MACAROON"]
SENDER_TLS_CERT = config["Peer"]["PEER_TLS_CERT"]

RECEIVER_IPPORT = config["Target"]["TARGET_IPPORT"]
RECEIVER_MACAROON = config["Target"]["TARGET_MACAROON"]
RECEIVER_TLS_CERT = config["Target"]["TARGET_TLS_CERT"]
RECEIVER_PUBKEY = config["Target"]["TARGET_PUBKEY"]

def generate_invoice(stub: lightningstub.LightningStub, amount: int) -> tuple[str, bytes, bytes]:
    response = stub.AddInvoice(lnrpc.Invoice(value=amount))

    invoice = response.payment_request
    r_hash = response.r_hash
    payment_addr = response.payment_addr

    return invoice, r_hash, payment_addr

def build_sharded_route_to_channel_partner(stub: routerstub.RouterStub, amount: int, number_of_shards: int, payment_addr: bytes, channel_id: int, receiver_pubkey: bytes) -> lnrpc.Route:
    buildroute_request = routerrpc.BuildRouteRequest(
        amt_msat=amount * 1000,
        hop_pubkeys=[receiver_pubkey]
    )

    buildroute_response = stub.BuildRoute(buildroute_request)

    mpp_record = lnrpc.MPPRecord(
        payment_addr=payment_addr,
        total_amt_msat=amount * 1000
    )

    hop = lnrpc.Hop(
        chan_id=channel_id,
        expiry=buildroute_response.route.total_time_lock,
        amt_to_forward_msat=int((amount * 1000) / number_of_shards),
        fee_msat=0,
        pub_key=receiver_pubkey.hex(),
        tlv_payload=True,
        mpp_record=mpp_record
    )

    route = lnrpc.Route(
        total_time_lock=buildroute_response.route.total_time_lock,
        total_fees_msat=0,
        total_amt_msat=int((amount * 1000) / number_of_shards),
        hops=[hop]
    )

    return route

def new_grps_creds(tls_cert_path: str, macaroon_path: str) -> grpc.ChannelCredentials:
    os.environ["GRPC_SSL_CIPHER_SUITES"] = 'HIGH+ECDSA'

    cert = open(os.path.expanduser(tls_cert_path), 'rb').read()
    ssl_creds = grpc.ssl_channel_credentials(cert)

    with open(os.path.expanduser(macaroon_path), 'rb') as f:
        macaroon_bytes = f.read()
        macaroon = codecs.encode(macaroon_bytes, 'hex')

    def metadata_callback(context, callback):
        callback([('macaroon', macaroon)], None)

    auth_creds = grpc.metadata_call_credentials(metadata_callback)
    creds = grpc.composite_channel_credentials(ssl_creds, auth_creds)

    return creds

receiver_creds = new_grps_creds(RECEIVER_TLS_CERT, RECEIVER_MACAROON)
receiver_channel = grpc.secure_channel(RECEIVER_IPPORT, receiver_creds)
receiver_stub = lightningstub.LightningStub(receiver_channel)

sender_creds = new_grps_creds(SENDER_TLS_CERT, SENDER_MACAROON)
sender_channel = grpc.secure_channel(SENDER_IPPORT, sender_creds)
sender_stub = routerstub.RouterStub(sender_channel)

print("Generating invoice on receiver end...")
invoice, r_hash, payment_addr = generate_invoice(receiver_stub, AMOUNT)
print(f"invoice: \033[93m{invoice}\033[0m")
print(f"r_hash: \033[93m{r_hash.hex()}\033[0m")
print(f"payment_addr: \033[93m{payment_addr.hex()}\033[0m")

print("Building a route from sender to receiver...")
route = build_sharded_route_to_channel_partner(
    sender_stub,
    AMOUNT,
    NUMBER_OF_SHARDS,
    payment_addr,
    CHANNEL_ID,
    bytes.fromhex(RECEIVER_PUBKEY)
)
print(f"route: \033[93m{route}\033[0m")

sendtoroute_request = routerrpc.SendToRouteRequest(
    payment_hash=r_hash,
    route=route
)

def sendtoroute_fn():
    sendtoroute_response = sender_stub.SendToRouteV2(sendtoroute_request)

threads = []

print(f"Sending payment of {NUMBER_OF_SHARDS} shards...")

for i in range(NUMBER_OF_SHARDS):
    threads.insert(i, Thread(target=sendtoroute_fn))
    threads[i].start()

for i in range(NUMBER_OF_SHARDS):
    threads[i].join()

print("Payment complete")
print("Reading payment resolve time on the receiving side...")

trackpayment_request = routerrpc.TrackPaymentRequest(
    payment_hash=r_hash,
    no_inflight_updates=True
)

for trackpayment_response in sender_stub.TrackPaymentV2(trackpayment_request):
    if trackpayment_response.status != lnrpc.Payment.PaymentStatus.SUCCEEDED:
        print(f"\033[91mPayment did not actually succeed. Failure Reason: {trackpayment_response.failure_reason}\033[0m")
        break

    print(f"creation_time_ns: \033[93m{trackpayment_response.creation_time_ns}\033[0m")
    max_resolve_time_ns = 0
    for htlc in trackpayment_response.htlcs:
        if max_resolve_time_ns < htlc.resolve_time_ns:
            max_resolve_time_ns = htlc.resolve_time_ns
    print(f"max_resolve_time_ns: \033[93m{max_resolve_time_ns}\033[0m")
    time_diff_sec = (max_resolve_time_ns - trackpayment_response.creation_time_ns) / 1000000000
    print(f"\033[92mReceiving side took {time_diff_sec} seconds to settle all HTLCs\033[0m")
    with open("benchmark_receive.log", "a") as myfile:
        myfile.write(f"{time_diff_sec}\n")

receiver_channel.close()
sender_channel.close()
