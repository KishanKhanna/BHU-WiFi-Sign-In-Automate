# BHU Wi-Fi Auto Login (Windows)

Automatically logs you in to the **BHU-WiFi** captive portal on a Windows laptop, so you don't have to re-enter your username and password every 24 hours.

- Logs in by itself when you connect to BHU-WiFi (also after sleep, hibernate, or boot)
- Re-checks every 15 minutes, so the 24-hour session expiry is handled too
- Only runs on the BHU network and does nothing on any other Wi-Fi
- Stores your password in **Windows Credential Manager**, never in the script
- Has a double-click desktop shortcut for manual login

> **Disclaimer:** This is an unofficial, personal project. It is not affiliated with or endorsed by BHU. Use it only with your own credentials, and follow the university's IT and network policies.

---

## How it works

1. The script checks `http://connectivitycheck.gstatic.com/generate_204`. If it returns `204`, you already have internet and the script exits.
2. It checks that the BHU portal (`10.40.51.37`) is reachable. If not, you're not on BHU Wi-Fi and it exits.
3. It reads your username and password from Windows Credential Manager.
4. It sends the login form to the guest portal, then forwards the response to the Aruba controller (a two-step login).
5. It checks the connectivity URL again to confirm that login worked.

---

## Requirements

- Windows 10 or 11
- PowerShell 5.1 (built in, nothing to install)
- A BHU-WiFi account (username and password)

---

## Setup (step by step)

### Step 1: Download the script

Download `bhu-login.ps1` from this repo and save it somewhere permanent, for example:

```
C:\Users\<YourName>\bhu-login.ps1
```

> Don't move, rename, or delete it later. The scheduled task and the shortcut both point to this exact path.

### Step 2: Save your credentials securely

Pick **one** of the two methods below. Both create the same entry.

> The entry must be a **generic** credential and its name must be exactly `BHU-WiFi-Test`. A normal "Windows credential" (domain type) hides the password from scripts and the login fails with "Credential password blob is empty".

#### Method A: PowerShell command

Open **PowerShell** (normal, not Admin) and run:

```powershell
cmdkey /generic:BHU-WiFi-Test /user:YOUR_USERNAME /pass
```

- Replace `YOUR_USERNAME` with your BHU Wi-Fi username.
- After `/pass` write nothing. PowerShell will ask for the password, so type it there. Special characters like `^ & % "` work fine this way.

#### Method B: Windows Credential Manager (GUI)

1. Press the Windows key, type **Credential Manager**, and open it (Control Panel).
2. Click **Windows Credentials**.
3. Click **Add a generic credential** (not "Add a Windows credential").
4. Fill in the three fields:
   - **Internet or network address:** `BHU-WiFi-Test`
   - **User name:** your BHU Wi-Fi username
   - **Password:** your BHU Wi-Fi password
5. Click **OK**.

To change or remove it later, find `BHU-WiFi-Test` under **Generic Credentials** in the same window, expand it, and click **Edit** or **Remove**.

#### Check that it was saved

```powershell
cmdkey /list
```

You should see `Target: BHU-WiFi-Test` (type: Generic).

### Step 3: Allow the script to run

The commands below use `-ExecutionPolicy Bypass`, so you don't need to change any system settings.

### Step 4: Test it manually

Connect to BHU-WiFi (without logging in on the portal), then run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\bhu-login.ps1"
```

Expected output:

```
=== BHU Wi-Fi Login ===
Checking BHU connectivity...
Login required.
...
 BHU AUTHENTICATION SUCCESSFUL
```

If you're already logged in you'll just see `Already authenticated.`, which is also fine. If something fails, see [Troubleshooting](#troubleshooting).

### Step 5: Make it run automatically

Run this once in PowerShell (no Admin needed). If your script is not at `%USERPROFILE%\bhu-login.ps1`, change `$script`.

```powershell
Unregister-ScheduledTask -TaskName "BHU-WiFi-Login" -Confirm:$false -ErrorAction SilentlyContinue

$script = "$env:USERPROFILE\bhu-login.ps1"

$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""

# Trigger 1: whenever you connect to BHU-WiFi (also after sleep/hibernate resume)
$cls = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
$tEvent = New-CimInstance -CimClass $cls -ClientOnly
$tEvent.Enabled = $true
$tEvent.Delay = "PT5S"
$tEvent.Subscription = @'
<QueryList><Query Id="0" Path="Microsoft-Windows-WLAN-AutoConfig/Operational"><Select Path="Microsoft-Windows-WLAN-AutoConfig/Operational">*[System[(EventID=8001)]] and *[EventData[Data[@Name='SSID']='BHU-WiFi']]</Select></Query></QueryList>
'@

# Trigger 2: when you log in to Windows (after boot/shutdown)
$tLogon = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

# Trigger 3: every 15 minutes (handles the 24-hour session expiry)
$tRepeat = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 15)

$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable -RunOnlyIfNetworkAvailable `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 2)

$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName "BHU-WiFi-Login" `
    -Action $action -Trigger @($tEvent, $tLogon, $tRepeat) `
    -Settings $settings -Principal $principal
```

The task must run as **your own Windows user**, because Credential Manager entries belong to the user who created them.

### Step 6: Test the automation

Run the task directly:

```powershell
Start-ScheduledTask -TaskName "BHU-WiFi-Login"
Start-Sleep 20
Get-ScheduledTaskInfo -TaskName "BHU-WiFi-Login" | Select LastRunTime, LastTaskResult
```

`LastRunTime` should be the current time and `LastTaskResult` should be `0`.

Then test the Wi-Fi trigger: turn Wi-Fi off, wait 5 seconds, turn it on, wait 20-30 seconds, and run the last command again. `LastRunTime` should be newer than before.

