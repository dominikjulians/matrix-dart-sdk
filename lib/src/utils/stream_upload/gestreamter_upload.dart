// SPDX-FileCopyrightText: 2026 Dominik Julian Wittkowski
//
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Gestreamter Datei-Upload — die Datei wird nie als Ganzes im Speicher
/// gehalten, auch nicht in verschluesselten Raeumen.
///
/// Anlass (15.09.2026): Eine 314-MB-CSV liess sich weder aus dem Browser noch
/// vom iPhone senden. `sendFileEvent` liest die Datei komplett ein, legt sie
/// in den Datenbank-Cache, verschluesselt sie als Kopie und uebergibt den
/// Puffer dem HTTP-Client — vier Kopien einer Datei, die auf Handy und im
/// Browser nicht viermal in den Speicher passt.
///
/// Zwei Wege, je Plattform ueber bedingten Import:
///   * dart:io (Handy, Mac, Windows, Linux): Chiffrat in eine temporaere
///     Datei, danach `uploadContentStream` von der Platte.
///   * Browser: Chiffrat-Stuecke werden zu einem `Blob` zusammengesetzt (der
///     Browser verwaltet den Speicher, nicht die Dart-Halde) und per
///     XMLHttpRequest mit Fortschritt gesendet.
library;

import '../../../matrix_api_lite/generated/api.dart';
import '../crypto/strom_verschluesselung.dart';
import 'gestreamter_upload_stub.dart'
    if (dart.library.io) 'gestreamter_upload_io.dart'
    if (dart.library.js_interop) 'gestreamter_upload_web.dart'
    as plattform;

export '../crypto/strom_verschluesselung.dart' show VerschluesselungsMeta;

/// Stille-Grenze des Dateiwegs: Laeuft so lange kein Byte hinaus, gilt die
/// Leitung als eingeschlafen ([UploadStille]). Bewusst KEINE Gesamtgrenze.
const Duration stilleGrenze = Duration(seconds: 120);

/// Ergebnis: die `mxc://`-Adresse und — in verschluesselten Raeumen — die
/// Werte fuer den `file`-Block des Ereignisses.
class GestreamterUploadErgebnis {
  const GestreamterUploadErgebnis({required this.mxc, this.verschluesselung});
  final Uri mxc;
  final VerschluesselungsMeta? verschluesselung;
}

/// Laedt einen Bytestrom bekannter Laenge hoch, optional vorher
/// verschluesselt (AES-256-CTR + SHA-256 wie [encryptFile]).
///
/// [oeffnen] muss den Klartext jedes Mal neu von vorn liefern (Wiederholung
/// nach Netzfehlern); [laenge] ist die Klartext-Laenge in Byte. [onProgress]
/// meldet gesendete Bytes des Uploads (nicht der Verschluesselung) — auf
/// dart:io erst, wenn das Betriebssystem das Stueck angenommen hat, im
/// Browser aus den Fortschrittsereignissen des XMLHttpRequest. [stille]
/// ist die einzige Zeitgrenze: so lange ohne gesendetes Byte → [UploadStille].
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
}) => plattform.gestreamtHochladen(
  api,
  oeffnen: oeffnen,
  laenge: laenge,
  verschluesseln: verschluesseln,
  filename: filename,
  contentType: contentType,
  onProgress: onProgress,
  abgebrochen: abgebrochen,
  stille: stille,
);
