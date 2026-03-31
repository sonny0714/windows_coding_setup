# ==============================================
# VSCode 커스텀 설정 셋업 스크립트
# 기존 설정 유지 + 스크립트 항목은 덮어씀
# ==============================================

Write-Host "`n=== VSCode 설정 셋업 시작 ===" -ForegroundColor Cyan

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

# === Hashtable을 재귀적으로 PSCustomObject로 변환 ===
function ConvertTo-PSObject {
    param($obj)
    if ($obj -is [hashtable]) {
        $pso = New-Object PSCustomObject
        foreach ($key in $obj.Keys) {
            $pso | Add-Member -NotePropertyName $key -NotePropertyValue (ConvertTo-PSObject $obj[$key])
        }
        return $pso
    }
    elseif ($obj -is [System.Collections.IList]) {
        return @($obj | ForEach-Object { ConvertTo-PSObject $_ })
    }
    return $obj
}

# === JSON 병합 함수 (스크립트 항목은 덮어씀, 기존 고유 항목은 유지) ===
function Merge-Json {
    param($existing, $template)
    foreach ($prop in $template.PSObject.Properties) {
        $key = $prop.Name
        $val = $prop.Value
        if ($existing.PSObject.Properties[$key]) {
            if ($val -is [PSCustomObject] -and $existing.$key -is [PSCustomObject]) {
                Merge-Json $existing.$key $val
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

# === settings.json 병합 ===
Write-Host "`n--- settings.json ---" -ForegroundColor Cyan

$templateSettings = @{
    "editor.fontSize" = 12
    "editor.minimap.enabled" = $false
    "editor.wordBasedSuggestions" = "allDocuments"
    "editor.suggest.filterGraceful" = $false
    "editor.acceptSuggestionOnCommitCharacter" = $false
    "editor.quickSuggestions" = @{ "other" = $false; "comments" = $false; "strings" = $false }
    "files.autoSave" = "afterDelay"
    "files.autoSaveDelay" = 600000
    "workbench.activityBar.location" = "top"
    "workbench.colorTheme" = "Dark+"
    "workbench.colorCustomizations" = @{
        "gitDecoration.modifiedResourceForeground" = "#ffa500"
        "gitDecoration.untrackedResourceForeground" = "#00cc66"
        "gitDecoration.addedResourceForeground" = "#00cc66"
        "gitDecoration.deletedResourceForeground" = "#ff3333"
        "gitDecoration.ignoredResourceForeground" = "#999999"
        "gitDecoration.conflictingResourceForeground" = "#ff0066"
        "gitDecoration.submoduleResourceForeground" = "#6699ff"
    }
    "explorer.confirmDragAndDrop" = $false
    "terminal.integrated.shellIntegration.enabled" = $false
    "vim.hlsearch" = $true
    "editor.experimentalEditContextEnabled" = $false
    "vim.handleKeys" = @{
        "<C-c>" = $false
        "<C-v>" = $false
        "<C-p>" = $true
    }
    "chat.agent.enabled" = $false
    "claudeCode.preferredLocation" = "panel"
    "github.copilot.enable" = @{
        "*" = $false
        "plaintext" = $false
        "markdown" = $false
        "scminput" = $false
    }
}
$template = ConvertTo-PSObject $templateSettings

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
if (Save-Utf8NoBom $settingsPath $json) {
    Write-Host "[OK] settings.json 저장 완료" -ForegroundColor Green
}

# === keybindings.json 병합 ===
Write-Host "`n--- keybindings.json ---" -ForegroundColor Cyan

$templateBindings = @()

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
        $existingBindings.Add([PSCustomObject]$tb) | Out-Null
        Write-Host "  [추가] $($tb.key) -> $($tb.command)" -ForegroundColor Green
    }
}

$json = ConvertTo-Json @($existingBindings) -Depth 5
if (Save-Utf8NoBom $keybindingsPath $json) {
    Write-Host "[OK] keybindings.json 저장 완료" -ForegroundColor Green
}

# === 확장 프로그램 설치 ===
if ($codePath) {
    Write-Host "`n=== 확장 프로그램 설치 ===" -ForegroundColor Cyan

    $extensions = @(
        "anthropic.claude-code"
        "llvm-vs-code-extensions.vscode-clangd"
        "ms-python.vscode-pylance"
        "ms-vscode-remote.remote-ssh"
        "ms-vscode-remote.remote-ssh-edit"
        "ms-vscode.remote-explorer"
        "vscodevim.vim"
    )

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
