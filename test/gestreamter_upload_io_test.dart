import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:matrix/matrix.dart';
import 'package:matrix/matrix_api_lite/generated/api.dart';
import 'package:test/test.dart';
import 'package:vodozemac/vodozemac.dart' as vod;

Uint8List _zufall(int laenge, int saat) {
  final r = Random(saat);
  return Uint8List.fromList(List.generate(laenge, (_) => r.nextInt(256)));
}

Stream<List<int>> _stueckweise(Uint8List daten, int groesse) async* {
  for (var pos = 0; pos < daten.length; pos += groesse) {
    yield daten.sublist(pos, min(pos + groesse, daten.length));
  }
}

/// Liefert [laenge] Byte Fuellung in 64-KiB-Stuecken, ohne sie zu halten.
Stream<List<int>> _fuellung(int laenge) async* {
  const stueck = 64 * 1024;
  var rest = laenge;
  while (rest > 0) {
    final n = min(stueck, rest);
    yield Uint8List(n);
    rest -= n;
  }
}

/// Kleiner Medien-Server auf 127.0.0.1: nimmt den Koerper entgegen (oder
/// liest ihn bewusst NICHT) und antwortet wie ein Homeserver.
class _Server {
  _Server(this.server);
  final HttpServer server;
  final empfangen = BytesBuilder(copy: false);
  String? kopfTyp;
  String? dateiname;
  bool lesen = true;
  int antwortStatus = 200;
  String antwortKoerper = '{"content_uri":"mxc://s/abc"}';
  final verbunden = Completer<void>();

  static Future<_Server> starten() async {
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final self = _Server(s);
    s.listen((req) async {
      self.kopfTyp = req.headers.contentType?.toString();
      self.dateiname = req.uri.queryParameters['filename'];
      if (!self.verbunden.isCompleted) self.verbunden.complete();
      if (!self.lesen) return; // Koerper nie lesen: die Leitung „schlaeft"
      try {
        await for (final teil in req) {
          self.empfangen.add(teil);
        }
      } catch (_) {
        return; // Client hat abgebrochen
      }
      req.response.statusCode = self.antwortStatus;
      req.response.write(self.antwortKoerper);
      await req.response.close();
    });
    return self;
  }

  Api get api => Api(
    baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
    bearerToken: 'geheim',
  );

  Future<void> stoppen() => server.close(force: true);
}

void main() {
  setUpAll(() async {
    try {
      await vod.init(wasmPath: './pkg/', libraryPath: './rust/target/debug/');
    } catch (_) {}
  });

  group('gestreamtHochladen (dart:io, echter Socket)', () {
    late _Server server;
    setUp(() async => server = await _Server.starten());
    tearDown(() => server.stoppen());

    test(
      'unverschluesselt: Koerper, Typ, Name, Fortschritt bis zum Ende',
      () async {
        final klar = _zufall(5 * 1024 * 1024 + 11, 1);
        final meldungen = <int>[];
        final ergebnis = await gestreamtHochladen(
          server.api,
          oeffnen: () => _stueckweise(klar, 123456),
          laenge: klar.length,
          verschluesseln: false,
          filename: 'a.csv',
          contentType: 'text/csv',
          onProgress: (sent, total) {
            expect(total, klar.length);
            meldungen.add(sent);
          },
        );
        expect(ergebnis.mxc.toString(), 'mxc://s/abc');
        expect(ergebnis.verschluesselung, isNull);
        expect(server.empfangen.toBytes(), klar);
        expect(server.kopfTyp, 'text/csv');
        expect(server.dateiname, 'a.csv');
        expect(meldungen.first, 0);
        expect(meldungen.last, klar.length);
        for (var i = 1; i < meldungen.length; i++) {
          expect(meldungen[i], greaterThanOrEqualTo(meldungen[i - 1]));
        }
      },
    );

    test('verschluesselt: Chiffrat kommt an, Temp-Ordner geraeumt', () async {
      final klar = _zufall(3 * 1024 * 1024 + 7, 2);
      final vorher = Directory.systemTemp
          .listSync()
          .where((e) => e.path.contains('ae-upload-'))
          .length;
      final ergebnis = await gestreamtHochladen(
        server.api,
        oeffnen: () => _stueckweise(klar, 65536),
        laenge: klar.length,
        verschluesseln: true,
        filename: 'Fallbestand.csv',
        contentType: 'text/csv',
      );
      expect(server.kopfTyp, 'application/octet-stream');
      expect(server.dateiname, 'crypt');
      final meta = ergebnis.verschluesselung!;
      final zurueck = await decryptFileImplementation(
        EncryptedFile(
          data: server.empfangen.toBytes(),
          k: meta.k,
          iv: meta.iv,
          sha256: meta.sha256,
        ),
      );
      expect(zurueck, klar);
      final nachher = Directory.systemTemp
          .listSync()
          .where((e) => e.path.contains('ae-upload-'))
          .length;
      expect(nachher, vorher);
    });

    test(
      'Stille: Server liest nicht → UploadStille, Zaehler rennt nicht voraus',
      () async {
        server.lesen = false;
        const laenge = 96 * 1024 * 1024;
        var letzter = 0;
        final uhr = Stopwatch()..start();
        await expectLater(
          gestreamtHochladen(
            server.api,
            oeffnen: () => _fuellung(laenge),
            laenge: laenge,
            verschluesseln: false,
            contentType: 'application/octet-stream',
            onProgress: (sent, total) => letzter = sent,
            stille: const Duration(seconds: 2),
          ),
          throwsA(
            isA<UploadStille>().having((e) => e.stille.inSeconds, 'stille', 2),
          ),
        );
        uhr.stop();
        // Die Grenze ist Stille, nicht Gesamtdauer: nach ~2 s Schluss.
        expect(uhr.elapsed, lessThan(const Duration(seconds: 30)));
        // Der Fortschritt zaehlt angenommene Bytes — die Datei war NICHT
        // „fertig", obwohl sie in Sekunden von der Platte kaeme.
        expect(letzter, lessThan(laenge));
        expect(letzter, greaterThan(0));
      },
    );

    test(
      'Abbruch waehrend des Sendens: UploadAbgebrochen, Rest bleibt weg',
      () async {
        const laenge = 64 * 1024 * 1024;
        var gesendet = 0;
        await expectLater(
          gestreamtHochladen(
            server.api,
            oeffnen: () => _fuellung(laenge),
            laenge: laenge,
            verschluesseln: false,
            contentType: 'application/octet-stream',
            onProgress: (sent, total) => gesendet = sent,
            abgebrochen: () => gesendet >= 2 * 1024 * 1024,
          ),
          throwsA(isA<UploadAbgebrochen>()),
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(server.empfangen.length, lessThan(laenge));
      },
    );

    test('Fehlerantwort des Servers wird zur MatrixException', () async {
      server.antwortStatus = 413;
      server.antwortKoerper =
          '{"errcode":"M_TOO_LARGE","error":"Datei zu gross"}';
      await expectLater(
        gestreamtHochladen(
          server.api,
          oeffnen: () => _fuellung(100000),
          laenge: 100000,
          verschluesseln: false,
          contentType: 'application/octet-stream',
        ),
        throwsA(
          isA<MatrixException>().having(
            (e) => e.errcode,
            'errcode',
            'M_TOO_LARGE',
          ),
        ),
      );
    });

    test('UploadStille nennt Sekunden und Bytes im Text', () {
      const e = UploadStille(12500000, 314000000, Duration(seconds: 120));
      expect(e.toString(), contains('120 s'));
      expect(e.toString(), contains('12.5 von 314.0 MB'));
    });
  });
}
