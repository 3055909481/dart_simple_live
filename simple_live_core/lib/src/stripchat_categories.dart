/// Stripchat 侧边栏分类（slug + 显示名）。
///
/// 来自 Stripchat 网页侧边栏，URL 形如 `/girls/<slug>`。
/// 分类页 HTML 的 __PRELOADED_STATE__.tagPage 含该分类的主播列表。
class StripchatCategories {
  StripchatCategories._();

  /// 所有分类，按侧边栏顺序。
  static const List<StripchatCategory> all = [
    StripchatCategory("recommended", "推荐"),
    StripchatCategory("best", "最佳私人秀"),
    StripchatCategory("chinese", "中文"),
    StripchatCategory("ukrainian", "乌克兰"),
    StripchatCategory("new", "新主播"),
    StripchatCategory("vr", "VR 摄像头"),
    StripchatCategory("bdsm", "虐恋"),
    StripchatCategory("ticket-and-group-shows", "购票表演"),
    StripchatCategory("teens", "青春美女 18+"),
    StripchatCategory("young", "鲜嫩青年 22+"),
    StripchatCategory("milfs", "熟女"),
    StripchatCategory("mature", "成熟"),
    StripchatCategory("grannies", "老奶奶"),
    StripchatCategory("arab", "阿拉伯"),
    StripchatCategory("asian", "亚洲"),
    StripchatCategory("ebony", "黑珍珠"),
    StripchatCategory("indian", "印度"),
    StripchatCategory("latin", "拉丁"),
    StripchatCategory("mixed", "混血"),
    StripchatCategory("white", "白人"),
    StripchatCategory("petite", "瘦小"),
    StripchatCategory("skinny", "苗条"),
    StripchatCategory("athletic", "运动型"),
    StripchatCategory("muscular", "肌肉"),
    StripchatCategory("medium", "中等身材"),
    StripchatCategory("curvy", "丰满"),
    StripchatCategory("bbw", "大号美女"),
    StripchatCategory("blondes", "金发"),
    StripchatCategory("brunettes", "棕发"),
    StripchatCategory("black-hair", "黑发"),
    StripchatCategory("redheads", "红发"),
    StripchatCategory("colorful", "彩色头发"),
    StripchatCategory("cheapest-privates", "8-12 代币"),
    StripchatCategory("cheap-privates", "16-24 代币"),
    StripchatCategory("middle-privates", "32-60 代币"),
    StripchatCategory("luxurious-privates", "90+ 代币"),
    StripchatCategory("recordable-privates", "可录制私秀"),
    StripchatCategory("spy", "偷窥表演"),
    StripchatCategory("cam2cam", "视频通话"),
    StripchatCategory("interactive-toys", "互动玩具"),
    StripchatCategory("mobile", "移动流"),
    StripchatCategory("group-sex", "群交"),
    StripchatCategory("big-tits", "巨乳"),
    StripchatCategory("hairy", "多毛"),
    StripchatCategory("outdoor", "户外"),
    StripchatCategory("big-ass", "大屁股"),
    StripchatCategory("anal", "肛交"),
    StripchatCategory("squirt", "潮吹"),
    StripchatCategory("fuck-machine", "炮机"),
    StripchatCategory("hardcore", "粗暴"),
    StripchatCategory("blowjob", "口交"),
  ];

  static StripchatCategory? find(String slug) {
    for (final c in all) {
      if (c.slug == slug) return c;
    }
    return null;
  }
}

class StripchatCategory {
  final String slug;
  final String name;

  const StripchatCategory(this.slug, this.name);
}
