"""Lets a phone on this computer's private network reach Parallax servers that listen only on
this computer (127.0.0.1), without restarting them.

    python3 scripts/forward.py 172.20.10.2 8100 8200

For each port, listens on ADDRESS:PORT and passes each connection to 127.0.0.1:PORT. A server
already on 127.0.0.1:PORT keeps it: an address and a port are taken together. Runs until
stopped; scripts/dev.sh starts and stops it.
"""

import asyncio
import errno
import sys


async def pipe(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    try:
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
    except (ConnectionError, OSError):
        pass
    finally:
        writer.close()


def handler(port: int):
    async def handle(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        try:
            up_reader, up_writer = await asyncio.open_connection("127.0.0.1", port)
        except OSError:
            writer.close()
            return
        await asyncio.gather(pipe(reader, up_writer), pipe(up_reader, writer))

    return handle


async def main(address: str, ports: list[int]) -> None:
    servers = []
    for port in ports:
        try:
            servers.append(await asyncio.start_server(handler(port), address, port))
            print(f"  Forwarding {address}:{port} to 127.0.0.1:{port}", flush=True)
        except OSError as error:
            if error.errno == errno.EADDRINUSE:
                print(f"  Port {port} is already open on {address}; nothing to forward", flush=True)
            else:
                print(f"  Could not forward port {port}: {error.strerror}", flush=True)
    if servers:
        await asyncio.gather(*(server.serve_forever() for server in servers))


if __name__ == "__main__":
    try:
        asyncio.run(main(sys.argv[1], [int(port) for port in sys.argv[2:]]))
    except KeyboardInterrupt:
        pass
