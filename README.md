# SilentDrop

Drag an MSI in. Get a silent install out.

I work on endpoint management and app packaging, and almost every MSI I get goes through the same routine: open it in Orca to find the ProductCode, type out the msiexec line, remember `/qn` and `/norestart`, add a log switch, then rename the log so I can actually find it later when something fails. Doing that by hand gets old fast, so I built a small GUI that does it for me.

This is my first project on GitHub, so if you spot something dumb in the code, feel free to open an issue. I'm here to learn.

<img width="698" height="690" alt="image" src="https://github.com/user-attachments/assets/aefb73b2-c5a4-4c84-8d62-e6f70ee647d3" />

<img width="862" height="577" alt="image" src="https://github.com/user-attachments/assets/2040a902-4568-48ce-b019-475ecbecca89" />

<img width="792" height="345" alt="image" src="https://github.com/user-attachments/assets/46366250-f9f1-40e1-bc45-3d0fc74ca595" />



## What it does

- Drop an `.msi` on the window (or use Browse)
- Reads the **ProductName, Version, Manufacturer, ProductCode and UpgradeCode** directly from the MSI database, no Orca needed
- Shows whether that product is already installed on the machine
- Builds the silent install and uninstall commands, with a Copy button for each
- Runs the install or uninstall silently and writes a verbose log to `C:\Temp`
- **Live log tab** shows the msiexec log while it's running, so you're not staring at a spinner wondering if it hung
- Tells you what the exit code means (1603, 1618, 3010 and friends)
- Keeps a running history of everything in `C:\Temp\SilentDrop_History.log`
- **Export .cmd** creates a folder with the MSI plus `Install.cmd` and `Uninstall.cmd`
- **Make .intunewin** turns that folder into a `.intunewin` file for an Intune Win32 app
- **Intune details** shows every field you fill in when you create the app in Intune, in the same order as the portal, including four ready-made detection rules based on what the test install actually did

## The workflow I actually use

1. Spin up a test VM
2. Drop the MSI in, hit **Install**, watch the Live log
3. Check the app works, then hit **Uninstall** and make sure it comes off cleanly
4. Hit **Make .intunewin**. The Intune details window pops up when it's done
5. Create the Win32 app in Intune and go through it page by page, copying values from the window (double-click a row to copy it)

Test results are saved per MSI version, so you can close SilentDrop between steps and it still remembers. It warns you if you try to package something you haven't tested.

## What happens during a test install

The moment a test install succeeds, SilentDrop takes a snapshot of what the MSI actually put on the machine, while it's still there:

- **Add/Remove Programs entry**: where it was registered (normal or WOW6432Node, machine or user), DisplayName, DisplayVersion, InstallLocation, EstimatedSize, UninstallString
- **Files**: asks Windows Installer where each component's key file ended up, then reads the file version of every `.exe`
- **Main exe**: best guess at the app's real exe (skips uninstallers and updaters, prefers one named like the product)
- **Registry key paths** the MSI wrote, decoded into normal `HKEY_LOCAL_MACHINE\...` paths with the 32/64-bit view
- **Logo**: the main exe's icon saved as `logo.png` for the Company Portal

After the uninstall it checks for leftovers: is the ARP entry gone, is the install folder gone.

## Intune details

This is the part I'm most happy with. One window, grouped like the Intune "Add app" wizard:

| Page | What it fills in |
|---|---|
| App information | Name, description, publisher, version, info URL, developer, owner, notes (with test results), logo |
| Program | Install/uninstall commands, install time (based on how long the test took), install behavior (System/User from where it registered), restart behavior, return codes |
| Requirements | Architecture from the MSI template (x86/x64/ARM64), disk space from EstimatedSize, any OS checks the MSI does |
| Detection rules | Four options: **MSI** product code, **Registry** (the real ARP key + 32-bit flag), **File** (main exe + file version), **Custom script** (`Detect.ps1`) |
| Dependencies | Launch conditions from the MSI that hint at prerequisites |
| Supersedence | UpgradeCode, and whether "Uninstall previous version" should be Yes or No |
| Assignments | Sensible starting point |

