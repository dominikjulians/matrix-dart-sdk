import 'package:test/test.dart';

import 'package:matrix/matrix_api_lite.dart';

void main() {
  group('mediaBaseUri', () {
    final api = MatrixApi(homeserver: Uri.parse('https://matrix.example.org'));

    test('ohne Medienbasis geht alles an den Homeserver', () {
      expect(
        api.resolveApiUri(Uri(path: '_matrix/media/v3/upload')).host,
        'matrix.example.org',
      );
    });

    test('Medienpfade gehen an die Medienbasis, der Rest nicht', () {
      api.mediaServer = Uri.parse('https://dateien.example.org');
      for (final pfad in [
        '_matrix/media/v3/upload',
        '_matrix/media/v3/download/a/b',
        '_matrix/media/v3/thumbnail/a/b',
        '_matrix/media/v1/create',
        '_matrix/client/v1/media/download/a/b',
        '_matrix/client/v1/media/thumbnail/a/b',
        '_matrix/client/v1/media/config',
      ]) {
        expect(
          api.resolveApiUri(Uri(path: pfad)).host,
          'dateien.example.org',
          reason: pfad,
        );
      }
      for (final pfad in [
        '_matrix/client/v3/sync',
        '_matrix/client/v3/rooms/!a:b/send/m.room.message/1',
        '_matrix/client/v1/media/preview_url',
        '_matrix/client/versions',
      ]) {
        expect(
          api.resolveApiUri(Uri(path: pfad)).host,
          'matrix.example.org',
          reason: pfad,
        );
      }
    });

    test('Pfad mit fuehrendem Schraegstrich wie in request()', () {
      expect(MatrixApi.isMediaPath('/_matrix/media/v3/upload'), isTrue);
      expect(MatrixApi.isMediaPath('/_matrix/client/v3/sync'), isFalse);
    });
  });
}
