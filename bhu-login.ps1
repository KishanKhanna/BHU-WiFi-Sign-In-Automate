$ErrorActionPreference = "Stop"

# ============================================================
# BHU Wi-Fi Automatic Login
# ============================================================

$credentialTarget = "BHU-WiFi-Test"
$checkUrl = "http://connectivitycheck.gstatic.com/generate_204"

Write-Host ""
Write-Host "=== BHU Wi-Fi Login ===" -ForegroundColor Cyan

# Only run when the BHU portal is reachable (retries while Wi-Fi finishes connecting)
$onBhu = $false
for ($i = 0; $i -lt 5 -and -not $onBhu; $i++) {
    try {
        $tcp = New-Object Net.Sockets.TcpClient
        $iar = $tcp.BeginConnect("10.40.51.37", 80, $null, $null)
        $onBhu = $iar.AsyncWaitHandle.WaitOne(2000) -and $tcp.Connected
        $tcp.Close()
    } catch { $onBhu = $false }
    if (-not $onBhu) { Start-Sleep -Seconds 3 }
}
if (-not $onBhu) {
    Write-Host "Not on BHU network. Nothing to do."
    exit 0
}

# ============================================================
# 1. Check authentication state
# ============================================================

Write-Host "Checking BHU connectivity..."

try {
    $check = Invoke-WebRequest `
        -Uri $checkUrl `
        -UseBasicParsing `
        -MaximumRedirection 0 `
        -ErrorAction Stop
}
catch {
    if ($_.Exception.Response) {
        $check = $_.Exception.Response
    }
    else {
        Write-Host "Connectivity check failed." -ForegroundColor Red
        exit 1
    }
}

$content = ""

if ($check.Content) {
    $content = $check.Content
}

# Internet already available
if ($check.StatusCode -eq 204) {
    Write-Host "Already authenticated." -ForegroundColor Green
    exit 0
}

# Aruba captive portal
if (
    $check.StatusCode -eq 200 -and
    $content -match "arubalp|cmd=redirect|generate_204"
) {
    Write-Host "Login required." -ForegroundColor Yellow
}
else {
    Write-Host "Unexpected connectivity state." -ForegroundColor Red
    Write-Host "HTTP status: $($check.StatusCode)"
    exit 2
}
# Cooldown: at most one login attempt per 2 minutes
$stateDir  = "$env:LOCALAPPDATA\bhu-login"
$stateFile = "$stateDir\last-attempt.txt"
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
if (Test-Path $stateFile) {
    $last = [datetime](Get-Content $stateFile -Raw)
    if (((Get-Date) - $last).TotalSeconds -lt 120) {
        Write-Host "Last attempt was less than 2 minutes ago. Skipping."
        exit 0
    }
}
(Get-Date).ToString("o") | Set-Content $stateFile


# ============================================================
# 2. Get current network information
# ============================================================

$wifi = Get-NetIPConfiguration |
    Where-Object {
        $_.NetAdapter.Status -eq "Up" -and
        $_.IPv4DefaultGateway
    } |
    Select-Object -First 1

if (-not $wifi) {
    Write-Host "Could not find active network adapter." -ForegroundColor Red
    exit 3
}

$ip = $wifi.IPv4Address.IPAddress

$adapter = Get-NetAdapter |
    Where-Object {
        $_.InterfaceIndex -eq $wifi.InterfaceIndex
    }

if (-not $adapter) {
    Write-Host "Could not find network adapter." -ForegroundColor Red
    exit 4
}

$mac = $adapter.MacAddress.Replace("-", ":").ToLower()


# ============================================================
# 3. Get SSID
# ============================================================

$essid = "BHU-WiFi"

