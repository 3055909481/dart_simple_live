import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// Stripchat 账号（Cookie）服务。
class StripchatAccountService extends GetxService {
  static StripchatAccountService get instance =>
      Get.find<StripchatAccountService>();

  var cookie = "";
  var hasCookie = false.obs;

  @override
  void onInit() {
    cookie = LocalStorageService.instance.getValue(
      LocalStorageService.kStripchatCookie,
      "",
    );
    hasCookie.value = cookie.isNotEmpty;
    setSite();
    super.onInit();
  }

  void setSite() {
    final site = Sites.allSites[Constant.kStripchat]?.liveSite;
    if (site is StripchatSite) site.cookie = cookie;
  }

  void setCookie(String value) {
    cookie = value;
    LocalStorageService.instance.setValue(
      LocalStorageService.kStripchatCookie,
      value,
    );
    hasCookie.value = value.isNotEmpty;
    setSite();
  }

  void clearCookie() => setCookie("");
}
