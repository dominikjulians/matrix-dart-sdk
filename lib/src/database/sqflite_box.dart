// SPDX-FileCopyrightText: 2019-Present Famedly GmbH
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'dart:convert';

import 'package:sqflite_common/sqflite.dart';

import '../../matrix.dart';
import 'zone_transaction_mixin.dart';

/// Key-Value store abstraction over Sqflite so that the sdk database can use
/// a single interface for all platforms. API is inspired by Hive.
class BoxCollection with ZoneTransactionMixin {
  // 04.09.2026 (Agent Ecosystem, iOS 0xdead10cc): nicht mehr final, damit die
  // Datenbank fuer den Hintergrund geschlossen und beim Zurueckkehren durch
  // eine frisch geoeffnete Verbindung ersetzt werden kann (schlafen/aufwachen).
  Database _db;

  // 05.09.2026 (Agent Ecosystem): Wartetor fuer den Hintergrund. Solange die
  // Verbindung schlaeft, warten alle Zugriffe hier, statt gegen die
  // geschlossene Datenbank zu laufen (DatabaseException database_closed in
  // Room.getTimeline, gesehen in Bau 3693). [aufwachen] oeffnet das Tor,
  // [close] laesst Wartende mit einem klaren Fehler los.
  Completer<void>? _schlaf;

  /// Selbstheilung (05./06.09.2026): Die App hinterlegt hier, wie die
  /// Verbindung neu zu oeffnen ist (gleiche Datei, gleicher Schluessel).
  /// Trifft ein Zugriff auf das geschlossene Tor, wird NICHT passiv gewartet,
  /// sondern die Verbindung sofort wieder geoeffnet — sonst haengt die App
  /// in einem Zustand fest, in dem jeder Chat „database_closed" zeigt, wenn
  /// das Wiederoeffnen beim Zurueckkehren einmal scheiterte.
  Future<Database> Function()? wiederoeffnen;
  Future<void>? _wiederoeffnenLaeuft;

  static const wartezeitTor = Duration(seconds: 20);

  Future<Database> get _bereit async {
    final tor = _schlaf;
    if (tor == null) return _db;
    final oeffnen = wiederoeffnen;
    if (oeffnen != null) {
      _wiederoeffnenLaeuft ??= () async {
        final uhr = Stopwatch()..start();
        try {
          aufwachen(await oeffnen());
          Logs().i(
            '[Hintergrund] Datenbank beim Zugriff selbst wieder geoeffnet '
            'in ${uhr.elapsedMilliseconds} ms',
          );
        } finally {
          _wiederoeffnenLaeuft = null;
        }
      }();
      try {
        await _wiederoeffnenLaeuft;
      } catch (e) {
        // Wiederoeffnen gescheitert: unten weiter warten, ein spaeterer
        // Zugriff versucht es erneut.
        Logs().w('[Hintergrund] Datenbank nicht selbst wieder geoeffnet', e);
      }
      if (_schlaf == null) return _db;
    }
    await tor.future.timeout(
      wartezeitTor,
      onTimeout: () => throw StateError(
        'Die Datenbank konnte nach dem Hintergrund nicht wieder geoeffnet '
        'werden. Bitte die App einmal schliessen und neu starten.',
      ),
    );
    return _db;
  }

  final Set<String> boxNames;
  final String name;

  BoxCollection(this._db, this.boxNames, this.name);

  static Future<BoxCollection> open(
    String name,
    Set<String> boxNames, {
    Object? sqfliteDatabase,
    DatabaseFactory? sqfliteFactory,
    dynamic idbFactory,
    int version = 1,
  }) async {
    if (sqfliteDatabase is! Database) {
      throw ('You must provide a Database `sqfliteDatabase` for use on native.');
    }
    final batch = sqfliteDatabase.batch();
    for (final name in boxNames) {
      batch.execute(
        'CREATE TABLE IF NOT EXISTS $name (k TEXT PRIMARY KEY NOT NULL, v TEXT)',
      );
      batch.execute('CREATE INDEX IF NOT EXISTS k_index ON $name (k)');
    }
    await batch.commit(noResult: true);
    return BoxCollection(sqfliteDatabase, boxNames, name);
  }

  Box<V> openBox<V>(String name) {
    if (!boxNames.contains(name)) {
      throw ('Box with name $name is not in the known box names of this collection.');
    }
    return Box<V>(name, this);
  }

