/// Minimal ZIP writer using the `store` (uncompressed) method.
///
/// Comic pages are already JPEG/PNG/WebP, so re-compressing them would only
/// waste CPU on the device. This keeps the OPDS chapter download dependency
/// free: no `archive` package and no temporary files are required.
library;

import 'dart:convert';
import 'dart:typed_data';

class ZipEntry {
  const ZipEntry(this.name, this.bytes);

  final String name;
  final Uint8List bytes;
}

final Uint32List _crcTable = _buildCrcTable();

Uint32List _buildCrcTable() {
  final table = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    var value = i;
    for (var bit = 0; bit < 8; bit++) {
      value = (value & 1) != 0 ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
    }
    table[i] = value;
  }
  return table;
}

int crc32(Uint8List bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc = _crcTable[(crc ^ byte) & 0xff] ^ (crc >>> 8);
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}

void _put16(BytesBuilder out, int value) {
  out.add(Uint8List.fromList([value & 0xff, (value >> 8) & 0xff]));
}

void _put32(BytesBuilder out, int value) {
  out.add(
    Uint8List.fromList([
      value & 0xff,
      (value >> 8) & 0xff,
      (value >> 16) & 0xff,
      (value >> 24) & 0xff,
    ]),
  );
}

/// Build a ZIP archive in memory.
///
/// `utf8Flag` marks names as UTF-8 (bit 11), which every modern ZIP reader
/// understands. Fixed DOS timestamps keep the output deterministic.
Uint8List buildStoreZip(List<ZipEntry> entries) {
  final local = BytesBuilder(copy: false);
  final central = BytesBuilder(copy: false);
  var offset = 0;

  for (final entry in entries) {
    final name = utf8.encode(entry.name);
    final checksum = crc32(entry.bytes);
    final size = entry.bytes.length;

    _put32(local, 0x04034b50);
    _put16(local, 20); // version needed
    _put16(local, 0x0800); // UTF-8 names
    _put16(local, 0); // stored
    _put16(local, 0); // time
    _put16(local, 0x21); // date: 1980-01-01
    _put32(local, checksum);
    _put32(local, size);
    _put32(local, size);
    _put16(local, name.length);
    _put16(local, 0); // extra length
    local.add(name);
    local.add(entry.bytes);

    _put32(central, 0x02014b50);
    _put16(central, 20); // version made by
    _put16(central, 20); // version needed
    _put16(central, 0x0800);
    _put16(central, 0);
    _put16(central, 0);
    _put16(central, 0x21);
    _put32(central, checksum);
    _put32(central, size);
    _put32(central, size);
    _put16(central, name.length);
    _put16(central, 0); // extra
    _put16(central, 0); // comment
    _put16(central, 0); // disk start
    _put16(central, 0); // internal attrs
    _put32(central, 0); // external attrs
    _put32(central, offset);
    central.add(name);

    offset += 30 + name.length + size;
  }

  final centralBytes = central.takeBytes();
  final end = BytesBuilder(copy: false)
    ..add(_u32(0x06054b50))
    ..add(_u16(0))
    ..add(_u16(0))
    ..add(_u16(entries.length))
    ..add(_u16(entries.length))
    ..add(_u32(centralBytes.length))
    ..add(_u32(offset))
    ..add(_u16(0));

  final total = BytesBuilder(copy: false)
    ..add(local.takeBytes())
    ..add(centralBytes)
    ..add(end.takeBytes());
  return total.takeBytes();
}

Uint8List _u16(int value) =>
    Uint8List.fromList([value & 0xff, (value >> 8) & 0xff]);

Uint8List _u32(int value) => Uint8List.fromList([
  value & 0xff,
  (value >> 8) & 0xff,
  (value >> 16) & 0xff,
  (value >> 24) & 0xff,
]);
