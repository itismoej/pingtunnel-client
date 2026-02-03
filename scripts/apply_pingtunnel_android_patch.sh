#!/usr/bin/env bash
set -euo pipefail

PINGTUNNEL_DIR="${1:-/home/moe/Projects/pingtunnel}"

if [[ ! -d "${PINGTUNNEL_DIR}" ]]; then
  echo "pingtunnel repo not found at ${PINGTUNNEL_DIR}" >&2
  exit 1
fi

export PINGTUNNEL_DIR
python - <<'PY'
import os
from pathlib import Path

root = Path(os.environ["PINGTUNNEL_DIR"])
client = root / "client.go"
server = root / "server.go"

def replace_listen(path: Path) -> None:
    text = path.read_text()
    needle = 'conn, err := icmp.ListenPacket("ip4:icmp", p.icmpAddr)'
    replacement = 'conn, err := listenICMP(p.icmpAddr)'
    if needle in text:
        text = text.replace(needle, replacement)
        path.write_text(text)
        return
    if replacement in text:
        return
    raise SystemExit(f"Expected line not found in {path}")

replace_listen(client)
replace_listen(server)

pingtunnel = root / "pingtunnel.go"
if pingtunnel.exists():
    text = pingtunnel.read_text()
    text = text.replace(
        "conn.WriteTo(bytes, server)",
        "conn.WriteTo(bytes, icmpDstAddr(server))",
    )
    text = text.replace(
        "src:    srcaddr.(*net.IPAddr),",
        "src:    icmpSrcToIPAddr(srcaddr),",
    )
    pingtunnel.write_text(text)

client_go = root / "client.go"
if client_go.exists():
    text = client_go.read_text()
    text = text.replace(
        "if packet.echoId != p.id {\n\t\treturn\n\t}\n",
        "if !icmpDatagram && packet.echoId != p.id {\n\t\treturn\n\t}\n",
    )
    client_go.write_text(text)

android_file = root / "icmp_listen_android.go"
android_file.write_text(
    '//go:build android\n\n'
    'package pingtunnel\n\n'
    'import "golang.org/x/net/icmp"\n\n'
    'func listenICMP(addr string) (*icmp.PacketConn, error) {\n'
    '\t// Try unprivileged ICMP socket on Android.\n'
    '\tif conn, err := icmp.ListenPacket("udp4", addr); err == nil {\n'
    '\t\tsetICMPDatagram(true)\n'
    '\t\treturn conn, nil\n'
    '\t}\n'
    '\tsetICMPDatagram(false)\n'
    '\t// Fallback to raw ICMP (will require CAP_NET_RAW).\n'
    '\treturn icmp.ListenPacket("ip4:icmp", addr)\n'
    '}\n'
)

other_file = root / "icmp_listen_other.go"
other_file.write_text(
    '//go:build !android\n\n'
    'package pingtunnel\n\n'
    'import "golang.org/x/net/icmp"\n\n'
    'func listenICMP(addr string) (*icmp.PacketConn, error) {\n'
    '\tsetICMPDatagram(false)\n'
    '\treturn icmp.ListenPacket("ip4:icmp", addr)\n'
    '}\n'
)

addr_file = root / "icmp_addr.go"
addr_file.write_text(
    'package pingtunnel\n\n'
    'import "net"\n\n'
    'var icmpDatagram bool\n\n'
    'func setICMPDatagram(enabled bool) {\n'
    '\ticmpDatagram = enabled\n'
    '}\n\n'
    'func icmpDstAddr(ip *net.IPAddr) net.Addr {\n'
    '\tif icmpDatagram {\n'
    '\t\treturn &net.UDPAddr{IP: ip.IP}\n'
    '\t}\n'
    '\treturn ip\n'
    '}\n\n'
    'func icmpSrcToIPAddr(addr net.Addr) *net.IPAddr {\n'
    '\tswitch v := addr.(type) {\n'
    '\tcase *net.IPAddr:\n'
    '\t\treturn v\n'
    '\tcase *net.UDPAddr:\n'
    '\t\treturn &net.IPAddr{IP: v.IP, Zone: v.Zone}\n'
    '\tdefault:\n'
    '\t\treturn &net.IPAddr{IP: net.IPv4zero}\n'
    '\t}\n'
    '}\n'
)

print(f"Patched {root}")
PY

echo "Applied Android ping-socket patch to ${PINGTUNNEL_DIR}."
