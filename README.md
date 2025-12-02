# Winget-Install (Alex / WIP v4) – Detailed return codes

## Install / Uninstall program return codes (Intune Win32App)

Standard installer codes (Intune defaults):
- 0    : Success
- 1707 : Success, no action (MSI)
- 3010 : Soft reboot required
- 1641 : Hard reboot required
- 1618 : Retry (another installer in progress)

Custom WIP failure codes:
- 1000 : Unknown fatal error (top-level catch)
- 1001 : winget.exe not found (Get-WingetPath failed)
- 1002 : Script precondition/parameter error (e.g. missing AppIDs)
- 1003 : WinGet INSTALL failed (non-standard exit code from `winget install`)
- 1004 : Post-install mod script error
- 1005 : WinGet UNINSTALL failed (non-standard exit code from `winget uninstall`)

Raw winget exit codes are still logged in the transcript alongside the mapped exit code.

## Detection internal codes (for logs only)

Intune custom detection scripts only use 0 vs non-zero to decide "installed". We still log
more granular detection codes to help triage:

- 2000 : Unknown detection error (top-level)
- 2001 : winget.exe not found
- 2002 : 'winget list' failed
- 2003 : App not present in 'winget list' (not installed)
- 2004 : 'winget upgrade' indicates an update available (installed but not compliant)
- 2005 : Installed and up to date (detected)

The detection script always exits:
- 0 for installed & compliant (and prints "Detected: Code 2005")
- 1 for all other cases (and prints "NotDetected: Code 20xx")
