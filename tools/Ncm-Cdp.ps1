# Portable local transport for Windows PowerShell 5.1 / PowerShell 7.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NcmPage {
    param([int]$Port)
    $pages = @(Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/list" -TimeoutSec 2)
    $matches = @($pages | Where-Object { $_.type -eq 'page' -and $_.url -eq 'orpheus://orpheus/pub/app.html' })
    if ($matches.Count -ne 1) { throw 'NCM_PAGE_NOT_UNIQUE' }
    $socket = [Uri]$matches[0].webSocketDebuggerUrl
    if ($socket.Scheme -ne 'ws' -or $socket.Host -ne '127.0.0.1' -or $socket.Port -ne $Port) { throw 'NCM_ENDPOINT_NOT_LOOPBACK' }
    return $socket.AbsoluteUri
}

function Find-NcmPort {
    param([switch]$Launch, [string]$ClientPath)
    $processes = @(Get-CimInstance Win32_Process -Filter "Name='cloudmusic.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -notmatch '--type=' })
    foreach ($process in $processes) {
        $match = [regex]::Match($process.CommandLine, 'remote-debugging-port[= ](\d+)')
        if ($match.Success) {
            $port = [int]$match.Groups[1].Value
            try { [void](Get-NcmPage -Port $port); return $port } catch { }
        }
    }
    if ($processes.Count -gt 0) { throw 'NCM_EXIT_AND_RESTART_WITH_LAUNCHER' }
    if (-not $Launch) { throw 'NCM_NOT_RUNNING' }
    $infoScript = Join-Path $PSScriptRoot 'Get-ClientInfo.ps1'
    if ($ClientPath) { $found = & $infoScript -ClientPath $ClientPath | ConvertFrom-Json }
    else { $found = & $infoScript | ConvertFrom-Json }
    if ($found.discovered -ne 1) { throw 'NCM_INSTALLATION_NOT_UNIQUE_USE_CLIENTPATH' }
    $executable = $found.clients[0].path
    $port = 9222
    for ($attempt = 0; $attempt -lt 12; $attempt++) {
        $listener = $null
        try {
            $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $port)
            $listener.Start(); break
        } catch { $port = Get-Random -Minimum 45000 -Maximum 55000 }
        finally { if ($listener) { $listener.Stop() } }
    }
    Start-Process -FilePath $executable -ArgumentList "--remote-debugging-address=127.0.0.1", "--remote-debugging-port=$port" -WindowStyle Hidden | Out-Null
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        try { [void](Get-NcmPage -Port $port); return $port } catch { Start-Sleep -Milliseconds 500 }
    }
    throw 'NCM_START_TIMEOUT'
}

function Invoke-NcmExpression {
    param([int]$Port, [string]$Expression, [switch]$UserGesture)
    $endpoint = Get-NcmPage -Port $Port
    $socket = New-Object Net.WebSockets.ClientWebSocket
    $socket.Options.Proxy = $null
    $timeout = New-Object Threading.CancellationTokenSource
    $timeout.CancelAfter(20000)
    try {
        $socket.ConnectAsync([Uri]$endpoint, $timeout.Token).GetAwaiter().GetResult() | Out-Null
        $payload = @{ id = 1; method = 'Runtime.evaluate'; params = @{
            expression = $Expression; returnByValue = $true; awaitPromise = $true;
            userGesture = [bool]$UserGesture; timeout = 15000
        } } | ConvertTo-Json -Depth 8 -Compress
        $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
        $segment = New-Object 'System.ArraySegment[byte]' -ArgumentList @(,$bytes)
        $socket.SendAsync($segment, [Net.WebSockets.WebSocketMessageType]::Text, $true, $timeout.Token).GetAwaiter().GetResult() | Out-Null
        $buffer = New-Object byte[] 65536
        while ($true) {
            $message = New-Object IO.MemoryStream
            try {
                do {
                    $chunk = New-Object 'System.ArraySegment[byte]' -ArgumentList @(,$buffer)
                    $received = $socket.ReceiveAsync($chunk, $timeout.Token).GetAwaiter().GetResult()
                    if ($received.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) { throw 'NCM_CONNECTION_CLOSED' }
                    $message.Write($buffer, 0, $received.Count)
                    if ($message.Length -gt 4MB) { throw 'NCM_RESPONSE_TOO_LARGE' }
                } while (-not $received.EndOfMessage)
                $response = [Text.Encoding]::UTF8.GetString($message.ToArray()) | ConvertFrom-Json
            } finally { $message.Dispose() }
            if ($response.PSObject.Properties.Name -notcontains 'id' -or $response.id -ne 1) { continue }
            if ($response.PSObject.Properties.Name -contains 'error') { throw 'NCM_PROTOCOL_ERROR' }
            if ($response.result.PSObject.Properties.Name -contains 'exceptionDetails') { throw 'NCM_SCRIPT_ERROR_UNSUPPORTED_CLIENT_OR_STATE' }
            if ($response.result.result.PSObject.Properties.Name -notcontains 'value') { throw 'NCM_RESULT_MISSING' }
            return $response.result.result.value
        }
    } finally { $socket.Abort(); $socket.Dispose(); $timeout.Dispose() }
}
