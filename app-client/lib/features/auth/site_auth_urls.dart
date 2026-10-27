/// 站点授权地址的拼装与回跳识别。
///
/// 单独抽出来是因为这三件事**必须能被单测钉住**，而它们又不该散落在页面里：
/// 授权地址拼错一个参数，站点会静默退回登录页，用户看到的是「点了没反应」；
/// 回跳识别放宽一点，别的 App 拿同一个 scheme 试探就能把票据喂进来。
///
/// 与 `docs/w1-login-dual-entry.md` §2.2 的契约一致：
/// 客户端只做「拼 authorize 地址、接回跳、拿 ticket」三步，换令牌在平台后端。
abstract final class SiteAuthUrls {
  const SiteAuthUrls._();

  /// 站点给这个客户端分配的 client_id（`docs/identity-linkup-contract.md`）。
  static const String clientId = 'otaku-app-client';

  /// 回跳地址。站点侧已加白名单，改它必须同步改站点配置，否则授权会被拒。
  static const String redirectUri = 'com.otaku.app:/oauth2redirect';

  /// 回跳的 scheme。`com.otaku.app:/oauth2redirect` 的 scheme 是 `com.otaku.app`。
  static const String redirectScheme = 'com.otaku.app';

  static const String redirectPath = '/oauth2redirect';

  /// 拼 `GET /oauth/authorize?...`。
  ///
  /// `redirect_uri` 必须由 [Uri] 负责转义：站点校验的是**解码后**的完整地址，
  /// 手拼字符串时 `:` 与 `/` 漏转义会让参数被截断，表现成「client_id 非法」。
  ///
  /// [siteBaseUrl] 末尾的 `/` 会被吃掉，避免出现 `//oauth/authorize`。
  static Uri authorize({required String siteBaseUrl, required String state}) {
    final base = siteBaseUrl.endsWith('/')
        ? siteBaseUrl.substring(0, siteBaseUrl.length - 1)
        : siteBaseUrl;
    return Uri.parse('$base/oauth/authorize').replace(
      queryParameters: {
        'client_id': clientId,
        'redirect_uri': redirectUri,
        'state': state,
        'response_type': 'code',
      },
    );
  }

  /// 这个地址是不是本 App 的授权回跳。
  ///
  /// 两种形态都认（`Uri` 对 `scheme:/path` 与 `scheme://host` 的解析不同）：
  /// - `com.otaku.app:/oauth2redirect?…` → path 命中
  /// - `com.otaku.app://oauth2redirect?…` → host 命中
  ///
  /// **必须同时校验 scheme**：只看 path 的话，任何 App 都能用
  /// `https://evil.example/oauth2redirect` 把票据递进来。
  static bool isRedirect(Uri uri) {
    if (uri.scheme != redirectScheme) return false;
    return uri.path == redirectPath || uri.host == 'oauth2redirect';
  }

  /// 从回跳里取一次性票据；没有就返回 null（不抛异常——「没带票据」是
  /// 正常分支，用户看到的是「授权没有返回票据」而不是崩溃）。
  static String? ticketOf(Uri uri) {
    final ticket = uri.queryParameters['ticket'];
    if (ticket == null || ticket.isEmpty) return null;
    return ticket;
  }
}
