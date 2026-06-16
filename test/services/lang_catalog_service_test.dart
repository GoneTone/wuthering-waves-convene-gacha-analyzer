import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/item_image_fetcher.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/lang_catalog_service.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/lang_catalog_storage.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('langsvc'));
  tearDown(() => dir.deleteSync(recursive: true));

  test(
    'miss => fetch + persist; second call hits disk, no extra fetch',
    () async {
      var fetchCount = 0;
      http.Client makeClient() => MockClient((req) async {
        fetchCount++;
        if (req.url.path.endsWith('/character')) {
          return http.Response(
            '{"roleList":[{"Id":1304,"Name":"Jinhsi","RoleHeadIcon":"u"}]}',
            200,
          );
        }
        return http.Response('{}', 200);
      });
      final svc = LangCatalogService(
        storage: LangCatalogStorage(dir),
        fetcher: ItemImageFetcher(),
        clientFactory: makeClient,
      );
      final c1 = await svc.ensure('en');
      expect(c1.byId[1304]!.name, 'Jinhsi');
      final after = fetchCount;

      final svc2 = LangCatalogService(
        storage: LangCatalogStorage(dir),
        fetcher: ItemImageFetcher(),
        clientFactory: () => MockClient((_) async {
          fail('should not fetch when cached on disk');
        }),
      );
      final c2 = await svc2.ensure('en');
      expect(c2.byId[1304]!.name, 'Jinhsi');
      expect(fetchCount, after);
    },
  );
}
