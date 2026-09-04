# TG JVM Local Bridge - v0006
# Localhost-only HTTP bridge for safely exposing selected JDK monitoring commands.
#
# Start:
#   powershell -ExecutionPolicy Bypass -File .\tg-jvm-bridge.ps1
#
# Browser tests:
#   http://localhost:32032/jvms
#   http://localhost:32032/version?pid=12345
#   http://localhost:32032/uptime?pid=12345
#   http://localhost:32032/gc?pid=12345
#   http://localhost:32032/gcutil?pid=12345
#   http://localhost:32032/class?pid=12345
#   http://localhost:32032/compiler?pid=12345
#   http://localhost:32032/threads?pid=12345
#   http://localhost:32032/flags?pid=12345
#   http://localhost:32032/properties?pid=12345
#   http://localhost:32032/perfcounters?pid=12345
#   http://localhost:32032/commands?pid=12345
#   http://localhost:32032/histogram?pid=12345
#   http://localhost:32032/shutdown
#
# The URL never supplies an executable or arbitrary shell command.
# Each endpoint maps to a fixed, predefined JDK diagnostic operation.
#
# Stop with Ctrl+C.

$ErrorActionPreference = "Stop"

$BindAddress = [System.Net.IPAddress]::Loopback
$Port = 32032

$Listener = [System.Net.Sockets.TcpListener]::new($BindAddress, $Port)
$script:ShutdownRequested = $false

function Send-HttpResponse {
    param(
        [Parameter(Mandatory = $true)]
        [System.Net.Sockets.NetworkStream] $Stream,

        [Parameter(Mandatory = $true)]
        [int] $StatusCode,

        [Parameter(Mandatory = $true)]
        [string] $StatusText,

        [Parameter(Mandatory = $true)]
        [string] $Body,

        [string] $ContentType = "text/plain; charset=utf-8"
    )

    $BodyBytes = [System.Text.Encoding]::UTF8.GetBytes($Body)

    $Headers =
        "HTTP/1.1 $StatusCode $StatusText`r`n" +
        "Content-Type: $ContentType`r`n" +
        "Content-Length: $($BodyBytes.Length)`r`n" +
        "Connection: close`r`n" +
        "Cache-Control: no-store`r`n" +
        "Access-Control-Allow-Origin: *`r`n" +
        "`r`n"

    $HeaderBytes = [System.Text.Encoding]::ASCII.GetBytes($Headers)

    $Stream.Write($HeaderBytes, 0, $HeaderBytes.Length)
    $Stream.Write($BodyBytes, 0, $BodyBytes.Length)
    $Stream.Flush()
}

function Resolve-JdkTool {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    $Command = Get-Command ($Name + ".exe") -ErrorAction SilentlyContinue

    if (-not $Command) {
        $Command = Get-Command $Name -ErrorAction SilentlyContinue
    }

    if (-not $Command) {
        throw "$Name was not found on PATH. Run the bridge from an environment where the JDK bin directory is available."
    }

    return $Command.Source
}

function Invoke-Tool {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Tool,

        [Parameter(Mandatory = $true)]
        [string[]] $Arguments
    )

    $Output = @(& $Tool @Arguments 2>&1)

    if ($LASTEXITCODE -ne 0) {
        throw "$([System.IO.Path]::GetFileName($Tool)) failed: $($Output -join ' ')"
    }

    return ($Output | ForEach-Object { "$_" })
}

function Get-DiscoveredJvms {
    $Jps = Resolve-JdkTool "jps"
    $Lines = @(Invoke-Tool -Tool $Jps -Arguments @("-l"))

    $Rows = @()

    foreach ($Line in $Lines) {
        $Trimmed = "$Line".Trim()

        if (-not $Trimmed) {
            continue
        }

        # Do not expose the temporary jps process itself.
        if (
            $Trimmed -match '\bsun\.tools\.jps\.Jps\b' -or
            $Trimmed -match '\bjdk\.jcmd/sun\.tools\.jps\.Jps\b'
        ) {
            continue
        }

        if ($Trimmed -match '^\s*(\d+)\s+(.+?)\s*$') {
            $Rows += [PSCustomObject]@{
                Pid  = $Matches[1]
                Name = $Matches[2]
            }
        }
        elseif ($Trimmed -match '^\s*(\d+)\s*$') {
            $Rows += [PSCustomObject]@{
                Pid  = $Matches[1]
                Name = "UNKNOWN"
            }
        }
    }

    return $Rows
}

