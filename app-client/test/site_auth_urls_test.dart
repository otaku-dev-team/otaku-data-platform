import 'package:flutter_test/flutter_test.dart';
import 'package:otaku_app/features/auth/site_auth_urls.dart';

/// 授权地址拼装与回跳识别的单测。
///
/// 这两件事都不该靠「真机跑一次看看」来保证：
/// - 地址拼错一个参数 → 站点静默退回登录页，表现是「点了没反应」；
/// - 回跳识别放宽一点 → 别的 App 拿同一个 scheme 就能把票据递进来。
void main() {
  group('authorize 地址', () {
    test('拼出站点 /oauth/authorize，带齐四个参数', () {
      final uri = SiteAuthUrls.authorize(
        siteBaseUrl: 'http://154.8.194.198:8000',
        state: 'abc123',
      );

      expect(uri.scheme, 'http');
      expect(uri.host, '154.8.194.198');
      expect(uri.port, 8000);
      expect(uri.path, '/oauth/authorize');
      expect(uri.queryParameters['client_id'], 'otaku-app-client');
      expect(uri.queryParameters['state'], 'abc123');
      expect(uri.queryParameters['response_type'], 'code');
    });

    test('redirect_uri 解码后是完整回跳地址（不被查询串截断）', () {
      final uri = SiteAuthUrls.authorize(
        siteBaseUrl: 'http://example.test',
        state: 's',
      );

      // 站点校验的是解码后的值；这里断言「原值能拿回来」，
      // 而不是断言百分号编码长什么样——编码细节交给 Uri。
      expect(uri.queryParameters['redirect_uri'], 'com.otaku.app:/oauth2redirect');
      expect(uri.toString(), contains('redirect_uri=com.otaku.app%3A%2Foauth2redirect'));
    });

    test('站点地址末尾的斜杠不会拼出双斜杠', () {
      final uri = SiteAuthUrls.authorize(
        siteBaseUrl: 'http://example.test/',
        state: 's',
      );
      expect(uri.path, '/oauth/authorize');
      expect(uri.toString(), isNot(contains('//oauth/authorize')));
    });

    test('state 含特殊字符时被正确转义', () {
      final uri = SiteAuthUrls.authorize(
        siteBaseUrl: 'http://example.test',
        state: 'a b&c=d',
      );
      expect(uri.queryParameters['state'], 'a b&c=d');
    });
  });

  group('回跳识别', () {
    test('scheme:/path 形态命中', () {
      expect(
        SiteAuthUrls.isRedirect(
          Uri.parse('com.otaku.app:/oauth2redirect?ticket=t&state=s'),
        ),
        isTrue,
      );
    });

    test('scheme://host 形态命中（Uri 解析差异的兜底）', () {
      expect(
        SiteAuthUrls.isRedirect(
          Uri.parse('com.otaku.app://oauth2redirect?ticket=t&state=s'),
        ),
        isTrue,
      );
    });

    test('别的 scheme 走同一个 path 不算——否则任何 App 都能递票据进来', () {
      expect(
        SiteAuthUrls.isRedirect(
          Uri.parse('https://evil.example/oauth2redirect?ticket=t&state=s'),
        ),
        isFalse,
      );
    });

    test('同 scheme 但别的路径不算', () {
      expect(
        SiteAuthUrls.isRedirect(Uri.parse('com.otaku.app:/other?ticket=t')),
        isFalse,
      );
    });

    test('站点的普通页面不算', () {
      expect(
        SiteAuthUrls.isRedirect(
          Uri.parse('http://154.8.194.198:8000/oauth/authorize?client_id=x'),
        ),
        isFalse,
      );
    });
  });

  group('票据提取', () {
    test('取出 ticket', () {
      expect(
        SiteAuthUrls.ticketOf(
          Uri.parse('com.otaku.app:/oauth2redirect?ticket=T-1&state=s'),
        ),
        'T-1',
      );
    });

    test('没有 ticket 返回 null，不抛异常', () {
      expect(
        SiteAuthUrls.ticketOf(
          Uri.parse('com.otaku.app:/oauth2redirect?state=s'),
        ),
        isNull,
      );
    });

    test('空 ticket 当作没有', () {
      expect(
        SiteAuthUrls.ticketOf(
          Uri.parse('com.otaku.app:/oauth2redirect?ticket=&state=s'),
        ),
        isNull,
      );
    });
  });
}