Anything you still have to decide yourself (category, privacy URL...) shows in orange.

## Making the .intunewin

This uses Microsoft's own [Win32 Content Prep Tool](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool) (`IntuneWinAppUtil.exe`). I don't ship it in this repo since it's Microsoft's tool with its own license. The first time you click **Make .intunewin**, SilentDrop asks whether to download it from Microsoft's GitHub into a `tools` folder, or whether you want to browse to a copy you already have.

What you get:

```
C:\Temp\SilentDrop\Packages\7-Zip_24.08.00.0\     <- source folder
    7z2408-x64.msi
    Install.cmd
    Uninstall.cmd

C:\Temp\SilentDrop\IntuneWin\7-Zip_24.08.00.0\    <- upload this
    7z2408-x64.intunewin
    IntuneDetails.html     <- every Intune field, nice to keep with the package
    IntuneDetails.txt      <- same thing, plain text
    Detect.ps1             <- custom detection script
    logo.png               <- app icon for Company Portal
```

## How to run it

No install, no modules. It's plain PowerShell 5.1, which every Windows 10/11 machine already has.

1. Download or clone this repo
   ```
   git clone https://github.com/Vinay-LazyButSecure/SilentDrop.git
   ```
2. Double-click `SilentDrop.cmd`
3. Drop an MSI on the window

You can also drag an MSI straight onto `SilentDrop.cmd` and it opens with that MSI loaded.

If Windows complains about the script being blocked, right-click `SilentDrop.ps1` → Properties → tick **Unblock**.

> **Don't run it as admin.** The app asks for admin (UAC) only when it actually runs msiexec. There's a reason for this, see "Things I learned" below.

## Where the logs go

Everything lands in `C:\Temp`, named so you can sort and search them easily:

```
C:\Temp\7-Zip_24.08.00.0_Install_20261023_221530.log
C:\Temp\7-Zip_24.08.00.0_Uninstall_20261023_222104.log
C:\Temp\SilentDrop_History.log
```

The pattern is `<ProductName>_<Version>_<Install|Uninstall>_<yyyyMMdd_HHmmss>.log`.

The history file gets one line per run:

```
2026-10-23 22:15:41 | Install   | 7-Zip 24.08 (x64 edition) | 24.08.00.0 | Exit 0 | C:\Temp\7-Zip_24.08.00.0_Install_20261023_221530.log
```

## The commands it builds

Install:

```
msiexec.exe /i "C:\path\app.msi" /qn /norestart /l*v "C:\Temp\App_1.0_Install_<timestamp>.log"
```

