#!/usr/bin/env python3
# Catch exactly one OTLP/HTTP export request raw: serve it, print the full HTTP
# request (request line + headers + body bytes) to stdout, answer 200, exit.
# Usage: python3 catch-request.py [port]   (default 8428)
# Point the agent's backend at this port with the receiver container stopped.
import socket
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8428
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("", PORT))
srv.listen(1)
conn, _ = srv.accept()
conn.settimeout(10)

data = b""
while b"\r\n\r\n" not in data:  # request head
    data += conn.recv(65536)
head, _, body = data.partition(b"\r\n\r\n")
h = head.decode("latin1").lower()

if "content-length:" in h:  # fixed-length body
    n = int(h.split("content-length:")[1].split("\r\n")[0].strip())
    while len(body) < n:
        body += conn.recv(65536)
    body = body[:n]
elif "chunked" in h:  # chunked body: terminator is 0\r\n\r\n
    while not body.endswith(b"0\r\n\r\n"):
        body += conn.recv(65536)

conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
conn.close()
srv.close()
sys.stdout.buffer.write(head + b"\r\n\r\n" + body)  # raw request exactly as sent
