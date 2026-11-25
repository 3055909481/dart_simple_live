import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// Bigo Live 账号（Cookie）服务。
///
/// Bigo 对部分出口 IP 要求登录态才返回播放地址，
/// 配置 www.bigo.tv 的完整 Cookie 可解除该限制。
class BigoAccountService extends GetxService {
  static BigoAccountService get instance => Get.find<BigoAccountService>();

  var cookie = "";
  var hasCookie = false.obs;

  @override
  void onInit() {
    cookie = LocalStorageService.instance.getValue(
      LocalStorageService.kBigoCookie,
      "",
    );
    hasCookie.value = cookie.isNotEmpty;
    setSite();
    super.onInit();
  }

  void setSite() {
    final site = Sites.allSites[Constant.kBigoTv]?.liveSite;
    if (site is BigoSite) site.cookie = cookie;
  }

  void setCookie(String value) {
    cookie = value;
    LocalStorageService.instance.setValue(
      LocalStorageService.kBigoCookie,
      value,
    );
    hasCookie.value = value.isNotEmpty;
    setSite();
  }

  void clearCookie() => setCookie("");
}
