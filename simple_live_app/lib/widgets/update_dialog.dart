import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/services/update_service.dart';

/// 更新提示对话框。
///
/// - 非强制：用户可选择"立即更新"或"暂不更新"
/// - "暂不更新"会记住当前版本，启动检查时不再提示
class UpdateDialog {
  static bool _isShowing = false;

  /// 检查并处理更新。
  ///
  /// [manual] = true 表示用户主动点击，即使没有新版本也给出反馈。
  static Future<void> check(BuildContext context, {bool manual = false}) async {
    if (_isShowing) return;
    final service = UpdateService.instance;
    if (service.checking.value) return;

    final info = await service.check(silent: !manual);
    if (info == null) {
      if (manual && context.mounted) {
        Get.snackbar(
          "检查更新",
          service.error.value != null
              ? "检查失败：${service.error.value}"
              : "当前已是最新版本",
          snackPosition: SnackPosition.BOTTOM,
        );
      }
      return;
    }
    if (!context.mounted) return;
    show(context, info);
  }

  /// 显示更新对话框。
  static void show(BuildContext context, AppRelease info) {
    if (_isShowing) return;
    _isShowing = true;

    final service = UpdateService.instance;
    Get.dialog(
      AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.system_update, size: 22),
            const SizedBox(width: 8),
            const Text("发现新版本"),
          ],
        ),
        content: SizedBox(
          width: 340,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "当前版本 ${service.currentVersion} → 新版本 ${info.version}",
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 12),
                if (info.body.trim().isNotEmpty)
                  Container(
                    constraints: const BoxConstraints(maxHeight: 200),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.black.withAlpha(15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      info.body.trim(),
                      style: const TextStyle(fontSize: 12, height: 1.5),
                    ),
                  ),
                const SizedBox(height: 8),
                Obx(
                  () {
                    if (service.updateError.value != null) {
                      return Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          service.updateError.value!,
                          style: TextStyle(
                            fontSize: 12,
                            color: Get.theme.colorScheme.error,
                          ),
                        ),
                      );
                    }
                    return service.downloading.value
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              LinearProgressIndicator(
                                value: service.downloadProgress.value > 0
                                    ? service.downloadProgress.value
                                    : null,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                "下载中 ${(service.downloadProgress.value * 100).toStringAsFixed(0)}%",
                                style: const TextStyle(fontSize: 11),
                              ),
                            ],
                          )
                        : const SizedBox.shrink();
                  },
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              service.skipVersion(info.version);
              Get.back();
            },
            child: const Text("暂不更新"),
          ),
          Obx(
            () => ElevatedButton(
              onPressed: service.downloading.value
                  ? null
                  : () async {
                      try {
                        final ok = await service.update(info);
                        if (ok && Get.isDialogOpen == true) {
                          Get.back();
                        }
                      } catch (e) {
                        Log.e("更新失败: $e", StackTrace.current);
                        Get.snackbar("更新失败", "$e",
                            snackPosition: SnackPosition.BOTTOM);
                      }
                    },
              child: const Text("立即更新"),
            ),
          ),
        ],
      ),
      barrierDismissible: false,
    ).whenComplete(() => _isShowing = false);
  }
}
