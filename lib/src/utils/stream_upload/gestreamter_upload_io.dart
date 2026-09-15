// SPDX-FileCopyrightText: 2026 Dominik Julian Wittkowski
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:io';

import '../../../matrix_api_lite/generated/api.dart';
import '../crypto/strom_verschluesselung.dart';
import 'gestreamter_upload.dart';

/// dart:io-Weg: Verschluesselung in eine temporaere Datei, Upload von dort.
/// Speicherbedarf bleibt bei einem Teilstueck (4 MiB) plus HTTP-Puffer.
Future<GestreamterUploadErgebnis> gestreamtHochladen(
  Api api, {
  required Stream<List<int>> Function() oeffnen,
  required int laenge,
  required bool verschluesseln,
  String? filename,
  String? contentType,
  void Function(int sent, int total)? onProgress,
}) async {
  if (!verschluesseln) {
    final mxc = await api.uploadContentStream(
      oeffnen,
      laenge,
      filename: filename,
      contentType: contentType,
      onProgress: onProgress,
    );
    return GestreamterUploadErgebnis(mxc: mxc);
  }

  final ordner = await Directory.systemTemp.createTemp('ae-upload-');
  final ziel = File('${ordner.path}${Platform.pathSeparator}crypt');
  try {
    final strom = StromVerschluesselung();
    final senke = ziel.openWrite();
    try {
      await senke.addStream(strom.verschluesseln(oeffnen()));
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
    final mxc = await api.uploadContentStream(
      ziel.openRead,
      chiffratLaenge,
      filename: 'crypt',
      contentType: 'application/octet-stream',
      onProgress: onProgress,
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
