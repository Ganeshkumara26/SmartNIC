#!/usr/bin/env python3
"""
SmartNIC Test Packet Generator
================================
Generates synthetic Ethernet/IPv4/UDP packets as hex files for Verilog
testbenches to load via $readmemh.

Each packet is output as one or more 512-bit (64-byte) beats, formatted
as 128-character hex strings (one per line).

Usage:
    python gen_packets.py                  # Generate default test set
    python gen_packets.py --count 100      # Generate 100 packets
    python gen_packets.py --mix hp=30,lp=70  # 30% HP, 70% LP traffic
"""

import struct
import argparse
import random
import os
import json

# ============================================================================
# Constants
# ============================================================================
BEAT_BYTES = 64        # 512-bit bus = 64 bytes per beat
ETHERTYPE_IPV4 = 0x0800
IP_PROTO_UDP = 17
IP_PROTO_TCP = 6

# Default MAC addresses
SRC_MAC = bytes([0x00, 0x11, 0x22, 0x33, 0x44, 0x55])
DST_MAC = bytes([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])

# ============================================================================
# Packet Building Helpers
# ============================================================================

def ip_checksum(header_bytes):
    """Calculate IPv4 header checksum (RFC 1071)."""
    if len(header_bytes) % 2 != 0:
        header_bytes += b'\x00'
    total = 0
    for i in range(0, len(header_bytes), 2):
        word = (header_bytes[i] << 8) + header_bytes[i + 1]
        total += word
    # Add carry
    while total >> 16:
        total = (total & 0xFFFF) + (total >> 16)
    return ~total & 0xFFFF


def build_ethernet_header(dst_mac, src_mac, ethertype):
    """Build a 14-byte Ethernet II header."""
    return dst_mac + src_mac + struct.pack('!H', ethertype)


def build_ipv4_header(src_ip, dst_ip, protocol, payload_len):
    """Build a 20-byte IPv4 header (no options)."""
    version_ihl = 0x45  # Version 4, IHL 5 (20 bytes)
    dscp_ecn = 0x00
    total_length = 20 + payload_len  # IP header + payload
    identification = random.randint(0, 0xFFFF)
    flags_frag = 0x4000  # Don't Fragment
    ttl = 64
    checksum = 0  # Will be calculated

    header = struct.pack('!BBHHHBBH4s4s',
        version_ihl, dscp_ecn, total_length,
        identification, flags_frag,
        ttl, protocol, checksum,
        bytes(int(x) for x in src_ip.split('.')),
        bytes(int(x) for x in dst_ip.split('.')))

    # Calculate and insert checksum
    chk = ip_checksum(header)
    header = header[:10] + struct.pack('!H', chk) + header[12:]
    return header


def build_udp_header(src_port, dst_port, payload_len):
    """Build an 8-byte UDP header."""
    length = 8 + payload_len
    checksum = 0  # Optional for IPv4 UDP
    return struct.pack('!HHHH', src_port, dst_port, length, checksum)


def build_udp_packet(src_ip, dst_ip, src_port, dst_port, payload_size=32):
    """Build a complete Ethernet/IPv4/UDP packet with random payload."""
    payload = bytes(random.randint(0, 255) for _ in range(payload_size))
    udp_header = build_udp_header(src_port, dst_port, payload_size)
    ip_payload_len = len(udp_header) + payload_size
    ip_header = build_ipv4_header(src_ip, dst_ip, IP_PROTO_UDP, ip_payload_len)
    eth_header = build_ethernet_header(DST_MAC, SRC_MAC, ETHERTYPE_IPV4)
    return eth_header + ip_header + udp_header + payload


# ============================================================================
# Traffic Profiles
# ============================================================================

# Predefined traffic classes matching classifier rules in testbenches
TRAFFIC_CLASSES = {
    'urllc': {  # Queue 0 — Highest Priority
        'dst_ip': '10.0.1.1',
        'dst_port': 5001,
        'src_ip': '192.168.1.100',
        'src_port_range': (10000, 10100),
        'payload_size': 64,     # Small, latency-sensitive
        'description': 'URLLC (Ultra-Reliable Low-Latency)'
    },
    'voice': {  # Queue 1 — High Priority
        'dst_ip': '10.0.2.1',
        'dst_port': 5060,
        'src_ip': '192.168.1.101',
        'src_port_range': (20000, 20100),
        'payload_size': 160,    # VoIP packet size
        'description': 'Real-time Voice (VoIP)'
    },
    'embb': {   # Queue 2 — Medium Priority
        'dst_ip': '10.0.3.1',
        'dst_port': 8080,
        'src_ip': '192.168.1.102',
        'src_port_range': (30000, 30100),
        'payload_size': 1400,   # Large, bulk data
        'description': 'eMBB (Enhanced Mobile Broadband)'
    },
    'iot': {     # Queue 3 — Lowest Priority
        'dst_ip': '10.0.4.1',
        'dst_port': 1883,
        'src_ip': '192.168.1.103',
        'src_port_range': (40000, 40100),
        'payload_size': 32,     # Tiny IoT sensor data
        'description': 'IoT / Best-Effort'
    }
}


