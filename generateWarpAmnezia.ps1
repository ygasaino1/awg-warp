<#
.SYNOPSIS
Generate WireGuard/AmneziaWG keys and a Cloudflare WARP .conf file.

.DESCRIPTION
This script generates a WireGuard private/public key pair, registers the public key
with Cloudflare's WARP API, writes a ready-to-use .conf file for the AmneziaWG
client and shows a scannable QR code of the config right in the terminal.

When started without any parameters (for example via "irm <url> | iex") it runs in
interactive mode and asks a few questions: where to save the file, an optional custom
endpoint, and whether to show the QR code. Press Enter to accept the default every time.
Pass any parameter, or -NoPrompt, to skip the questions.

Works on Windows PowerShell 5.1 and PowerShell 7+.

.PARAMETER OutputFile
Path to the output .conf file. Defaults to a file named after the current date/time
(e.g. 2026-10-01-143022.conf) in the current folder. If the current folder is inside
the Windows folder (typical for an admin terminal), your user profile folder is used instead.

.PARAMETER WgPath
Path to wg.exe or awg.exe. If not specified, the script tries to find it automatically.

.PARAMETER Endpoint
Custom endpoint in the form <ip:port> (e.g. 162.159.192.1:2408).
If provided, it overrides the endpoint returned by the WARP API.

.PARAMETER NoQr
Do not print the QR code in the terminal.

.PARAMETER Force
Overwrite the output file if it already exists.

.PARAMETER NoPrompt
Never ask questions, always use the defaults (or the parameters you passed).

.EXAMPLE
.\generateWarpAmnezia.ps1

.EXAMPLE
.\generateWarpAmnezia.ps1 -OutputFile "warp.conf"

.EXAMPLE
.\generateWarpAmnezia.ps1 -Endpoint "162.159.192.1:2408" -NoQr

.EXAMPLE
# Run straight from a URL (interactive, asks a few questions):
irm "https://example.com/generateWarpAmnezia.ps1" | iex

.EXAMPLE
# Run straight from a URL, with parameters (no questions asked):
& ([scriptblock]::Create((irm "https://example.com/generateWarpAmnezia.ps1"))) -NoQr -Force
#>
param(
    [string]$OutputFile = "",
    [string]$WgPath = "",
    [string]$Endpoint = "",
    [switch]$NoQr,
    [switch]$Force,
    [switch]$NoPrompt
)

