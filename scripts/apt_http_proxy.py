#!/usr/bin/env python3
"""Minimal HTTP forward proxy for apt via adb reverse (HTTP only)."""
from __future__ import annotations

import http.client
import socket
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse


class AptProxy(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _proxy(self) -> None:
        raw = self.path
        if raw.startswith("http://"):
            parsed = urlparse(raw)
            host = parsed.hostname or ""
            port = parsed.port or 80
            path = parsed.path or "/"
            if parsed.query:
                path += "?" + parsed.query
        else:
            host_hdr = self.headers.get("Host", "")
            if ":" in host_hdr:
                host, port_s = host_hdr.rsplit(":", 1)
                port = int(port_s)
            else:
                host, port = host_hdr, 80
            path = raw

        length = int(self.headers.get("Content-Length", "0") or 0)
        body = self.rfile.read(length) if length > 0 else None

        try:
            conn = http.client.HTTPConnection(host, port, timeout=120)
            headers = {
                k: v
                for k, v in self.headers.items()
                if k.lower() not in ("host", "proxy-connection", "connection", "content-length")
            }
            headers["Host"] = host if port == 80 else f"{host}:{port}"
            conn.request(self.command, path, body=body, headers=headers)
            resp = conn.getresponse()
            data = resp.read()
            self.send_response(resp.status, resp.reason)
            for k, v in resp.getheaders():
                if k.lower() in ("transfer-encoding", "connection", "proxy-connection"):
                    continue
                self.send_header(k, v)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Connection", "close")
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(data)
            conn.close()
        except Exception as exc:  # noqa: BLE001 — surface to apt client
            self.send_error(502, f"proxy error: {exc}")

    def do_GET(self) -> None:
        self._proxy()

    def do_POST(self) -> None:
        self._proxy()

    def do_HEAD(self) -> None:
        self._proxy()

    def do_CONNECT(self) -> None:
        # HTTPS tunnel (optional); apt ports.ubuntu.com is HTTP in our sources.
        try:
            host, port_s = self.path.split(":")
            port = int(port_s)
            with socket.create_connection((host, port), timeout=30) as upstream:
                self.send_response(200, "Connection Established")
                self.end_headers()
                self.connection.setblocking(False)
                upstream.setblocking(False)
                import select

                socks = [self.connection, upstream]
                while True:
                    r, _, x = select.select(socks, [], socks, 60)
                    if x or not r:
                        break
                    for s in r:
                        other = upstream if s is self.connection else self.connection
                        data = s.recv(65536)
                        if not data:
                            return
                        other.sendall(data)
        except Exception as exc:  # noqa: BLE001
            self.send_error(502, f"CONNECT error: {exc}")


def main() -> int:
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 3128
    server = ThreadingHTTPServer(("127.0.0.1", port), AptProxy)
    print(f"apt-http-proxy listening on 127.0.0.1:{port}", flush=True)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
