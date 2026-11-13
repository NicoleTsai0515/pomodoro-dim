# 番茄鐘護眼 Pomodoro Dim

> Mac menu-bar Pomodoro timer. Every 25 minutes, all your screens fade into a calm green "breathing orb" screen and make you rest for 5 minutes. Free, open source (MIT).

工作 25 分鐘後，**所有螢幕蓋上柔和的深綠暗幕、強制休息 5 分鐘**，中央一顆光球跟著呼吸慢慢漲縮（吸氣 4 秒、吐氣 4 秒）。休息結束響鈴，自動開始下一輪。

## 特色
- 休息時**所有螢幕**（含 iPad 副螢幕 Sidecar）一起變暗，不需要任何系統權限
- 平面光球加超柔和漸層，邊緣羽化；細黑體大倒數，標題與小字像雜誌排版
- 光球跟著呼吸節奏漲縮，畫面上同步顯示「吸氣／吐氣」，休息就真的在放鬆
- **想偷懶要長按 5 秒**才能提早結束；跳過的休息會補到下一輪（最多補 5 分鐘）
- 每 4 輪一次 15 分鐘長休息
- 工作 15／25／30／45／50 分鐘、休息 3／5／10／15 分鐘都能選，會記住
- 只在選單列顯示 🍅 倒數，不佔 Dock；可設定隨開機開啟
- 系統開了「減少動態效果」時，不播放呼吸動畫
- 蘋果晶片與 Intel Mac 都能跑（macOS 12 以上；隨開機開啟需 macOS 13 以上）

## 下載與安裝（一分鐘）
1. 下載最新版：**[PomodoroDim.zip](https://github.com/NicoleTsai0515/pomodoro-dim/releases/latest/download/PomodoroDim.zip)**（也可到 [Releases](https://github.com/NicoleTsai0515/pomodoro-dim/releases/latest) 頁面）
2. 雙擊解壓縮，把「番茄鐘護眼」拖進「應用程式」資料夾
3. **第一次打開**：對它按右鍵（或 Control＋點一下）→「打開」→ 再按一次「打開」

### 為什麼第一次會被 Mac 擋？
這個 app 沒有付費的 Apple 開發者簽章與公證，所以 macOS 會跳「無法驗證開發者」。這是正常的，原始碼就在這個 repo 裡，歡迎自己檢查、自己編譯。

如果右鍵打開還是被擋，可以：
- 系統設定 → 隱私權與安全性 → 往下找到「仍要打開」；或
- 開終端機貼上這行（移除「從網路下載」的標記）：

```bash
xattr -dr com.apple.quarantine /Applications/番茄鐘護眼.app
```

### 隨開機開啟
選單列點 🍅 → 勾選「隨開機開啟」（app 要放在「應用程式」資料夾；需 macOS 13 以上）。

## 選單說明
點選單列的 🍅：暫停／繼續（只有工作中能暫停）、現在就休息、重新開始工作計時、工作時間、休息時間、隨開機開啟、結束。

## 自己編譯
需要 Xcode Command Line Tools（`xcode-select --install`）：

```bash
git clone https://github.com/NicoleTsai0515/pomodoro-dim.git
cd pomodoro-dim
./build.sh
```

會產生蘋果晶片＋Intel 通用的 `番茄鐘護眼.app`。想快速看效果，可以用短時間測試（單位分鐘，可小數）：

```bash
番茄鐘護眼.app/Contents/MacOS/Pomodoro --work 0.1 --rest 0.3
```

其他測試旗標：`--hold 秒`（長按幾秒）、`--long 分鐘`、`--every 輪數`、`--debug`、`--login on|off|status`。

## 已知限制
- 「調暗」是蓋一層全螢幕暗幕，不是改螢幕硬體亮度（外接螢幕與 iPad 本來就改不了亮度）；暗幕不是 100% 不透明，底下視窗會隱約可見。
- 休息中滑鼠點不到底下的視窗，但 `⌘Tab` 仍可切換 app（畫面還是被蓋住）。
- 沒有付費簽章，第一次要手動允許（見上）。

## 授權
[MIT License](LICENSE)。
