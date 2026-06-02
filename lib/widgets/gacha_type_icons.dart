import 'package:flutter/material.dart';

/// 將卡池類型的 i18n [nameKey] 對應至「outlined」風格圖示。
///
/// 同一對照同時用於分頁標題圖示（banner_page）與側欄未選中 rail 圖示
/// （app_shell）；側欄「選中」狀態用實心變體，另行對照。未知 key 回 casino 圖示。
IconData gachaTypeOutlinedIcon(String nameKey) => switch (nameKey) {
  'gachaTypeCharacter' => Icons.person_outline,
  'gachaTypeWeapon' => Icons.shield_outlined,
  'gachaTypeStandardCharacter' => Icons.person_pin_outlined,
  'gachaTypeStandardWeapon' => Icons.gpp_good_outlined,
  'gachaTypeBeginner' => Icons.school_outlined,
  'gachaTypeBeginnerChoice' => Icons.checklist_outlined,
  'gachaTypeNewVoyageCharacter' => Icons.sailing_outlined,
  'gachaTypeNewVoyageWeapon' => Icons.explore_outlined,
  _ => Icons.casino_outlined,
};
