#!/usr/bin/env python3
"""Stateful, loopback-only TronGrid/USDT/TronSave simulator. Never forwards requests."""

import argparse
import copy
import hashlib
import json
import shutil
import subprocess
import tempfile
import threading
import time
from decimal import Decimal, ROUND_DOWN
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent
TOKEN = "41a614f803b6fd780986a42c78ec9c7f77e6ded13c"
RENTAL = "41e1d21475bbdc974045a4121fc5209f027be618a4"
TRANSFER_EVENT = "ddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


def base58check(raw):
    data = raw + hashlib.sha256(hashlib.sha256(raw).digest()).digest()[:4]
    value, encoded = int.from_bytes(data, "big"), ""
    while value:
        value, digit = divmod(value, 58)
        encoded = ALPHABET[digit] + encoded
    return "1" * (len(data) - len(data.lstrip(b"\0"))) + encoded


def varint(value):
    result = bytearray()
    while value > 127:
        result.append((value & 127) | 128)
        value >>= 7
    return bytes(result + bytes([value]))


def field(number, value):
    # Test-only encoding of the documented java-tron protobuf subset. The actual
    # Coffer TransactionVerifier decodes these bytes using generated protobuf types.
    if isinstance(value, int):
        return varint(number << 3) + varint(value)
    if isinstance(value, str):
        value = value.encode()
    return varint((number << 3) | 2) + varint(len(value)) + value


def verify_signature(public_key, digest, signature):
    """Use OpenSSL's secp256k1 verifier; no custom elliptic-curve implementation."""
    if len(signature) != 65 or signature[64] not in range(4):
        return False

    def integer(data):
        data = data.lstrip(b"\0") or b"\0"
        if data[0] & 128:
            data = b"\0" + data
        return b"\x02" + bytes([len(data)]) + data

    integers = integer(signature[:32]) + integer(signature[32:64])
    der = b"\x30" + bytes([len(integers)]) + integers
    spki = bytes.fromhex("3056301006072a8648ce3d020106052b8104000a034200") + bytes.fromhex(public_key)
    with tempfile.TemporaryDirectory(prefix="coffer-sim-signature-") as directory:
        directory = Path(directory)
        for name, content in [("public.der", spki), ("hash", digest), ("signature.der", der)]:
            (directory / name).write_bytes(content)
        result = subprocess.run(
            [shutil.which("openssl"), "pkeyutl", "-verify", "-pubin", "-keyform", "DER",
             "-inkey", str(directory / "public.der"), "-in", str(directory / "hash"),
             "-sigfile", str(directory / "signature.der")], capture_output=True, timeout=5)
        return result.returncode == 0


