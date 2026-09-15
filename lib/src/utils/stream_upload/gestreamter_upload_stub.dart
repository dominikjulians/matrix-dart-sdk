// SPDX-FileCopyrightText: 2026 Dominik Julian Wittkowski
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import '../../../matrix_api_lite/generated/api.dart';
import 'gestreamter_upload.dart';

Future<GestreamterUploadErgebnis> gestreamtHochladen(
  Api api, {
  required Stream<List<int>> Function() oeffnen,
  required int laenge,
  required bool verschluesseln,
  String? filename,
  String? contentType,
  void Function(int sent, int total)? onProgress,
  bool Function()? abgebrochen,
}) => throw UnsupportedError(
  'Gestreamter Upload: weder dart:io noch Browser verfuegbar',
);