### Step 7 (optional): Desktop shortcut for manual login

```powershell
$script = "$env:USERPROFILE\bhu-login.ps1"
$ws = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut("$env:USERPROFILE\Desktop\BHU WiFi Login.lnk")
$lnk.TargetPath = "powershell.exe"
$lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -Command `"& '$script'; Start-Sleep -Seconds 4`""
$lnk.IconLocation = "%SystemRoot%\System32\SHELL32.dll,13"
$lnk.Save()
```

Double-click **BHU WiFi Login** on your Desktop. A window shows the login output and closes after 4 seconds.

Because the shortcut and the task both run the same script file, any edit to `bhu-login.ps1` applies to everything.

---

## Troubleshooting

When the script runs from Task Scheduler the window is hidden, so check `LastTaskResult`. To see the full message, double-click the desktop shortcut.

| Exit code | Meaning | What to do |
|---|---|---|
| `0` | Success, already logged in, or not on BHU Wi-Fi | Nothing |
| `1` | Credential password blob is empty | Re-create the credential with `/generic` (Step 2) |
| `2` | Unexpected connectivity response | Make sure you are on BHU-WiFi and not a VPN or another network |
| `3`, `4` | Could not find the active network adapter | Check that Wi-Fi is connected |
| `6` | Credential missing, or username/password empty | Run `cmdkey /list`, then redo Step 2 |
| `7` | Could not reach the guest portal | Check that the portal address in the script matches your network |
| `8` | Login form not found | The portal page may have changed; see below |
| `10` | Verification request failed | Retry; check your connection |
| `11` | Login was not confirmed | Wrong password, or the portal rejected the login; try logging in manually once |

**Win32 error 1168** during credential read means the entry doesn't exist. Redo Step 2.

**The task never runs on Wi-Fi connect.** Check that Windows logs connect events for your network:

```powershell
(Get-WinEvent -LogName "Microsoft-Windows-WLAN-AutoConfig/Operational" -MaxEvents 50 |
  Where-Object Id -eq 8001 | Select -First 1).ToXml()
```

Look at the `<Data Name='SSID'>` line. It must be exactly `BHU-WiFi` to match the trigger.

**Portal differences.** The portal address (`10.40.51.37`) and form layout may differ in other parts of campus or after BHU updates the portal. If login stops working, open the login page in a browser, use DevTools (Network tab, Preserve log) to see which forms are submitted, and adjust the script. **Never share your password, cookies, or tokens** when asking for help or opening an issue.

---

## Security notes

- Your password is stored in Windows Credential Manager under your Windows account and is not written in the script. Don't paste it into the script or commit it to Git.
- The BHU portal and Aruba controller use plain **HTTP**, so credentials are sent unencrypted over the campus network. This is how the portal works for normal browser logins too; the script doesn't make it better or worse.
- The script only sends credentials after it confirms the BHU portal (`10.40.51.37`) is reachable, so on other networks they are not sent anywhere.
- A 2-minute cooldown prevents repeated login attempts, so a wrong password can't lock your account by spamming the portal.
- Don't save script output to log files. It prints your username, IP, and MAC address.

---

## Uninstall / revert everything to normal

Run this in PowerShell to remove everything this project added. Adjust the script path if you saved it somewhere else.

```powershell
# 1. Remove the scheduled task (stops all automatic runs)
Unregister-ScheduledTask -TaskName "BHU-WiFi-Login" -Confirm:$false -ErrorAction SilentlyContinue

# 2. Remove the saved BHU credential from Credential Manager
cmdkey /delete:BHU-WiFi-Test

# 3. Remove the desktop shortcut
Remove-Item "$env:USERPROFILE\Desktop\BHU WiFi Login.lnk" -ErrorAction SilentlyContinue

# 4. Remove the cooldown/state folder created by the script
Remove-Item "$env:LOCALAPPDATA\bhu-login" -Recurse -Force -ErrorAction SilentlyContinue

# 5. Remove leftover debug file (only exists if you used the debug version)
Remove-Item "$env:USERPROFILE\Desktop\bhu-portal-debug.html" -ErrorAction SilentlyContinue

# 6. Remove the script itself
Remove-Item "$env:USERPROFILE\bhu-login.ps1" -ErrorAction SilentlyContinue
```

Verify that everything is gone:

```powershell
Get-ScheduledTask -TaskName "BHU-WiFi-Login" -ErrorAction SilentlyContinue   # should print nothing
cmdkey /list | Select-String "BHU-WiFi-Test"                                  # should print nothing
Test-Path "$env:LOCALAPPDATA\bhu-login"                                       # should print False
```

If you removed the credential through the GUI instead: open **Credential Manager**, then **Windows Credentials**, expand `BHU-WiFi-Test` under **Generic Credentials**, and click **Remove**.

After this, your laptop behaves exactly as before: BHU-WiFi will show the normal login page again and you log in manually. The project changes no system settings, no execution policy, and nothing outside the items above.

**Just want to pause it?** Disable the task instead of deleting it:

```powershell
Disable-ScheduledTask -TaskName "BHU-WiFi-Login"
# re-enable later:
Enable-ScheduledTask -TaskName "BHU-WiFi-Login"
```

---

## Changing your password

When your BHU password changes, run Step 2 again:

```powershell
cmdkey /delete:BHU-WiFi-Test
cmdkey /generic:BHU-WiFi-Test /user:YOUR_USERNAME /pass
```

---

## Contributing

Issues and pull requests are welcome, especially for portal changes in other hostels or campus areas. Please remove usernames, passwords, MAC addresses, IPs, and cookies from any logs you post.

## License

Add a license of your choice (for example MIT) before publishing.
