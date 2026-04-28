#Requires -Version 5.1
<#
.SYNOPSIS
    Windows Terminal 커스텀 설정 스크립트
.DESCRIPTION
    기존 settings.json을 보존하면서, 커스텀 설정만 병합(덮어쓰기)합니다.
    WSL 프로필 관련 설정은 건드리지 않습니다.
    아무 경로에서나 실행 가능합니다.
#>

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

# ============================================================
# 데이터 파일 경로
# ============================================================
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$dataDir = Join-Path $scriptDir "data"
$globalsPath     = Join-Path $dataDir "globals.json"
$defaultsPath    = Join-Path $dataDir "defaults.json"
$schemesPath     = Join-Path $dataDir "schemes.json"
$actionsPath     = Join-Path $dataDir "actions.json"
$keybindingsPath = Join-Path $dataDir "keybindings.json"

foreach ($p in @($globalsPath, $defaultsPath, $schemesPath, $actionsPath, $keybindingsPath)) {
    if (-not (Test-Path $p)) {
        Write-Host "[ERROR] 데이터 파일 없음: $p" -ForegroundColor Red
        exit 1
    }
}

function Load-JsonFile {
    param([string]$Path)
    $raw = Get-Content $Path -Raw -Encoding UTF8
    $clean = Clean-Jsonc $raw
    try {
        return $clean | ConvertFrom-Json
    } catch {
        Write-Host "[ERROR] $Path 파싱 실패: $_" -ForegroundColor Red
        exit 1
    }
}

