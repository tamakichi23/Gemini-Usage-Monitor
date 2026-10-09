# Gemini Usage Monitor 0.1.12

Display and refresh improvements.

- Widen the taskbar display so longer reset labels such as `~100% · 59m` fit completely.
- Add an **今すぐ更新** command to the notification-area menu. It signals the existing collector to refresh immediately without launching a second Chrome process.
- Keep the existing Gemini quota display, account switching, startup controls, and local profile behavior.

Requires Windows 10/11 x64, Node.js 22 or later, and Google Chrome. The installer is currently unsigned.

The Gemini usage page exposes a shared quota, not a separate video-generation limit; the app continues to display the shared five-hour and weekly quotas.
