// SPDX-FileCopyrightText: 2026 Dominik Julian Wittkowski
//
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Fork 31.10.2026: Die lokale Datenbank wuchs auf allen Plattformen ohne Ende
// (Windows-Abzug 30.10.2026: 11,2 GB, davon 7,6 GB verwaiste Ereignisse;
// Mac 20 GB). Zwei Ursachen, zwei Prüfungen:
// 1. `deleteTimelineForRoom` (nach `limited`) ließ die Ereignisse liegen.
// 2. Räume ohne `limited` wuchsen unbegrenzt — jetzt [Client.zeitleisteGrenze].

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';

import 'package:matrix/matrix.dart';

import 'fake_client.dart';
import 'fake_database.dart';

const _raum = '!grenze:fakeServer.notExisting';

MatrixEvent _nachricht(String id, int i) => MatrixEvent(
  type: EventTypes.Message,
  content: {'msgtype': 'm.text', 'body': 'Nachricht $i'},
  senderId: '@agent:fakeServer.notExisting',
  eventId: id,
  originServerTs: DateTime.fromMillisecondsSinceEpoch(1790000000000 + i),
);

SyncUpdate _sync(
  List<MatrixEvent> events, {
  String? prevBatch,
  bool? limited,
  String nextBatch = 'n',
}) => SyncUpdate(
  nextBatch: nextBatch,
  rooms: RoomsUpdate(
    join: {
      _raum: JoinedRoomUpdate(
        timeline: TimelineUpdate(
          events: events,
          prevBatch: prevBatch,
          limited: limited,
        ),
      ),
    },
  ),
);

Future<int> _ereignisseImRaum(MatrixSdkDatabase db, String raum) async {
  var n = 0;
  await db.mitVerbindungExklusiv((v) async {
    final r = await v.rawQuery(
      "SELECT count(*) AS n FROM box_events WHERE k LIKE ? ESCAPE '\\'",
      ['${raum.replaceAll('_', r'\_')}|%'],
    );
    n = (r.first['n'] as num).toInt();
  });
  return n;
}

