# 鳴潮集音分析ツール Wuthering Waves Convene Gacha Analyzer

[繁體中文](README.md) | [简体中文](README_ZH-HANS.md) | [English](README_EN.md) | 日本語

[![Crowdin](https://badges.crowdin.net/wuthering-waves-convene-gacha-analyzer/localized.svg)](https://crowdin.com/project/wuthering-waves-convene-gacha-analyzer)

鳴潮の集音履歴を分析するためのソフトウェアで、Windows と Android に対応しています。起動するだけで各種データがひと目で分かり、もう手計算は不要です。

Windows 版の仕組みは、「データ更新」を押すと、お使いのコンピューター上だけで動作するローカルの傍受プログラムを起動し（システム管理者権限が必要なため、UAC の確認が一度表示されます。「はい」を押してください）、ローカルで生成したルート証明書を自動でインストールします。続いて、鳴潮の集音履歴ページから公式の集音履歴 API へのリクエストをローカルへリダイレクトして解析することで、そのリクエストを傍受します。そのため、更新を押した後にゲーム内で集音履歴を開いて初めて傍受できます。傍受できたら、集音履歴の照会に必要なパラメーターを解析します。これらのパラメーターは公式の集音関連 API に使用されます。傍受は更新中のみ行われ、完了すると直ちに停止してネットワークの状態を元に戻します。

Android 版は通信を傍受できないため、鳴潮が書き出すログファイルを読み取り、そこから集音履歴の URL を見つけます。Android ではアプリが他のアプリのファイルを直接読むことはできないため、端末の状況に応じて root、直接読み取り（Android 10 以前）、またはシステム標準の「ワイヤレスデバッグ」を使って読み取ります。ワイヤレスデバッグを使う場合は読み取りが終わるとすぐに接続を切断し、ワイヤレスデバッグを本アプリがオンにした場合はオフに戻します。

初めて「データ更新」を押すと、あなたの完全な集音履歴を読み込みます。これには少し時間がかかる場合があります。完了するとデータはお使いのデバイス内に保存されるため、次回ソフトウェアを起動する際にデータの読み込みを待つ必要がなくなります。その後、新しいデータを取得したいときは「データ更新」を押すだけです。ソフトウェアは以前に取得した照会パラメーターを記憶しており、使えるならそのまま再利用し、毎回取得し直す必要はありません。照会パラメーターが失効している場合は、ゲームで集音履歴ページをもう一度開いて再取得するようお願いします。

ご安心ください。本ソフトウェアはいかなるゲームファイルも改ざんせず、ゲームのメモリーを読み取ったり改ざんしたりすることもなく、ゲーム自体の動作にも影響を与えません。Windows 版は集音履歴ページを開いたときに、公式の集音履歴 API への、そのひとつのリクエストだけを傍受して照会パラメーターを取得するだけで、その他すべての通信はそのまま素通しし、一切触れません。Android 版はゲームのログファイルを読み取るだけです。そのため、アカウントが BAN される心配はありません。もし BAN された場合は、別の原因ではないかをご検討ください。私たちのせいにしないでください。

記事：
- 巴哈姆特（Bahamut）：<https://forum.gamer.com.tw/C.php?bsn=74934&snA=17364>

## 多言語対応

本ソフトウェアを各国語へ翻訳するご協力をお願いします。

<https://crowdin.com/project/wuthering-waves-convene-gacha-analyzer>

## ソフトウェアのダウンロード

本ソフトウェアはインストールや実行時にウイルス対策ソフトによってブロックされることがあります。これは、本ソフトウェアがローカルのルート証明書を自ら生成してインストールし、更新を押した際にシステム管理者権限で傍受プログラム（[WinDivert](https://github.com/basil00/WinDivert) カーネルドライバーを内蔵）を起動して、鳴潮の集音履歴ページのリクエストをローカルへリダイレクトして解析するためです。こうした挙動（証明書のインストール、カーネルドライバーの読み込み、通信のリダイレクト）はマルウェアと似ているため、特に誤検知されやすくなっています。しかし本ソフトウェアは公式の集音履歴 API のみを傍受し、証明書はお使いのコンピューターに留まり、オープンソースなのでソースコードをご自身で確認できます。正常に実行できない場合は、ウイルス対策ソフトを無効にしてから実行してみてください。本ソフトウェアは無害であることを保証します。

<https://github.com/GoneTone/wuthering-waves-convene-gacha-analyzer/releases>

### 他のゲームに対応したバージョンもあります

- 原神：<https://github.com/GoneTone/genshin-impact-wish-gacha-analyzer>
- 今後さらに多くのゲームに対応するかもしれません...

## 使い方

### Windows

1. 鳴潮を起動します（まだ集音履歴ページは開かないでください）。
2. 本ソフトウェアを開いて「データ更新」を押します。ソフトウェアがローカルの傍受プログラムを起動し（UAC のシステム管理者確認が一度表示されます。「はい」を押してください）、傍受を待機します。
3. ゲームに戻り、「集音 → 集音履歴」から集音履歴ページを開きます。
4. ソフトウェアが URL を傍受すると自動で傍受を停止し、ネットワークの状態を元に戻してデータの取得を開始します。その後再び更新したいときは手順 2 を繰り返すだけで、URL が失効していなければそのまま適用されます。

### Android

1. 初めて「データ更新」を押すと、ゲームのログファイルを読み取る方法の設定画面が表示されます。root 化された端末や Android 10 以前の端末は直接読み取ります。それ以外の端末はシステム標準の「ワイヤレスデバッグ」を使い、画面の案内に従って一度ペア設定すれば、以降はアプリがワイヤレスデバッグを自動でオン／オフします。
2. 「データ更新」を押したらゲームに切り替え、「集音 → 集音履歴」から集音履歴ページを開きます。
3. アプリがゲームのログファイルから URL を見つけると、自動でデータの取得を開始します。
4. ワイヤレスデバッグが使えない場合（Wi‑Fi に接続していないなど）は、集音履歴の URL を手動で入力することもできます。

## 機能と特長

- Windows と Android に対応
- 集音履歴の URL を自動取得し、手動で貼り付ける必要はありません。Windows 版は鳴潮の集音履歴ページから公式の集音履歴 API へのリクエストを傍受（ローカルの傍受プログラムと自己署名ルート証明書を利用）、Android 版はゲームのログファイルを読み取ります（root、直接読み取り、またはワイヤレスデバッグ）
- グローバルサーバーに対応（中国サーバーには現在未対応）
- 12 種類の集音を網羅：共鳴者集音（イベント）、武器集音（イベント）、共鳴者集音（恒常）、武器集音（恒常）、初心者集音、初心者応援セレクト集音、共鳴者集音（旅立ち）、武器集音（旅立ち）、共鳴者集音（コラボ）、武器集音（コラボ）、共鳴者集音（追憶）、武器集音（追憶）
- 複数アカウント（UID）管理：エイリアスのカスタマイズ、ドラッグでの並べ替え、ワンクリック切り替え
- 新旧データを自動でマージし、過去の記録を上書きしません。公式の履歴が古くなって消えても、記録は失われません
- 総取得数および ★5 / ★4 / ★3 の件数と割合の統計
- ★5 と ★4 それぞれの天井プログレスバー。天井まで残り何回かを表示
- ★5 / ★4 の平均排出回数の統計（集音ごとおよび全体）
- 集音ごとの ★5 タイムライン
- ★5 総覧：これまでに引いたすべての重複しない ★5 を横並びで表示し、それぞれに累計回数のバッジを付け、クリックで詳細を表示。各集音ページ、総合データページ、シェア画像のいずれにも表示されます
- 集音ごとの最高レアリティ件数を比較する棒グラフ
- レアリティ分布の円グラフ
- タイプ分布の円グラフ
- 履歴テーブル：複数列ソート、キーワード検索（名前による）、レアリティとアイテムタイプでの絞り込み、ページネーション
- アイテムアイコンの自動取得（出典：encore.moe API）：共鳴者、武器、アイテムのいずれにもアイコンがあり、テーブル、タイムライン、★5 総覧に対応するアイコンを表示します
- アイテムをクリックして詳細を表示：共鳴者は概要、属性、武器タイプ、および切り替え可能な「衣装」と「募集」の立ち絵を表示（募集の立ち絵は encore がレンダリングした画面をローカルでリアルタイムに取り込んでキャッシュするもので、アートを再配布しません）。武器は概要と武器タイプを表示します
- ワンクリックでシェア画像を生成（ダーク / ライトテーマ、UID をすべて表示するか先頭 3 桁のみ残してマスクするかを選択可能）。クリップボードへのコピーや PNG ファイルとしての保存ができ、Android 版ではシステムの共有機能で直接共有することもできます
- アカウントデータを JSON でエクスポート / インポート
- クラウド同期：ご自身の Google アカウントを連携すると、募集履歴が自動的に Google ドライブへバックアップされ、複数のデバイス間で同期されます。アカウント削除時にクラウドからも削除するよう選択できます
- ダーク / ライトテーマの切り替え
- 多言語対応（[翻訳にご協力ください](https://crowdin.com/project/wuthering-waves-convene-gacha-analyzer)）
- 設定で画面上の UID マスク（先頭 3 桁のみ表示）を有効にでき、プライバシーを保護します
- 起動時に自動で新バージョンをチェック。設定ページから手動で実行することもできます（Android 版は Google Play で更新）
- すべてのデータは既定でローカルに留まり、アップロードされません。クラウド同期は任意機能で、有効にした場合もご自身の Google ドライブにのみバックアップされます
- Android 版には AdMob のネイティブ広告が表示されます（同意が必要な地域では事前に同意を求めます）。Windows 版に広告はありません

## インポートに対応したサードパーティープラットフォーム

本ソフトウェア自身がエクスポートしたバックアップファイルのインポートに加えて、以下のサードパーティープラットフォームからエクスポートした集音履歴データもインポートできます（設定ページ →「他のプラットフォームからインポート」）：

- [WuWa Tracker](https://wuwatracker.com/)
- 今後さらに多くのプラットフォームに対応するかもしれません...

## スクリーンショット

### Windows

![ゲームで集音履歴ページが開かれるのを待機](docs/images/ja-JP/windows/1.png)
![総合データページ](docs/images/ja-JP/windows/2.png)
![共鳴者集音（イベント）ページ](docs/images/ja-JP/windows/3.png)
![武器集音（イベント）ページ](docs/images/ja-JP/windows/4.png)
![シェア画像の生成設定](docs/images/ja-JP/windows/5.png)
![シェア画像](docs/images/ja-JP/windows/6.png)
![アイテム詳細の表示](docs/images/ja-JP/windows/7.png)
![設定ページ](docs/images/ja-JP/windows/8.png)

### Android スマートフォン

<p>
<img src="docs/images/play-store/screenshots/ja/phone/1.png" alt="総合データページ" width="24%">
<img src="docs/images/play-store/screenshots/ja/phone/2.png" alt="共鳴者集音（イベント）ページ" width="24%">
<img src="docs/images/play-store/screenshots/ja/phone/3.png" alt="★5 タイムラインと ★5 一覧" width="24%">
<img src="docs/images/play-store/screenshots/ja/phone/4.png" alt="武器集音（イベント）ページ" width="24%">
<img src="docs/images/play-store/screenshots/ja/phone/5.png" alt="アイテム詳細の表示" width="24%">
<img src="docs/images/play-store/screenshots/ja/phone/6.png" alt="シェア画像の生成設定" width="24%">
<img src="docs/images/play-store/screenshots/ja/phone/7.png" alt="ゲームで集音履歴ページが開かれるのを待機" width="24%">
<img src="docs/images/play-store/screenshots/ja/phone/8.png" alt="設定ページ" width="24%">
</p>

### Android タブレット

<p>
<img src="docs/images/play-store/screenshots/ja/tablet-10/1.png" alt="総合データページ" width="49%">
<img src="docs/images/play-store/screenshots/ja/tablet-10/2.png" alt="共鳴者集音（イベント）ページ" width="49%">
<img src="docs/images/play-store/screenshots/ja/tablet-10/3.png" alt="★5 タイムラインと ★5 一覧" width="49%">
<img src="docs/images/play-store/screenshots/ja/tablet-10/4.png" alt="武器集音（イベント）ページ" width="49%">
<img src="docs/images/play-store/screenshots/ja/tablet-10/5.png" alt="アイテム詳細の表示" width="49%">
<img src="docs/images/play-store/screenshots/ja/tablet-10/6.png" alt="シェア画像の生成設定" width="49%">
<img src="docs/images/play-store/screenshots/ja/tablet-10/7.png" alt="ゲームで集音履歴ページが開かれるのを待機" width="49%">
<img src="docs/images/play-store/screenshots/ja/tablet-10/8.png" alt="設定ページ" width="49%">
</p>

## 開発

### 前提条件

- Windows 版は Windows 上でビルドします。Android 版には別途 [Android Studio](https://developer.android.com/studio)（Android SDK）が必要です
- [Flutter SDK](https://docs.flutter.dev/install)（最新の安定版）
- [Rust toolchain](https://rustup.rs/)（stable）
- `flutter doctor` を実行し、不足しているツールを指示に従って補ってください

### ソースコードの取得と依存関係のインストール

```bash
git clone https://github.com/GoneTone/wuthering-waves-convene-gacha-analyzer.git
cd wuthering-waves-convene-gacha-analyzer
flutter pub get
```

Rust は `flutter run` / `flutter build` の際に `rust_builder/` の cargokit によって自動でコンパイルされるため、手動で `cargo build` する必要はありません（ただし事前に Rust toolchain のインストールが必要です）。

### 開発モードでの実行

```bash
flutter run -d windows        # Windows
flutter run -d <device id>    # Android の実機またはエミュレーター（ID は flutter devices で確認）
```

### クラウド同期の認証情報（任意）

クラウド同期（Google ドライブへのバックアップ）には Google OAuth 認証情報が必要です。未設定でも他の機能には一切影響せず、設定ページのクラウド同期欄に未設定の案内が表示されるだけです。

自分のビルドで有効にするには：

1. [Google Cloud Console](https://console.cloud.google.com/) でプロジェクトを作成し、**Google Drive API** を有効化、OAuth 同意画面を設定（スコープ：`.../auth/drive.appdata` と `email`）し、「**デスクトップ アプリ**」タイプの OAuth クライアントを作成します。
2. プロジェクトルートに `secrets/cloud_sync_defines.json` を作成します（git 管理外）：

   ```json
   {
     "CLOUD_SYNC_CLIENT_ID": "あなたの client id",
     "CLOUD_SYNC_CLIENT_SECRET": "あなたの client secret"
   }
   ```

3. 実行時にこのファイルを渡します（JetBrains IDE では同梱の「main.dart (cloud sync + ads)」実行構成が使えます（後述の `secrets/ads_defines.json` も渡すため、両方のファイルが必要です）。`build_release.ps1` はパッケージ時に自動検出します）：

   ```bash
   flutter run -d windows --dart-define-from-file=secrets/cloud_sync_defines.json
   ```

4. Android でも同じ `secrets/cloud_sync_defines.json` を使いますが、**同じ** Google Cloud プロジェクトに「**Android**」タイプの OAuth クライアントを追加で作成してください。パッケージ名は `tw.reh.wuwa.gacha`、SHA-1 には APK に署名する鍵のフィンガープリントを指定します（開発用の debug 鍵は `keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android` で確認できます）。このクライアントの ID を設定ファイルに入れる必要はありません。Google がパッケージ名と署名で照合します。デスクトップ用クライアントと同じプロジェクトでないと、スマホと PC で別々の同期ファイルを読み書きすることになります。

   ```bash
   flutter run -d <デバイス ID> --dart-define-from-file=secrets/cloud_sync_defines.json
   ```

### 広告 ID（任意、Android）

Android のネイティブ広告の AdMob ID もビルド時に注入し、ソースコードには書きません。自分のビルドで本番広告を配信するには、プロジェクトルートに `secrets/ads_defines.json` を作成し（git 管理外）、クラウド同期の設定ファイルと一緒に渡します：

```json
{
  "ADMOB_APP_ID": "ca-app-pub-xxxxxxxxxxxxxxxx~yyyyyyyyyy",
  "ADMOB_NATIVE_UNIT_ID": "ca-app-pub-xxxxxxxxxxxxxxxx/wwwwwwwwww"
}
```

```bash
flutter run -d <device id> --dart-define-from-file=secrets/cloud_sync_defines.json --dart-define-from-file=secrets/ads_defines.json
```

このファイルがない場合や release 以外のビルドでは、Google 公式のテスト広告 ID を使い、テスト広告のみ表示されます。

### Rust ↔ Dart ブリッジコードの生成

`rust/src/api/` 内の Rust 関数を変更した後、ブリッジコードを再生成します。初回利用前に codegen ツールをインストールしてください：

```bash
cargo install flutter_rust_bridge_codegen --version 2.12.0
```

以降は API を変更するたびに実行します：

```bash
flutter_rust_bridge_codegen generate
```

生成されたファイルは `lib/src/rust/` に配置されます。

### 本番版のビルド

Windows：

```bash
flutter build windows --release
```

出力：`build\windows\x64\runner\Release\`

Android：

```bash
flutter build apk --release        # 直接インストール用の APK
flutter build appbundle --release  # Google Play アップロード用の AAB
```

出力：`build/app/outputs/flutter-apk/app-release.apk`、`build/app/outputs/bundle/release/app-release.aab`

自分の鍵で署名するには、`android/key.properties`（git 管理外）に `storeFile`、`storePassword`、`keyAlias`、`keyPassword` を記入します。このファイルがない場合は debug 鍵で署名されます。

### テストの実行

```bash
flutter test
cargo test --manifest-path rust/Cargo.toml
```
