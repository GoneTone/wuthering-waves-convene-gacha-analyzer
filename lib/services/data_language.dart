/// 單一可選資料語言：encore 對齊的 [code] 與母語顯示 [label]。
typedef DataLanguageOption = ({String code, String label});

/// 可選的資料語言清單（顯示順序固定），代碼對齊 encore.moe，與 App UI 語言獨立。
const List<DataLanguageOption> kDataLanguageOptions = [
  (code: 'zh-Hant', label: '繁體中文'),
  (code: 'zh-Hans', label: '简体中文'),
  (code: 'en', label: 'English'),
  (code: 'ja', label: '日本語'),
  (code: 'ko', label: '한국어'),
  (code: 'fr', label: 'Français'),
  (code: 'de', label: 'Deutsch'),
  (code: 'es', label: 'Español'),
  (code: 'th', label: 'ภาษาไทย'),
];

/// 可選資料語言代碼集合（供 seeding 判定語言是否在選項內）。
final Set<String> kDataLanguageCodes = {
  for (final o in kDataLanguageOptions) o.code,
};

/// [code] 是否為可選資料語言（用於自動播種：落在選項外則維持未設定）。
bool isSupportedDataLanguage(String code) => kDataLanguageCodes.contains(code);
