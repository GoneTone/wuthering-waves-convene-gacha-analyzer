import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/services/file_access.dart';

void main() {
  tearDown(() {
    resetFileAccessSeams();
    debugDefaultTargetPlatformOverride = null;
  });

  final bytes = Uint8List.fromList([1, 2, 3]);

  Future<SavedFile?> save() => saveBytes(
    bytes,
    suggestedName: 'wuwa.json',
    extension: 'json',
    mimeType: 'application/json',
  );

  test(
    'saveBytes returns null and writes nothing when the user cancels',
    () async {
      fileSaveDialog = (_, _, _, _, _) async => null;
      expect(await save(), isNull);
    },
  );

  test('saveBytes on desktop returns the file path and its basename', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    fileSaveDialog = (_, _, _, _, _) async => r'C:\tmp\a.json';
    final saved = await save();
    expect(saved!.path, r'C:\tmp\a.json');
    expect(saved.displayName, 'a.json');
  });

  test('saveBytes on Android returns no path', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    fileSaveDialog = (_, _, _, _, _) async =>
        '/document/primary:Download/a.json';
    final saved = await save();
    expect(saved!.path, isNull);
    expect(saved.displayName, 'a.json');
  });

  test(
    'saveBytes on Android falls back to the suggested name for opaque ids',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      fileSaveDialog = (_, _, _, _, _) async => '/document/msf:1234';
      final saved = await save();
      expect(saved!.path, isNull);
      expect(saved.displayName, 'wuwa.json');
    },
  );

  test('saveBytes passes the dialog title through', () async {
    String? title;
    fileSaveDialog = (_, _, _, _, t) async {
      title = t;
      return null;
    };
    await saveBytes(
      bytes,
      suggestedName: 'a.json',
      extension: 'json',
      mimeType: 'application/json',
      dialogTitle: '儲存',
    );
    expect(title, '儲存');
  });

  test(
    'displayNameForSavedPath falls back when the extension does not match',
    () {
      expect(
        displayNameForSavedPath(
          '/document/primary:Download/a.txt',
          suggestedName: 'wuwa.json',
          extension: 'json',
        ),
        'wuwa.json',
      );
    },
  );

  test('saveBytes rethrows when the dialog fails', () async {
    fileSaveDialog = (_, _, _, _, _) async => throw StateError('boom');
    expect(save(), throwsStateError);
  });

  test('shareBytes passes the name and mime type and returns true', () async {
    String? name;
    String? mime;
    fileSharer = (_, n, m) async {
      name = n;
      mime = m;
    };
    expect(
      await shareBytes(bytes, fileName: 'a.png', mimeType: 'image/png'),
      isTrue,
    );
    expect(name, 'a.png');
    expect(mime, 'image/png');
  });

  test('shareBytes returns false when sharing throws', () async {
    fileSharer = (_, _, _) async => throw StateError('boom');
    expect(
      await shareBytes(bytes, fileName: 'a.png', mimeType: 'image/png'),
      isFalse,
    );
  });

  test('pickTextFile decodes UTF-8 Chinese text', () async {
    fileOpenDialog = (_) async =>
        Uint8List.fromList(utf8.encode('{"alias":"主號"}'));
    expect(await pickTextFile(extensions: ['json']), '{"alias":"主號"}');
  });

  test('pickTextFile throws FormatException on invalid UTF-8', () async {
    fileOpenDialog = (_) async => Uint8List.fromList([0xff, 0xfe, 0x00]);
    expect(pickTextFile(extensions: ['json']), throwsFormatException);
  });

  test('pickTextFile returns null when cancelled', () async {
    fileOpenDialog = (_) async => null;
    expect(await pickTextFile(extensions: ['json']), isNull);
  });
}
