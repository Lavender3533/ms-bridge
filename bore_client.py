#!/usr/bin/env python3
"""Minimal client for the bore tunnel protocol (https://github.com/ekzhang/bore).

Exposes a local TCP port at <server>:<remote_port>. Reconnects forever.
Usage: python3 bore_client.py LOCAL_PORT REMOTE_PORT [SERVER]
"""
import json
import socket
import sys
import threading
import time

CONTROL_PORT = 7835


def send_msg(sock, obj):
    sock.sendall(json.dumps(obj).encode() + b"\0")


def recv_msg(sock, buf):
    while b"\0" not in buf[0]:
        chunk = sock.recv(4096)
        if not chunk:
            raise ConnectionError("server closed")
        buf[0] += chunk
    raw, _, rest = buf[0].partition(b"\0")
    buf[0] = rest
    return json.loads(raw)


def pipe(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def handle(server, conn_id, local_port):
    try:
        remote = socket.create_connection((server, CONTROL_PORT), 15)
        remote.settimeout(None)
        send_msg(remote, {"Accept": conn_id})
        local = socket.create_connection(("127.0.0.1", local_port), 15)
        local.settimeout(None)
        threading.Thread(target=pipe, args=(remote, local), daemon=True).start()
        pipe(local, remote)
    except OSError as e:
        print("connection error:", e, flush=True)


def run(local_port, remote_port, server):
    ctl = socket.create_connection((server, CONTROL_PORT), 15)
    ctl.settimeout(None)
    ctl.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
    buf = [b""]
    send_msg(ctl, {"Hello": remote_port})
    reply = recv_msg(ctl, buf)
    if isinstance(reply, dict) and "Hello" in reply:
        print(f"TUNNEL READY {server}:{reply['Hello']}", flush=True)
    elif isinstance(reply, dict) and "port already in use" in str(reply.get("Error", "")):
        raise PortTaken()
    else:
        raise ConnectionError(f"unexpected reply: {reply}")
    ctl.settimeout(15)
    beats, last_report = 0, time.time()
    try:
        while True:
            try:
                msg = recv_msg(ctl, buf)
            except socket.timeout:
                raise ConnectionError("no heartbeat from server for 15s (connection silently dropped)")
            if isinstance(msg, dict) and "Connection" in msg:
                print("incoming connection", flush=True)
                threading.Thread(target=handle, args=(server, msg["Connection"], local_port),
                                 daemon=True).start()
            elif isinstance(msg, dict) and "Error" in msg:
                raise ConnectionError(msg["Error"])
            else:
                beats += 1
            if time.time() - last_report > 300:
                print(f"alive, {beats} heartbeats", flush=True)
                last_report = time.time()
    finally:
        ctl.close()


class PortTaken(Exception):
    pass


def main():
    local_port = int(sys.argv[1])
    first_port = int(sys.argv[2])
    server = sys.argv[3] if len(sys.argv) > 3 else "bore.pub"
    candidates = list(range(first_port, first_port + 20))
    i = 0
    while True:
        port = candidates[i % len(candidates)]
        try:
            run(local_port, port, server)
        except PortTaken:
            print(f"port {port} taken, trying next", flush=True)
            i += 1
            continue
        except Exception as e:  # keep the tunnel alive across network hiccups
            print("tunnel down:", e, "- retrying in 5s", flush=True)
        time.sleep(5)


if __name__ == "__main__":
    main()