try {

    $netsh = netsh wlan show interfaces 2>$null

    $ssidLine = $netsh |
        Select-String "^\s*SSID\s*:"

    if ($ssidLine) {

        $detectedEssid = (
            $ssidLine.Line `
            -replace "^\s*SSID\s*:\s*", ""
        ).Trim()

        if ($detectedEssid) {
            $essid = $detectedEssid
        }
    }

}
catch {
    # Location Services may prevent SSID detection.
    # BHU-WiFi fallback remains active.
}

Write-Host ""
Write-Host "Current connection:"
Write-Host "IP   : $ip"
Write-Host "MAC  : $mac"
Write-Host "SSID : $essid"


# ============================================================
# 4. Windows Credential Manager
# ============================================================

Write-Host ""
Write-Host "Retrieving BHU credentials..."


# IMPORTANT:
# Use Windows' actual CREDENTIAL structure.
# This avoids the incorrect pointer layout that caused
# CredentialBlob to appear as NULL.

if (-not ("BhuCredentialApi" -as [type])) {

Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class BhuCredentialApi
{
    [StructLayout(
        LayoutKind.Sequential,
        CharSet = CharSet.Unicode
    )]
    public struct CREDENTIAL
    {
        public UInt32 Flags;
        public UInt32 Type;

        public IntPtr TargetName;
        public IntPtr Comment;

        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;

        public UInt32 CredentialBlobSize;
        public IntPtr CredentialBlob;

        public UInt32 Persist;
        public UInt32 AttributeCount;

        public IntPtr Attributes;
        public IntPtr TargetAlias;
        public IntPtr UserName;
    }

    [DllImport(
        "advapi32.dll",
        CharSet = CharSet.Unicode,
        SetLastError = true
    )]
    public static extern bool CredRead(
        string target,
        UInt32 type,
        UInt32 flags,
        out IntPtr credential
    );

    [DllImport(
        "advapi32.dll",
        SetLastError = true
    )]
    public static extern void CredFree(
        IntPtr credential
    );
}
"@
}


$credPtr = [IntPtr]::Zero

# Type 1 = CRED_TYPE_GENERIC
$success = [BhuCredentialApi]::CredRead(
    $credentialTarget,
    1,
    0,
    [ref]$credPtr
)

if (-not $success) {

    $errorCode =
        [Runtime.InteropServices.Marshal]::GetLastWin32Error()

    Write-Host ""
    Write-Host "Credential could not be read." -ForegroundColor Red
    Write-Host "Target : $credentialTarget"
    Write-Host "Win32 error: $errorCode"
    Write-Host ""
    Write-Host "Check with:"
    Write-Host "cmdkey /list"

    exit 6
}


try {

    $cred = [Runtime.InteropServices.Marshal]::PtrToStructure(
        $credPtr,
        [type][BhuCredentialApi+CREDENTIAL]
    )

    $username =
        [Runtime.InteropServices.Marshal]::PtrToStringUni(
            $cred.UserName
        )

    if ($cred.CredentialBlob -eq [IntPtr]::Zero) {
        throw "Credential password blob is empty."
    }

    if ($cred.CredentialBlobSize -le 0) {
        throw "Credential password blob has zero length."
    }

    $password =
        [Runtime.InteropServices.Marshal]::PtrToStringUni(
            $cred.CredentialBlob,
            [int]($cred.CredentialBlobSize / 2)
        )

}
finally {

    [BhuCredentialApi]::CredFree($credPtr)
}


if ([string]::IsNullOrEmpty($username)) {
    Write-Host "Username could not be retrieved." -ForegroundColor Red
    exit 6
}

if ([string]::IsNullOrEmpty($password)) {
    Write-Host "Password could not be retrieved." -ForegroundColor Red
    exit 6
}

Write-Host "Credential retrieved successfully."
Write-Host "Username: $username"


# ============================================================
# 5. Request BHU guest portal
# ============================================================

Write-Host ""
Write-Host "Requesting BHU guest portal..."

$session =
    New-Object Microsoft.PowerShell.Commands.WebRequestSession

$guestUrl =
    "http://10.40.51.37/guest/login.php?_browser=1"

$guestBody = @{
    url      = $checkUrl
    apgroup  = ""
    apname   = ""
    essid    = $essid
    ip       = $ip
    mac      = $mac
    cmd      = "login"
    no_login = ""
    static_u = ""
    no_u     = ""
    no_p     = ""
}

try {

    $guestResponse = Invoke-WebRequest `
        -Uri $guestUrl `
        -Method POST `
        -Body $guestBody `
        -WebSession $session `
        -UseBasicParsing `
        -MaximumRedirection 0 `
        -ErrorAction Stop

}
catch {

    if ($_.Exception.Response) {

        $guestResponse = $_.Exception.Response

    }
    else {

        Write-Host "Guest portal request failed." `
            -ForegroundColor Red

        Write-Host $_.Exception.Message
        exit 7
    }
}

$html = $guestResponse.Content


# ============================================================
# 6. Find login form
# ============================================================

Write-Host "Extracting login form..."

$portalBase = "http://10.40.51.37"

function Get-InputBody([string]$formHtml) {
    $b = @{}
    foreach ($m in [regex]::Matches($formHtml, '(?is)<input\b[^>]*>')) {
        $n = [regex]::Match($m.Value, '(?i)\bname\s*=\s*["'']([^"'']+)["'']')
        if (-not $n.Success) { continue }
        $v = [regex]::Match($m.Value, '(?i)\bvalue\s*=\s*["'']([^"'']*)["'']')
        if ($v.Success) { $b[$n.Groups[1].Value] = [System.Net.WebUtility]::HtmlDecode($v.Groups[1].Value) }
        else { $b[$n.Groups[1].Value] = "" }
    }
    return $b
}

function Send-Post($url, $body, $session) {
    try {
        Invoke-WebRequest -Uri $url -Method POST -Body $body -WebSession $session `
            -UseBasicParsing -MaximumRedirection 0 -ErrorAction Stop
    }
    catch {
        if ($_.Exception.Response) { return $_.Exception.Response }
        throw
    }
}

$loginForm = $null
foreach ($f in [regex]::Matches($html, '(?is)<form\b[^>]*action\s*=\s*["'']([^"'']+)["''][^>]*>.*?</form>')) {
    if ($f.Value -match '(?i)name\s*=\s*["'']password["'']') { $loginForm = $f; break }
}
if (-not $loginForm) {
    Write-Host "Login form not found." -ForegroundColor Red
    exit 8
}

$action = [System.Net.WebUtility]::HtmlDecode($loginForm.Groups[1].Value)
if ($action -match '^https?://') { $loginUrl = $action }
else { $loginUrl = $portalBase + $action }

Write-Host "Login endpoint: $loginUrl"


# ============================================================
# 7. Build POST body
# ============================================================

$loginBody = Get-InputBody $loginForm.Value
$loginBody["user"]     = $username
$loginBody["password"] = $password


# ============================================================
# 8. Submit login (and follow Aruba hop if present)
# ============================================================

Write-Host ""
Write-Host "Submitting BHU authentication..."

$authResponse = Send-Post $loginUrl $loginBody $session
$authHtml = ""
if ($authResponse.Content -is [string]) { $authHtml = $authResponse.Content }

$loc = $authResponse.Headers['Location']
Write-Host "Login response status : $($authResponse.StatusCode)"
if ($loc) {
    $u = [Uri]$loc
    Write-Host "Redirect to           : $($u.Scheme)://$($u.Host)$($u.AbsolutePath)"
}

# Next hop: a form pointing to another host (Aruba controller)
if ($authHtml) {
    foreach ($f in [regex]::Matches($authHtml, '(?is)<form\b[^>]*action\s*=\s*["'']([^"'']+)["''][^>]*>.*?</form>')) {
        $nextAction = [System.Net.WebUtility]::HtmlDecode($f.Groups[1].Value)
        Write-Host "Form in response      : $(($nextAction -split '\?')[0])"
        if ($nextAction -match '^https?://' -and $nextAction -notmatch '10\.40\.51\.37') {
            $nextBody = Get-InputBody $f.Value
            Write-Host "Submitting to controller..."
            $null = Send-Post $nextAction $nextBody $session
        }
    }
}


# ============================================================
# 9. Verify authentication
# ============================================================

Write-Host ""
Write-Host "Verifying Internet access..."

Start-Sleep -Milliseconds 500

try {

    $verify = Invoke-WebRequest `
        -Uri $checkUrl `
        -WebSession $session `
        -UseBasicParsing `
        -MaximumRedirection 0 `
        -ErrorAction Stop

}
catch {

    if ($_.Exception.Response) {

        $verify =
            $_.Exception.Response

    }
    else {

        Write-Host "Verification request failed." `
            -ForegroundColor Red

        exit 10
    }
}


if ($verify.StatusCode -eq 204) {

    Write-Host ""
    Write-Host "====================================" `
        -ForegroundColor Green

    Write-Host " BHU AUTHENTICATION SUCCESSFUL" `
        -ForegroundColor Green

    Write-Host "====================================" `
        -ForegroundColor Green

    exit 0
}


Write-Host ""
Write-Host "BHU authentication was NOT confirmed." `
    -ForegroundColor Red

Write-Host "Verification HTTP status: $($verify.StatusCode)"

if ($verify.Content) {

    if (
        $verify.Content `
        -match "arubalp|cmd=redirect|generate_204"
    ) {
        Write-Host "Login is still required."
    }
}

exit 11