import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/l10n/generated/app_localizations.dart';

/// 抽查數量為 1 與 2 時的輸出：名詞、形容詞、動詞都要跟著單複數變（曾出現「For 1 dager siden」、「1 accounts」）。
void main() {
  AppLocalizations l(String tag) {
    final parts = tag.split('_');
    return lookupAppLocalizations(
      Locale(parts.first, parts.length > 1 ? parts[1] : null),
    );
  }

  test('relative time uses the singular for one', () {
    expect(l('no').relativeDaysAgo(1), 'For 1 dag siden');
    expect(l('no').relativeDaysAgo(2), 'For 2 dager siden');
    expect(l('da').relativeHoursAgo(1), 'For 1 time siden');
    expect(l('sv').relativeMinutesAgo(1), 'För 1 minut sedan');
    expect(l('nl').relativeSecondsAgo(1), '1 seconde geleden');
    expect(l('fi').relativeYearsAgo(1), '1 vuosi sitten');
    expect(l('fi').relativeYearsAgo(2), '2 vuotta sitten');
    expect(l('el').relativeMonthsAgo(1), 'Πριν από 1 μήνα');
  });

  test('counted records and pulls use the singular for one', () {
    expect(l('da').accountRecordCount(1), '1 post');
    expect(l('el').timelineNowPulls(1), '1 τράβηγμα');
    expect(l('nl').pityDistance(1), 'Nog 1 pull tot gegarandeerd');
  });

  test('import confirmation agrees with both counts', () {
    expect(
      l('en').settingsImportConfirmIntro(1, 1),
      'About to import 1 account (1 record total):',
    );
    expect(
      l('en').settingsImportConfirmIntro(2, 30),
      'About to import 2 accounts (30 records total):',
    );
    expect(
      l('de').settingsImportConfirmIntro(1, 1),
      'Es wird 1 Konto importiert (1 Eintrag insgesamt):',
    );
  });

  test('adjectives and verbs agree with one', () {
    expect(
      l('fr').progressDoneImportSummary(1, 1, 1),
      '1 compte importé : 1 nouveau, 1 déjà présent',
    );
    expect(l('es').timelineLoadMore(1), 'Cargar más (queda 1)');
    expect(l('fi').progressPoolStatus(1, 10, 1), 'Banneri 1 / 10, 1 uusi');
    expect(
      l('en').settingsDataLanguageUnifyDone(3, 1, 0),
      'Converted 3, recovered 1 ID, 0 could not be converted.',
    );
  });

  test('pt_BR still resolves', () {
    expect(l('pt_BR').timelineLoadMore(1), 'Carregar mais (1 restante)');
  });
}