Uninstall (uses the ProductCode, so you don't even need the MSI file later):

```
msiexec.exe /x {PRODUCT-CODE-GUID} /qn /norestart /l*v "C:\Temp\App_1.0_Uninstall_<timestamp>.log"
```

| Switch | What it means |
|---|---|
| `/i` | install |
| `/x` | uninstall |
| `/qn` | no UI at all (the "silent" part) |
| `/norestart` | never reboot on its own, even if it wants to |
| `/l*v` | log everything, verbose |

## Exit codes you'll run into

| Code | Meaning |
|---|---|
| 0 | Success |
| 3010 | Success, but a restart is needed |
| 1603 | Fatal error. Open the log and search for `return value 3`, the real error is usually a few lines above it |
| 1605 | Product isn't installed (common when uninstalling twice) |
| 1618 | Another install is already running. Wait and retry |
| 1619 | MSI couldn't be opened (bad path, or the file is blocked) |
| 1638 | A different version is already installed |

## Things I learned building this

Writing these down because each one cost me some time.

- **Drag and drop doesn't work in an elevated window.** Windows blocks drag and drop from a normal Explorer window into an app running as admin (it's called UIPI). So the GUI runs as a normal user and only `msiexec` gets elevated with `-Verb RunAs`. If you do launch it as admin, it now warns you and offers to restart itself as a normal user (launching through `explorer.exe` drops the admin rights). The Browse button works either way.
- **Drop events don't bubble up in WinForms.** My first version only listened for drops on the form, so dropping on any textbox did nothing. Version 1.0.1 hooks every control on the window.
- **The MSI stays locked unless you release the COM objects.** Reading the MSI through `WindowsInstaller.Installer` leaves a handle open, and you can't move or delete the file until the app closes. Releasing every COM object plus a `[GC]::Collect()` fixed it.
- **`ExitCode` can come back empty.** With `Start-Process -PassThru` and no `-Wait`, PowerShell sometimes loses the exit code. Touching `$proc.Handle` right after starting the process fixes it. Weird, but it works.
- **Reading a file that's still being written.** msiexec keeps its log open, so a normal read fails with "file in use". Opening it with `FileShare.ReadWrite` and calling `ReadToEnd()` on a timer gives you a live tail. The log is UTF-16, and the StreamReader picks that up from the first two bytes.
- **Asking Windows Installer where files went.** Instead of guessing install paths, `Installer.ComponentPath(productCode, componentId)` gives the exact installed location of every component's key file. Registry components come back as `02:\SOFTWARE\...` where the number is the hive (0 HKCR, 1 HKCU, 2 HKLM, 3 HKU) plus 20 for the 64-bit view.
- **Intune doesn't want WOW6432Node in registry rules.** You give it the normal path and tick "Associated with a 32-bit app on 64-bit clients". SilentDrop sees where the ARP key really landed and sets that flag for you.
- **`0..-1` is not an empty range in PowerShell.** It means "item 0 and the last item". That one gave me duplicated lines in the live log for a while.
- **Don't use `-Wait` in a GUI.** It freezes the whole window. A timer that checks `HasExited` once a second keeps everything responsive.
- **`.cmd` files hate UTF-8 with BOM.** The first line breaks. The exported scripts are saved as ANSI for that reason.
- **`%DATE%` in batch depends on regional settings**, so the exported scripts call PowerShell for a clean timestamp instead.

## Known limitations

- MSI only. EXE installers each have their own silent switches, so that's a different problem.
- No transform (`.mst`) support yet.
- No custom properties (like `ALLUSERS=1` or license keys) yet.
- Log folder is fixed to `C:\Temp`.
- Only tested on Windows 10 and 11 with Windows PowerShell 5.1.

## Ideas for later

- [ ] Add `.mst` transform support
- [ ] Box for extra MSI properties
- [ ] Let you pick the log folder
- [ ] Generate a PSADT (PowerShell App Deployment Toolkit) script
- [x] ~~Detection rule output for Intune~~ (done in 1.1.0)
- [x] ~~Live log while installing~~ (done in 1.1.0)
- [x] ~~Full Intune field list with detection options~~ (done in 1.2.0)
- [ ] Upload straight to Intune with Microsoft Graph
- [ ] Dark mode, because why not

## Project files

```
SilentDrop/
├── SilentDrop.ps1    # the app
├── SilentDrop.cmd    # double-click launcher
├── lib/
│   ├── Msi.ps1           # reads the MSI, snapshots the installed app
│   └── IntuneDetails.ps1 # Intune fields, reports, details window
├── tools/            # IntuneWinAppUtil.exe lands here (not committed)
├── README.md
├── CHANGELOG.md
├── LICENSE
└── .gitignore
```

## Disclaimer

This runs real installs and uninstalls on the machine you use it on. Test on a VM or a test device first, not on your daily laptop or a production server.

## License

MIT. Use it, change it, break it. See [LICENSE](LICENSE).

---

## About me

I'm **Vinay Kumar Kamtam**. I work on endpoint management, application packaging and development, and cybersecurity. SilentDrop started as a way to stop doing the same boring steps for every MSI, and turned into my first proper project.

- LinkedIn: [linkedin.com/in/kamtamvinaykumar](https://www.linkedin.com/in/kamtamvinaykumar/)
- GitHub: [github.com/Vinay-LazyButSecure](https://github.com/Vinay-LazyButSecure)

If this saved you some time, a star on the repo would make my day, and I'm always happy to connect on LinkedIn.
