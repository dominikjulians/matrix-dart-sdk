import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:matrix/matrix_api_lite.dart';

void main() {
  test(
    'StreamUploadRequest streamt Bloecke unveraendert mit Fortschritt',
    () async {
      final daten = Uint8List.fromList(List.generate(300000, (i) => i % 251));
      final meldungen = <int>[];
      final req = StreamUploadRequest(
        'POST',
        Uri.parse('https://example.org/upload'),
        () => Stream.fromIterable([
          daten.sublist(0, 100000),
          daten.sublist(100000, 250000),
          daten.sublist(250000),
        ]),
        daten.length,
        onProgress: (sent, total) => meldungen.add(sent),
      );
      final koerper = await req.finalize().toBytes();
      expect(koerper, daten);
      expect(req.contentLength, daten.length);
      expect(meldungen.first, 0);
      expect(meldungen.last, daten.length);
      expect(meldungen, [0, 100000, 250000, 300000]);
    },
  );
}
