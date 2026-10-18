# TH.GL Clean Layout

Hide TH.GL's dashboard ad sidebar and the bottom-right ad panel on the **AION 2 interactive map**, while keeping the map and live position tracking intact.

**Windows only · TH.GL Companion App · tested with TH.GL 22.20.0**

No modified executables, game memory access, network blocking, browser extensions, or third-party software installations. Uses **Microsoft Edge WebView2 DevTools Local Overrides** and a small Windows Task Scheduler watchdog.

## Install

1. Download this repo as a ZIP and extract it. Review the scripts before running them.
2. Open **Windows PowerShell 5.1 as Administrator** in the extracted folder, then run:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
   ```

3. In **TH.GL → Settings → Developer Tools**, open **dashboard** DevTools. In **Sources → Overrides**, choose **Select folder for overrides** and select the folder printed by the installer (default: `Documents\THGL-Clean-Layout`). Allow file access and ensure **Local overrides** is checked. If DevTools was minimized automatically, restore it from the Windows taskbar.
4. With AION 2 running, open **aion2 (overlay)** DevTools in the same TH.GL settings. Repeat **Sources → Overrides** setup, using the **same folder**.
5. Refresh dashboard and map once. After that, the auto-start task will reopen/minimize DevTools and refresh the pages when needed. First appearance can take a few seconds.

**The folder selection/permission is a one-time, manual WebView2 security step.** The installer cannot grant it silently. If a source stylesheet changes after a TH.GL update, rerun `install.ps1` and refresh both views.

## What it does

- `clean-layout.css` contains **two narrowly scoped CSS rules**: hide the 360px dashboard ad sidebar and the map's fixed ad panel.
- `install.ps1` fetches the **current common CSS stylesheet from `static.th.gl`**, appends these rules to a local override copy, then registers the **THGL Clean Layout** scheduled task for the current Windows user.
- `watchdog.ps1` checks for TH.GL approximately every 7 seconds. When a relevant DevTools window is missing, it opens it via TH.GL's own **Developer Tools** buttons, refreshes the page and minimizes DevTools.

The downloaded upstream CSS is stored **locally only**; this repository redistributes none of TH.GL's assets. The task runs at **highest available privileges** because TH.GL may run as administrator. Its PowerShell script is stored in **`Program Files\THGL-Clean-Layout`** (administrator-writable), not in the user-writable overrides folder. It only interacts with TH.GL's windows; it does not read your game memory or credentials.

## Uninstall

In an **Administrator PowerShell** window from the extracted repo folder:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
```

This removes the **THGL Clean Layout** task, its protected script, and CSS files managed by this project. In both DevTools windows you can also disable **Sources → Overrides → Local overrides** or revoke the folder permission. No other Task Scheduler tasks or TH.GL installation files are changed.

## Limitations

- The application UI, DevTools labels, ad elements or hashed CSS filenames may change between TH.GL versions; rerun the installer for updated CSS, or update the selectors when necessary.
- DevTools may appear briefly, and the watchdog can cause a **one-time map/dashboard refresh** when it attaches. It requires an unlocked interactive Windows session.
- Confirmed on one Windows setup with TH.GL 22.20.0; **not yet tested across other PCs or releases**. Use at your own risk.
- Community project, **not affiliated with TH.GL**. Check TH.GL's applicable terms before using it.

Licensed under MIT; this license applies only to the files written for this repository.
