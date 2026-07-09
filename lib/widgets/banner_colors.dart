import 'package:flutter/material.dart';

/// 卡池配色表，給 Timeline 系列 widget 共用。
///
/// 配色刻意全部落在 cyan → 洋紅 的冷色／洋紅弧段，避開「歐非色」占用的綠
/// （[GachaTokens.stateSuccess]）、琥珀（[GachaTokens.stateWarning]）、紅
/// （[GachaTokens.stateDanger]）三個色帶——時間軸已改以歐非色標示節點與抽數，
/// 卡池色僅作為卡池名稱／圖例的識別，若落在同色帶會與歐非語意混淆。每個
/// cardPoolType 一個獨特色相，dark / light 各一組對應飽和度。
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
    required this.collabCharacter,
    required this.collabWeapon,
    required this.reverbCharacter,
    required this.reverbWeapon,
    required this.fallback,
  });

  /// 依當前 [Brightness] 取得 dark / light palette。
  factory BannerColors.of(Brightness brightness) =>
      brightness == Brightness.dark ? _dark : _light;

  /// Dark mode palette（全部位於 cyan → 洋紅 弧段，避開綠／琥珀／紅）。
  static const _dark = BannerColors(
    character: Color(0xFF22B5C2), // 青藍
    weapon: Color(0xFF4C9CEA), // 天藍
    standardCharacter: Color(0xFF6E7CE8), // 矢車菊藍
    standardWeapon: Color(0xFFA56FDE), // 紫羅蘭
    beginner: Color(0xFF7E8AA8), // 灰藍
    beginnerChoice: Color(0xFFC596E2), // 薰衣草紫
    newVoyageCharacter: Color(0xFF59C0D8), // 淺青
    newVoyageWeapon: Color(0xFFD074CC), // 蘭紫
    collabCharacter: Color(0xFFE070A6), // 桃紅
    collabWeapon: Color(0xFF8266E0), // 靛藍
    reverbCharacter: Color(0xFFE66EC6), // 洋紅
    reverbWeapon: Color(0xFFA08BC0), // 灰紫
    fallback: Color(0xFF8A92A6), // 中性
  );

  /// Light mode palette（同色相、加深以利白底對比）。
  static const _light = BannerColors(
    character: Color(0xFF0E8C99), // 青藍
    weapon: Color(0xFF2E6FC4), // 天藍
    standardCharacter: Color(0xFF4A4FC0), // 矢車菊藍
    standardWeapon: Color(0xFF8341B0), // 紫羅蘭
    beginner: Color(0xFF5A6680), // 灰藍
    beginnerChoice: Color(0xFF8A57BE), // 薰衣草紫
    newVoyageCharacter: Color(0xFF1C8FAE), // 淺青
    newVoyageWeapon: Color(0xFFA63C9E), // 蘭紫
    collabCharacter: Color(0xFFB83E78), // 桃紅
    collabWeapon: Color(0xFF5547C0), // 靛藍
    reverbCharacter: Color(0xFFB93A96), // 洋紅
    reverbWeapon: Color(0xFF71589A), // 灰紫
    fallback: Color(0xFF6A7080), // 中性
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

  /// 角色聯動喚取配色（cardPoolType 10）。
  final Color collabCharacter;

  /// 武器聯動喚取配色（cardPoolType 11）。
  final Color collabWeapon;

  /// 角色憶旅喚取配色（cardPoolType 12）。
  final Color reverbCharacter;

  /// 武器憶旅喚取配色（cardPoolType 13）。
  final Color reverbWeapon;

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
    '10' => collabCharacter,
    '11' => collabWeapon,
    '12' => reverbCharacter,
    '13' => reverbWeapon,
    _ => fallback,
  };
}
