<div align="center">

# TH.GL Clean Layout

**Universal ad-panel layout fix for TH.GL Companion on Windows.**

Automatically detects the active game and hides TH.GL's standard dashboard and game-overlay ad panels using local CSS overrides.

<p>
  <img src="https://img.shields.io/badge/Platform-Windows-334155?style=flat-square" alt="Windows" />
  <img src="https://img.shields.io/badge/PowerShell-5.1-334155?style=flat-square" alt="Windows PowerShell 5.1" />
  <a href="https://github.com/Kubuzer/thgl-clean-layout/actions/workflows/tests.yml"><img src="https://github.com/Kubuzer/thgl-clean-layout/actions/workflows/tests.yml/badge.svg?branch=main" alt="Regression tests" /></a>
  <img src="https://img.shields.io/badge/License-MIT-155e63?style=flat-square" alt="MIT license" />
</p>

</div>

> [!IMPORTANT]
> **Visual hiding, not ad blocking.** Advertising requests may still occur. This tool does not unlock paid features or modify TH.GL or game executables.

| Dashboard | Active game overlay |
|:--|:--|
| Hides the advertising sidebar and reclaims its space. | Hides the small or large bottom-right advertising panel, including **Get AD Free**. |
| Navigation remains available. | Map controls and player tracking are not changed by the CSS. |

The same detection and CSS rules are used across games; there is no game list to maintain. **One active game overlay is supported at a time.** Compatibility depends on TH.GL continuing to use its shared overlay layout and stylesheet.

## Requirements

- Windows with **Windows PowerShell 5.1**. No Python, Node.js, or PowerShell 7 is needed to use the tool.
- TH.GL Companion already installed, with a working overlay for your game.
- Administrator access **on the same Windows account that runs TH.GL**. Do not install using another account's administrator credentials: the folder and logon task belong to the installing account.
- Internet access during installation and updates. The watchdog needs an unlocked, interactive Windows session.

## First-time setup

