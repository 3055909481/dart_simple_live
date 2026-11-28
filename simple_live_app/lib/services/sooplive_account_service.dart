import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// SOOP 账号 Cookie 管理。
/// 公开直播无需登录；订阅/19+ 直播需粘贴浏览器登录后的完整 Cookie。
class SoopliveAccountService extends GetxService {
  static SoopliveAccountService get instance =>
      Get.find<SoopliveAccountService>();

  var cookie = "";
  var hasCookie = false.obs;

  @override
  void onInit() {
    cookie = LocalStorageService.instance
        .getValue(LocalStorageService.kSoopliveCookie, "");
    hasCookie.value = cookie.isNotEmpty;
    setSite();
    super.onInit();
  }

  void setSite() {
    final site = Sites.allSites[Constant.kSooplive]?.liveSite;
    if (site is SoopliveSite) {
      site.cookie = cookie;
    }
  }

  void setCookie(String value) {
    cookie = value.trim();
    LocalStorageService.instance.setValue(
      LocalStorageService.kSoopliveCookie,
      cookie,
    );
    hasCookie.value = cookie.isNotEmpty;
    setSite();
  }

  void clearCookie() {
    setCookie("");
  }
}