function Assert-ValidJvmPid {
    param(
        [Parameter(Mandatory = $true)]
        [string] $PidText
    )

    if ($PidText -notmatch '^[1-9][0-9]*$') {
        throw "Invalid pid. A positive numeric JVM process ID is required."
    }

    $Found = $false

    foreach ($Jvm in @(Get-DiscoveredJvms)) {
        if ($Jvm.Pid -eq $PidText) {
            $Found = $true
            break
        }
    }

    if (-not $Found) {
        throw "PID $PidText is not currently present in the JVM discovery list."
    }

    return $PidText
}

function Invoke-Jcmd {
    param(
        [Parameter(Mandatory = $true)]
        [string] $PidText,

        [Parameter(Mandatory = $true)]
        [string[]] $CommandArguments
    )

    $PidText = Assert-ValidJvmPid $PidText
    $Jcmd = Resolve-JdkTool "jcmd"

    return @(
        Invoke-Tool `
            -Tool $Jcmd `
            -Arguments (@($PidText) + $CommandArguments)
    )
}

function Invoke-Jstat {
    param(
        [Parameter(Mandatory = $true)]
        [string] $PidText,

        [Parameter(Mandatory = $true)]
        [string] $StatOption
    )

    $PidText = Assert-ValidJvmPid $PidText
    $Jstat = Resolve-JdkTool "jstat"

    # A single snapshot: header + one data row.
    return @(
        Invoke-Tool `
            -Tool $Jstat `
            -Arguments @($StatOption, $PidText)
    )
}

function Get-VersionSummary {
    param(
        [Parameter(Mandatory = $true)]
        [string] $PidText
    )

    try {
        $Lines = @(Invoke-Jcmd -PidText $PidText -CommandArguments @("VM.version"))

        # Remove the standard "12345:" prefix and collapse version detail
        # into one browser-friendly line.
        $Clean = @(
            $Lines |
            ForEach-Object { "$_".Trim() } |
            Where-Object {
                $_ -and
                $_ -notmatch ('^' + [regex]::Escape($PidText) + ':$')
            }
        )

        if ($Clean.Count -eq 0) {
            return "UNKNOWN"
        }

        return ($Clean -join " / ")
    }
    catch {
        return "UNAVAILABLE: $($_.Exception.Message)"
    }
}

function Get-JvmListText {
    $Rows = @(Get-DiscoveredJvms)

    if ($Rows.Count -eq 0) {
        return "NO_JVMS"
    }

    $Output = foreach ($Jvm in $Rows) {
        $Version = Get-VersionSummary $Jvm.Pid
        "$($Jvm.Pid)|$($Jvm.Name)|$Version"
    }

    return ($Output -join "`n")
}

function Get-QueryValue {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Target,

        [Parameter(Mandatory = $true)]
        [string] $Key
    )

    try {
        $Uri = [System.Uri]("http://localhost$Target")
        $Query = $Uri.Query.TrimStart("?")

        if (-not $Query) {
            return $null
        }

        foreach ($Pair in ($Query -split "&")) {
            $Parts = $Pair -split "=", 2
            $Name = [System.Uri]::UnescapeDataString($Parts[0])

            if ($Name -eq $Key) {
                if ($Parts.Count -lt 2) {
                    return ""
                }

                return [System.Uri]::UnescapeDataString($Parts[1])
            }
        }

        return $null
    }
    catch {
        return $null
    }
}

function Require-PidFromTarget {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Target
    )

    $PidText = Get-QueryValue -Target $Target -Key "pid"

    if ([string]::IsNullOrWhiteSpace($PidText)) {
        throw "Missing required query parameter: pid"
    }

    return (Assert-ValidJvmPid $PidText)
}

function Join-Lines {
    param(
        [Parameter(Mandatory = $true)]
        [object[]] $Lines
    )

    return (($Lines | ForEach-Object { "$_" }) -join "`n")
}


function Get-CommandListText {
    return @"
TG JVM Local Bridge v0006 commands

Bridge:
  http://localhost:32032/
  http://localhost:32032/help
  http://localhost:32032/command1
  http://localhost:32032/shutdown

JVM discovery:
  http://localhost:32032/jvms

Selected JVM information:
  http://localhost:32032/version?pid=PID
  http://localhost:32032/uptime?pid=PID
  http://localhost:32032/flags?pid=PID
  http://localhost:32032/properties?pid=PID
  http://localhost:32032/commands?pid=PID

Live monitoring snapshots:
  http://localhost:32032/gc?pid=PID
  http://localhost:32032/gcutil?pid=PID
  http://localhost:32032/class?pid=PID
  http://localhost:32032/compiler?pid=PID
  http://localhost:32032/perfcounters?pid=PID

On-demand diagnostic:
  http://localhost:32032/threads?pid=PID
  http://localhost:32032/histogram?pid=PID

Replace PID with a JVM process ID returned by /jvms.
"@
}

