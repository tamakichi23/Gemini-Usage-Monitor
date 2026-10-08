# Gemini Usage Monitor Collector

Geminiの使用量を取得する独立モジュールです。別のUsage Monitorアプリがなくても動作し、タスクバー表示とWindows通知は親フォルダの `start-gemini-addon.ps1` が担当します。

## 開発・確認

Windows、Node.js 22以上、インストール済みChromeを使います。

```powershell
npm ci --ignore-scripts
npm test
node cli.mjs login
node cli.mjs collect
node cli.mjs watch --interval 300
```

`login` は最初の一度だけ専用Chromeを開き、ユーザーがGoogleにログインします。`collect` と `watch` は画面を表示せず、専用プロファイルを使います。Google側の再認証が必要になった場合は `auth_required` になります。

## 取得データ

新規利用ではデータを `%LOCALAPPDATA%\GeminiUsageMonitor` に保存します。旧バージョンの `%LOCALAPPDATA%\GeminiUsagePoC` に専用Chromeプロファイルがある場合は、そのサインイン状態とデータを引き続き使います。どちらの場所も配布物には含めません。

- `session`: 現在の5時間枠の使用率、残量、リセット時刻。
- `weekly`: 週次枠の使用率、残量、リセット時刻。
- `captured_at` / `last_success_at`: 今回と最後に成功した取得日時。
- `status` / `stale`: 成否と値の鮮度。
- `reset_text` / `reset_precision` / `timezone`: 画面に出た原文と、日時解釈の精度・タイムゾーン。

取得元は `https://gemini.google.com/usage` の `gxu-currently` / `gxu-weekly` カードです。動画専用枠や生成回数は識別せず、共通枠の残量を保持します。カードや日時を解釈できない場合は `null` のままにし、0%や100%を推測で埋めません。失敗時は直近の成功値をstaleとして残します。

## パッケージ

リポジトリ直下の `package-gemini-addon.ps1` が、collector本体と固定した `playwright-core` 依存をZIPへまとめます。Geminiの使用量はUsageページの表示済みDOMから読み取り、動画専用枠や生成回数は推測しません。
