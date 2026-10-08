# Gemini Usage Monitor

**Windows taskbar display for Gemini usage. Runs on its own.**

[日本語](#日本語) · [English](#english)

## 日本語

Gemini Usage Monitor は、Gemini の使用状況ページを読み取り、5時間枠と週次枠の残量・リセットまでの時間を Windows タスクバーに表示する個人開発の Windows アプリです。別の Usage Monitor アプリは必要ありません。横に公式の Usage Monitor がある場合は隣へ並び、ない場合はタスクバーの空き領域を使います。

動画専用の利用枠や「残り何回」は Gemini の使用状況ページから識別できないため表示しません。動画生成も消費する共通枠の残量を表示します。

### インストール

1. [GitHub Releases](https://github.com/tamakichi23/Gemini-Usage-Monitor/releases/latest) から `GeminiUsageMonitor-*.msi` をダウンロードして実行します。
2. Windows のスタートメニューから **Gemini Usage Monitor** を起動します。
3. 通知領域アイコンのメニューから **Googleアカウントを切り替える** を選び、専用 Chrome で Google にログインします。初回ログイン後、専用 Chrome のウィンドウを閉じると取得を開始します。

必要環境は Windows 10/11 x64、Node.js 22 以降、Google Chrome です。Google のサインイン情報は専用 Chrome プロファイルに保存されます。通常の Chrome プロファイルには触れません。

### 操作と更新

通知領域アイコンのメニューから、バーの表示、自動起動、Google アカウント切り替え、使用状況ページを操作できます。Windows の **設定 → アプリ → インストールされているアプリ** からアンインストールできます。更新時は新しい MSI を上書きインストールします。

### 取得情報と保存先

- `https://gemini.google.com/usage` の表示済みページから、5時間枠・週次枠の使用率、残量、リセット表示を取得します。
- 取得間隔は5分です。残量があり、リセットが30分以内に迫った場合は Windows 通知を1回表示します。
- 取得値と専用 Chrome プロファイルは PC 内に保存され、アプリの作者へ送信されません。
- 新規利用の保存先は `%LOCALAPPDATA%\GeminiUsageMonitor` です。旧版の `%LOCALAPPDATA%\GeminiUsagePoC` に専用 Chrome プロファイルがある場合は、そのプロファイルを継続利用します。
- アンインストールではアプリ本体を削除し、ログイン状態と使用量データは残します。完全に削除する場合は、上記の保存先を手動で削除してください。

Gemini の画面構造が変わると取得できなくなる場合があります。[Google の利用規約](https://policies.google.com/terms?hl=ja)とアカウントのルールに従って利用してください。本アプリは Google の公式製品ではありません。現在の MSI はコード署名されていないため、Windows が発行元を確認できない旨を表示する場合があります。

### ソースからビルド

Windows、Node.js 22 以降、.NET Framework C# compiler、WiX Toolset 3 が必要です。

```powershell
cd collector
npm ci --ignore-scripts
npm test
cd ..
powershell -NoProfile -ExecutionPolicy Bypass -File .\build-gemini-addon-msi.ps1
```

MSI は `target\GeminiUsageMonitor-<VERSION>.msi` に作成されます。リリースは `v<VERSION>` タグを push すると GitHub Actions がテスト、MSI ビルド、GitHub Release 作成を行います。バージョン更新時は `VERSION`、C# のアセンブリバージョン、`RELEASE_NOTES.md` も更新してください。

## English

Gemini Usage Monitor is an independently runnable Windows app that reads the
Gemini usage page and displays the five-hour and weekly remaining quotas and
reset times on the taskbar. If Claude Code Usage Monitor is present, the bar
can sit beside it; otherwise it uses a free taskbar slot.

The Gemini usage page does not expose a separate video quota or remaining
generation count, so the app shows only the shared quota used by video
generation as well as other Gemini activity.

Download the latest MSI from [GitHub Releases](https://github.com/tamakichi23/Gemini-Usage-Monitor/releases/latest),
install it, and start **Gemini Usage Monitor** from the Start menu. Use the tray
menu's **Googleアカウントを切り替える** command to sign in through its
dedicated Chrome profile. Node.js 22 or later and Google Chrome are required.

Usage snapshots and the dedicated browser profile stay on the PC. The app polls
every five minutes, and uninstalling preserves that local data. New installs
store it under `%LOCALAPPDATA%\GeminiUsageMonitor`; existing installations can
continue using their legacy profile. This project is not affiliated with
Google.

See the Japanese section above for build and release instructions.
