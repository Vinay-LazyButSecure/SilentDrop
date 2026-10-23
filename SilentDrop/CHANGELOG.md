# Changelog

## 1.3.0 - 2026-10-23

- Credits: author name in the window title, a footer with LinkedIn and GitHub links, and an About box.
- Generated Install.cmd, Uninstall.cmd, Detect.ps1 and the Intune reports now say where they came from.
- README has an About me section.

## 1.2.0 - 2026-10-23

- New: **Intune details** window. Every field for an Intune Win32 app, grouped like the portal (App information, Program, Requirements, Detection rules, Dependencies, Supersedence, Assignments). Double-click to copy.
- New: four detection rule options worked out for you: MSI, Registry, File, and a generated `Detect.ps1` custom script.
- New: install snapshot. After a successful test install SilentDrop records the ARP registry entry, install location, exe files and versions, registry key paths, and extracts the app icon as `logo.png`.
- New: leftover check after uninstall (ARP entry and install folder).
- New: `IntuneDetails.html` and `IntuneDetails.txt` saved next to the .intunewin (replaces `IntuneInfo.txt`).
- New: test results and snapshots are saved per MSI version in `C:\Temp\SilentDrop\State`, so they survive closing the app.
- Reads more from the MSI: architecture (x86/x64/ARM64), ALLUSERS, info URL, launch conditions, upgrade table, shortcuts.
- Moved MSI and Intune code into `lib\` to keep the main script readable.

## 1.1.0 - 2026-10-23

- New: **Live log** tab. Streams the msiexec log while the install or uninstall runs. "Only important lines" filters the noise, untick it to see everything.
- New: warns in the Activity tab the moment `Return value 3` shows up in the log.
- New: **Make .intunewin** button. Exports the package folder and runs Microsoft's IntuneWinAppUtil.exe on it. Downloads the tool on first use if you don't have it.
- New: `IntuneInfo.txt` next to the .intunewin with the install/uninstall commands and MSI detection rule to paste into Intune.
- Packaging warns you if you haven't had a successful install and uninstall of that MSI yet.
- Window is a bit taller to fit the new tabs.

## 1.0.1 - 2026-10-23

- Fixed: drag and drop only worked on the blue drop box. You can now drop an MSI anywhere on the window.
- Fixed: when started as admin, drag and drop silently did nothing. The app now says so and offers to restart itself as a normal user.

## 1.0.0 - 2026-10-23

First release.

- Drag and drop MSI onto the window, or drop it on `SilentDrop.cmd`
- Reads product details from the MSI database
- Builds silent install / uninstall commands with copy buttons
- Runs msiexec elevated, logs to `C:\Temp` with app name, version and timestamp
- Explains common msiexec exit codes
- History log in `C:\Temp\SilentDrop_History.log`
- Exports `Install.cmd` / `Uninstall.cmd` with the MSI into a package folder
