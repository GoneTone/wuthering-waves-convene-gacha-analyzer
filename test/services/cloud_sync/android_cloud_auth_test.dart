import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/android_cloud_auth.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/cloud_auth.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/google_auth_service.dart';
import 'package:wuthering_waves_convene_gacha_analyzer/services/cloud_sync/google_authorization_gateway.dart';

/// 依佇列回放通行證的 fake gateway；佇列元素為 null 代表需要使用者操作。
class _FakeGateway implements GoogleAuthorizationGateway {
  /// 靜默取得的回應佇列。
  final List<String?> silent = [];

  /// 互動取得的回應佇列。
  final List<String?> interactive = [];

  /// 互動取得時是否模擬使用者取消。
  bool cancelInteractive = false;

  /// 已被清掉的通行證。
  final cleared = <String>[];

  /// signOut 呼叫次數。
  int signOutCalls = 0;

  @override
  Future<String?> silentToken() async => silent.removeAt(0);

  @override
  Future<String> interactiveToken() async {
    if (cancelInteractive) throw const CloudLinkCancelledException('canceled');
    final token = interactive.removeAt(0);
    if (token == null) throw StateError('interactive token must not be null');
    return token;
  }

  @override
  Future<void> clearToken(String token) async => cleared.add(token);

  @override
  Future<void> signOut() async => signOutCalls++;
}

void main() {
  late _FakeGateway gateway;
  late List<Uri> requests;
  late AndroidCloudAuth auth;

  setUp(() {
    gateway = _FakeGateway();
    requests = [];
    auth = AndroidCloudAuth(
      gateway: gateway,
      baseClientFactory: () => MockClient((request) async {
        requests.add(request.url);
        final token = request.headers['authorization']?.split(' ').last ?? '';
        if (token == 'stale') return http.Response('{}', 401);
        final email = token == 'other' ? 'x@example.com' : 'u@example.com';
        return http.Response(
          jsonEncode({'email': email}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
  });

  test('link: interactive token → email and a client', () async {
    gateway.interactive.add('good-1');

    final result = await auth.link(openUrl: (_) {});

    expect(result.email, 'u@example.com');
    await result.commit();
    result.client.close();
  });

  test(
    'link: stale token from interactive authorize → clear and retry once',
    () async {
      gateway.interactive.addAll(['stale', 'good-2']);

      final result = await auth.link(openUrl: (_) {});

      expect(result.email, 'u@example.com');
      expect(gateway.cleared, ['stale']);
    },
  );

  test('link: user cancels → CloudLinkCancelledException propagates', () async {
    gateway.cancelInteractive = true;

    expect(
      auth.link(openUrl: (_) {}),
      throwsA(isA<CloudLinkCancelledException>()),
    );
  });

  test('restore: silent token → client', () async {
    gateway.silent.add('good-1');

    final client = await auth.restoreClient(expectedEmail: 'u@example.com');

    expect(client, isNotNull);
    client!.close();
  });

  test('restore: no silent token → null', () async {
    gateway.silent.add(null);

    expect(await auth.restoreClient(expectedEmail: 'u@example.com'), isNull);
  });

  test('restore: different account than the linked email → reauth', () async {
    gateway.silent.add('other');

    expect(
      auth.restoreClient(expectedEmail: 'u@example.com'),
      throwsA(isA<CloudReauthRequiredException>()),
    );
  });

  test('restore: stale cached token that cannot be renewed → reauth', () async {
    gateway.silent.addAll(['stale', null]);

    expect(await auth.restoreClient(expectedEmail: 'u@example.com'), isNull);
    expect(gateway.cleared, ['stale']);
  });

  test(
    'unlink: clears the cached token and signs out without revoking',
    () async {
      gateway.silent.add('good-1');

      await auth.unlink();

      expect(gateway.cleared, ['good-1']);
      expect(gateway.signOutCalls, 1);
      expect(requests.where((u) => u.path.contains('revoke')), isEmpty);
    },
  );

  test('keepsClientAcrossRounds is false', () {
    expect(auth.keepsClientAcrossRounds, isFalse);
  });
}
