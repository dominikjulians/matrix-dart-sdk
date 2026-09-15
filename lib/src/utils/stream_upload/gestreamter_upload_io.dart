// SPDX-FileCopyrightText: 2026 Dominik Julian Wittkowski
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../matrix_api_lite/generated/api.dart';
import '../../../matrix_api_lite/model/matrix_exception.dart';
import '../crypto/strom_verschluesselung.dart';
import 'gestreamter_upload.dart';

/// dart:io-Weg: Verschluesselung in eine temporaere Datei, Upload von dort.
/// Speicherbedarf bleibt bei einem Teilstueck (4 MiB) plus HTTP-Puffer.
///
/// Der Upload laeuft direkt ueber [HttpClient] (nicht ueber package:http):
///   * Jedes Stueck wird mit `flush()` an das Betriebssystem uebergeben,
///     bevor das naechste gelesen wird. Der Fortschritt zaehlt also wirklich
///     gesendete Bytes — nicht, wie schnell die Datei von der Platte kommt
///     (Kunde 15.09.2026: „329,7 MB von 329,7 MB" nach Sekunden, danach
///     minutenlang nur „Hochladen" ueber eine 7-Mbit-Leitung).
///   * Es gibt KEINE Gesamtzeitgrenze; nur [stille] ohne angenommenes Byte
///     beendet den Upload mit [UploadStille]. Der `FixedTimeoutHttpClient`
///     des SDK (35 s auf die Antwort) und `sendTimelineEventTimeout` greifen
///     hier nicht.
Future<GestreamterUploadErgebnis> gestreamtHochladen(
  Api api, {
  required Stream<List<int>> Function() oeffnen,
  required int laenge,
  required bool verschluesseln,
  String? filename,
  String? contentType,
  void Function(int sent, int total)? onProgress,
  bool Function()? abgebrochen,
  Duration stille = stilleGrenze,
}) async {
  if (!verschluesseln) {
    final mxc = await hochladenIo(
      api,
      oeffnen: oeffnen,
      laenge: laenge,
      filename: filename,
      contentType: contentType ?? 'application/octet-stream',
      onProgress: onProgress,
      abgebrochen: abgebrochen,
      stille: stille,
    );
    return GestreamterUploadErgebnis(mxc: mxc);
  }

  final ordner = await Directory.systemTemp.createTemp('ae-upload-');
  final ziel = File('${ordner.path}${Platform.pathSeparator}crypt');
  try {
    final strom = StromVerschluesselung();
    final senke = ziel.openWrite();
    try {
      await senke.addStream(
        strom.verschluesseln(_abbrechbar(oeffnen(), abgebrochen)),
      );
      await senke.flush();
    } catch (e) {
      // Ein Fehler im Strom schliesst die Senke bereits mit Fehler; das
      // zweite close() darf den ersten Grund nicht verdecken.
      try {
        await senke.close();
      } catch (_) {}
      rethrow;
    }
    await senke.close();
    final meta = strom.meta;
    final chiffratLaenge = await ziel.length();
    // Das Chiffrat ist genauso lang wie der Klartext (CTR-Modus) — eine
    // Abweichung hiesse: Schreiben unvollstaendig, nicht hochladen.
    if (chiffratLaenge != laenge) {
      throw StateError(
        'Chiffrat $chiffratLaenge Byte, Klartext $laenge Byte — Verschluesselung unvollstaendig',
      );
    }
    final mxc = await hochladenIo(
      api,
      oeffnen: ziel.openRead,
      laenge: chiffratLaenge,
      filename: 'crypt',
      contentType: 'application/octet-stream',
      onProgress: onProgress,
      abgebrochen: abgebrochen,
      stille: stille,
    );
    return GestreamterUploadErgebnis(mxc: mxc, verschluesselung: meta);
  } finally {
    try {
      await ordner.delete(recursive: true);
    } catch (_) {
      // Ein Rest im Temp-Ordner ist aergerlich, aber kein Fehler des Uploads.
    }
  }
}

/// Wartezeit fuer den Verbindungsaufbau (Kopfzeilen sind noch nicht
/// unterwegs — hier ist eine feste Grenze richtig).
const Duration _verbindungsAufbau = Duration(seconds: 35);

/// Abstand, in dem waehrend eines wartenden `flush()` Abbruch und Stille
/// geprueft werden.
const Duration _pruefTakt = Duration(seconds: 1);

