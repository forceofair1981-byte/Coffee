# 焙煎ノート（iOS / iPadOS）

コーヒー豆ごとの焙煎条件、1分ごとの温度、酸味・苦味を記録して振り返るSwiftUIアプリです。

## 主な機能

- 豆の種類を記録し、次回以降は登録済みの豆から選択
- 焙煎温度・焙煎時間と、酸味・苦味（各10段階）を記録
- 焙煎タイマーと、経過分ごとの温度入力
- 豆ごとの日別平均温度・時間グラフ、焙煎履歴と温度推移グラフ
- JSONバックアップと復元
- コーヒー用品・消耗品の商品ページへのリンク
- データは端末内に保存

## Xcodeで開く

1. `CoffeeRoastLog.xcodeproj` をMacのXcodeで開きます。
2. `CoffeeRoastLog` schemeを選び、iPhoneまたはiPadシミュレータを指定します。
3. Signing & Capabilitiesでご自身のApple Developer Teamを設定して実機またはTestFlight向けにビルドします。

iOS 17以降を対象にしています（SwiftUI Chartsを利用）。このリポジトリはソースとXcodeプロジェクトを含みます。署名済みアプリの配布にはApple DeveloperアカウントとXcodeでの署名が必要です。
