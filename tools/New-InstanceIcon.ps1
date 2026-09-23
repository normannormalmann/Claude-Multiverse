<#
.SYNOPSIS
    Generate a simple .ico badge so each Claude instance is distinguishable
    in the taskbar.

.DESCRIPTION
    Draws a rounded square in a colour of your choice with a single large
    letter on top, and writes it as a 256x256 PNG-compressed .ico
    (supported by Windows Vista and later).

    Deliberately generic artwork - no third-party logos are redistributed
    with this repository. Point -OutFile anywhere and pass the result to
    claude-multiverse.ps1 shortcut -Icon.

.EXAMPLE
    .\New-InstanceIcon.ps1 -Letter P -Color "#D97757" -OutFile "$env:USERPROFILE\.claude-icons\private.ico"
    .\New-InstanceIcon.ps1 -Letter W -Color "#4A7DBF" -OutFile "$env:USERPROFILE\.claude-icons\work.ico"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^.$')]
    [string]$Letter,

    [string]$Color = '#D97757',

    [string]$TextColor = '#F0EEE6',

    [Parameter(Mandatory = $true)]
    [string]$OutFile,

    # Suppress the summary lines (used when called from claude-multiverse.ps1).
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

function ConvertFrom-Hex {
    param([string]$Hex)
    $h = $Hex.TrimStart('#')
    if ($h.Length -ne 6) { throw "Colour must be #RRGGBB, got '$Hex'" }
    return [System.Drawing.Color]::FromArgb(
        255,
        [Convert]::ToInt32($h.Substring(0, 2), 16),
        [Convert]::ToInt32($h.Substring(2, 2), 16),
        [Convert]::ToInt32($h.Substring(4, 2), 16)
    )
}

$size    = 256
$bgColor = ConvertFrom-Hex $Color
$fgColor = ConvertFrom-Hex $TextColor

$bmp = New-Object System.Drawing.Bitmap($size, $size)
$g   = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
$g.Clear([System.Drawing.Color]::Transparent)

# rounded square background
$r    = [int]($size * 0.22)
$d    = $r * 2
$path = New-Object System.Drawing.Drawing2D.GraphicsPath
$path.AddArc(0, 0, $d, $d, 180, 90)
$path.AddArc($size - $d - 1, 0, $d, $d, 270, 90)
$path.AddArc($size - $d - 1, $size - $d - 1, $d, $d, 0, 90)
$path.AddArc(0, $size - $d - 1, $d, $d, 90, 90)
$path.CloseFigure()

$brush = New-Object System.Drawing.SolidBrush($bgColor)
$g.FillPath($brush, $path)

# centred letter
$font      = New-Object System.Drawing.Font('Segoe UI', ($size * 0.58), [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
$textBrush = New-Object System.Drawing.SolidBrush($fgColor)
$format    = New-Object System.Drawing.StringFormat
$format.Alignment     = [System.Drawing.StringAlignment]::Center
$format.LineAlignment = [System.Drawing.StringAlignment]::Center
$rect = New-Object System.Drawing.RectangleF(0, 0, $size, $size)
$g.DrawString($Letter.ToUpper(), $font, $textBrush, $rect, $format)

foreach ($o in $g, $font, $textBrush, $brush, $path, $format) { $o.Dispose() }

# --- write PNG-compressed .ico -------------------------------------------
$ms = New-Object System.IO.MemoryStream
$bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
$png = $ms.ToArray()
$ms.Dispose()
$bmp.Dispose()

$dir = Split-Path $OutFile -Parent
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

$fs = [System.IO.File]::Create($OutFile)
$bw = New-Object System.IO.BinaryWriter($fs)
$bw.Write([UInt16]0)               # reserved
$bw.Write([UInt16]1)               # type: icon
$bw.Write([UInt16]1)               # image count
$bw.Write([Byte]0)                 # width  (0 = 256)
$bw.Write([Byte]0)                 # height (0 = 256)
$bw.Write([Byte]0)                 # palette
$bw.Write([Byte]0)                 # reserved
$bw.Write([UInt16]1)               # colour planes
$bw.Write([UInt16]32)              # bits per pixel
$bw.Write([UInt32]$png.Length)     # payload size
$bw.Write([UInt32]22)              # payload offset
$bw.Write($png)
$bw.Close()
$fs.Close()

if (-not $Quiet) {
    Write-Host "  OK    Icon written: $OutFile" -ForegroundColor Green
    Write-Host "  ..    Use it with: .\claude-multiverse.ps1 shortcut <name> -Icon `"$OutFile`"" -ForegroundColor Gray
}