  Batch? _activeBatch;

  Future<void> transaction(
    Future<void> Function() action, {
    List<String>? boxNames,
    bool readOnly = false,
  }) => zoneTransaction(() async {
    final db = await _bereit;
    final batch = db.batch();
    _activeBatch = batch;
    await action();
    _activeBatch = null;
    await batch.commit(noResult: true);
  });

  Future<void> clear() => transaction(() async {
    final db = await _bereit;
    for (final name in boxNames) {
      await db.delete(name);
    }
  });

  Future<void> close() => zoneTransaction(() async {
    // Endgueltig zu: Wartende nicht ewig haengen lassen.
    final tor = _schlaf;
    if (tor != null && !tor.isCompleted) {
      tor.completeError(StateError('Datenbank wurde geschlossen'));
    }
    _schlaf = null;
    if (_db.isOpen) await _db.close();
  });

  /// Schliesst die SQLite-Verbindung fuer den Hintergrund (iOS: eine offene
  /// Verbindung auf eine Datei im geteilten App-Group-Container haelt beim
  /// Einfrieren eine Sperre, iOS beendet die App dann mit 0xdead10cc).
  /// Laufende Transaktionen werden abgewartet. Danach sind alle Zugriffe bis
  /// [aufwachen] Fehler — der Aufrufer sorgt dafuer, dass nichts mehr laeuft.
  Future<void> schlafen() {
    _schlaf ??= Completer<void>();
    return zoneTransaction(_db.close);
  }

  /// Setzt eine neu geoeffnete Verbindung auf dieselbe Datei ein. Die Boxen
  /// bleiben gueltig, sie greifen ueber diese Collection auf [_db] zu.
  void aufwachen(Database db) {
    _db = db;
    final tor = _schlaf;
    _schlaf = null;
    if (tor != null && !tor.isCompleted) tor.complete();
  }

  bool get istOffen => _schlaf == null && _db.isOpen;

  /// Fuer Tests: wartet gerade jemand am Tor?
  bool get schlaeft => _schlaf != null;

  @Deprecated('use collection.deleteDatabase now')
  static Future<void> delete(String path, [dynamic factory]) =>
      (factory ?? databaseFactory).deleteDatabase(path);

  Future<void> deleteDatabase(String path, [dynamic factory]) async {
    await close();
    await (factory ?? databaseFactory).deleteDatabase(path);
  }
}

class Box<V> {
  final String name;
  final BoxCollection boxCollection;
  final Map<String, V?> _quickAccessCache = {};

  /// _quickAccessCachedKeys is only used to make sure that if you fetch all keys from a
  /// box, you do not need to have an expensive read operation twice. There is
  /// no other usage for this at the moment. So the cache is never partial.
  /// Once the keys are cached, they need to be updated when changed in put and
  /// delete* so that the cache does not become outdated.
  Set<String>? _quickAccessCachedKeys;

  static const Set<Type> allowedValueTypes = {
    List<dynamic>,
    Map<dynamic, dynamic>,
    String,
    int,
    double,
    bool,
  };

  Box(this.name, this.boxCollection) {
    if (!allowedValueTypes.any((type) => V == type)) {
      throw Exception(
        'Illegal value type for Box: "$V". Must be one of $allowedValueTypes',
      );
    }
  }

  String? _toString(V? value) {
    if (value == null) return null;
    switch (V) {
      case const (List<dynamic>):
      case const (Map<dynamic, dynamic>):
        return jsonEncode(value);
      case const (String):
      case const (int):
      case const (double):
      case const (bool):
      default:
        return value.toString();
    }
  }

  V? _fromString(Object? value) {
    if (value == null) return null;
    if (value is! String) {
      throw Exception(
        'Wrong database type! Expected String but got one of type ${value.runtimeType}',
      );
    }
    switch (V) {
      case const (int):
        return int.parse(value) as V;
      case const (double):
        return double.parse(value) as V;
      case const (bool):
        return (value == 'true') as V;
      case const (List<dynamic>):
        return List.unmodifiable(jsonDecode(value)) as V;
      case const (Map<dynamic, dynamic>):
        return Map.unmodifiable(jsonDecode(value)) as V;
      case const (String):
      default:
        return value as V;
    }
  }

