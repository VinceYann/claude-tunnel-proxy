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
import os
import signal
import socket
import threading

# 读请求头的上限与超时：客户端连上却不发数据时不能把线程永远挂住
MAX_HEADER_BYTES = 64 * 1024
HEADER_TIMEOUT = 30
# 隧道建立后的空闲超时
IDLE_TIMEOUT = 300
# 连接目标站点的超时
CONNECT_TIMEOUT = 15

_stopping = threading.Event()


def log(msg):
    print(f"[proxy] {msg}", flush=True)


def split_host_port(hostport):
    """把 CONNECT 里的 host:port 拆开，兼容 IPv6 字面量 [::1]:443。"""
    if hostport.startswith("["):
        host, _, rest = hostport[1:].partition("]")
        port = rest.lstrip(":") or "443"
    else:
        host, sep, port = hostport.rpartition(":")
        if not sep:
            host, port = hostport, "443"
    try:
        return host, int(port)
    except ValueError:
        return None, None


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


def handle(client, peer):
    upstream = None
    established = False
    try:
        client.settimeout(HEADER_TIMEOUT)
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = client.recv(4096)
            if not chunk:
                return
            data += chunk
            if len(data) > MAX_HEADER_BYTES:
                client.sendall(b"HTTP/1.1 431 Request Header Fields Too Large\r\n"
                               b"Connection: close\r\n\r\n")
                return

        request_line = data.split(b"\r\n", 1)[0].decode("utf-8", "replace")
        parts = request_line.split()
        if not parts or parts[0].upper() != "CONNECT":
            # 本代理只做 CONNECT 隧道；明文 HTTP 直接回 501，别让客户端干等
            client.sendall(b"HTTP/1.1 501 Not Implemented\r\n"
                           b"Content-Length: 0\r\nConnection: close\r\n\r\n")
            return
        if len(parts) < 2:
            client.sendall(b"HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n")
            return

        host, port = split_host_port(parts[1])
        if not host or not port:
            client.sendall(b"HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n")
            return

        log(f"CONNECT {host}:{port}")
        upstream = socket.create_connection((host, port), timeout=CONNECT_TIMEOUT)
        client.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        established = True

        client.settimeout(IDLE_TIMEOUT)
        upstream.settimeout(IDLE_TIMEOUT)

        t1 = threading.Thread(target=pump, args=(client, upstream), daemon=True)
        t2 = threading.Thread(target=pump, args=(upstream, client), daemon=True)
        t1.start()
        t2.start()
        t1.join()
        t2.join()
    except socket.timeout:
        if not established:
            log(f"error: 读请求头超时 ({peer})")
    except OSError as e:
        log(f"error ({peer}): {e}")
        if not established:
            # 目标连不上时明确回一个 502，客户端不用等到超时
            try:
                client.sendall(b"HTTP/1.1 502 Bad Gateway\r\n"
                               b"Content-Length: 0\r\nConnection: close\r\n\r\n")
            except OSError:
                pass
    finally:
        for sock in (upstream, client):
            if sock is not None:
                try:
                    sock.close()
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
    srv.settimeout(1.0)      # 让 accept 循环能定期检查退出标志

    # SIGTERM（tunnel-daemon.sh stop）时干净退出，而不是被硬杀
    def shutdown(signum, _frame):
        _stopping.set()
    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    log(f"HTTP CONNECT proxy running on {args.host}:{args.port}")
    if args.host not in ("127.0.0.1", "localhost", "::1"):
        # 本代理不做认证，暴露到局域网等于开放代理
        log(f"警告: 绑定在 {args.host}，无认证的代理不要暴露到公网/局域网")

    try:
        while not _stopping.is_set():
            try:
                conn, addr = srv.accept()
            except socket.timeout:
                continue
            except OSError as e:
                if _stopping.is_set():
                    break
                log(f"accept error: {e}")
                continue
            threading.Thread(target=handle, args=(conn, addr), daemon=True).start()
    finally:
        srv.close()
        log("stopped")


if __name__ == "__main__":
    main()
