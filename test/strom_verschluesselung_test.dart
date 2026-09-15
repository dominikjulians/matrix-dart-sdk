import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:vodozemac/vodozemac.dart' as vod;

import 'package:matrix/matrix.dart';
import 'package:matrix/matrix_api_lite/generated/api.dart';

Uint8List _zufall(int laenge, int saat) {
  final r = Random(saat);
  return Uint8List.fromList(List.generate(laenge, (_) => r.nextInt(256)));
}

/// Klartext in unregelmaessigen Stuecken liefern — so wie ein Dateisystem
/// oder ein Blob es tut, nie an Blockgrenzen ausgerichtet.
Stream<List<int>> _stueckweise(Uint8List daten, List<int> groessen) async* {
  var pos = 0;
  var i = 0;
  while (pos < daten.length) {
    final n = min(groessen[i % groessen.length], daten.length - pos);
    yield daten.sublist(pos, pos + n);
    pos += n;
    i++;
  }
}

void main() {
  setUpAll(() async {
    try {
      await vod.init(wasmPath: './pkg/', libraryPath: './rust/target/debug/');
    } catch (_) {
      // Die native Bibliothek kommt sonst ueber die Build-Hooks.
    }
  });

  group('StromVerschluesselung', () {
    test('ivBei zaehlt Big-Endian ueber die volle Breite mit Uebertrag', () {
      final iv = Uint8List.fromList([
        0, 0, 0, 0, 0, 0, 0, 0, //
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe,
      ]);
      expect(StromVerschluesselung.ivBei(iv, 0), iv);
      expect(StromVerschluesselung.ivBei(iv, 1).last, 0xff);
      final umgeschlagen = StromVerschluesselung.ivBei(iv, 2);
      expect(umgeschlagen.sublist(8), List.filled(8, 0));
      expect(umgeschlagen[7], 1);
    });

    for (final laenge in [0, 1, 15, 16, 17, 4096, 4 * 1024 * 1024 + 5, 9 * 1024 * 1024 + 123]) {
      test('gestreamt == Einmal-Verschluesselung bei $laenge Byte', () async {
        final klar = _zufall(laenge, laenge + 7);
        final key = _zufall(32, 1);
        final iv = _zufall(16, 2);
        final erwartet = vod.CryptoUtils.aesCtr(input: klar, key: key, iv: iv);
        final erwarteterHash = base64
            .encode(vod.CryptoUtils.sha256(input: erwartet))
            .replaceAll('=', '');

        final strom = StromVerschluesselung(key: key, iv: iv);
        final teile = <int>[];
        await for (final t in strom.verschluesseln(
          _stueckweise(klar, [1000, 65536, 3, 1024 * 1024 + 1, 7]),
        )) {
          teile.addAll(t);
        }
        expect(teile, erwartet, reason: 'Chiffrat weicht ab');
        expect(strom.meta.sha256, erwarteterHash);
        expect(strom.meta.k, base64Url.encode(key).replaceAll('=', ''));
        expect(strom.meta.iv, base64.encode(iv).replaceAll('=', ''));

        // Und der Weg zurueck: mit den Meta-Werten entschluesselt der
        // bestehende In-Memory-Weg den Klartext.
        final zurueck = await decryptFileImplementation(
          EncryptedFile(
            data: Uint8List.fromList(teile),
            k: strom.meta.k,
            iv: strom.meta.iv,
            sha256: strom.meta.sha256,
          ),
        );
        expect(zurueck, klar);
      });
    }

    test('meta vor dem Ende wirft', () {
      final strom = StromVerschluesselung();
      expect(() => strom.meta, throwsStateError);
    });
  });

  group('gestreamtHochladen (dart:io)', () {
    test('verschluesselt in Temp-Datei, laedt mit Fortschritt, raeumt auf',
        () async {
      final klar = _zufall(5 * 1024 * 1024 + 11, 42);
      Uint8List? empfangen;
      String? kopfTyp;
      final api = Api(
        httpClient: MockClient.streaming((request, bodyStream) async {
          empfangen = await bodyStream.toBytes();
          kopfTyp = request.headers['content-type'];
          expect(request.url.path, '/_matrix/media/v3/upload');
          expect(request.url.queryParameters['filename'], 'crypt');
          return http.StreamedResponse(
            Stream.value(utf8.encode('{"content_uri":"mxc://s/abc"}')),
            200,
          );
        }),
        baseUri: Uri.parse('https://example.org'),
        bearerToken: 'geheim',
      );
      final meldungen = <int>[];
      final ergebnis = await gestreamtHochladen(
        api,
        oeffnen: () => _stueckweise(klar, [123456, 1024 * 1024]),
        laenge: klar.length,
        verschluesseln: true,
        filename: 'Fallbestand.csv',
        contentType: 'text/csv',
        onProgress: (sent, total) => meldungen.add(sent),
      );
      expect(ergebnis.mxc.toString(), 'mxc://s/abc');
      expect(kopfTyp, 'application/octet-stream');
      expect(empfangen!.length, klar.length);
      expect(meldungen.last, klar.length);
      final meta = ergebnis.verschluesselung!;
      final zurueck = await decryptFileImplementation(
        EncryptedFile(
          data: empfangen!,
          k: meta.k,
          iv: meta.iv,
          sha256: meta.sha256,
        ),
      );
      expect(zurueck, klar);
    });

    test('unverschluesselt: Klartext mit eigenem Typ und Namen', () async {
      final klar = _zufall(70000, 9);
      Uint8List? empfangen;
      final api = Api(
        httpClient: MockClient.streaming((request, bodyStream) async {
          empfangen = await bodyStream.toBytes();
          expect(request.headers['content-type'], 'text/csv');
          expect(request.url.queryParameters['filename'], 'a.csv');
          return http.StreamedResponse(
            Stream.value(utf8.encode('{"content_uri":"mxc://s/klar"}')),
            200,
          );
        }),
        baseUri: Uri.parse('https://example.org'),
        bearerToken: 'geheim',
      );
      final ergebnis = await gestreamtHochladen(
        api,
        oeffnen: () => _stueckweise(klar, [4096]),
        laenge: klar.length,
        verschluesseln: false,
        filename: 'a.csv',
        contentType: 'text/csv',
      );
      expect(ergebnis.verschluesselung, isNull);
      expect(empfangen, klar);
    });
  });
}
