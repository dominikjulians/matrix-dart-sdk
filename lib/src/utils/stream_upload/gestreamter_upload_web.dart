// SPDX-FileCopyrightText: 2026 Dominik Julian Wittkowski
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../../../matrix_api_lite/generated/api.dart';
import '../../../matrix_api_lite/model/matrix_exception.dart';
import '../crypto/strom_verschluesselung.dart';
import 'gestreamter_upload.dart';

/// Browser-Weg: Die (verschluesselten) Stuecke werden als JS-Arrays gesammelt
/// und zu EINEM Blob zusammengesetzt. Den Blob verwaltet der Browser
/// ausserhalb der Dart-Halde; XMLHttpRequest sendet ihn direkt von dort und
/// liefert echte Fortschrittsereignisse. Damit entfallen die Kopien, die
/// `package:http` im Browser braucht (Uint8List-Koerper im Speicher).
///
/// Warum kein `fetch` mit ReadableStream: Fortschritt beim Hochladen gibt es
/// dort nicht, und der Duplex-Modus haengt an HTTP/2 und Browserversion.
/// Der Kunde am 15.09.2026 sass auf Chrome 109 (Windows Server 2012 R2).
Future<GestreamterUploadErgebnis> gestreamtHochladen(
  Api api, {
  required Stream<List<int>> Function() oeffnen,
  required int laenge,
  required bool verschluesseln,
  String? filename,
  String? contentType,
  void Function(int sent, int total)? onProgress,
}) async {
  final teile = <JSAny>[];
  VerschluesselungsMeta? meta;
  if (verschluesseln) {
    final strom = StromVerschluesselung();
    await for (final stueck in strom.verschluesseln(oeffnen())) {
      teile.add(stueck.toJS);
    }
    meta = strom.meta;
  } else {
    await for (final stueck in oeffnen()) {
      teile.add(
        (stueck is Uint8List ? stueck : Uint8List.fromList(stueck)).toJS,
      );
    }
  }
  final typ = verschluesseln
      ? 'application/octet-stream'
      : (contentType ?? 'application/octet-stream');
  final blob = web.Blob(teile.toJS, web.BlobPropertyBag(type: typ));
  teile.clear();

  final requestUri = Uri(
    path: '_matrix/media/v3/upload',
    queryParameters: {'filename': verschluesseln ? 'crypt' : (filename ?? '')},
  );
  final ziel = api.resolveApiUri(requestUri);
  final antwort = await _xhrSenden(
    ziel,
    blob,
    bearer: api.bearerToken!,
    contentType: typ,
    onProgress: onProgress,
  );
  final mxc = _mxcAus(antwort);
  return GestreamterUploadErgebnis(mxc: mxc, verschluesselung: meta);
}

Uri _mxcAus(String koerper) {
  final json = jsonDecode(koerper);
  final uri = json['content_uri'];
  if (uri is String && uri.startsWith('mxc://')) return Uri.parse(uri);
  throw Exception('Antwort ohne mxc-Adresse: $koerper');
}

Future<String> _xhrSenden(
  Uri ziel,
  web.Blob blob, {
  required String bearer,
  required String contentType,
  void Function(int sent, int total)? onProgress,
}) {
  final fertig = Completer<String>();
  final xhr = web.XMLHttpRequest();
  xhr.open('POST', ziel.toString());
  xhr.setRequestHeader('authorization', 'Bearer $bearer');
  xhr.setRequestHeader('content-type', contentType);
  final gesamt = blob.size;
  onProgress?.call(0, gesamt);
  xhr.upload.onprogress = ((web.ProgressEvent e) {
    onProgress?.call(e.loaded, e.lengthComputable ? e.total : gesamt);
  }).toJS;
  xhr.onload = ((web.Event _) {
    final status = xhr.status;
    final text = xhr.responseText;
    if (status == 200) {
      onProgress?.call(gesamt, gesamt);
      fertig.complete(text);
      return;
    }
    Object fehler = Exception('http error response ($status)');
    try {
      fehler = MatrixException.fromJson(
        (jsonDecode(text) as Map).cast<String, Object?>(),
      );
    } catch (_) {}
    fertig.completeError(fehler);
  }).toJS;
  xhr.onerror = ((web.Event _) {
    fertig.completeError(
      Exception('Netzfehler beim Hochladen (Verbindung abgebrochen)'),
    );
  }).toJS;
  xhr.onabort = ((web.Event _) {
    fertig.completeError(Exception('Hochladen abgebrochen'));
  }).toJS;
  xhr.send(blob);
  return fertig.future;
}
