// SPDX-FileCopyrightText: 2019-Present Famedly GmbH
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:async';
import 'package:matrix/src/database/sqflite_box.dart'
    if (dart.library.js_interop) 'package:matrix/src/database/indexeddb_box.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';

void main() {
  group('Box tests', () {
    late BoxCollection collection;
    const boxNames = <String>{'cats', 'dogs'};
    const data = {'name': 'Fluffy', 'age': 2};
    const data2 = {'name': 'Loki', 'age': 4};
    Database? db;
    const isWeb = bool.fromEnvironment('dart.library.js_interop');
    setUp(() async {
      if (!isWeb) {
        db = await databaseFactoryFfi.openDatabase(':memory:');
      }
      collection = await BoxCollection.open(
        'testbox',
        boxNames,
        sqfliteDatabase: db,
        sqfliteFactory: isWeb ? null : databaseFactoryFfi,
      );
    });

    test('Box.put and Box.get', () async {
      final box = collection.openBox<Map>('cats');
      await box.put('fluffy', data);
      expect(await box.get('fluffy'), data);
      await box.clear();
    });

    test('Box.getAll', () async {
      final box = collection.openBox<Map>('cats');
      await box.put('fluffy', data);
      await box.put('loki', data2);
      expect(await box.getAll(['fluffy', 'loki']), [data, data2]);
      await box.clear();
    });

    test('Box.getAllKeys', () async {
      final box = collection.openBox<Map>('cats');
      await box.put('fluffy', data);
      await box.put('loki', data2);
      expect(await box.getAllKeys(), ['fluffy', 'loki']);
      await box.clear();
    });

    test('Box.getAllValues', () async {
      final box = collection.openBox<Map>('cats');
      await box.put('fluffy', data);
      await box.put('loki', data2);
      expect(await box.getAllValues(), {'fluffy': data, 'loki': data2});
      await box.clear();
    });

    test('Box.delete', () async {
      final box = collection.openBox<Map>('cats');
      await box.put('fluffy', data);
      await box.put('loki', data2);
      await box.delete('fluffy');
      expect(await box.get('fluffy'), null);
      await box.clear();
    });

    test('Box.delete in transaction', () async {
      final box = collection.openBox<Map>('cats');
      await box.put('fluffy', data);
      await box.put('loki', data2);
      await collection.transaction(() async {
        await box.delete('fluffy');
        expect(await box.get('fluffy'), null);
      });
      expect(await box.get('fluffy'), null);
      await box.clear();
    });

    test('Box.deleteAll', () async {
      final box = collection.openBox<Map>('cats');
      await box.put('fluffy', data);
      await box.put('loki', data2);
      await box.deleteAll(['fluffy', 'loki']);
      expect(await box.get('fluffy'), null);
      expect(await box.get('loki'), null);
      await box.clear();
    });

    test('Box.clear', () async {
      final box = collection.openBox<Map>('cats');
      await box.put('fluffy', data);
      await box.put('loki', data2);
      await box.clear();
      expect(await box.get('fluffy'), null);
      expect(await box.get('loki'), null);
    });

    test('Box.close', () async {
      await collection.close();
    });

    test('Collection.deleteDatabase', () async {
      await collection.deleteDatabase(
        db?.path ?? '',
        isWeb ? null : databaseFactoryFfi,
      );
    });

    // 05.09.2026 (Agent Ecosystem): Wartetor — Zugriffe waehrend des Schlafens
    // warten bis aufwachen(), statt mit database_closed zu scheitern.
    test('schlafen: Zugriff wartet bis aufwachen', () async {
      if (isWeb) return;
      final box = collection.openBox<Map>('cats');
      await box.put('fluffy', data);
      await collection.schlafen();
      expect(collection.schlaeft, isTrue);
      expect(collection.istOffen, isFalse);
      var fertig = false;
      // getAllKeys geht immer an die Datenbank (get koennte aus dem Box-Cache kommen).
      final wartend = box.getAllKeys().then((v) {
        fertig = true;
        return v;
      });
      await Future.delayed(const Duration(milliseconds: 50));
      expect(fertig, isFalse, reason: 'darf nicht gegen die geschlossene DB laufen');
      final neu = await databaseFactoryFfi.openDatabase(':memory:');
      await BoxCollection.open('testbox', boxNames, sqfliteDatabase: neu,
          sqfliteFactory: databaseFactoryFfi);
      collection.aufwachen(neu);
      await wartend;
      expect(fertig, isTrue);
      expect(collection.istOffen, isTrue);
      await box.put('loki', data2);
      expect(await box.get('loki'), data2);
    });

    test('close waehrend des Schlafens: Wartende bekommen einen Fehler', () async {
      if (isWeb) return;
      final box = collection.openBox<Map>('cats');
      await collection.schlafen();
      final wartend = box.getAllKeys();
      final erwartung = expectLater(wartend, throwsA(isA<StateError>()));
      await collection.close();
      await erwartung;
    });

    test('schlafen mit wiederoeffnen: Zugriff oeffnet die Verbindung selbst', () async {
      if (isWeb) return;
      final box = collection.openBox<Map>('cats');
      await box.put('fluffy', data);
      var aufrufe = 0;
      collection.wiederoeffnen = () async {
        aufrufe++;
        final neu = await databaseFactoryFfi.openDatabase(':memory:');
        await BoxCollection.open('testbox', boxNames, sqfliteDatabase: neu,
            sqfliteFactory: databaseFactoryFfi);
        return neu;
      };
      await collection.schlafen();
      // Zwei gleichzeitige Zugriffe — nur EIN Wiederoeffnen.
      final a = box.getAllKeys();
      final b = box.getAllValues();
      await Future.wait([a, b]);
      expect(aufrufe, 1);
      expect(collection.istOffen, isTrue);
      await box.put('loki', data2);
      expect(await box.get('loki'), data2);
    });

    test('schlafen im Hintergrund: Zugriff wartet, wiederoeffnen bleibt aus', () async {
      if (isWeb) return;
      final box = collection.openBox<Map>('cats');
      await box.put('fluffy', data);
      var aufrufe = 0;
      collection.wiederoeffnen = () async {
        aufrufe++;
        final neu = await databaseFactoryFfi.openDatabase(':memory:');
        await BoxCollection.open('testbox', boxNames, sqfliteDatabase: neu,
            sqfliteFactory: databaseFactoryFfi);
        return neu;
      };
      collection.imHintergrund = true;
      await collection.schlafen();
      var fertig = false;
      final zugriff = box.getAllKeys().then((k) {
        fertig = true;
        return k;
      });
      await Future.delayed(const Duration(milliseconds: 200));
      // Im Hintergrund: kein Wiederoeffnen, der Zugriff wartet am Tor.
      expect(aufrufe, 0);
      expect(fertig, isFalse);
      expect(collection.istOffen, isFalse);
      // Zurueck im Vordergrund oeffnet die App die Verbindung selbst.
      collection.imHintergrund = false;
      final neu = await databaseFactoryFfi.openDatabase(':memory:');
      await BoxCollection.open('testbox', boxNames, sqfliteDatabase: neu,
          sqfliteFactory: databaseFactoryFfi);
      collection.aufwachen(neu);
      await zugriff;
      expect(fertig, isTrue);
      expect(aufrufe, 0);
    });

    test('schlafen mit scheiterndem wiederoeffnen: Fehler statt ewig warten', () async {
      if (isWeb) return;
      final box = collection.openBox<Map>('cats');
      collection.wiederoeffnen = () async => throw Exception('Schluessel nicht lesbar');
      await collection.schlafen();
      // Kurze Wartezeit fuer den Test.
      final wartend = box.getAllKeys().timeout(const Duration(seconds: 3), onTimeout: () => throw TimeoutException('x'));
      await expectLater(wartend, throwsA(anything));
    });
  });
}
