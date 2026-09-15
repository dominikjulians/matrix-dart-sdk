// SPDX-FileCopyrightText: 2026 Dominik Julian Wittkowski
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as krypto;
import 'package:vodozemac/vodozemac.dart';

import 'crypto.dart';

/// Ergebnis einer gestreamten Datei-Verschluesselung: dieselben drei Werte,
/// die der Matrix-Ereignisinhalt unter `file` braucht (`key.k`, `iv`,
/// `hashes.sha256`), ohne den Chiffrat-Puffer.
class VerschluesselungsMeta {
  const VerschluesselungsMeta({
    required this.k,
    required this.iv,
    required this.sha256,
  });

  /// Schluessel, base64url ohne Auffuellung (wie [EncryptedFile.k]).
  final String k;

  /// Initialisierungsvektor, base64 ohne Auffuellung (wie [EncryptedFile.iv]).
  final String iv;

  /// SHA-256 ueber das gesamte Chiffrat, base64 ohne Auffuellung.
  final String sha256;
}

/// Verschluesselt einen Bytestrom nach der Matrix-Spezifikation fuer Anhaenge
/// (AES-256-CTR, SHA-256 ueber das Chiffrat) — Block fuer Block, ohne die
/// Datei jemals ganz im Speicher zu halten.
///
/// Warum (15.09.2026): `encryptFileImplementation` verlangt ein `Uint8List`
/// der ganzen Datei und erzeugt davon eine ebenso grosse Kopie. Eine 314-MB-
/// CSV eines Kunden hat so den Browser und das iPhone ueberfordert, bevor
/// ein einziges Byte hochgeladen war. Hier laeuft dieselbe Mathematik in
/// Teilstuecken: Der Zaehler des CTR-Modus wird je Teilstueck um die Zahl der
/// verbrauchten 16-Byte-Bloecke weitergezaehlt, das Ergebnis ist Byte fuer
/// Byte identisch mit der Einmal-Verschluesselung (Test
/// `strom_verschluesselung_test.dart`).
///
/// Die Werte `k`, `iv` und `sha256` stehen nach dem Ende des Stroms in
/// [meta]; vorher wirft der Zugriff.
class StromVerschluesselung {
  StromVerschluesselung({Uint8List? key, Uint8List? iv})
    : _key = key ?? secureRandomBytes(32),
      _iv = iv ?? secureRandomBytes(16) {
    if (_key.length != 32) throw ArgumentError('Schluessel muss 32 Byte haben');
    if (_iv.length != 16) throw ArgumentError('IV muss 16 Byte haben');
  }

  /// Teilstuecke werden auf dieses Vielfache von 16 Byte gerundet, damit die
  /// Blockgrenzen des CTR-Modus stimmen. 4 MiB haelt den Speicher klein und
  /// die Zahl der Aufrufe in die native Bibliothek gering.
  static const int stueckGroesse = 4 * 1024 * 1024;

  final Uint8List _key;
  final Uint8List _iv;
  VerschluesselungsMeta? _meta;

  /// Steht nach vollstaendigem Durchlauf von [verschluesseln] bereit.
  VerschluesselungsMeta get meta {
    final m = _meta;
    if (m == null) {
      throw StateError('Der Strom ist noch nicht vollstaendig verschluesselt');
    }
    return m;
  }

  /// Gibt das Chiffrat als Strom zurueck; die Stuecke sind (bis auf das
  /// letzte) Vielfache von 16 Byte, damit sie ohne Umkopieren gesendet oder
  /// in eine Datei geschrieben werden koennen.
  Stream<Uint8List> verschluesseln(Stream<List<int>> klartext) async* {
    final hash = _HashSammler();
    var block = 0; // Zahl der bereits verarbeiteten 16-Byte-Bloecke
    final rest = BytesBuilder(copy: false);
    await for (final teil in klartext) {
      rest.add(teil);
      // Nur ganze Bloecke verarbeiten, der Ueberhang wartet auf das
      // naechste Teilstueck.
      while (rest.length >= stueckGroesse) {
        final puffer = rest.takeBytes();
        final ganze = puffer.length - (puffer.length % 16);
        final chiffre = _block(puffer.sublist(0, ganze), block);
        block += ganze ~/ 16;
        hash.add(chiffre);
        if (ganze < puffer.length) rest.add(puffer.sublist(ganze));
        yield chiffre;
      }
    }
    if (rest.length > 0) {
      final puffer = rest.takeBytes();
      final chiffre = _block(puffer, block);
      hash.add(chiffre);
      yield chiffre;
    }
    _meta = VerschluesselungsMeta(
      k: base64Url.encode(_key).replaceAll('=', ''),
      iv: base64.encode(_iv).replaceAll('=', ''),
      sha256: base64.encode(hash.abschliessen()).replaceAll('=', ''),
    );
  }

  Uint8List _block(Uint8List klar, int blockVersatz) => Uint8List.fromList(
    CryptoUtils.aesCtr(input: klar, key: _key, iv: ivBei(_iv, blockVersatz)),
  );

  /// Zaehler des CTR-Modus: Der 16-Byte-IV ist ein Big-Endian-Zaehler ueber
  /// die volle Breite (so rechnet auch vodozemac); fuer den Block
  /// [blockVersatz] wird dieser Wert addiert.
  static Uint8List ivBei(Uint8List iv, int blockVersatz) {
    final ergebnis = Uint8List.fromList(iv);
    var uebertrag = blockVersatz;
    for (var i = 15; i >= 0 && uebertrag > 0; i--) {
      final summe = ergebnis[i] + (uebertrag & 0xff);
      ergebnis[i] = summe & 0xff;
      uebertrag = (uebertrag >> 8) + (summe >> 8);
    }
    return ergebnis;
  }
}

/// SHA-256 haeppchenweise (package:crypto), damit der Hash mit dem Strom
/// mitwaechst statt am Ende ueber das ganze Chiffrat zu laufen.
class _HashSammler {
  _HashSammler() {
    _senke = krypto.sha256.startChunkedConversion(_ausgabe);
  }
  final _ausgabe = _DigestSenke();
  late final ByteConversionSink _senke;

  void add(List<int> daten) => _senke.add(daten);

  Uint8List abschliessen() {
    _senke.close();
    return Uint8List.fromList(_ausgabe.digest!.bytes);
  }
}

class _DigestSenke implements Sink<krypto.Digest> {
  krypto.Digest? digest;
  @override
  void add(krypto.Digest data) => digest = data;
  @override
  void close() {}
}