& {
    # Shared state lives in one hashtable so nothing leaks into the caller's session.
    $Ctx = @{}

    $ErrorActionPreference = 'Stop'
    $Ctx.StartTime = Get-Date
    $Ctx.Hint = ''

    # WARP API identity. Mirrors the current wgcf release (v2.3.0, Sept 2026).
    # Cloudflare changes these now and then; if registration starts failing, check here first.
    $Ctx.WarpApiUrl        = 'https://api.cloudflareclient.com/v0a5641/reg'
    $Ctx.WarpUserAgent     = '1.1.1.1/6.38.9-5641 (Android 16.0.0)'
    $Ctx.WarpClientVersion = 'a-6.38.9-5641'

    # Keep TLS 1.2 enabled (without disabling anything newer) for the API request
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    # =====================================================================
    #  Terminal look & feel
    # =====================================================================

    # Fancy unicode glyphs only where the font is known to handle them (Windows Terminal, VS Code, ConEmu).
    # The script source is pure ASCII on purpose, so it never breaks on any PowerShell encoding.
    $Ctx.Fancy = [bool]($env:WT_SESSION -or $env:TERM_PROGRAM -or $env:ConEmuANSI)

    if ($Ctx.Fancy) {
        $Ctx.G = @{
            Ok    = [string][char]0x2714   # check mark
            Fail  = [string][char]0x2718   # cross
            Warn  = [string][char]0x25B2   # triangle
            Arrow = [string][char]0x203A   # >
            H     = [string][char]0x2500
            V     = [string][char]0x2502
            TL    = [string][char]0x256D
            TR    = [string][char]0x256E
            BL    = [string][char]0x2570
            BR    = [string][char]0x256F
            Spin  = @(0x280B, 0x2819, 0x2839, 0x2838, 0x283C, 0x2834, 0x2826, 0x2827, 0x2807, 0x280F | ForEach-Object { [string][char]$_ })
        }
    } else {
        $Ctx.G = @{
            Ok = '+'; Fail = 'x'; Warn = '!'; Arrow = '>'
            H = '-'; V = '|'; TL = '+'; TR = '+'; BL = '+'; BR = '+'
            Spin = @('|', '/', '-', '\')
        }
    }

    function Get-ConsoleWidth {
        try {
            $w = $Host.UI.RawUI.WindowSize.Width
            if ($w -gt 0) { return [int]$w }
        } catch { }
        return 120
    }

    function Write-Seg {
        param([string]$Text, [ConsoleColor]$Color = 'Gray')
        Write-Host $Text -ForegroundColor $Color -NoNewline
    }

    function Write-Line {
        param([string]$Text = '', [ConsoleColor]$Color = 'Gray')
        Write-Host $Text -ForegroundColor $Color
    }

    function Format-Centered {
        param([string]$Text, [int]$Width)
        $left = [int][Math]::Floor([double]($Width - $Text.Length) / 2)
        return (' ' * $left) + $Text + (' ' * ($Width - $Text.Length - $left))
    }

    function Write-Banner {
        $w = 46
        $g = $Ctx.G
        Write-Host ''
        Write-Line ("  " + $g.TL + ($g.H * $w) + $g.TR) Cyan
        Write-Seg ("  " + $g.V) Cyan
        Write-Seg (Format-Centered 'WARP  ->  AmneziaWG' $w) White
        Write-Line $g.V Cyan
        Write-Seg ("  " + $g.V) Cyan
        Write-Seg (Format-Centered 'config generator with QR code' $w) DarkGray
        Write-Line $g.V Cyan
        Write-Line ("  " + $g.BL + ($g.H * $w) + $g.BR) Cyan
    }

    function Write-Step {
        param([int]$N, [int]$Total, [string]$Title)
        Write-Host ''
        Write-Seg "  [$N/$Total] " DarkCyan
        Write-Line $Title White
    }

    function Write-Ok {
        param([string]$Text, [string]$Detail = '')
        Write-Seg ("    " + $Ctx.G.Ok + " ") Green
        Write-Seg $Text White
        if ($Detail) { Write-Seg ("  " + $Detail) DarkGray }
        Write-Host ''
    }

    function Write-Warn {
        param([string]$Text)
        Write-Seg ("    " + $Ctx.G.Warn + " ") Yellow
        Write-Line $Text Yellow
    }

    function Write-Row {
        param([string]$Label, [string]$Value, [ConsoleColor]$ValueColor = 'White')
        Write-Seg ("  " + $Ctx.G.V + "  ") Cyan
        Write-Seg ($Label.PadRight(11)) DarkGray
        Write-Line $Value $ValueColor
    }

    function Wait-TaskWithSpinner {
        param($Task, [string]$Message)

        $interactive = (-not [Console]::IsOutputRedirected) -and ($Host.Name -ne 'Windows PowerShell ISE Host')
        $cursorHidden = $false
        if ($interactive) {
            try { [Console]::CursorVisible = $false; $cursorHidden = $true } catch { }
        }
        $i = 0
        try {
            while (-not $Task.IsCompleted) {
                if ($interactive) {
                    $frame = $Ctx.G.Spin[$i % $Ctx.G.Spin.Count]
                    Write-Host ("`r    " + $frame + " " + $Message) -ForegroundColor Cyan -NoNewline
                    $i++
                }
                Start-Sleep -Milliseconds 80
            }
        } finally {
            if ($interactive) {
                Write-Host ("`r" + (' ' * ((Get-ConsoleWidth) - 1)) + "`r") -NoNewline
            }
            if ($cursorHidden) {
                try { [Console]::CursorVisible = $true } catch { }
            }
        }
    }

    # =====================================================================
    #  Cloudflare WARP registration (async, so the spinner can animate)
    # =====================================================================

    function Invoke-WarpRegistration {
        param([string]$Url, [string]$Json)

        Add-Type -AssemblyName System.Net.Http
        $client = [System.Net.Http.HttpClient]::new()
        try {
            $client.Timeout = [TimeSpan]::FromSeconds(30)
            [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('User-Agent', $Ctx.WarpUserAgent)
            [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('CF-Client-Version', $Ctx.WarpClientVersion)
            $content = [System.Net.Http.StringContent]::new($Json, [Text.Encoding]::UTF8, 'application/json')
            $content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('application/json; charset=UTF-8')

            $task = $client.PostAsync($Url, $content)
            Wait-TaskWithSpinner -Task $task -Message 'Contacting Cloudflare WARP API...'

            if ($task.IsCanceled) { throw 'The request timed out after 30 seconds.' }
            if ($task.IsFaulted)  { throw $task.Exception.GetBaseException().Message }

            $resp = $task.Result
            $text = $resp.Content.ReadAsStringAsync().Result
            if (-not $resp.IsSuccessStatusCode) {
                $code = [int]$resp.StatusCode
                if ($code -eq 429 -or $code -eq 403) {
                    $Ctx.Hint = 'Cloudflare may be rate-limiting you or rejecting the TLS fingerprint (PowerShell cannot imitate the Android app). Retry in a few minutes; if it keeps failing, register with wgcf v2.3.0 instead.'
                }
                throw ("Cloudflare answered with HTTP " + [int]$resp.StatusCode + " " + $resp.ReasonPhrase)
            }
            return ($text | ConvertFrom-Json)
        } finally {
            $client.Dispose()
        }
    }

    function Resolve-WarpEndpoint {
        param($Peer)
        # The WARP API usually returns IP:0 for v4/v6 (port 0 is not usable), the real port is 2408.
        $ep = $null
        foreach ($candidate in @($Peer.endpoint.v4, $Peer.endpoint.v6)) {
            if ($candidate) { $ep = [string]$candidate; break }
        }
        if ($ep) {
            $port = 2408
            if ($Peer.endpoint.ports) { $port = [int]@($Peer.endpoint.ports)[0] }
            if ($ep -match ':0$') { $ep = $ep -replace ':0$', (':' + $port) }
            return $ep
        }
        if ($Peer.endpoint.host) { return [string]$Peer.endpoint.host }
        return 'engage.cloudflareclient.com:2408'
    }

    # =====================================================================
    #  Tiny QR code encoder (byte mode, error correction L, versions 1-20)
    #  Renders with half-block characters so it fits in a terminal.
    # =====================================================================

    function Get-QrRawCodewords {
        param([int]$V)
        $r = (16 * $V + 128) * $V + 64
        if ($V -ge 2) {
            $na = [int][Math]::Floor([double]$V / 7) + 2
            $r -= (25 * $na - 10) * $na - 55
            if ($V -ge 7) { $r -= 36 }
        }
        return [int][Math]::Floor([double]$r / 8)
    }

    function Set-QrFn {
        param($Mod, $Fn, [int]$Size, [int]$X, [int]$Y, $Dark)
        $idx = $Y * $Size + $X
        if ($Dark) { $Mod[$idx] = 1 } else { $Mod[$idx] = 0 }
        $Fn[$idx] = $true
    }

    function Add-QrFinder {
        param($Mod, $Fn, [int]$Size, [int]$Cx, [int]$Cy)
        for ($dy = -4; $dy -le 4; $dy++) {
            for ($dx = -4; $dx -le 4; $dx++) {
                $d = [Math]::Max([Math]::Abs($dx), [Math]::Abs($dy))
                $xx = $Cx + $dx
                $yy = $Cy + $dy
                if ($xx -ge 0 -and $xx -lt $Size -and $yy -ge 0 -and $yy -lt $Size) {
                    Set-QrFn $Mod $Fn $Size $xx $yy (($d -ne 2) -and ($d -ne 4))
                }
            }
        }
    }

    function Add-QrAlignment {
        param($Mod, $Fn, [int]$Size, [int]$Cx, [int]$Cy)
        for ($dy = -2; $dy -le 2; $dy++) {
            for ($dx = -2; $dx -le 2; $dx++) {
                $d = [Math]::Max([Math]::Abs($dx), [Math]::Abs($dy))
                Set-QrFn $Mod $Fn $Size ($Cx + $dx) ($Cy + $dy) ($d -ne 1)
            }
        }
    }

    function Set-QrFormat {
        param($Mod, $Fn, [int]$Size, [int]$Mask)
        $data = (1 -shl 3) -bor $Mask          # error correction level L = 1
        $rem = $data
        for ($i = 0; $i -lt 10; $i++) { $rem = ($rem -shl 1) -bxor (($rem -shr 9) * 0x537) }
        $bits = (($data -shl 10) -bor $rem) -bxor 0x5412
        $fb = @(for ($i = 0; $i -lt 15; $i++) { ($bits -shr $i) -band 1 })

        for ($i = 0; $i -le 5; $i++) { Set-QrFn $Mod $Fn $Size 8 $i ($fb[$i]) }
        Set-QrFn $Mod $Fn $Size 8 7 ($fb[6])
        Set-QrFn $Mod $Fn $Size 8 8 ($fb[7])
        Set-QrFn $Mod $Fn $Size 7 8 ($fb[8])
        for ($i = 9; $i -le 14; $i++) { Set-QrFn $Mod $Fn $Size (14 - $i) 8 ($fb[$i]) }

        for ($i = 0; $i -le 7; $i++) { Set-QrFn $Mod $Fn $Size ($Size - 1 - $i) 8 ($fb[$i]) }
        for ($i = 8; $i -le 14; $i++) { Set-QrFn $Mod $Fn $Size 8 ($Size - 15 + $i) ($fb[$i]) }
        Set-QrFn $Mod $Fn $Size 8 ($Size - 8) $true   # always-dark module
    }

    function New-QrMatrix {
        param([Parameter(Mandatory)][string]$Text)

        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        $eccPerBlock = 0, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28
        $blockCount  = 0, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8

        # ---- pick the smallest version that fits ----
        $version = 0
        $dataCw = 0
        $ccBits = 8
        for ($v = 1; $v -le 20; $v++) {
            $dataCw = (Get-QrRawCodewords $v) - $eccPerBlock[$v] * $blockCount[$v]
            $ccBits = 8
            if ($v -ge 10) { $ccBits = 16 }
            if ((4 + $ccBits + 8 * $bytes.Length) -le ($dataCw * 8)) { $version = $v; break }
        }
        if ($version -eq 0) { throw 'The configuration is too large for a QR code.' }

        # ---- build the data bit stream ----
        $bits = [System.Collections.Generic.List[int]]::new()
        foreach ($i in 3..0) { $bits.Add((4 -shr $i) -band 1) }                       # mode: byte
        foreach ($i in ($ccBits - 1)..0) { $bits.Add(($bytes.Length -shr $i) -band 1) } # length
        foreach ($byteVal in $bytes) {
            foreach ($i in 7..0) { $bits.Add(($byteVal -shr $i) -band 1) }
        }
        $term = [Math]::Min(4, ($dataCw * 8) - $bits.Count)
        for ($i = 0; $i -lt $term; $i++) { $bits.Add(0) }
        while (($bits.Count % 8) -ne 0) { $bits.Add(0) }

        $cw = [int[]]::new($dataCw)
        for ($i = 0; $i -lt $bits.Count; $i++) {
            if ($bits[$i] -eq 1) { $cw[$i -shr 3] = $cw[$i -shr 3] -bor (0x80 -shr ($i -band 7)) }
        }
        $pad = 0xEC
        for ($i = [int]($bits.Count / 8); $i -lt $dataCw; $i++) {
            $cw[$i] = $pad
            if ($pad -eq 0xEC) { $pad = 0x11 } else { $pad = 0xEC }
        }

        # ---- Reed-Solomon over GF(256) ----
        $gfExp = [int[]]::new(512)
        $gfLog = [int[]]::new(256)
        $x = 1
        for ($i = 0; $i -lt 255; $i++) {
            $gfExp[$i] = $x
            $gfLog[$x] = $i
            $x = $x -shl 1
            if ($x -band 0x100) { $x = $x -bxor 0x11D }
        }
        for ($i = 255; $i -lt 512; $i++) { $gfExp[$i] = $gfExp[$i - 255] }

        $nb = $blockCount[$version]
        $el = $eccPerBlock[$version]
        $raw = Get-QrRawCodewords $version

        $gen = [int[]]::new($el)
        $gen[$el - 1] = 1
        $root = 1
        for ($i = 0; $i -lt $el; $i++) {
            for ($j = 0; $j -lt $el; $j++) {
                $g = $gen[$j]
                if ($g -ne 0) { $g = $gfExp[$gfLog[$g] + $gfLog[$root]] }
                $gen[$j] = $g
                if (($j + 1) -lt $el) { $gen[$j] = $gen[$j] -bxor $gen[$j + 1] }
            }
            $root = $gfExp[$gfLog[$root] + 1]   # root * 2
        }

        $nShort = $nb - ($raw % $nb)
        $shortLen = [int][Math]::Floor([double]$raw / $nb)
        $dataBlocks = [System.Collections.Generic.List[int[]]]::new()
        $eccBlocks  = [System.Collections.Generic.List[int[]]]::new()
        $k = 0
        for ($blk = 0; $blk -lt $nb; $blk++) {
            $n = $shortLen - $el
            if ($blk -ge $nShort) { $n++ }
            $d = [int[]]::new($n)
            [Array]::Copy($cw, $k, $d, 0, $n)
            $k += $n
            $rem = [int[]]::new($el)
            foreach ($cwByte in $d) {
                $f = $cwByte -bxor $rem[0]
                for ($j = 0; $j -lt ($el - 1); $j++) { $rem[$j] = $rem[$j + 1] }
                $rem[$el - 1] = 0
                if ($f -ne 0) {
                    $lf = $gfLog[$f]
                    for ($j = 0; $j -lt $el; $j++) {
                        $c = $gen[$j]
                        if ($c -ne 0) { $rem[$j] = $rem[$j] -bxor $gfExp[$gfLog[$c] + $lf] }
                    }
                }
            }
            $dataBlocks.Add($d)
            $eccBlocks.Add($rem)
        }

        $final = [int[]]::new($raw)
        $p = 0
        $maxLen = $shortLen - $el + 1
        for ($i = 0; $i -lt $maxLen; $i++) {
            foreach ($db in $dataBlocks) {
                if ($i -lt $db.Length) { $final[$p] = $db[$i]; $p++ }
            }
        }
        for ($i = 0; $i -lt $el; $i++) {
            foreach ($eb in $eccBlocks) { $final[$p] = $eb[$i]; $p++ }
        }

        # ---- function patterns ----
        $size = $version * 4 + 17
        $mod = [int[]]::new($size * $size)
        $fn  = [bool[]]::new($size * $size)

        for ($i = 0; $i -lt $size; $i++) {
            Set-QrFn $mod $fn $size 6 $i (($i % 2) -eq 0)
            Set-QrFn $mod $fn $size $i 6 (($i % 2) -eq 0)
        }
        Add-QrFinder $mod $fn $size 3 3
        Add-QrFinder $mod $fn $size ($size - 4) 3
        Add-QrFinder $mod $fn $size 3 ($size - 4)

        if ($version -ge 2) {
            $na = [int][Math]::Floor([double]$version / 7) + 2
            $step = [int][Math]::Floor([double]($version * 4 + $na * 2 + 1) / ($na * 2 - 2)) * 2
            $pos = @(6) + @(for ($i = $na - 2; $i -ge 0; $i--) { $size - 7 - $i * $step })
            $last = $pos.Count - 1
            for ($i = 0; $i -lt $pos.Count; $i++) {
                for ($j = 0; $j -lt $pos.Count; $j++) {
                    if (($i -eq 0 -and $j -eq 0) -or ($i -eq 0 -and $j -eq $last) -or ($i -eq $last -and $j -eq 0)) { continue }
                    Add-QrAlignment $mod $fn $size $pos[$i] $pos[$j]
                }
            }
        }

        Set-QrFormat $mod $fn $size 0   # placeholder, rewritten after masking

        if ($version -ge 7) {
            $rem = $version
            for ($i = 0; $i -lt 12; $i++) { $rem = ($rem -shl 1) -bxor (($rem -shr 11) * 0x1F25) }
            $vbits = ($version -shl 12) -bor $rem
            for ($i = 0; $i -lt 18; $i++) {
                $bit = ($vbits -shr $i) -band 1
                $a = $size - 11 + ($i % 3)
                $b = [int][Math]::Floor([double]$i / 3)
                Set-QrFn $mod $fn $size $a $b $bit
                Set-QrFn $mod $fn $size $b $a $bit
            }
        }

        # ---- place data bits in the zigzag pattern ----
        $total = $final.Length * 8
        $bitIdx = 0
        $right = $size - 1
        while ($right -ge 1) {
            $r = $right
            if ($r -le 6) { $r-- }
            $up = ((($r + 1) -band 2) -eq 0)
            for ($vert = 0; $vert -lt $size; $vert++) {
                if ($up) { $y = $size - 1 - $vert } else { $y = $vert }
                for ($j = 0; $j -lt 2; $j++) {
                    $xx = $r - $j
                    $idx = $y * $size + $xx
                    if ((-not $fn[$idx]) -and ($bitIdx -lt $total)) {
                        $mod[$idx] = ($final[$bitIdx -shr 3] -shr (7 - ($bitIdx -band 7))) -band 1
                        $bitIdx++
                    }
                }
            }
            $right -= 2
        }

        # ---- mask 0: (x + y) even ----
        for ($y = 0; $y -lt $size; $y++) {
            for ($xx = 0; $xx -lt $size; $xx++) {
                $idx = $y * $size + $xx
                if ((-not $fn[$idx]) -and ((($xx + $y) -band 1) -eq 0)) { $mod[$idx] = $mod[$idx] -bxor 1 }
            }
        }
        Set-QrFormat $mod $fn $size 0

        return [pscustomobject]@{ Version = $version; Size = $size; Modules = $mod }
    }

    function Write-QrCode {
        param($Qr, [string]$Indent = '    ')
        $size = $Qr.Size
        $m = $Qr.Modules
        $quiet = 4
        $full = [string][char]0x2588
        $upper = [string][char]0x2580
        $lower = [string][char]0x2584

        # Dark modules are drawn in black on a white background, so it scans in any terminal theme.
        for ($row = -$quiet; $row -lt ($size + $quiet); $row += 2) {
            $sb = [System.Text.StringBuilder]::new()
            for ($col = -$quiet; $col -lt ($size + $quiet); $col++) {
                $top = $false
                $bottom = $false
                if ($col -ge 0 -and $col -lt $size) {
                    if ($row -ge 0 -and $row -lt $size) { $top = ($m[$row * $size + $col] -eq 1) }
                    $row2 = $row + 1
                    if ($row2 -ge 0 -and $row2 -lt $size) { $bottom = ($m[$row2 * $size + $col] -eq 1) }
                }
                if ($top -and $bottom) { [void]$sb.Append($full) }
                elseif ($top)          { [void]$sb.Append($upper) }
                elseif ($bottom)       { [void]$sb.Append($lower) }
                else                   { [void]$sb.Append(' ') }
            }
            Write-Host $Indent -NoNewline
            # -NoNewline matters: if the newline is written while the white background is active,
            # Windows Terminal paints the rest of the row white. The newline goes out separately.
            Write-Host $sb.ToString() -ForegroundColor Black -BackgroundColor White -NoNewline
            Write-Host ''
        }
    }

    # =====================================================================
    #  Interactive prompts
    # =====================================================================

    function Test-EndpointFormat {
        param([string]$Value)
        if ($Value -match '^(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9.-]+):(\d{1,5})$') {
            return ([int]$Matches[2] -le 65535)
        }
        return $false
    }

    function Read-Option {
        param([string]$Label, [string]$DefaultText)
        Write-Seg ("    " + $Ctx.G.Arrow + " ") Cyan
        Write-Seg $Label White
        Write-Line ("   Enter = " + $DefaultText) DarkGray
        Write-Seg ("      " + $Ctx.G.Arrow + " ") DarkCyan
        $value = [string](Read-Host)
        return $value.Trim().Trim('"').Trim("'").Trim()
    }

    function Read-YesNo {
        param([string]$Question, [bool]$Default = $true)
        if ($Default) { $hint = '[Y/n]' } else { $hint = '[y/N]' }
        while ($true) {
            Write-Seg ("    " + $Ctx.G.Arrow + " ") Cyan
            Write-Seg ($Question + " ") White
            Write-Seg ($hint + " ") DarkGray
            $answer = ([string](Read-Host)).Trim().ToLower()
            if ($answer -eq '') { return $Default }
            if ($answer -in 'y', 'yes') { return $true }
            if ($answer -in 'n', 'no') { return $false }
            Write-Warn 'Please answer y or n.'
        }
    }

    # =====================================================================
    #  Main
    # =====================================================================

    $exitCode = 0
    $prevEncoding = $null
    try {
        $prevEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    } catch { }

    try {
        Write-Banner

        # Interactive mode: started without any parameters -> ask a few questions (Enter = default)
        $interactive = (-not $NoPrompt) -and (-not $OutputFile) -and (-not $WgPath) -and (-not $Endpoint) -and (-not $NoQr) -and (-not $Force)
        try { if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { $interactive = $false } } catch { }

        if (-not $OutputFile) {
            $baseDir = (Get-Location).ProviderPath
            if ($env:windir -and $baseDir.StartsWith($env:windir, [StringComparison]::OrdinalIgnoreCase)) {
                $baseDir = [Environment]::GetFolderPath('UserProfile')   # do not drop a private key into the Windows folder
            }
            $OutputFile = Join-Path $baseDir ((Get-Date -Format 'yyyy-MM-dd-HHmmss') + '.conf')
        }

        if ($interactive) {
            Write-Host ''
            Write-Line '  Options  (press Enter to keep the default)' White
            Write-Host ''
            $answer = Read-Option -Label 'Save config as' -DefaultText $OutputFile
            if ($answer) {
                if ($answer -notmatch '\.[A-Za-z0-9]+$') { $answer += '.conf' }
                $OutputFile = $answer
            }
            Write-Host ''
            while ($true) {
                $answer = Read-Option -Label 'Custom endpoint (ip:port)' -DefaultText "use the one Cloudflare assigns"
                if (-not $answer) { break }
                if (Test-EndpointFormat $answer) { $Endpoint = $answer; break }
                Write-Warn 'Expected <host-or-ip>:<port>, for example 162.159.192.1:2408'
            }
        }

        # ---------------- Step 1: preparation ----------------
        Write-Step 1 4 'Preparing'

        if (-not $WgPath) {
            $possiblePaths = @(
                "wg.exe",
                "awg.exe",
                "C:\Program Files\WireGuard\wg.exe",
                "C:\Program Files\AmneziaWG\awg.exe",
                "C:\Program Files (x86)\WireGuard\wg.exe",
                "C:\Program Files (x86)\AmneziaWG\awg.exe"
            )
            foreach ($p in $possiblePaths) {
                if (Get-Command $p -ErrorAction SilentlyContinue) { $WgPath = $p; break }
            }
        }
        if ($interactive -and (-not $WgPath -or -not (Get-Command $WgPath -ErrorAction SilentlyContinue))) {
            Write-Warn 'Could not find wg.exe or awg.exe automatically.'
            while ($true) {
                $answer = Read-Option -Label 'Path to wg.exe or awg.exe' -DefaultText 'leave empty to cancel'
                if (-not $answer) { break }
                if (Get-Command $answer -ErrorAction SilentlyContinue) { $WgPath = $answer; break }
                Write-Warn 'That file was not found.'
            }
        }
        if (-not $WgPath -or -not (Get-Command $WgPath -ErrorAction SilentlyContinue)) {
            $Ctx.Hint = 'Install WireGuard (wireguard.com/install) or AmneziaWG, or pass -WgPath <path>.'
            throw 'Could not find wg.exe or awg.exe.'
        }
        $wgCmd = Get-Command $WgPath
        $wgDisplay = $wgCmd.Source
        if (-not $wgDisplay) { $wgDisplay = $WgPath }
        Write-Ok ("Found " + (Split-Path -Leaf $wgDisplay)) $wgDisplay

        $finalEndpoint = ''
        if ($Endpoint) {
            if (-not (Test-EndpointFormat $Endpoint)) {
                $Ctx.Hint = 'Expected <host-or-ip>:<port>, for example 162.159.192.1:2408 or [2606:4700:d0::a29f:c001]:2408'
                throw "Invalid -Endpoint value: $Endpoint"
            }
            $finalEndpoint = $Endpoint
        }

        $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputFile)
        $outDir = Split-Path -Parent $fullPath
        if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
            throw "Output folder does not exist: $outDir"
        }
        if ((Test-Path -LiteralPath $fullPath) -and -not $Force) {
            if ($interactive) {
                Write-Warn ("File already exists: " + $fullPath)
                if (-not (Read-YesNo -Question 'Overwrite it?' -Default $false)) {
                    throw 'Cancelled. The existing file was left untouched.'
                }
            } else {
                $Ctx.Hint = 'Use -Force to overwrite it, or choose another -OutputFile.'
                throw "Output file already exists: $fullPath"
            }
        }
        Write-Ok 'Output path is ready'

        # ---------------- Step 2: keys ----------------
        Write-Step 2 4 'Generating key pair'

        $privateKey = (& $WgPath genkey | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or $privateKey -notmatch '^[A-Za-z0-9+/]{43}=$') {
            throw 'Failed to generate a valid private key.'
        }
        $publicKey = ($privateKey | & $WgPath pubkey | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or $publicKey -notmatch '^[A-Za-z0-9+/]{43}=$') {
            throw 'Failed to derive a valid public key.'
        }
        Write-Ok 'Private key generated' '(kept secret, only written to the .conf)'
        Write-Ok 'Public key derived' $publicKey

        # ---------------- Step 3: registration ----------------
        Write-Step 3 4 'Registering with Cloudflare WARP'

        $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.000Z")
        $body = @{
            key           = $publicKey
            install_id    = ""
            fcm_token     = ""
            tos           = $timestamp
            model         = "PC"
            serial_number = ""
            locale        = "en_US"
            os_version    = "16.0.0"
            key_type      = "curve25519"
            tunnel_type   = "wireguard"
        } | ConvertTo-Json -Compress

        $apiUrl = $Ctx.WarpApiUrl
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            $response = Invoke-WarpRegistration -Url $apiUrl -Json $body
        } catch {
            if (-not $Ctx.Hint) { $Ctx.Hint = 'Check your internet connection, VPN or firewall and try again.' }
            throw ("Registration failed: " + $_.Exception.Message)
        }
        $sw.Stop()

        $peer = $response.config.peers | Select-Object -First 1
        if (-not $peer -or -not $peer.public_key) { throw 'No peer information in the WARP response.' }

        $addressParts = @()
        $clientAddressV4 = $response.config.interface.addresses.v4
        $clientAddressV6 = $response.config.interface.addresses.v6
        if ($clientAddressV4) { $addressParts += "$clientAddressV4/32" }
        if ($clientAddressV6) { $addressParts += "$clientAddressV6/128" }
        $address = $addressParts -join ", "
        if (-not $address) { throw 'No client address in the WARP response.' }

        Write-Ok 'Registration successful' ("(" + $sw.Elapsed.TotalSeconds.ToString('0.0') + "s)")

        $accountType = [string]$response.account.account_type
        if ($accountType) { Write-Ok ("Account type: " + $accountType) }

        if ($finalEndpoint) {
            Write-Ok ("Using custom endpoint: " + $finalEndpoint)
        } else {
            $finalEndpoint = Resolve-WarpEndpoint -Peer $peer
            Write-Ok ("Endpoint: " + $finalEndpoint)
        }

        # ---------------- Step 4: write config ----------------
        Write-Step 4 4 'Writing configuration'

        $confLines = @(
            '[Interface]',
            "PrivateKey = $privateKey",
            "Address = $address",
            'Jc = 5',
            'Jmin = 47',
            'Jmax = 98',
            'H1 = 1',
            'H2 = 2',
            'H3 = 3',
            'H4 = 4',
            'DNS = 1.1.1.1, 2606:4700:4700::1111',
            'MTU = 1280',
            '',
            '[Peer]',
            "PublicKey = $($peer.public_key)",
            "Endpoint = $finalEndpoint",
            'AllowedIPs = 0.0.0.0/0, ::/0',
            'PersistentKeepalive = 25'
        )
        $confFile = ($confLines -join "`r`n") + "`r`n"
        $confQr   = ($confLines -join "`n") + "`n"

        # UTF-8 *without* BOM (Out-File -Encoding utf8 adds a BOM on Windows PowerShell 5.1)
        [IO.File]::WriteAllText($fullPath, $confFile, [Text.UTF8Encoding]::new($false))
        Write-Ok 'Config file is ready' $fullPath

        # ---------------- Summary card ----------------
        $g = $Ctx.G
        Write-Host ''
        Write-Seg ("  " + $g.TL + $g.H + " ") Cyan
        Write-Seg 'Summary ' White
        Write-Line ($g.H * 40) Cyan
        Write-Row 'File'       $fullPath
        Write-Row 'Endpoint'   $finalEndpoint Green
        Write-Row 'Address'    $address
        Write-Row 'DNS'        '1.1.1.1, 2606:4700:4700::1111'
        Write-Row 'Public key' $publicKey DarkGray
        Write-Line ("  " + $g.BL + ($g.H * 49)) Cyan

        # ---------------- QR code ----------------
        $showQr = -not $NoQr
        if ($interactive) {
            Write-Host ''
            $showQr = Read-YesNo -Question 'Show a QR code for your phone?' -Default $true
        }
        if ($showQr) {
            try {
                $qr = New-QrMatrix -Text $confQr
                $needed = $qr.Size + 8 + 4
                if ((Get-ConsoleWidth) -lt $needed) {
                    Write-Host ''
                    Write-Warn ("Terminal is too narrow for the QR code (needs " + $needed + " columns). Widen the window and run again.")
                } else {
                    Write-Host ''
                    Write-Seg ("  " + $g.Arrow + " ") Cyan
                    Write-Line 'Scan with the AmneziaWG / WireGuard mobile app' White
                    Write-Host ''
                    Write-QrCode -Qr $qr
                }
            } catch {
                Write-Host ''
                Write-Warn ("Could not draw the QR code: " + $_.Exception.Message)
            }
        }

        # ---------------- Next steps ----------------
        Write-Host ''
        Write-Line '  Next steps' White
        Write-Seg ("    1. ") DarkCyan
        Write-Line 'Desktop: open AmneziaWG > Add tunnel > pick the .conf file' Gray
        Write-Seg ("    2. ") DarkCyan
        Write-Line 'Phone:   open the app > + > Scan from QR code' Gray
        Write-Host ''
        Write-Warn 'The .conf and the QR contain your private key - do not share them.'

        $elapsed = ((Get-Date) - $Ctx.StartTime).TotalSeconds.ToString('0.0')
        Write-Host ''
        Write-Seg ("  " + $g.Ok + " ") Green
        Write-Line ("All done in " + $elapsed + "s") Green
        Write-Host ''
    }
    catch {
        Write-Host ''
        Write-Seg ("  " + $Ctx.G.Fail + " ") Red
        Write-Line $_.Exception.Message Red
        if ($Ctx.Hint) { Write-Line ("    " + $Ctx.Hint) DarkGray }
        Write-Host ''
        $exitCode = 1
    }
    finally {
        if ($prevEncoding) { try { [Console]::OutputEncoding = $prevEncoding } catch { } }
    }

    # Only quit the host when run as a file. Under 'irm | iex' an exit would close the user's terminal.
    if ($PSCommandPath) {
        # Double-click / "Run with PowerShell": the window disappears the moment the script ends,
        # so wait for a key. Only when this script itself started the host (its name is on the
        # host's command line) and Explorer launched it, so normal terminal sessions are untouched.
        $pauseAtEnd = $false
        try {
            $cmdLine = [Environment]::CommandLine
            $scriptName = [IO.Path]::GetFileName($PSCommandPath)
            if (($cmdLine.IndexOf($scriptName, [StringComparison]::OrdinalIgnoreCase) -ge 0) -and ($cmdLine -notmatch '(?i)-NoExit')) {
                $pauseAtEnd = $true   # assume we own the window unless the parent check says otherwise
                try {
                    $parentId = (Get-CimInstance Win32_Process -Filter ("ProcessId = " + $PID)).ParentProcessId
                    if ((Get-Process -Id $parentId -ErrorAction Stop).ProcessName -ne 'explorer') { $pauseAtEnd = $false }
                } catch { }
            }
            if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { $pauseAtEnd = $false }
        } catch { }

        if ($pauseAtEnd) {
            Write-Seg '  Press any key to close this window...' DarkGray
            try { [void][Console]::ReadKey($true) } catch { [void](Read-Host) }
            Write-Host ''
        }
        exit $exitCode
    }
}