def packet_to_beats(packet_bytes):
    """
    Split a packet into 64-byte (512-bit) beats.
    Returns list of (data_hex, keep_hex, is_last) tuples.
    """
    beats = []
    offset = 0
    while offset < len(packet_bytes):
        chunk = packet_bytes[offset:offset + BEAT_BYTES]
        valid_bytes = len(chunk)

        # Pad to 64 bytes
        padded = chunk + b'\x00' * (BEAT_BYTES - valid_bytes)

        # TKEEP: one bit per valid byte (LSB-first)
        keep = (1 << valid_bytes) - 1

        is_last = (offset + BEAT_BYTES >= len(packet_bytes))

        # Convert to hex string (MSB first in the string)
        data_hex = padded.hex()
        keep_hex = f'{keep:016x}'

        beats.append((data_hex, keep_hex, is_last))
        offset += BEAT_BYTES

    return beats


def generate_test_packets(output_dir, num_packets=20, traffic_mix=None):
    """
    Generate test packets and write them as hex files for Verilog $readmemh.

    Produces:
      - packets_data.hex  : TDATA values (one 512-bit beat per line)
      - packets_keep.hex  : TKEEP values (one 64-bit value per line)
      - packets_last.hex  : TLAST values (one bit per line)
      - packets_meta.json : Human-readable metadata about each packet
    """
    if traffic_mix is None:
        traffic_mix = {'urllc': 25, 'voice': 25, 'embb': 25, 'iot': 25}

    os.makedirs(output_dir, exist_ok=True)

    # Build packet list according to mix
    packet_list = []
    for class_name, percentage in traffic_mix.items():
        count = max(1, int(num_packets * percentage / 100))
        tc = TRAFFIC_CLASSES[class_name]
        for _ in range(count):
            src_port = random.randint(*tc['src_port_range'])
            pkt = build_udp_packet(
                src_ip=tc['src_ip'],
                dst_ip=tc['dst_ip'],
                src_port=src_port,
                dst_port=tc['dst_port'],
                payload_size=tc['payload_size']
            )
            packet_list.append({
                'class': class_name,
                'bytes': pkt,
                'src_ip': tc['src_ip'],
                'dst_ip': tc['dst_ip'],
                'src_port': src_port,
                'dst_port': tc['dst_port'],
                'size': len(pkt)
            })

    # Shuffle to create realistic interleaved traffic
    random.shuffle(packet_list)

    # Write hex files
    data_lines = []
    keep_lines = []
    last_lines = []
    metadata = []

    for pkt_idx, pkt_info in enumerate(packet_list):
        beats = packet_to_beats(pkt_info['bytes'])
        pkt_meta = {
            'packet_id': pkt_idx,
            'class': pkt_info['class'],
            'src_ip': pkt_info['src_ip'],
            'dst_ip': pkt_info['dst_ip'],
            'src_port': pkt_info['src_port'],
            'dst_port': pkt_info['dst_port'],
            'size_bytes': pkt_info['size'],
            'num_beats': len(beats),
            'first_beat_index': len(data_lines)
        }
        metadata.append(pkt_meta)

        for data_hex, keep_hex, is_last in beats:
            data_lines.append(data_hex)
            keep_lines.append(keep_hex)
            last_lines.append('1' if is_last else '0')

    # Write files
    with open(os.path.join(output_dir, 'packets_data.hex'), 'w') as f:
        f.write('\n'.join(data_lines) + '\n')

    with open(os.path.join(output_dir, 'packets_keep.hex'), 'w') as f:
        f.write('\n'.join(keep_lines) + '\n')

    with open(os.path.join(output_dir, 'packets_last.hex'), 'w') as f:
        f.write('\n'.join(last_lines) + '\n')

    with open(os.path.join(output_dir, 'packets_meta.json'), 'w') as f:
        json.dump({
            'total_packets': len(packet_list),
            'total_beats': len(data_lines),
            'traffic_mix': traffic_mix,
            'packets': metadata
        }, f, indent=2)

    print(f"Generated {len(packet_list)} packets ({len(data_lines)} beats)")
    print(f"Traffic mix: {traffic_mix}")
    for cls in TRAFFIC_CLASSES:
        count = sum(1 for p in metadata if p['class'] == cls)
        print(f"  {cls}: {count} packets")
    print(f"Output directory: {output_dir}")

    return metadata


# ============================================================================
# Main
# ============================================================================
if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='SmartNIC Test Packet Generator')
    parser.add_argument('--count', type=int, default=20,
                        help='Number of packets to generate (default: 20)')
    parser.add_argument('--output', type=str, default=None,
                        help='Output directory (default: ../sim/)')
    parser.add_argument('--mix', type=str, default='urllc=25,voice=25,embb=25,iot=25',
                        help='Traffic mix percentages (default: equal)')
    parser.add_argument('--seed', type=int, default=42,
                        help='Random seed for reproducibility')
    args = parser.parse_args()

    random.seed(args.seed)

    # Parse traffic mix
    mix = {}
    for item in args.mix.split(','):
        name, pct = item.split('=')
        mix[name.strip()] = int(pct.strip())

    output_dir = args.output or os.path.join(os.path.dirname(__file__), '..', 'sim')
    generate_test_packets(output_dir, num_packets=args.count, traffic_mix=mix)
