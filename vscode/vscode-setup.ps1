# ==============================================
# VSCode 커스텀 설정 셋업 스크립트
# 기존 설정 유지 + 스크립트 항목은 덮어씀
# ==============================================

Write-Host "`n=== VSCode 설정 셋업 시작 ===" -ForegroundColor Cyan

# --- 데이터 파일 경로 ---
# 호출 방식별 fallback: -File 실행($PSScriptRoot), 일반 호출($MyInvocation), .bat의 인라인 호출($env:SCRIPT_DIR)
if ($PSScriptRoot) {
    $scriptDir = $PSScriptRoot
} elseif ($MyInvocation.MyCommand.Path) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
} elseif ($env:SCRIPT_DIR) {
    $scriptDir = $env:SCRIPT_DIR.TrimEnd('\')
} else {
    Write-Host "[오류] 스크립트 디렉토리를 확인할 수 없습니다." -ForegroundColor Red
    exit 1
}
$dataDir = Join-Path $scriptDir "data"
$settingsTemplatePath = Join-Path $dataDir "settings.json"
$keybindingsTemplatePath = Join-Path $dataDir "keybindings.json"
$extensionsListPath = Join-Path $dataDir "extensions.txt"

foreach ($p in @($settingsTemplatePath, $keybindingsTemplatePath, $extensionsListPath)) {
    if (!(Test-Path $p)) {
        Write-Host "[오류] 데이터 파일 없음: $p" -ForegroundColor Red
        exit 1
    }
}

# --- VSCode 실행 경로 자동 탐색 ---
$codePath = $null
$codePath = Get-Command code -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
if (!$codePath) {
    $candidates = @(
        "$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd",
        "$env:ProgramFiles\Microsoft VS Code\bin\code.cmd",
        "${env:ProgramFiles(x86)}\Microsoft VS Code\bin\code.cmd",
        "$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe",
        "$env:ProgramFiles\Microsoft VS Code\Code.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { $codePath = $c; break }
    }
}

if ($codePath) {
    Write-Host "[OK] VSCode 발견: $codePath" -ForegroundColor Green
} else {
    Write-Host "[경고] VSCode를 찾을 수 없습니다. 확장 설치는 건너뜁니다." -ForegroundColor Yellow
}

# --- 설정 디렉토리 ---
$settingsDir = "$env:APPDATA\Code\User"
if (!(Test-Path $settingsDir)) {
    New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
    Write-Host "[생성] $settingsDir" -ForegroundColor Green
}

# === JSONC 주석 제거 함수 ===
function Remove-JsonComments {
    param([string]$text)
    # 문자열 리터럴을 보존하면서 주석만 제거
    $result = [System.Text.StringBuilder]::new()
    $i = 0
    while ($i -lt $text.Length) {
        # 문자열 리터럴 ("...")은 그대로 통과
        if ($text[$i] -eq '"') {
            $result.Append($text[$i]) | Out-Null
            $i++
            while ($i -lt $text.Length -and $text[$i] -ne '"') {
                if ($text[$i] -eq '\') {
                    $result.Append($text[$i]) | Out-Null
                    $i++
                    if ($i -lt $text.Length) {
                        $result.Append($text[$i]) | Out-Null
                        $i++
                    }
                } else {
                    $result.Append($text[$i]) | Out-Null
                    $i++
                }
            }
            if ($i -lt $text.Length) {
                $result.Append($text[$i]) | Out-Null
                $i++
            }
        }
        # 한줄 주석 //
        elseif ($i + 1 -lt $text.Length -and $text[$i] -eq '/' -and $text[$i+1] -eq '/') {
            while ($i -lt $text.Length -and $text[$i] -ne "`n") { $i++ }
        }
        # 블록 주석 /* */
        elseif ($i + 1 -lt $text.Length -and $text[$i] -eq '/' -and $text[$i+1] -eq '*') {
            $i += 2
            while ($i + 1 -lt $text.Length -and -not ($text[$i] -eq '*' -and $text[$i+1] -eq '/')) { $i++ }
            if ($i + 1 -lt $text.Length) { $i += 2 }
        }
        # trailing comma 제거 (}, ] 앞의 쉼표)
        elseif ($text[$i] -eq ',') {
            $j = $i + 1
            while ($j -lt $text.Length -and $text[$j] -match '\s') { $j++ }
            if ($j -lt $text.Length -and ($text[$j] -eq '}' -or $text[$j] -eq ']')) {
                $i++  # 쉼표 건너뜀
            } else {
                $result.Append($text[$i]) | Out-Null
                $i++
            }
        }
        else {
            $result.Append($text[$i]) | Out-Null
            $i++
        }
    }
    return $result.ToString()
}

# === JSON 병합 함수 (스크립트 항목은 덮어씀, 기존 고유 항목은 유지) ===
# 케이스 불일치(예: "Editor.fontSize" vs "editor.fontSize")는 템플릿의 정상 케이스로 정정.
# 사용자의 값은 보존하고 키 이름만 정정 후 일반 병합 로직 진행 (nested 객체 데이터 보존).
function Merge-Json {
    param($existing, $template)
    foreach ($prop in $template.PSObject.Properties) {
        $key = $prop.Name
        $val = $prop.Value
        $existingProp = $existing.PSObject.Properties[$key]
        if ($existingProp) {
            if ($existingProp.Name -cne $key) {
                $oldName = $existingProp.Name
                $oldValue = $existingProp.Value
                $existing.PSObject.Properties.Remove($oldName)
                $existing | Add-Member -NotePropertyName $key -NotePropertyValue $oldValue
                Write-Host "  [케이스 수정] '$oldName' -> '$key'" -ForegroundColor Yellow
                $existingProp = $existing.PSObject.Properties[$key]
            }
            if ($val -is [PSCustomObject] -and $existingProp.Value -is [PSCustomObject]) {
                Merge-Json $existingProp.Value $val
            } else {
                $existing.$key = $val
                Write-Host "  [덮어씀] $key" -ForegroundColor Yellow
            }
        } else {
            $existing | Add-Member -NotePropertyName $key -NotePropertyValue $val
            Write-Host "  [추가] $key" -ForegroundColor Green
        }
    }
}

# === UTF8 BOM 없이 저장하는 함수 ===
function Save-Utf8NoBom {
    param([string]$path, [string]$content)
    try {
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($path, $content, $utf8)
        return $true
    } catch {
        Write-Host "[오류] 파일 저장 실패: $path" -ForegroundColor Red
        Write-Host "  원인: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  VSCode가 실행 중이면 닫고 다시 시도하세요." -ForegroundColor Yellow
        return $false
    }
}

# === PS 5.1 ConvertTo-Json의 과도한 \uXXXX 이스케이프 복원 ===
# PS 5.1은 < > & ' 및 모든 비-ASCII를 \uXXXX로 출력함.
# 리터럴 백슬래시(\\)는 보존, 제어문자(0x00-0x1F)와 orphan surrogate도 보존.
# 정규식: (?<!\\)((?:\\\\)*)\\u(...) — 앞쪽 백슬래시 짝을 캡처해 보존하면서 진짜 \u 이스케이프만 매칭.
function Restore-JsonUnicode {
    param([string]$json)
    # 1) Surrogate pair (이모지 등 BMP 외 문자) 먼저 처리
    $json = [regex]::Replace($json, '(?<!\\)((?:\\\\)*)\\u([dD][89abAB][0-9a-fA-F]{2})\\u([dD][c-fC-F][0-9a-fA-F]{2})', {
        param($m)
        $hi = [Convert]::ToInt32($m.Groups[2].Value, 16)
        $lo = [Convert]::ToInt32($m.Groups[3].Value, 16)
        $cp = ((($hi - 0xD800) * 0x400) + ($lo - 0xDC00)) + 0x10000
        return $m.Groups[1].Value + [char]::ConvertFromUtf32($cp)
    })
    # 2) BMP 단일 \uXXXX → 실제 문자. 제어문자/orphan surrogate는 보존.
    $json = [regex]::Replace($json, '(?<!\\)((?:\\\\)*)\\u([0-9a-fA-F]{4})', {
        param($m)
        $code = [Convert]::ToInt32($m.Groups[2].Value, 16)
        if ($code -lt 0x20) { return $m.Value }
        if ($code -ge 0xD800 -and $code -le 0xDFFF) { return $m.Value }
        return $m.Groups[1].Value + [string][char]$code
    })
    return $json
}

# === settings.json 병합 ===
Write-Host "`n--- settings.json ---" -ForegroundColor Cyan

$templateRaw = Get-Content $settingsTemplatePath -Raw -Encoding UTF8
$templateClean = Remove-JsonComments $templateRaw
try {
    $template = $templateClean | ConvertFrom-Json
} catch {
    Write-Host "[오류] $settingsTemplatePath 파싱 실패: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

$settingsPath = "$settingsDir\settings.json"
if (Test-Path $settingsPath) {
    $raw = Get-Content $settingsPath -Raw -Encoding UTF8
    $cleaned = Remove-JsonComments $raw
    try {
        $existing = $cleaned | ConvertFrom-Json
        Write-Host "[OK] 기존 settings.json 발견 - 병합 모드" -ForegroundColor Green
        Merge-Json $existing $template
    } catch {
        Write-Host "[경고] 기존 settings.json 파싱 실패 - 백업 후 새로 생성" -ForegroundColor Yellow
        Copy-Item $settingsPath "$settingsPath.bak" -Force
        Write-Host "  백업: $settingsPath.bak" -ForegroundColor Yellow
        $existing = $template
    }
} else {
    Write-Host "[OK] settings.json 없음 - 새로 생성" -ForegroundColor Green
    $existing = $template
}

$json = $existing | ConvertTo-Json -Depth 10
$json = Restore-JsonUnicode $json
if (Save-Utf8NoBom $settingsPath $json) {
    Write-Host "[OK] settings.json 저장 완료" -ForegroundColor Green
}

# === keybindings.json 병합 ===
Write-Host "`n--- keybindings.json ---" -ForegroundColor Cyan

$kbTemplateRaw = Get-Content $keybindingsTemplatePath -Raw -Encoding UTF8
$kbTemplateClean = Remove-JsonComments $kbTemplateRaw
try {
    $parsedTemplateBindings = $kbTemplateClean | ConvertFrom-Json
    if ($null -eq $parsedTemplateBindings) {
        $templateBindings = @()
    } elseif ($parsedTemplateBindings -is [array]) {
        $templateBindings = $parsedTemplateBindings
    } else {
        $templateBindings = @($parsedTemplateBindings)
    }
} catch {
    Write-Host "[오류] $keybindingsTemplatePath 파싱 실패: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

$keybindingsPath = "$settingsDir\keybindings.json"
if (Test-Path $keybindingsPath) {
    $raw = Get-Content $keybindingsPath -Raw -Encoding UTF8
    $cleaned = Remove-JsonComments $raw
    try {
        $parsed = $cleaned | ConvertFrom-Json
        # 단일 객체여도 배열로 래핑
        if ($parsed -is [array]) {
            $existingBindings = [System.Collections.ArrayList]@($parsed)
        } else {
            $existingBindings = [System.Collections.ArrayList]@(,$parsed)
        }
        Write-Host "[OK] 기존 keybindings.json 발견 - 병합 모드" -ForegroundColor Green
    } catch {
        Copy-Item $keybindingsPath "$keybindingsPath.bak" -Force
        Write-Host "[경고] 파싱 실패 - 백업: $keybindingsPath.bak" -ForegroundColor Yellow
        $existingBindings = [System.Collections.ArrayList]::new()
    }
} else {
    $existingBindings = [System.Collections.ArrayList]::new()
    Write-Host "[OK] keybindings.json 없음 - 새로 생성" -ForegroundColor Green
}

foreach ($tb in $templateBindings) {
    $found = $false
    foreach ($eb in $existingBindings) {
        if ($eb.key -eq $tb.key -and $eb.command -eq $tb.command) {
            $found = $true; break
        }
    }
    if (!$found) {
        $existingBindings.Add($tb) | Out-Null
        Write-Host "  [추가] $($tb.key) -> $($tb.command)" -ForegroundColor Green
    }
}

$json = ConvertTo-Json @($existingBindings) -Depth 5
$json = Restore-JsonUnicode $json
if (Save-Utf8NoBom $keybindingsPath $json) {
    Write-Host "[OK] keybindings.json 저장 완료" -ForegroundColor Green
}

# === 확장 프로그램 설치 ===
if ($codePath) {
    Write-Host "`n=== 확장 프로그램 설치 ===" -ForegroundColor Cyan

    $extensions = @(Get-Content $extensionsListPath -Encoding UTF8 |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') })

    $installed = & $codePath --list-extensions 2>$null

    foreach ($ext in $extensions) {
        if ($installed -contains $ext) {
            Write-Host "  $ext ... " -NoNewline
            Write-Host "이미 설치됨" -ForegroundColor DarkGray
        } else {
            Write-Host "  $ext ... " -NoNewline
            & $codePath --install-extension $ext --force > $null 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "설치 완료" -ForegroundColor Green
            } else {
                Write-Host "실패" -ForegroundColor Red
            }
        }
    }
}

Write-Host "`n=== 완료! VSCode를 재시작하세요. ===" -ForegroundColor Cyan