**1. Download and extract.** [Download the ZIP](https://github.com/Kubuzer/thgl-clean-layout/archive/refs/heads/main.zip), use **Extract All**, and review the scripts. Keep the extracted folder for updates and removal. If another script manages TH.GL DevTools, stop it and disable its autostart first, preserving its files.

**2. Prepare the shell.** Fully quit TH.GL from its system tray menu and close its DevTools, saving any work first. Open **Windows PowerShell as administrator** using your usual Windows account. Change to the extracted folder containing `install.ps1`; replace the example path below with its actual full path:

```powershell
Set-Location -LiteralPath 'C:\full\path\to\thgl-clean-layout-main'
```

**3. Install.** Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

Continue only after the installer reports success. **If it reports an error, stop here and read it; do not continue setup.** The installer prints the absolute Overrides folder to use.

**4. Pause the task for setup.** After installation succeeds, run:

```powershell
Stop-ScheduledTask -TaskName 'THGL Clean Layout' -TaskPath '\'
```

This keeps the watchdog from moving, minimizing, or closing DevTools while you configure folder access.

**5. Connect the dashboard.** Start TH.GL, then open **Settings > Developer Tools > dashboard**. In DevTools:

1. Select **Sources**.
2. In the **left-side Navigator**, select **Overrides**. If it is hidden, use the small **More tabs** arrow beside **Page / Workspace**.
3. Choose **Select folder for overrides**, select the **folder printed by the installer**, and approve **Allow**. The usual location is `Documents\THGL-Clean-Layout`; redirected Documents folders can differ.
4. Leave **Local overrides** enabled.

**Do not drag, upload, or add individual files.** The installer already created the CSS. Select the folder itself, not the stylesheet inside it. If the correct folder is already selected, keep it. If it points elsewhere, use **Clear configuration** and select the correct folder.

**6. Connect the active overlay.** Start your game and show its TH.GL overlay. In **TH.GL > Settings > Developer Tools**, open the running game's **`<game> (overlay)`** entry. Check **Sources > Overrides** there too, using the **same folder**. A shared profile may already have this configured; a new profile may need **Allow** once. Close the DevTools windows after setup, reviewing any unsaved-changes warning yourself.

**7. Resume and verify.** In the same Administrator Windows PowerShell window, run:

```powershell
Start-ScheduledTask -TaskName 'THGL Clean Layout' -TaskPath '\'
Get-ScheduledTask -TaskName 'THGL Clean Layout' -TaskPath '\' | Select-Object TaskName, State
```

The state should be **Running**. Leave TH.GL and the overlay open and avoid switching windows while the watchdog attaches. DevTools opens briefly, each view reloads, and DevTools closes after the CSS is confirmed. The advertisement should disappear while the map remains usable.

**Running alone is not proof that CSS was applied.** Check the log:

```powershell
Get-Content -LiteralPath (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'THGL-Clean-Layout\watchdog.log') -Tail 20
```

Look for both messages, with your game's actual identifier:

```text
CSS confirmed; closed DevTools dashboard
CSS confirmed; closed DevTools apps/<game>/overlay
```

On later logons, the task starts automatically. It detects the active overlay, confirms the loaded CSS, and closes DevTools without a per-game configuration file. Reused profiles keep their folder access.

## Updates, inspection, and removal

**Update:** quit TH.GL and close DevTools after saving any work. Extract the latest ZIP into a separate folder, open Administrator Windows PowerShell there under the same account, and run `install.ps1` again. The installer updates the managed files and restarts the task. Start TH.GL again; retain the existing Overrides folder selection.

**Inspect DevTools:** pause the task with the `Stop-ScheduledTask` command above before opening DevTools for manual work. Resume it with `Start-ScheduledTask` when finished; the watchdog also closes manually opened DevTools after CSS confirmation.

**Uninstall:** quit TH.GL and close DevTools. In Administrator Windows PowerShell, change to the extracted source folder and run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
```

This removes the scheduled task and managed installation files. TH.GL itself is unchanged. Legacy backups and unrelated files are preserved. You may clear the Overrides folder selection in DevTools afterward.

If update or uninstall reports a modified or unrecognized file, preserve your changes and resolve the error before retrying. The installer deliberately refuses to discard unknown changes.

## Troubleshooting

| Symptom | What to check |
|:--|:--|
| Advertisement remains visible | Confirm the task is Running, then check the log and the active overlay's Overrides folder. Startup can require retries; completed views are not reloaded on every check. |
| No game overlay entry | Open a supported game's TH.GL overlay first. Keep one eligible map/overlay window open; multiple windows or game buttons are treated as ambiguous. |
| DevTools stays open or minimized | CSS or Console confirmation has not completed. Check folder access, close DevTools and fully quit TH.GL, then restart it. After an upstream layout/stylesheet change, update the tool. |
| **Leave site?** warns about unsaved changes | Review those changes. Choose **Leave** yourself only if you want to discard them, or **Cancel** to retain them. The watchdog does not dismiss this warning automatically. |
| Advertisement returns after a reload or game switch | Restart TH.GL to reapply the CSS. If a game reuses the same window, opening **Settings** can expose its new game button for discovery. |

The log is `watchdog.log` in the folder printed by the installer. One previous log is retained as `watchdog.log.1`. For a bug report, include your TH.GL version, game identifier, what happened, and the relevant log lines after reviewing them for personal information.

## Compatibility and limits

- Manual acceptance: **one Windows 11 PC, TH.GL 23.23.0, Loftia**. Ad hiding, map operation, automatic DevTools closing, and overlay hide/show were checked. Other game identifiers have regression coverage; every game has not been manually tested.
- Universal discovery applies to TH.GL's **shared overlay layout**. The tool selects a dashboard stylesheet currently shared by the tested overlay. A different layout or stylesheet may need an update; missing CSS confirmation leaves DevTools open instead of claiming success.
- Closing DevTools preserves the loaded document's styling. A later navigation or manual reload in the same window may lose Overrides. Restart TH.GL to reapply them.
- The watcher waits two seconds between checks, with longer delays after failures. It reloads a new view once; initial ads and a brief focus change can occur during attachment.
- Installation uses the account's Documents folder, an administrator-protected watchdog in `Program Files\THGL-Clean-Layout`, and the **THGL Clean Layout** logon task. Managed paths must be ordinary filesystem directories, without symbolic links or junctions.

This is an unofficial community project, not affiliated with or endorsed by TH.GL. Review the scripts and TH.GL's applicable terms before using it.

<details>
<summary>Development and verification</summary>

Run commands from the repository root. The installer tests require Python 3, using only its standard library. Launch them from Windows PowerShell 5.1 so child processes inherit the correct module paths. Supply the installed engine you want to test:

```text
python tests/test_install.py --pwsh powershell.exe
python tests/test_install.py --pwsh pwsh
```

Watchdog fixtures use inert Windows APIs; they do not operate real windows or send keys. PowerShell 7 is required for the following command:

```text
pwsh -NoLogo -NoProfile -NonInteractive -File tests/Test-Watchdog.ps1
```

CI runs the installer suite on Windows PowerShell 5.1 and PowerShell 7, plus watchdog fixtures on PowerShell 7. These checks do not replace manual Overrides permission, game UI, or logon acceptance.

Live staging downloads the current stylesheet into an isolated folder without registering a task or starting the watchdog:

```powershell
$qaRoot = Join-Path $env:TEMP ('THGL-QA-' + [Guid]::NewGuid().ToString('N'))
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -StageOnly -InstallRoot $qaRoot
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -StageOnly -Uninstall -InstallRoot $qaRoot
```

The installer validates paths, manifests, response types and file hashes, writes through temporary files, and attempts rollback on caught errors. Logging is bounded and does not append through pre-existing filesystem links. Recovery from forced termination or power loss is not guaranteed. Manifest hashes detect edits; they do not authenticate a user-writable directory.

The upstream stylesheet is downloaded locally and is not redistributed in this repository. [Microsoft Edge Overrides documentation](https://learn.microsoft.com/en-us/microsoft-edge/devtools/sources/).

</details>

<sub>License: [MIT](LICENSE) applies to this repository's original files only.</sub>