class World:
    def reset(self, name, accounts=None):
        path = (ROOT / "scenarios" / name).resolve()
        if path.parent != ROOT / "scenarios" or path.suffix != ".json":
            raise ValueError("Unknown scenario")
        scenario = json.loads(path.read_text())
        if scenario["schema_version"] != 1 or scenario["provenance"]["kind"] not in ("incident-model", "synthetic"):
            raise ValueError("Unsupported scenario schema")
        self.scenario = name
        self.config = json.loads((ROOT / "defaults.json").read_text())
        self.config.update(scenario.get("environment", {}))
        self.origin = time.monotonic()
        self.wall_origin = int(time.time() * 1000)
        self.offset_ms, self.block = 0, 1
        self.accounts = {}
        for item in accounts or self.config["accounts"]:
            item = copy.deepcopy(item)
            raw = bytes.fromhex(item["hex"])
            if len(raw) != 21 or raw[0] != 0x41 or len(bytes.fromhex(item["public_key"])) != 65:
                raise ValueError("Invalid public fixture account")
            item["address"] = base58check(raw)
            item.setdefault("trx", self.config["initial_trx"])
            item.setdefault("usdt", self.config["initial_usdt"])
            item.setdefault("energy", 0)
            item.setdefault("free_bandwidth", self.config["free_bandwidth"])
            item.setdefault("bandwidth", 0)
            item.setdefault("activated", item["trx"] > 0)
            self.accounts[item["hex"]] = item
        self.issued, self.transactions, self.receipts, self.orders = {}, {}, {}, {}
        self.requests, self.counts, self.delegations, self.buckets = [], {}, [], {}
        return self.snapshot()

    @property
    def now(self):
        return self.wall_origin + int((time.monotonic() - self.origin) * 1000) + self.offset_ms

    def snapshot(self):
        return {"scenario": self.scenario, "now": self.now, "block": self.block,
                "accounts": list(self.accounts.values()), "requests": self.requests,
                "orders": list(self.orders.values()), "receipts": self.receipts,
                "committed_transactions": len(self.transactions), "pending_delegations": self.delegations}

    def account(self, address):
        return next((item for item in self.accounts.values()
                     if address in (item["hex"], item["address"])), None)

    def receiving_account(self, address):
        if address not in self.accounts:
            self.accounts[address] = {"hex": address, "address": base58check(bytes.fromhex(address)),
                                      "public_key": None, "trx": 0, "usdt": 0, "energy": 0,
                                      "bandwidth": 0, "free_bandwidth": 0, "activated": False}
        return self.accounts[address]

    def energy_required(self, receiver):
        factor = 1_000_000
        for step in self.config["energy_schedule"]:
            if self.block >= step["at_block"]:
                factor = step["factor_ppm"]
        amount = (self.config["base_energy"] * factor + 999_999) // 1_000_000
        account = self.account(receiver)
        return amount + (self.config["new_recipient_extra_energy"] if not account or account["usdt"] == 0 else 0)

    def apply_delegations(self):
        for delegation in self.delegations[:]:
            if self.block >= delegation["at_block"]:
                self.accounts[delegation["owner"]]["energy"] += delegation["energy"]
                self.delegations.remove(delegation)

    def fault(self, path, phase):
        return next((item for item in self.config["faults"] if item["path"] == path
                     and item.get("phase", "before") == phase
                     and self.counts[path] in item["attempts"]), None)

    def rate_limit(self, authenticated):
        name = "keyed" if authenticated else "anonymous"
        rule = self.config.get("rate_limits", {}).get(name)
        if not rule:
            return False
        now = time.monotonic()
        tokens, previous = self.buckets.get(name, (rule["capacity"], now))
        tokens = min(rule["capacity"], tokens + (now - previous) * rule["refill_per_second"])
        self.buckets[name] = (max(0, tokens - 1), now)
        return tokens < 1

    def build(self, body, native=False):
        owner = body["owner_address"].lower()
        if not self.account(owner) or not self.account(owner).get("public_key"):
            raise ValueError("Only configured public test accounts are accepted")
        if native:
            value = {"owner_address": owner, "to_address": body["to_address"].lower(), "amount": body["amount"]}
            contract_type, type_name = 1, "TransferContract"
            payload = field(1, bytes.fromhex(owner)) + field(2, bytes.fromhex(value["to_address"])) + field(3, value["amount"])
        else:
            value = {"owner_address": owner, "contract_address": body["contract_address"].lower(),
                     "data": "a9059cbb" + body["parameter"]}
            if value["contract_address"] != TOKEN or body["function_selector"] != "transfer(address,uint256)":
                raise ValueError("Unsupported contract call")
            contract_type, type_name = 31, "TriggerSmartContract"
            payload = field(1, bytes.fromhex(owner)) + field(2, bytes.fromhex(TOKEN)) + field(4, bytes.fromhex(value["data"]))
        any_message = field(1, "type.googleapis.com/protocol." + type_name) + field(2, payload)
        contract = field(1, contract_type) + field(2, any_message)
        timestamp = self.now + len(self.issued)  # Unique ids without changing authorized contents.
        expiration = timestamp + 60_000
        raw = field(1, (self.block & 65535).to_bytes(2, "big")) + field(4, b"SIMBLOCK")
        raw += field(8, expiration) + field(11, contract) + field(14, timestamp)
        raw_json = {"expiration": expiration, "timestamp": timestamp,
                    "contract": [{"type": type_name, "parameter": {"value": value}}]}
        if not native:
            raw += field(18, body["fee_limit"])
            raw_json["fee_limit"] = body["fee_limit"]
        transaction = {"txID": hashlib.sha256(raw).hexdigest(), "visible": False,
                       "raw_data_hex": raw.hex(), "raw_data": raw_json}
        self.issued[transaction["txID"]] = copy.deepcopy(transaction)
        return transaction

    def accept(self, transaction):
        expected = self.issued.get(transaction.get("txID"))
        if not expected or any(transaction.get(key) != value for key, value in expected.items()):
            return {"result": False, "code": "TRANSACTION_MISMATCH"}
        txid = expected["txID"]
        if txid in self.transactions:
            return {"result": False, "code": "DUP_TRANSACTION_ERROR"}
        raw = bytes.fromhex(expected["raw_data_hex"])
        value = expected["raw_data"]["contract"][0]["parameter"]["value"]
        owner = copy.deepcopy(self.account(value["owner_address"]))
        signatures = transaction.get("signature", [])
        if len(signatures) != 1 or not verify_signature(owner["public_key"], hashlib.sha256(raw).digest(), bytes.fromhex(signatures[0])):
            return {"result": False, "code": "SIGERROR"}
        if expected["raw_data"]["expiration"] <= self.now:
            return {"result": False, "code": "TRANSACTION_EXPIRATION_ERROR"}
        bandwidth = len(field(1, raw)) + len(field(2, bytes(65))) + 64
        fee = 0
        pool = next((name for name in ["bandwidth", "free_bandwidth"] if owner[name] >= bandwidth), None)
        if pool:
            owner[pool] -= bandwidth
        else:
            fee = bandwidth * self.config["bandwidth_price"]
        energy, energy_fee, status = 0, 0, "SUCCESS"
        if "data" in value:
            receiver = "41" + value["data"][8:72][-40:]
            amount = int(value["data"][-64:], 16)
            energy = self.energy_required(receiver)
            limit = expected["raw_data"]["fee_limit"]
            if energy * self.config["energy_price"] > limit:
                status, energy = "OUT_OF_ENERGY", limit // self.config["energy_price"]
            elif owner["usdt"] < amount or self.config["vm_revert"]:
                status = "REVERT"
            covered = min(owner["energy"], energy)
            owner["energy"] -= covered
            energy_fee = (energy - covered) * self.config["energy_price"]
        else:
            amount = value["amount"]
            if owner["trx"] < amount + fee:
                return {"result": False, "code": "CONTRACT_VALIDATE_ERROR"}
            owner["trx"] -= amount
        if owner["trx"] < fee + energy_fee:
            return {"result": False, "code": "BALANCE_INSUFFICIENT"}
        owner["trx"] -= fee + energy_fee
        if "data" in value and status == "SUCCESS":
            owner["usdt"] -= amount
        self.accounts[owner["hex"]] = owner
        if "data" in value and status == "SUCCESS":
            self.receiving_account(receiver)["usdt"] += amount
        elif "data" not in value:
            target = self.receiving_account(value["to_address"])
            target["trx"] += amount
            target["activated"] = True
        self.block += 1
        receipt = {"id": txid, "blockNumber": self.block, "fee": fee + energy_fee,
                   "receipt": {"result": status, "net_fee": fee, "energy_fee": energy_fee, "energy_usage_total": energy}}
        if "data" in value and status == "SUCCESS":
            receipt["log"] = self.transfer_logs(owner["hex"], receiver, amount)
        self.receipts[txid] = receipt
        self.transactions[txid] = copy.deepcopy(transaction)
        return {"result": True, "txid": txid}

    @staticmethod
    def transfer_logs(owner, receiver, amount):
        return [{"address": TOKEN[2:], "topics": [TRANSFER_EVENT, owner[2:].zfill(64), receiver[2:].zfill(64)],
                 "data": format(amount, "064x")}]

    def route(self, path, body):
        if path == "/__admin/advance":
            self.block += body.get("blocks", 0)
            self.offset_ms += body.get("seconds", 0) * 1000
            self.apply_delegations()
            return self.snapshot()
        if path == "/__admin/configure":
            unknown = set(body) - set(self.config)
            if unknown:
                raise ValueError("Unknown configuration: " + ", ".join(unknown))
            self.config.update(body)
            return self.snapshot()
        if path.startswith("/v1/accounts/"):
            account = self.account(path.rsplit("/", 1)[1])
            return {"success": True, "data": [{"balance": account["trx"]}] if account and account["activated"] else []}
        if path == "/wallet/getchainparameters":
            return {"chainParameter": [{"key": "getEnergyFee", "value": self.config["energy_price"]},
                                       {"key": "getTransactionFee", "value": self.config["bandwidth_price"]}]}
        if path == "/wallet/getaccountresource":
            self.apply_delegations()
            account = self.account(body["address"])
            return {"EnergyLimit": account["energy"], "NetLimit": account["bandwidth"], "freeNetLimit": account["free_bandwidth"]}
        if path == "/wallet/triggerconstantcontract":
            if body["function_selector"] == "balanceOf(address)":
                account = self.account("41" + body["parameter"][-40:])
                return {"result": {"result": True}, "constant_result": [format(account["usdt"] if account else 0, "064x")]}
            owner = self.account(body["owner_address"])
            receiver, amount = "41" + body["parameter"][:64][-40:], int(body["parameter"][64:], 16)
            if self.config["vm_revert"] or owner["usdt"] < amount:
                return {"result": {"result": True, "message": "524556455254"}, "energy_used": 1000,
                        "transaction": {"ret": [{"ret": "FAILED", "contractRet": "REVERT"}]}, "constant_result": [], "logs": []}
            return {"result": {"result": True}, "energy_used": self.energy_required(receiver),
                    "transaction": {"ret": [{}]}, "constant_result": [self.config["usdt_return"]],
                    "logs": self.transfer_logs(owner["hex"], receiver, amount)}
        if path == "/wallet/triggersmartcontract":
            return {"result": {"result": True}, "transaction": self.build(body)}
        if path == "/wallet/createtransaction":
            return self.build(body, native=True)
        if path == "/wallet/broadcasttransaction":
            return self.accept(body)
        if path.endswith("/gettransactioninfobyid"):
            receipt = self.receipts.get(body["value"], {})
            return receipt if self.block >= receipt.get("blockNumber", 0) + self.config["receipt_delay_blocks"] else {}
        if path.endswith("/gettransactionbyid"):
            return self.transactions.get(body["value"], {})
        if path == "/walletsolidity/getnowblock":
            return {"block_header": {"raw_data": {"timestamp": self.now, "number": self.block}}}
        if path == "/v2/estimate-buy-resource":
            rent = int((Decimal(body["resourceAmount"]) * Decimal(str(self.config["rental_unit_price"]))).to_integral_value(rounding=ROUND_DOWN))
            return {"error": False, "data": {"unitPrice": self.config["rental_unit_price"], "durationSec": 3600,
                                             "estimateTrx": rent, "availableResource": self.config["rental_supply"]}}
        if path == "/v2/buy-resource":
            payment = body["signedTx"]
            value = payment["raw_data"]["contract"][0]["parameter"]["value"]
            rent = int(Decimal(body["resourceAmount"]) * Decimal(str(self.config["rental_unit_price"])))
            options = body["options"]
            if (value.get("to_address") != RENTAL or value.get("amount") != rent
                    or body["resourceAmount"] > self.config["rental_supply"]
                    or Decimal(str(options["maxPriceAccepted"])) < Decimal(str(self.config["rental_unit_price"]))):
                return {"error": True, "message": "quote changed"}
            accepted = self.accept(payment)
            if not accepted["result"]:
                return {"error": True, "message": accepted["code"]}
            order = {"orderId": "sim-" + payment["txID"][:16], "payment_hash": payment["txID"], "energy": body["resourceAmount"]}
            self.orders[order["orderId"]] = order
            self.delegations.append({"owner": value["owner_address"], "energy": body["resourceAmount"],
                                     "at_block": self.block + self.config["delegation_delay_blocks"]})
            self.apply_delegations()
            return {"error": False, "data": {"orderId": order["orderId"]}}
        raise ValueError("Unsupported endpoint: " + path)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        self.handle_request()

    def do_POST(self):
        self.handle_request()

    def handle_request(self):
        try:
            length = int(self.headers.get("Content-Length", 0))
            if length < 0 or length > 131072:
                raise ValueError("Request too large")
            body = json.loads(self.rfile.read(length)) if length else {}
            path = urlsplit(self.path).path
            with self.server.world_lock:
                world = self.server.world
                if path == "/__admin/reset":
                    return self.reply(200, world.reset(body["scenario"], body.get("accounts")))
                if path == "/__admin/state":
                    return self.reply(200, world.snapshot())
                if path.startswith("/__admin/"):
                    return self.reply(200, world.route(path, body))
                world.counts[path] = world.counts.get(path, 0) + 1
                authenticated = bool(self.headers.get("TRON-PRO-API-KEY"))
                world.requests.append({"method": self.command, "path": path, "time": time.monotonic(),
                                       "authenticated": authenticated, "attempt": world.counts[path]})
                fault = world.fault(path, "before")
                if fault:
                    return self.reply(fault["status"], fault.get("body", {}), fault.get("headers", {}))
                if not path.startswith("/v2/") and world.rate_limit(authenticated):
                    return self.reply(429, {"error": "quota exceeded"}, {"Retry-After": "1"})
                response = world.route(path, body)
                fault = world.fault(path, "after")
                if fault:
                    return self.reply(fault["status"], fault.get("body", {}), fault.get("headers", {}))
                self.reply(200, response)
        except (KeyError, ValueError, TypeError) as error:
            self.reply(400, {"error": str(error)})

    def reply(self, status, body, headers=None):
        data = json.dumps(body, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        for key, value in (headers or {}).items():
            self.send_header(key, str(value))
        self.end_headers()
        self.wfile.write(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scenario", default="direct-usdt-zero-return.json")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--ready-file", type=Path)
    args = parser.parse_args()
    if not shutil.which("openssl"):
        parser.error("OpenSSL or macOS LibreSSL is required for signature verification")
    world = World()
    world.reset(args.scenario)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    server.world, server.world_lock = world, threading.RLock()
    ready = {"base_url": "http://127.0.0.1:%d" % server.server_port, "scenario": world.scenario}
    if args.ready_file:
        args.ready_file.write_text(json.dumps(ready))
    print(json.dumps(ready), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
