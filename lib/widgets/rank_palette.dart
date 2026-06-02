import 'package:flutter/material.dart';

import 'package:wuthering_waves_convene_gacha_analyzer/theme/tokens.dart';

/// 依稀有度 rank 取對應主色 token（鳴潮僅 3/4/5★）。
Color accentForRank(int rank, GachaTokens t) => switch (rank) {
  5 => t.fiveStar,
  4 => t.fourStar,
  3 => t.threeStar,
  _ => t.textMuted,
};
