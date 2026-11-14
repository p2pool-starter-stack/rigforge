#!/usr/bin/env python3
import argparse
import asyncio
import ipaddress
import socket
import sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", required=True)
    ap.add_argument("--map", action="append", default=[])
    ap.add_argument("--log", required=True)
    args = ap.parse_args()
    routes = {}
    for item in args.map:
        src, dst = item.split("=", 1)
        host, port = dst.rsplit(":", 1)
        routes[src] = (host, int(port))
    log = open(args.log, "a", buffering=1)

    async def pipe(reader, writer):
        try:
            while True:
                data = await reader.read(65536)
                if not data:
                    break
                writer.write(data)
                await writer.drain()
        except Exception:
            pass
        finally:
            try:
                writer.close()
            except Exception:
                pass

    async def handle(reader, writer):
        try:
            _, count = await reader.readexactly(2)
            await reader.readexactly(count)
            writer.write(b"\x05\x00")
            _, cmd, _, atyp = await reader.readexactly(4)
            if atyp == 1:
                kind, host = "ip", socket.inet_ntoa(await reader.readexactly(4))
            elif atyp == 3:
                size = (await reader.readexactly(1))[0]
                kind, host = "domain", (await reader.readexactly(size)).decode()
            elif atyp == 4:
                kind = "ip"
                host = ipaddress.IPv6Address(await reader.readexactly(16)).compressed
            else:
                return
            port = int.from_bytes(await reader.readexactly(2), "big")
            target = routes.get(f"{host}:{port}")
            log.write(f"{kind} {host}:{port} {'ALLOW' if target and cmd == 1 else 'DENY'}\n")
            if cmd != 1 or target is None:
                writer.write(b"\x05\x02\x00\x01\x00\x00\x00\x00\x00\x00")
                await writer.drain()
                return
            up_reader, up_writer = await asyncio.open_connection(*target)
            writer.write(b"\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00")
            await writer.drain()
            await asyncio.gather(pipe(reader, up_writer), pipe(up_reader, writer))
        except Exception:
            pass
        finally:
            try:
                writer.close()
            except Exception:
                pass

    async def serve():
        host, port = args.listen.rsplit(":", 1)
        server = await asyncio.start_server(handle, host, int(port))
        async with server:
            await server.serve_forever()

    asyncio.run(serve())


if __name__ == "__main__":
    sys.exit(main())
