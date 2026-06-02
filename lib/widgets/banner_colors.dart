import 'package:flutter/material.dart';

/// 卡池配色表，給 Timeline 系列 widget 共用。
///
/// 配色刻意跟稀有度 token（5★ 金、4★ 紫、3★ 藍）保持距離，避免使用者看到
/// 時間軸節點的顏色誤判為稀有度。每個 cardPoolType 一個獨特色相，dark / light
/// 各一組對應飽和度。
@immutable
class BannerColors {
  /// 建立 [BannerColors]。
  const BannerColors({
    required this.character,
    required this.weapon,
    required this.standardCharacter,
    required this.standardWeapon,
    required this.beginner,
    required this.beginnerChoice,
    required this.newVoyageCharacter,
    required this.newVoyageWeapon,
    required this.fallback,
  });

  /// 依當前 [Brightness] 取得 dark / light palette。
  factory BannerColors.of(Brightness brightness) =>
      brightness == Brightness.dark ? _dark : _light;

  /// Dark mode palette。
  static const _dark = BannerColors(
    character: Color(0xFF46B07A), // 森林綠
    weapon: Color(0xFFE6736B), // 珊瑚紅
    standardCharacter: Color(0xFF26A69A), // 青綠
    standardWeapon: Color(0xFFEFA94A), // 鮮橘
    beginner: Color(0xFF7A8AAD), // 灰藍
    beginnerChoice: Color(0xFFB59FE5), // 薰衣草紫
    newVoyageCharacter: Color(0xFF5AB6E0), // 天藍
    newVoyageWeapon: Color(0xFFD98AC4), // 紫粉
    fallback: Color(0xFF8A92A6), // 中性
  );

  /// Light mode palette。
  static const _light = BannerColors(
    character: Color(0xFF2E7D32),
    weapon: Color(0xFFC62828),
    standardCharacter: Color(0xFF00897B),
    standardWeapon: Color(0xFFB8651B),
    beginner: Color(0xFF5A6680),
    beginnerChoice: Color(0xFF6E5BAB),
    newVoyageCharacter: Color(0xFF1E6AA8),
    newVoyageWeapon: Color(0xFFA53D8C),
    fallback: Color(0xFF6A7080),
  );

  /// 角色活動喚取配色（cardPoolType 1）。
  final Color character;

  /// 武器活動喚取配色（cardPoolType 2）。
  final Color weapon;

  /// 角色常駐喚取配色（cardPoolType 3）。
  final Color standardCharacter;

  /// 武器常駐喚取配色（cardPoolType 4）。
  final Color standardWeapon;

  /// 新手喚取配色（cardPoolType 5）。
  final Color beginner;

  /// 新手自選喚取配色（cardPoolType 6）。
  final Color beginnerChoice;

  /// 角色新旅喚取配色（cardPoolType 8）。
  final Color newVoyageCharacter;

  /// 武器新旅喚取配色（cardPoolType 9）。
  final Color newVoyageWeapon;

  /// 未知 cardPoolType 的備用配色。
  final Color fallback;

  /// 依 [cardPoolType] 字串（如 `'1'`）回傳對應色；未知 type 回傳 [fallback]。
  Color colorFor(String cardPoolType) => switch (cardPoolType) {
    '1' => character,
    '2' => weapon,
    '3' => standardCharacter,
    '4' => standardWeapon,
    '5' => beginner,
    '6' => beginnerChoice,
    '8' => newVoyageCharacter,
    '9' => newVoyageWeapon,
    _ => fallback,
  };
}
