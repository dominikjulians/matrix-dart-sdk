// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Beweis fuer den Byte-Fortschritt beim Upload: ProgressUploadRequest streamt
// den Koerper unveraendert in Bloecken und meldet monoton steigenden
// Fortschritt, der bei total/total endet.

import 'dart:typed_data';

import 'package:http/http.dart';
import 'package:test/test.dart';

import 'package:matrix/matrix_api_lite/generated/api.dart';

void main() {
  test('ProgressUploadRequest streamt den Koerper und meldet vollen '
      'Fortschritt', () async {
    final total = (64 * 1024 * 3) + 123; // drei volle 64-KB-Bloecke + Rest
    final body = Uint8List.fromList(List<int>.generate(total, (i) => i % 256));
    final meldungen = <List<int>>[];

    final req = ProgressUploadRequest(
      'POST',
      Uri.parse('https://example.invalid/_matrix/media/v3/upload'),
      body,
      onProgress: (sent, t) => meldungen.add([sent, t]),
    );

    expect(req.contentLength, total);

    final gesammelt = await req.finalize().toBytes();

    // Der Koerper geht unveraendert durch.
    expect(gesammelt, equals(body));

    // Erste Meldung 0/total (Zeile erscheint sofort), letzte total/total.
    expect(meldungen.first, [0, total]);
    expect(meldungen.last, [total, total]);

    // Monoton steigend, Gesamtwert immer korrekt.
    for (var i = 1; i < meldungen.length; i++) {
      expect(meldungen[i][0] >= meldungen[i - 1][0], isTrue);
      expect(meldungen[i][1], total);
    }
    // Mehr als eine Meldung -> es wurde wirklich in Bloecken gestreamt.
    expect(meldungen.length, greaterThan(2));
  });

  test('ProgressUploadRequest ohne Rueckruf funktioniert weiter', () async {
    final body = Uint8List.fromList([1, 2, 3, 4, 5]);
    final req = ProgressUploadRequest(
      'POST',
      Uri.parse('https://example.invalid/upload'),
      body,
    );
    final gesammelt = await req.finalize().toBytes();
    expect(gesammelt, equals(body));
  });
}
