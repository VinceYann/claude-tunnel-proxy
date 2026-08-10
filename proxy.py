#!/usr/bin/env python3
"""HTTP CONNECT proxy — forward HTTPS requests through an SSH tunnel.

Supports CONNECT tunneling only (HTTPS), which is sufficient for
Claude Code and most API clients.

Usage:
    python proxy.py                    # defaults to 127.0.0.1:1080
    python proxy.py --host 0.0.0.0     # bind to all interfaces
    python proxy.py --port 2080        # use a different port
"""
import argparse
import socket
import threading
import os


def handle(client):
    try:
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = client.recv(4096)
            if not chunk:
                break
            data += chunk
        if not data.startswith(b"CONNECT "):
            client.close()
            return
        line = data.split(b"\r\n")[0].decode("utf-8", "replace")
        hostport = line.split()[1]
        host, _, port = hostport.rpartition(":")
        port = int(port)
        print(f"[proxy] CONNECT {host}:{port}", flush=True)
        upstream = socket.create_connection((host, port), timeout=15)
        client.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        client.settimeout(300)
        upstream.settimeout(300)

        def pump(src, dst):
            try:
                while True:
                    buf = src.recv(65536)
                    if not buf:
                        break
                    dst.sendall(buf)
            except OSError:
                pass
            finally:
                try:
                    dst.shutdown(socket.SHUT_WR)
                except OSError:
                    pass

        t1 = threading.Thread(target=pump, args=(client, upstream), daemon=True)
        t2 = threading.Thread(target=pump, args=(upstream, client), daemon=True)
        t1.start()
        t2.start()
        t1.join()
        t2.join()
    except Exception as e:
        print(f"[proxy] error: {e}", flush=True)
    finally:
        try:
            client.close()
        except OSError:
            pass


def main():
    parser = argparse.ArgumentParser(
        description="HTTP CONNECT proxy for SSH tunnel use"
    )
    parser.add_argument(
        "--host", default=os.environ.get("PROXY_HOST", "127.0.0.1"),
        help="Bind address (default: 127.0.0.1, env: PROXY_HOST)"
    )
    parser.add_argument(
        "--port", type=int, default=int(os.environ.get("PROXY_PORT", "1080")),
        help="Bind port (default: 1080, env: PROXY_PORT)"
    )
    args = parser.parse_args()

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((args.host, args.port))
    srv.listen(64)
    print(f"[proxy] HTTP CONNECT proxy running on {args.host}:{args.port}", flush=True)
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=handle, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    main()
