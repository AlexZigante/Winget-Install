# Winget-Install (Alex / WIP v2) – BurntToast from PSGallery

This version:

- Uses WinGet for fully silent install/uninstall.
- Logs per app under `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\<PackageIdentifierSanitized>`.
- Uses BurntToast for interactive status where possible, but:
  - Installs BurntToast from PSGallery at runtime if missing.
  - Removes the module afterwards if it was installed in this run.
- Detection script also uses BurntToast (best-effort) for visibility when run in user context, while still following Intune's custom detection rules.