void main() {
  setUpAll(sqfliteFfiInit);

  group('deleteTimelineForRoom', () {
    test('löscht die Ereignisse der Zeitleiste mit, SENDING bleibt', () async {
      final db = await getMatrixSdkDatabase();
      final client = Client('grenze', database: db);
      final room = Room(id: _raum, client: client);
      for (var i = 0; i < 20; i++) {
        await db.storeEventUpdate(
          room.id,
          _nachricht('\$e$i', i),
          EventUpdateType.timeline,
          client,
        );
      }
      // Ein eigenes Ereignis, das noch gesendet wird (Liste SENDING).
      await db.storeEventUpdate(
        room.id,
        Event(
          type: EventTypes.Message,
          content: {'msgtype': 'm.text', 'body': 'unterwegs'},
          senderId: '@test:fakeServer.notExisting',
          eventId: 'txn1',
          originServerTs: DateTime.now(),
          room: room,
          status: EventStatus.sending,
        ),
        EventUpdateType.timeline,
        client,
      );
      // Ein anderer Raum bleibt unberührt.
      await db.storeEventUpdate(
        '!anders:fakeServer.notExisting',
        _nachricht('\$x', 0),
        EventUpdateType.timeline,
        client,
      );
      expect(await db.getTimelineEventCount(room.id), 20);
      expect(await _ereignisseImRaum(db, room.id), 21);

      await db.deleteTimelineForRoom(room.id);

      expect(await db.getTimelineEventCount(room.id), 0);
      expect(await _ereignisseImRaum(db, room.id), 1);
      expect(await db.getEventById('\$e3', room), isNull);
      final rest = await db.getEventList(room);
      expect(rest.map((e) => e.eventId), ['txn1']);
      expect(await _ereignisseImRaum(db, '!anders:fakeServer.notExisting'), 1);
      await db.close();
    });

    test('übergroße Altliste: höchstens loeschenHoechstens sofort, '
        'der Rest bleibt für das Räumen im Hintergrund', () async {
      final db = await getMatrixSdkDatabase();
      final client = Client('grenze', database: db);
      for (var i = 0; i < 8; i++) {
        await db.storeEventUpdate(
          _raum,
          _nachricht('\$e$i', i),
          EventUpdateType.timeline,
          client,
        );
      }
      final vorher = MatrixSdkDatabase.loeschenHoechstens;
      MatrixSdkDatabase.loeschenHoechstens = 3;
      try {
        await db.deleteTimelineForRoom(_raum);
      } finally {
        MatrixSdkDatabase.loeschenHoechstens = vorher;
      }
      expect(await db.getTimelineEventCount(_raum), 0);
      expect(await _ereignisseImRaum(db, _raum), 5);
      expect(await db.verwaisteEreignisseLoeschen(), 5);
      expect(await _ereignisseImRaum(db, _raum), 0);
      await db.close();
    });

    test('Altbestand: verwaisteEreignisseLoeschen räumt nur Waisen', () async {
      final roh = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      final vorher = await MatrixSdkDatabase.init(
        'grenze',
        database: roh,
        sqfliteFactory: databaseFactoryFfi,
      );
      final client = Client('grenze', database: vorher);
      for (var i = 0; i < 10; i++) {
        await vorher.storeEventUpdate(
          _raum,
          _nachricht('\$alt$i', i),
          EventUpdateType.timeline,
          client,
        );
      }
      // Waisen wie vor dem Fix: nur die Liste geht verloren.
      await roh.delete('box_timeline_fragments');
      // Frische Instanz auf derselben Verbindung (ohne Zwischenspeicher).
      final db = await MatrixSdkDatabase.init(
        'grenze',
        database: roh,
        sqfliteFactory: databaseFactoryFfi,
      );
      final room = Room(id: _raum, client: client);
      for (var i = 0; i < 3; i++) {
        await db.storeEventUpdate(
          room.id,
          _nachricht('\$neu$i', 100 + i),
          EventUpdateType.timeline,
          client,
        );
      }
      expect(await _ereignisseImRaum(db, room.id), 13);
      expect(await db.verwaisteEreignisseLoeschen(), 10);
      expect(await _ereignisseImRaum(db, room.id), 3);
      final liste = await db.getEventList(room);
      expect(liste.map((e) => e.eventId), ['\$neu2', '\$neu1', '\$neu0']);
      await db.close();
    });
  });

  group('Client.zeitleisteGrenze', () {
    late Client client;

    setUp(() async {
      client = await getClient();
      client.zeitleisteGrenze = 10;
    });
    tearDown(() => client.dispose(closeDatabase: true));

    test('unter der Grenze wächst die Zeitleiste', () async {
      await client.handleSync(
        _sync([
          for (var i = 0; i < 8; i++) _nachricht('\$a$i', i),
        ], prevBatch: 'p1'),
      );
      expect(await client.database.getTimelineEventCount(_raum), 8);
    });

    test('über der Grenze: verworfen wie limited, prev_batch vom Sync, '
        'Ereignisse dieses Syncs bleiben', () async {
      await client.handleSync(
        _sync([
          for (var i = 0; i < 8; i++) _nachricht('\$a$i', i),
        ], prevBatch: 'p1'),
      );
      final ankunft = <bool?>[];
      final sub = client.onSync.stream.listen(
        (s) => ankunft.add(s.rooms?.join?[_raum]?.timeline?.limited),
      );
      await client.handleSync(
        _sync([
          for (var i = 0; i < 4; i++) _nachricht('\$b$i', 10 + i),
        ], prevBatch: 'p2'),
      );
      await Future.delayed(Duration.zero);
      await sub.cancel();

      expect(ankunft, [true], reason: 'offene Zeitleisten sehen limited');
      final db = client.database as MatrixSdkDatabase;
      expect(await db.getTimelineEventCount(_raum), 4);
      expect(await _ereignisseImRaum(db, _raum), 4);
      final room = client.getRoomById(_raum)!;
      expect(room.prev_batch, 'p2');
      final gespeichert = (await db.getRoomList(
        client,
      )).firstWhere((r) => r.id == _raum);
      expect(gespeichert.prev_batch, 'p2');

      // „Verlauf laden“ schließt genau an den Anfang dieses Syncs an.
      try {
        await room.requestHistory();
      } catch (_) {
        // Die Attrappe kennt diesen Raum nicht — es zählt nur die Anfrage.
      }
      expect(
        FakeMatrixApi.calledEndpoints.keys.where(
          (k) => k.contains('/messages?from=p2&dir=b'),
        ),
        isNotEmpty,
      );
    });

    test(
      'ohne prev_batch im Sync bleibt die Zeitleiste (kein Anschluss)',
      () async {
        await client.handleSync(
          _sync([
            for (var i = 0; i < 8; i++) _nachricht('\$a$i', i),
          ], prevBatch: 'p1'),
        );
        await client.handleSync(
          _sync([for (var i = 0; i < 4; i++) _nachricht('\$b$i', 10 + i)]),
        );
        expect(await client.database.getTimelineEventCount(_raum), 12);
      },
    );

    test('Grenze 0 schaltet ab; Verlauf (direction) zählt nie', () async {
      client.zeitleisteGrenze = 0;
      await client.handleSync(
        _sync([
          for (var i = 0; i < 12; i++) _nachricht('\$a$i', i),
        ], prevBatch: 'p1'),
      );
      client.zeitleisteGrenze = 10;
      await client.handleSync(
        _sync([
          for (var i = 0; i < 5; i++) _nachricht('\$h$i', -10 - i),
        ], prevBatch: 'p0'),
        direction: Direction.b,
      );
      expect(await client.database.getTimelineEventCount(_raum), 17);
    });
  });
}