  Future<List<String>> getAllKeys([Transaction? txn]) async {
    if (_quickAccessCachedKeys != null) return _quickAccessCachedKeys!.toList();

    final executor = txn ?? await boxCollection._bereit;

    final result = await executor.query(name, columns: ['k']);
    final keys = result.map((row) => row['k'] as String).toList();

    _quickAccessCachedKeys = keys.toSet();
    return keys;
  }

  Future<Map<String, V>> getAllValues([Transaction? txn]) async {
    final executor = txn ?? await boxCollection._bereit;

    final result = await executor.query(name);
    return Map.fromEntries(
      result.map(
        (row) => MapEntry(row['k'] as String, _fromString(row['v']) as V),
      ),
    );
  }

  Future<V?> get(String key, [Transaction? txn]) async {
    if (_quickAccessCache.containsKey(key)) return _quickAccessCache[key];

    final executor = txn ?? await boxCollection._bereit;

    final result = await executor.query(
      name,
      columns: ['v'],
      where: 'k = ?',
      whereArgs: [key],
    );

    final value = result.isEmpty ? null : _fromString(result.single['v']);
    _quickAccessCache[key] = value;
    return value;
  }

  Future<List<V?>> getAll(List<String> keys, [Transaction? txn]) async {
    if (!keys.any((key) => !_quickAccessCache.containsKey(key))) {
      return keys.map((key) => _quickAccessCache[key]).toList();
    }

    // The SQL operation might fail with more than 1000 keys. We define some
    // buffer here and half the amount of keys recursively for this situation.
    const getAllMax = 800;
    if (keys.length > getAllMax) {
      final half = keys.length ~/ 2;
      return [
        ...(await getAll(keys.sublist(0, half))),
        ...(await getAll(keys.sublist(half))),
      ];
    }

    final executor = txn ?? await boxCollection._bereit;

    final list = <V?>[];

    final result = await executor.query(
      name,
      where: 'k IN (${keys.map((_) => '?').join(',')})',
      whereArgs: keys,
    );
    final resultMap = Map<String, V?>.fromEntries(
      result.map((row) => MapEntry(row['k'] as String, _fromString(row['v']))),
    );

    // We want to make sure that they values are returnd in the exact same
    // order than the given keys. That's why we do this instead of just return
    // `resultMap.values`.
    list.addAll(keys.map((key) => resultMap[key]));

    _quickAccessCache.addAll(resultMap);

    return list;
  }

  Future<void> put(String key, V val) async {
    final txn = boxCollection._activeBatch;

    final params = {'k': key, 'v': _toString(val)};
    if (txn == null) {
      await (await boxCollection._bereit).insert(
        name,
        params,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } else {
      txn.insert(name, params, conflictAlgorithm: ConflictAlgorithm.replace);
    }

    _quickAccessCache[key] = val;
    _quickAccessCachedKeys?.add(key);
    return;
  }

  Future<void> delete(String key, [Batch? txn]) async {
    txn ??= boxCollection._activeBatch;

    if (txn == null) {
      await (await boxCollection._bereit).delete(name, where: 'k = ?', whereArgs: [key]);
    } else {
      txn.delete(name, where: 'k = ?', whereArgs: [key]);
    }

    // Set to null instead remove() so that inside of transactions null is
    // returned.
    _quickAccessCache[key] = null;
    _quickAccessCachedKeys?.remove(key);
    return;
  }

  Future<void> deleteAll(List<String> keys, [Batch? txn]) async {
    txn ??= boxCollection._activeBatch;

    final placeholder = keys.map((_) => '?').join(',');
    if (txn == null) {
      await (await boxCollection._bereit).delete(
        name,
        where: 'k IN ($placeholder)',
        whereArgs: keys,
      );
    } else {
      txn.delete(name, where: 'k IN ($placeholder)', whereArgs: keys);
    }

    for (final key in keys) {
      _quickAccessCache[key] = null;
      _quickAccessCachedKeys?.removeAll(keys);
    }
    return;
  }

  void clearQuickAccessCache() {
    _quickAccessCache.clear();
    _quickAccessCachedKeys = null;
  }

  Future<void> clear([Batch? txn]) async {
    txn ??= boxCollection._activeBatch;

    if (txn == null) {
      await (await boxCollection._bereit).delete(name);
    } else {
      txn.delete(name);
    }

    clearQuickAccessCache();
  }
}