try {
    $Listener.Start()

    Write-Host ""
    Write-Host (Get-CommandListText)
    Write-Host "Stop with Ctrl+C or open:"
    Write-Host "  http://localhost:$Port/shutdown"
    Write-Host ""

    while (-not $script:ShutdownRequested) {
        $Client = $null
        $Stream = $null
        $Reader = $null

        try {
            $Client = $Listener.AcceptTcpClient()
            $Stream = $Client.GetStream()

            $Reader = [System.IO.StreamReader]::new(
                $Stream,
                [System.Text.Encoding]::ASCII,
                $false,
                4096,
                $true
            )

            $RequestLine = $Reader.ReadLine()

            if ([string]::IsNullOrWhiteSpace($RequestLine)) {
                Send-HttpResponse `
                    -Stream $Stream `
                    -StatusCode 400 `
                    -StatusText "Bad Request" `
                    -Body "ERROR: Empty request."
                continue
            }

            Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $RequestLine"

            $Parts = $RequestLine.Split(" ")

            if ($Parts.Count -lt 2) {
                Send-HttpResponse `
                    -Stream $Stream `
                    -StatusCode 400 `
                    -StatusText "Bad Request" `
                    -Body "ERROR: Invalid HTTP request."
                continue
            }

            $Method = $Parts[0].ToUpperInvariant()
            $Target = $Parts[1]
            $Path = ($Target -split "\?", 2)[0]

            # Normalize endpoint paths so browser variations such as
            # /shutdown/, /SHUTDOWN, etc. map to the same fixed key.
            if ($Path.Length -gt 1) {
                $Path = $Path.TrimEnd("/")
            }
            $Path = $Path.ToLowerInvariant()

            if ($Method -ne "GET") {
                Send-HttpResponse `
                    -Stream $Stream `
                    -StatusCode 405 `
                    -StatusText "Method Not Allowed" `
                    -Body "ERROR: Only GET is supported."
                continue
            }

            try {
                switch ($Path) {
                    "/" {
                        $Body = @"
TG JVM Local Bridge v0006 is running.

Discovery:
  /jvms

Low-impact target information:
  /version?pid=PID
  /uptime?pid=PID
  /flags?pid=PID
  /properties?pid=PID
  /commands?pid=PID

Live monitoring snapshots:
  /gc?pid=PID
  /gcutil?pid=PID
  /class?pid=PID
  /compiler?pid=PID
  /perfcounters?pid=PID

On-demand diagnostic:
  /threads?pid=PID
  /histogram?pid=PID

Bridge control:
  /shutdown

Basic connectivity:
  /command1
"@

                        Send-HttpResponse `
                            -Stream $Stream `
                            -StatusCode 200 `
                            -StatusText "OK" `
                            -Body $Body
                    }

                    "/help" {
                        Send-HttpResponse `
                            -Stream $Stream `
                            -StatusCode 200 `
                            -StatusText "OK" `
                            -Body (Get-CommandListText)
                    }

                    "/command1" {
                        Send-HttpResponse `
                            -Stream $Stream `
                            -StatusCode 200 `
                            -StatusText "OK" `
                            -Body "OK: command1 was received and processed."
                    }

                    "/jvms" {
                        Send-HttpResponse `
                            -Stream $Stream `
                            -StatusCode 200 `
                            -StatusText "OK" `
                            -Body (Get-JvmListText)
                    }

                    "/version" {
                        $PidText = Require-PidFromTarget $Target
                        $Body = Join-Lines @(Invoke-Jcmd -PidText $PidText -CommandArguments @("VM.version"))

                        Send-HttpResponse -Stream $Stream -StatusCode 200 -StatusText "OK" -Body $Body
                    }

                    "/uptime" {
                        $PidText = Require-PidFromTarget $Target
                        $Body = Join-Lines @(Invoke-Jcmd -PidText $PidText -CommandArguments @("VM.uptime"))

                        Send-HttpResponse -Stream $Stream -StatusCode 200 -StatusText "OK" -Body $Body
                    }

                    "/flags" {
                        $PidText = Require-PidFromTarget $Target
                        $Body = Join-Lines @(Invoke-Jcmd -PidText $PidText -CommandArguments @("VM.flags"))

                        Send-HttpResponse -Stream $Stream -StatusCode 200 -StatusText "OK" -Body $Body
                    }

                    "/properties" {
                        $PidText = Require-PidFromTarget $Target
                        $Body = Join-Lines @(Invoke-Jcmd -PidText $PidText -CommandArguments @("VM.system_properties"))

                        Send-HttpResponse -Stream $Stream -StatusCode 200 -StatusText "OK" -Body $Body
                    }

                    "/commands" {
                        $PidText = Require-PidFromTarget $Target
                        $Body = Join-Lines @(Invoke-Jcmd -PidText $PidText -CommandArguments @("help"))

                        Send-HttpResponse -Stream $Stream -StatusCode 200 -StatusText "OK" -Body $Body
                    }

                    "/threads" {
                        $PidText = Require-PidFromTarget $Target
                        $Body = Join-Lines @(Invoke-Jcmd -PidText $PidText -CommandArguments @("Thread.print"))

                        Send-HttpResponse -Stream $Stream -StatusCode 200 -StatusText "OK" -Body $Body
                    }

                    "/perfcounters" {
                        $PidText = Require-PidFromTarget $Target
                        $Body = Join-Lines @(Invoke-Jcmd -PidText $PidText -CommandArguments @("PerfCounter.print"))

                        Send-HttpResponse -Stream $Stream -StatusCode 200 -StatusText "OK" -Body $Body
                    }

                    "/gc" {
                        $PidText = Require-PidFromTarget $Target
                        $Body = Join-Lines @(Invoke-Jstat -PidText $PidText -StatOption "-gc")

                        Send-HttpResponse -Stream $Stream -StatusCode 200 -StatusText "OK" -Body $Body
                    }

                    "/gcutil" {
                        $PidText = Require-PidFromTarget $Target
                        $Body = Join-Lines @(Invoke-Jstat -PidText $PidText -StatOption "-gcutil")

                        Send-HttpResponse -Stream $Stream -StatusCode 200 -StatusText "OK" -Body $Body
                    }

                    "/class" {
                        $PidText = Require-PidFromTarget $Target
                        $Body = Join-Lines @(Invoke-Jstat -PidText $PidText -StatOption "-class")

                        Send-HttpResponse -Stream $Stream -StatusCode 200 -StatusText "OK" -Body $Body
                    }

                    "/compiler" {
                        $PidText = Require-PidFromTarget $Target
                        $Body = Join-Lines @(Invoke-Jstat -PidText $PidText -StatOption "-compiler")

                        Send-HttpResponse -Stream $Stream -StatusCode 200 -StatusText "OK" -Body $Body
                    }


                    "/histogram" {
                        # On-demand live class histogram. This can be more intrusive
                        # than jstat sampling, so the browser should not poll it rapidly.
                        $PidText = Require-PidFromTarget $Target
                        $Body = Join-Lines @(Invoke-Jcmd -PidText $PidText -CommandArguments @("GC.class_histogram"))

                        Send-HttpResponse -Stream $Stream -StatusCode 200 -StatusText "OK" -Body $Body
                    }

                    "/shutdown" {
                        # Graceful localhost shutdown endpoint.
                        # The listener is bound to 127.0.0.1 only, so this is
                        # reachable only from the local machine.
                        Send-HttpResponse `
                            -Stream $Stream `
                            -StatusCode 200 `
                            -StatusText "OK" `
                            -Body "OK: TG JVM Local Bridge is shutting down."

                        $script:ShutdownRequested = $true
                    }

                    default {
                        Send-HttpResponse `
                            -Stream $Stream `
                            -StatusCode 404 `
                            -StatusText "Not Found" `
                            -Body "ERROR: Unknown command key '$Path'."
                    }
                }
            }
            catch {
                Send-HttpResponse `
                    -Stream $Stream `
                    -StatusCode 400 `
                    -StatusText "Bad Request" `
                    -Body ("ERROR: " + $_.Exception.Message)
            }
        }
        catch {
            Write-Warning $_.Exception.Message

            if ($Stream -and $Stream.CanWrite) {
                try {
                    Send-HttpResponse `
                        -Stream $Stream `
                        -StatusCode 500 `
                        -StatusText "Internal Server Error" `
                        -Body "ERROR: Server processing failed."
                }
                catch {
                    # Ignore secondary connection/write failures.
                }
            }
        }
        finally {
            if ($Reader) { $Reader.Dispose() }
            if ($Stream) { $Stream.Dispose() }
            if ($Client) { $Client.Close() }
        }
    }
}
finally {
    if ($Listener) {
        $Listener.Stop()
    }

    Write-Host ""
    Write-Host "TG JVM Local Bridge stopped."
}
