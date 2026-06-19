import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';

/// 保底規則：指定 rank 的抽數門檻。
class PityRule {
  /// 建立 [PityRule]。
  const PityRule({required this.rank, required this.threshold});

  /// 觸發保底的星級。
  final int rank;

  /// 觸發保底所需的抽數。
  final int threshold;
}

/// 卡池類型定義，含 API cardPoolType、名稱 i18n key 與保底規則。
class GachaType {
  /// 建立 [GachaType]。
  const GachaType({
    required this.cardPoolType,
    required this.nameKey,
    required this.pities,
  });

  /// 對應喚取記錄 API 的 `cardPoolType`（int，集合 [1,2,3,4,5,6,8,9,10,11]，無 7）。
  final int cardPoolType;

  /// 對外 key/route/map 用的字串（即 [cardPoolType] 的字串形式）。
  /// 轉換只發生於此 getter，禁止散落於各處硬轉（spec D4）。
  String get key => cardPoolType.toString();

  /// i18n key（透過 [resolveName] 取顯示字串）。
  final String nameKey;

  /// 由高 rank 到低 rank。[0] 為主保底（5★），[1] 為副保底（4★）。
  final List<PityRule> pities;

  /// 主保底（[pities] 第一條）。
  PityRule get primaryPity => pities.first;

  /// 副保底（若 [pities] 長度 > 1），否則 null。
  PityRule? get secondaryPity => pities.length > 1 ? pities[1] : null;

  /// 將 [nameKey] 對應到目前語言的顯示字串。
  String resolveName(AppLocalizations l) => switch (nameKey) {
    'gachaTypeCharacter' => l.gachaTypeCharacter,
    'gachaTypeWeapon' => l.gachaTypeWeapon,
    'gachaTypeStandardCharacter' => l.gachaTypeStandardCharacter,
    'gachaTypeStandardWeapon' => l.gachaTypeStandardWeapon,
    'gachaTypeBeginner' => l.gachaTypeBeginner,
    'gachaTypeBeginnerChoice' => l.gachaTypeBeginnerChoice,
    'gachaTypeNewVoyageCharacter' => l.gachaTypeNewVoyageCharacter,
    'gachaTypeNewVoyageWeapon' => l.gachaTypeNewVoyageWeapon,
    'gachaTypeCollabCharacter' => l.gachaTypeCollabCharacter,
    'gachaTypeCollabWeapon' => l.gachaTypeCollabWeapon,
    _ => nameKey,
  };
}

/// 五星保底 80 抽（角色／武器活動、常駐、新手自選、新旅）。
const _pityFive80 = PityRule(rank: 5, threshold: 80);

/// 五星保底 50 抽（新手喚取）。
const _pityFive50 = PityRule(rank: 5, threshold: 50);

/// 四星保底 10 抽（所有卡池統一）。
const _pityFour10 = PityRule(rank: 4, threshold: 10);

/// 全部支援的卡池類型定義，順序對應側欄顯示順序。
const gachaTypes = <GachaType>[
  GachaType(
    cardPoolType: 1,
    nameKey: 'gachaTypeCharacter',
    pities: [_pityFive80, _pityFour10],
  ),
  GachaType(
    cardPoolType: 2,
    nameKey: 'gachaTypeWeapon',
    pities: [_pityFive80, _pityFour10],
  ),
  GachaType(
    cardPoolType: 3,
    nameKey: 'gachaTypeStandardCharacter',
    pities: [_pityFive80, _pityFour10],
  ),
  GachaType(
    cardPoolType: 4,
    nameKey: 'gachaTypeStandardWeapon',
    pities: [_pityFive80, _pityFour10],
  ),
  GachaType(
    cardPoolType: 5,
    nameKey: 'gachaTypeBeginner',
    pities: [_pityFive50, _pityFour10],
  ),
  GachaType(
    cardPoolType: 6,
    nameKey: 'gachaTypeBeginnerChoice',
    pities: [_pityFive80, _pityFour10],
  ),
  GachaType(
    cardPoolType: 8,
    nameKey: 'gachaTypeNewVoyageCharacter',
    pities: [_pityFive80, _pityFour10],
  ),
  GachaType(
    cardPoolType: 9,
    nameKey: 'gachaTypeNewVoyageWeapon',
    pities: [_pityFive80, _pityFour10],
  ),
  GachaType(
    cardPoolType: 10,
    nameKey: 'gachaTypeCollabCharacter',
    pities: [_pityFive80, _pityFour10],
  ),
  GachaType(
    cardPoolType: 11,
    nameKey: 'gachaTypeCollabWeapon',
    pities: [_pityFive80, _pityFour10],
  ),
];

/// 依 [cardPoolType] 字串查 [GachaType]；查無時回傳帶預設保底（5★80／4★10）
/// 的 fallback（[cardPoolType] 非數字時其 `cardPoolType` 欄為 0）。
GachaType gachaTypeFor(String cardPoolType) => gachaTypes.firstWhere(
  (t) => t.key == cardPoolType,
  orElse: () => GachaType(
    cardPoolType: int.tryParse(cardPoolType) ?? 0,
    nameKey: cardPoolType,
    pities: const [
      PityRule(rank: 5, threshold: 80),
      PityRule(rank: 4, threshold: 10),
    ],
  ),
);

/// 查 [cardPoolType] 池中 [rank] 的保底門檻；該池無對應 [rank] 的規則時，
/// 回傳主保底門檻當保守值。
int pityThresholdFor(String cardPoolType, int rank) {
  final type = gachaTypeFor(cardPoolType);
  for (final p in type.pities) {
    if (p.rank == rank) return p.threshold;
  }
  return type.primaryPity.threshold;
}