function Clean-Jsonc {
    param([string]$Text)
    # JSONC → 표준 JSON 변환
    # 1) // 주석, /* */ 주석 제거 (문자열 리터럴 내부 보존)
    # 2) trailing comma 제거 (문자열 리터럴 내부 보존)
    $result = [System.Text.StringBuilder]::new()
    $i = 0
    $len = $Text.Length
    while ($i -lt $len) {
        $ch = $Text[$i]

        # ---- 문자열 리터럴: 그대로 통과 ----
        if ($ch -eq '"') {
            $result.Append($ch) | Out-Null
            $i++
            while ($i -lt $len -and $Text[$i] -ne '"') {
                if ($Text[$i] -eq '\') {
                    $result.Append($Text[$i]) | Out-Null
                    $i++
                    if ($i -lt $len) {
                        $result.Append($Text[$i]) | Out-Null
                        $i++
                    }
                } else {
                    $result.Append($Text[$i]) | Out-Null
                    $i++
                }
            }
            if ($i -lt $len) {
                $result.Append($Text[$i]) | Out-Null
                $i++
            }
        }
        # ---- // 한줄 주석 ----
        elseif ($ch -eq '/' -and ($i + 1) -lt $len -and $Text[$i + 1] -eq '/') {
            while ($i -lt $len -and $Text[$i] -ne "`n") { $i++ }
        }
        # ---- /* */ 블록 주석 ----
        elseif ($ch -eq '/' -and ($i + 1) -lt $len -and $Text[$i + 1] -eq '*') {
            $i += 2
            while ($i -lt $len) {
                if ($Text[$i] -eq '*' -and ($i + 1) -lt $len -and $Text[$i + 1] -eq '/') {
                    $i += 2
                    break
                }
                $i++
            }
        }
        # ---- trailing comma: ,] 또는 ,} ----
        elseif ($ch -eq ',') {
            # 쉼표 뒤의 공백/줄바꿈을 건너뛰고 다음 실질 문자 확인
            $j = $i + 1
            while ($j -lt $len -and ($Text[$j] -eq ' ' -or $Text[$j] -eq "`t" -or $Text[$j] -eq "`r" -or $Text[$j] -eq "`n")) { $j++ }
            if ($j -lt $len -and ($Text[$j] -eq ']' -or $Text[$j] -eq '}')) {
                # trailing comma → 쉼표 제거, 공백은 보존
                $i++
            } else {
                $result.Append($ch) | Out-Null
                $i++
            }
        }
        else {
            $result.Append($ch) | Out-Null
            $i++
        }
    }
    return $result.ToString()
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Windows Terminal 커스텀 설정 도우미" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================
# settings.json 경로 자동 탐색
# ============================================================
$possiblePaths = @(
    "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
    "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json"
    "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json"
)

$settingsPath = $null
foreach ($p in $possiblePaths) {
    if (Test-Path $p) {
        $settingsPath = $p
        break
    }
}

if (-not $settingsPath) {
    Write-Host "[ERROR] Windows Terminal settings.json을 찾을 수 없습니다." -ForegroundColor Red
    Write-Host ""
    Write-Host "Windows Terminal을 먼저 설치해 주세요." -ForegroundColor Yellow
    Write-Host "  - Microsoft Store에서 'Windows Terminal' 검색" -ForegroundColor Gray
    Write-Host "  - 또는: winget install Microsoft.WindowsTerminal" -ForegroundColor Gray
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Host "[OK] settings.json 발견: $settingsPath" -ForegroundColor Green

# ============================================================
# 파일 쓰기 가능 여부 확인 (권한 + 잠금)
# ============================================================
try {
    $stream = [System.IO.File]::Open($settingsPath, 'Open', 'ReadWrite', 'Read')
    $stream.Close()
    $stream.Dispose()
} catch [System.UnauthorizedAccessException] {
    Write-Host "[ERROR] settings.json에 쓰기 권한이 없습니다." -ForegroundColor Red
    Write-Host "        관리자 권한으로 다시 실행하거나 파일 속성을 확인해 주세요." -ForegroundColor Yellow
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit 1
} catch [System.IO.IOException] {
    Write-Host "[ERROR] settings.json이 다른 프로세스에 의해 잠겨 있습니다." -ForegroundColor Red
    Write-Host "        Windows Terminal을 닫고 다시 실행해 주세요." -ForegroundColor Yellow
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit 1
} catch {
    Write-Host "[ERROR] settings.json 접근 실패: $_" -ForegroundColor Red
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit 1
}

# ============================================================
# 백업 생성
# ============================================================
$backupPath = "$settingsPath.bak_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
try {
    Copy-Item $settingsPath $backupPath -ErrorAction Stop
    Write-Host "[OK] 백업 완료: $backupPath" -ForegroundColor Green
} catch {
    Write-Host "[ERROR] 백업 파일 생성 실패: $_" -ForegroundColor Red
    Write-Host "        디스크 용량 또는 쓰기 권한을 확인해 주세요." -ForegroundColor Yellow
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit 1
}
Write-Host ""

# ============================================================
# 기존 설정 읽기 (JSONC → JSON 변환 후 파싱)
# ============================================================
try {
    $rawJson = Get-Content $settingsPath -Raw -Encoding UTF8 -ErrorAction Stop
    $cleanJson = Clean-Jsonc $rawJson
    $settings = $cleanJson | ConvertFrom-Json -ErrorAction Stop
} catch {
    Write-Host "[ERROR] settings.json 파싱 실패: $_" -ForegroundColor Red
    Write-Host "        파일이 손상되었을 수 있습니다. 백업에서 복구하거나" -ForegroundColor Yellow
    Write-Host "        Windows Terminal을 초기화해 주세요." -ForegroundColor Yellow
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit 1
}

# ============================================================
# 1. 전역 설정 (없으면 추가, 있으면 덮어쓰기)
# ============================================================
$globalOverrides = Load-JsonFile $globalsPath

foreach ($prop in $globalOverrides.PSObject.Properties) {
    $settings | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value -Force
}
Write-Host "[OK] 전역 설정 병합 (copyFormatting, disableAnimations 등)" -ForegroundColor Green

# ============================================================
# 2. 프로필 기본값 (defaults) - 기존 값 보존 + 덮어쓰기
# ============================================================
$defaultsTemplate = Load-JsonFile $defaultsPath

# profiles 객체 자체가 없을 수 있음
if (-not $settings.profiles) {
    $settings | Add-Member -NotePropertyName "profiles" -NotePropertyValue ([PSCustomObject]@{
        defaults = [PSCustomObject]@{}
        list     = @()
    }) -Force
}

# defaults가 없으면 생성
if (-not $settings.profiles.defaults) {
    $settings.profiles | Add-Member -NotePropertyName "defaults" -NotePropertyValue ([PSCustomObject]@{}) -Force
}

# 기존 defaults 위에 덮어쓰기 (font는 별도로 nested 병합)
foreach ($prop in $defaultsTemplate.PSObject.Properties) {
    if ($prop.Name -eq "font") { continue }
    $settings.profiles.defaults | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value -Force
}

# font 객체도 기존 보존 + 병합
if ($defaultsTemplate.PSObject.Properties["font"]) {
    if (-not $settings.profiles.defaults.font) {
        $settings.profiles.defaults | Add-Member -NotePropertyName "font" -NotePropertyValue ([PSCustomObject]@{}) -Force
    }
    foreach ($prop in $defaultsTemplate.font.PSObject.Properties) {
        $settings.profiles.defaults.font | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value -Force
    }
}
Write-Host "[OK] 프로필 기본값 병합 (vintage 커서, 폰트 9, 컬러스킴)" -ForegroundColor Green

# ============================================================
# 3. 커스텀 컬러 스킴 (동일 이름은 덮어쓰기, 나머지 보존)
# ============================================================
$customSchemes = @(Load-JsonFile $schemesPath)

$customNames = $customSchemes | ForEach-Object { $_.name }

if ($settings.schemes) {
    $kept = @($settings.schemes | Where-Object { $_.name -notin $customNames })
} else {
    $kept = @()
}
$settings.schemes = @($kept) + @($customSchemes)
Write-Host "[OK] 컬러 스킴 병합 (Campbell modified, sonny_color)" -ForegroundColor Green

# ============================================================
# 4. 액션 (기존 보존 + 커스텀 덮어쓰기)
# ============================================================
$customActions = @(Load-JsonFile $actionsPath)

$customActionIds = $customActions | ForEach-Object { $_.id }

if ($settings.actions) {
    $keptActions = @($settings.actions | Where-Object { $_.id -notin $customActionIds })
} else {
    $keptActions = @()
}
$settings.actions = @($keptActions) + @($customActions)
Write-Host "[OK] 액션 병합 (기존 액션 보존 + 커스텀 추가/덮어쓰기)" -ForegroundColor Green

# ============================================================
# 5. 키바인딩 (기존 보존 + 커스텀 덮어쓰기)
# ============================================================
$customKeybindings = @(Load-JsonFile $keybindingsPath)

$customKbIds = $customKeybindings | ForEach-Object { $_.id }

if ($settings.keybindings) {
    $keptKb = @($settings.keybindings | Where-Object { $_.id -notin $customKbIds })
} else {
    $keptKb = @()
}
$settings.keybindings = @($keptKb) + @($customKeybindings)
Write-Host "[OK] 키바인딩 병합 (기존 보존 + 커스텀 추가/덮어쓰기)" -ForegroundColor Green

# ============================================================
# 저장
# ============================================================
try {
    $jsonOutput = $settings | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($settingsPath, $jsonOutput, [System.Text.UTF8Encoding]::new($false))
} catch {
    Write-Host ""
    Write-Host "[ERROR] settings.json 저장 실패: $_" -ForegroundColor Red
    Write-Host "        Windows Terminal을 닫고 다시 시도해 주세요." -ForegroundColor Yellow
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " 설정 적용 완료!" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "적용 항목:" -ForegroundColor White
Write-Host "  - 커서: vintage / 폰트: 9pt" -ForegroundColor Gray
Write-Host "  - 컬러 스킴: Campbell (modified)" -ForegroundColor Gray
Write-Host "  - 키바인딩: alt+1~9 탭전환, alt+o 새탭" -ForegroundColor Gray
Write-Host "  - 애니메이션 비활성화, URL감지 비활성화" -ForegroundColor Gray
Write-Host ""
Write-Host "건드리지 않은 항목:" -ForegroundColor White
Write-Host "  - 기본 프로필 (defaultProfile)" -ForegroundColor Gray
Write-Host "  - 프로필 목록 (profiles.list)" -ForegroundColor Gray
Write-Host "  - 기존 액션/키바인딩 중 겹치지 않는 것들" -ForegroundColor Gray
Write-Host ""
Write-Host "백업: $backupPath" -ForegroundColor Gray
Write-Host "Windows Terminal을 재시작하면 적용됩니다." -ForegroundColor Yellow
Write-Host ""
Read-Host "Press Enter to exit"