/// Laedt einen Bytestrom bekannter Laenge per `POST /_matrix/media/v3/upload`
/// hoch. Oeffentlich nur fuer Tests und Sonderfaelle; der normale Weg ist
/// [gestreamtHochladen].
Future<Uri> hochladenIo(
  Api api, {
  required Stream<List<int>> Function() oeffnen,
  required int laenge,
  required String contentType,
  String? filename,
  void Function(int sent, int total)? onProgress,
  bool Function()? abgebrochen,
  Duration stille = stilleGrenze,
  HttpClient? httpClient,
}) async {
  final ziel = api.resolveApiUri(
    Uri(
      path: '_matrix/media/v3/upload',
      queryParameters: {'filename': ?filename},
    ),
  );
  final client = httpClient ?? HttpClient();
  final eigenerClient = httpClient == null;
  try {
    if (abgebrochen?.call() == true) throw const UploadAbgebrochen();
    final anfrage = await client.postUrl(ziel).timeout(_verbindungsAufbau);
    anfrage.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${api.bearerToken!}',
    );
    anfrage.headers.set(HttpHeaders.contentTypeHeader, contentType);
    anfrage.contentLength = laenge;
    anfrage.persistentConnection = false;

    var gesendet = 0;
    onProgress?.call(0, laenge);
    try {
      await for (final stueck in oeffnen()) {
        if (abgebrochen?.call() == true) throw const UploadAbgebrochen();
        anfrage.add(stueck);
        await _flushMitWache(
          anfrage,
          gesendet: gesendet,
          gesamt: laenge,
          abgebrochen: abgebrochen,
          stille: stille,
        );
        gesendet += stueck.length;
        onProgress?.call(gesendet, laenge);
      }
    } catch (e) {
      anfrage.abort(e);
      rethrow;
    }

    // Kopfzeilen der Antwort: Der Server hat alles, darf aber noch pruefen
    // (Hash, Speicher). Auch hier nur die Stille-Grenze.
    final HttpClientResponse antwort;
    try {
      antwort = await anfrage.close().timeout(stille);
    } on TimeoutException {
      anfrage.abort();
      throw UploadStille(gesendet, laenge, stille);
    }
    final koerper = await antwort
        .transform(utf8.decoder)
        .join()
        .timeout(stille, onTimeout: () => '');
    if (antwort.statusCode != 200) {
      try {
        throw MatrixException.fromJson(
          (jsonDecode(koerper) as Map).cast<String, Object?>(),
        );
      } on MatrixException {
        rethrow;
      } catch (_) {
        throw Exception('http error response (${antwort.statusCode})');
      }
    }
    final json = jsonDecode(koerper);
    final uri = json is Map ? json['content_uri'] : null;
    if (uri is String && uri.startsWith('mxc://')) return Uri.parse(uri);
    throw Exception('Antwort ohne mxc-Adresse: $koerper');
  } finally {
    if (eigenerClient) client.close();
  }
}

/// Wartet, bis das Betriebssystem alle gepufferten Bytes angenommen hat.
/// Prueft dabei im Takt, ob der Aufrufer abgebrochen hat oder die Leitung
/// [stille] lang nichts angenommen hat.
Future<void> _flushMitWache(
  HttpClientRequest anfrage, {
  required int gesendet,
  required int gesamt,
  required bool Function()? abgebrochen,
  required Duration stille,
}) async {
  final fertig = anfrage.flush();
  final beginn = DateTime.now();
  while (true) {
    try {
      await fertig.timeout(_pruefTakt);
      return;
    } on TimeoutException {
      if (abgebrochen?.call() == true) throw const UploadAbgebrochen();
      if (DateTime.now().difference(beginn) >= stille) {
        throw UploadStille(gesendet, gesamt, stille);
      }
    }
  }
}

/// Bricht den Klartext-Strom ab, sobald der Aufrufer es verlangt — auch die
/// Verschluesselung in die Temp-Datei soll nicht bis zum Ende laufen.
Stream<List<int>> _abbrechbar(
  Stream<List<int>> quelle,
  bool Function()? abgebrochen,
) async* {
  await for (final teil in quelle) {
    if (abgebrochen?.call() == true) throw const UploadAbgebrochen();
    yield teil;
  }
}
