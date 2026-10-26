param(
  [Parameter(Position = 0)][string]$Product = '',
  [Parameter(Position = 1)][string]$Action = ''
)
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -eq 'Desktop' -and [int][Net.ServicePointManager]::SecurityProtocol -ne 0) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}
$utf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8

if (@('codex:wait', 'codex:session-start', 'codex:claim', 'claude:wait', 'claude:session-start', 'claude:claim') -notcontains "${Product}:${Action}") {
  [Console]::Error.WriteLine('usage: wake.ps1 codex|claude wait|session-start|claim')
  exit 64
}

if ($env:AGENT_CHAT_WAKE_DIR) {
  $dir = $env:AGENT_CHAT_WAKE_DIR
} elseif ($Product -eq 'codex') {
  $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
  $dir = Join-Path $codexHome 'agent-chat'
} else {
  $claudeHome = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
  $dir = Join-Path $claudeHome 'agent-chat'
}
$config = Join-Path $dir 'wake.env'
$pluginRoot = Split-Path -Parent $PSScriptRoot
$idleText = 'No new agent-chat notices. Call the agent-chat tool chat_identity once so this session keeps waiting, then end the turn with one word.'
$refusedText = 'The chat refused the agent-chat wake token, so this session stopped waiting for notices: the connection was removed or expired, or the agent or its workspace was deleted. Tell the person in one sentence, and say they can type Connect agent-chat to connect again.'
$connectedText = 'agent-chat connected this conversation, and it now waits for notices. Tell the person in one short sentence that it is connected, then end the turn.'
$codeRefusedText = 'The chat refused the agent-chat connection code, so this conversation is not connected. Tell the person, and run the agent-chat connect skill again only if they ask.'
$addressMissingText = 'The agent-chat plugin has no chat address in its .mcp.json, so this conversation is not connected. Tell the person to reinstall the agent-chat plugin.'
$unreachableText = 'agent-chat could not reach the chat to connect this conversation. Tell the person to check the network, and run the agent-chat connect skill again only if they ask.'
$foreignCodeText = 'The agent-chat connection code was not used, because this conversation did not get it from the chat_wake_code tool of agent-chat. Tell the person, and run the agent-chat connect skill again only if they ask.'
$alreadyConnectedText = 'This conversation is already connected to agent-chat, so the new connection code was not used. To connect another agent, the person removes this connection on the Agents page of agent-chat, under Tokens and Plugin connections, and then runs the agent-chat connect skill again.'

function Read-Settings {
  $values = @{}
  if (Test-Path -LiteralPath $config) {
    foreach ($line in [System.IO.File]::ReadAllLines($config, $utf8)) {
      $index = $line.IndexOf('=')
      if ($index -gt 0) { $values[$line.Substring(0, $index)] = $line.Substring($index + 1).Trim() }
    }
  }
  $values
}

function Test-ConnectedAsBefore {
  (Read-Settings)['AGENT_CHAT_WAKE_TOKEN'] -eq $script:token
}

function Save-Setting([string]$Key, [string]$Value) {
  $lines = @()
  if (Test-Path -LiteralPath $config) { $lines = @([System.IO.File]::ReadAllLines($config, $utf8) | Where-Object { -not $_.StartsWith("$Key=") }) }
  if ($Value) { $lines += "$Key=$Value" }
  $temporary = "$config.$PID.tmp"
  try {
    [System.IO.File]::WriteAllLines($temporary, [string[]]$lines, $utf8)
    Move-Item -LiteralPath $temporary -Destination $config -Force
  } finally {
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
  }
}

function Number-Setting([hashtable]$Values, [string]$Key, [int]$Default) {
  $value = $Values[$Key]
  if ($value -match '^\d+$') { [int]$value } else { $Default }
}

function Read-Number([string]$Path) {
  if (Test-Path -LiteralPath $Path) {
    $value = ([System.IO.File]::ReadAllText($Path, $utf8)).Trim()
    if ($value -match '^\d+$') { return $value }
  }
  $null
}

function Get-TokenMark {
  $digest = [System.Security.Cryptography.SHA256]::Create().ComputeHash($utf8.GetBytes("$script:token"))
  -join ($digest[0..5] | ForEach-Object { $_.ToString('x2') })
}

function Read-Marked([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return @{ State = 'missing' } }
  $parts = @(([System.IO.File]::ReadAllText($Path, $utf8)).Trim() -split '\s+')
  if ($parts.Count -eq 1 -and $parts[0] -match '^\d+$') { return @{ State = 'mine'; Number = $parts[0] } }
  if ($parts.Count -eq 2 -and $parts[1] -match '^\d+$') {
    if ($parts[0] -eq (Get-TokenMark)) { return @{ State = 'mine'; Number = $parts[1] } }
    return @{ State = 'foreign' }
  }
  @{ State = 'missing' }
}

function Write-Number([string]$Path, [string]$Value) {
  [System.IO.File]::WriteAllText($Path, "$Value`n", $utf8)
}

$settings = Read-Settings
$url = "$($settings['AGENT_CHAT_WAKE_URL'])".TrimEnd('/')
$token = "$($settings['AGENT_CHAT_WAKE_TOKEN'])"
$code = "$($settings['AGENT_CHAT_WAKE_CODE'])"
$budget = Number-Setting $settings 'AGENT_CHAT_WAKE_BUDGET_SECONDS' 1740
$waitSeconds = Number-Setting $settings 'AGENT_CHAT_WAKE_WAIT_SECONDS' 20
$margin = Number-Setting $settings 'AGENT_CHAT_WAKE_MARGIN_SECONDS' 15
$retryMin = Number-Setting $settings 'AGENT_CHAT_WAKE_RETRY_MIN_SECONDS' 2
$retryMax = Number-Setting $settings 'AGENT_CHAT_WAKE_RETRY_MAX_SECONDS' 60
$unknownCursor = '999999999999999'
$userAgent = 'agent-chat-wake/1'

foreach ($leftover in @(Get-ChildItem -LiteralPath $dir -Filter 'wake.env.*.tmp' -File -ErrorAction SilentlyContinue)) {
  if ($leftover.Name -match '^wake\.env\.(\d{1,9})\.tmp$' -and ([int]$Matches[1] -eq $PID -or -not (Get-Process -Id ([int]$Matches[1]) -ErrorAction SilentlyContinue))) {
    Remove-Item -LiteralPath $leftover.FullName -Force -ErrorAction SilentlyContinue
  }
}

function Invoke-Wake([string]$Method, [string]$Address, [hashtable]$Headers, [string]$Body, [int]$TimeoutSeconds) {
  $arguments = @{ Uri = $Address; Method = $Method; Headers = $Headers; UserAgent = $userAgent; TimeoutSec = $TimeoutSeconds; UseBasicParsing = $true }
  if ($Body) { $arguments['Body'] = $utf8.GetBytes($Body); $arguments['ContentType'] = 'application/json' }
  try {
    $response = Invoke-WebRequest @arguments
    $reader = New-Object System.IO.StreamReader($response.RawContentStream, $utf8)
    $cursor = $response.Headers['X-Agent-Chat-Cursor']
    if ($cursor -is [array]) { $cursor = $cursor[-1] }
    return @{ Status = [int]$response.StatusCode; Body = $reader.ReadToEnd(); Cursor = "$cursor" }
  } catch [System.Net.WebException] {
    $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
    return @{ Status = $status; Body = ''; Cursor = '' }
  } catch {
    $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
    return @{ Status = $status; Body = ''; Cursor = '' }
  }
}

function Invoke-Claim {
  if ($script:code -notmatch '^[A-Za-z0-9_-]+$') {
    [Console]::Error.WriteLine('No valid AGENT_CHAT_WAKE_CODE in wake.env.')
    return $false
  }
  $answer = Invoke-Wake 'POST' "$url/wake/claim" @{} "{`"code`":`"$($script:code)`"}" ($waitSeconds + $margin)
  $script:claimStatus = $answer.Status
  $received = $answer.Body.Trim()
  if ($answer.Status -eq 200 -and $received -match '^saw_[A-Za-z0-9_-]+$') {
    Save-Setting 'AGENT_CHAT_WAKE_TOKEN' $received
    Save-Setting 'AGENT_CHAT_WAKE_CODE' ''
    $script:token = $received
    Write-Marked (Join-Path $dir 'cursor') $unknownCursor
    Remove-Item -LiteralPath (Join-Path $dir 'stopped'), (Join-Path $dir 'pending') -Force -ErrorAction SilentlyContinue
    return $true
  }
  [Console]::Error.WriteLine("The chat refused the connection code (HTTP $($answer.Status)). Run the connect skill again for a new code.")
  $false
}

function Write-Marked([string]$Path, [string]$Value) {
  Write-Number $Path "$(Get-TokenMark) $Value"
}

function Deliver-Body([string]$Body) {
  if ($Product -eq 'codex') {
    [Console]::Out.Write($Body)
    exit 0
  }
  [Console]::Error.Write($Body)
  exit 2
}

function Deliver-Text([string]$Text) {
  if ($Product -eq 'codex') {
    [Console]::Out.WriteLine((@{ decision = 'block'; reason = $Text } | ConvertTo-Json -Compress))
    exit 0
  }
  [Console]::Error.WriteLine($Text)
  exit 2
}

function Test-IssuedHere([string]$Transcript, [string]$Offered) {
  if (-not $Transcript) { return $false }
  for ($try = 0; $try -lt 5; $try++) {
    if (Test-Path -LiteralPath $Transcript -PathType Leaf) {
      $stream = $null
      try {
        $stream = New-Object System.IO.FileStream($Transcript, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $reader = New-Object System.IO.StreamReader($stream, $utf8)
        while ($null -ne ($line = $reader.ReadLine())) {
          if ($line.Contains('"server":"agent-chat","tool":"chat_wake_code"') -and $line.Contains("`"structuredContent`":{`"code`":`"$Offered`"")) { return $true }
        }
      } catch {
      } finally {
        if ($stream) { $stream.Dispose() }
      }
    }
    if ($try -lt 4) { Start-Sleep -Seconds 1 }
  }
  $false
}

if ($Product -eq 'codex' -and $Action -eq 'wait' -and [Console]::IsInputRedirected) {
  $stopText = [Console]::In.ReadToEnd()
  $offers = [regex]::Matches($stopText, 'agent-chat wake code: `?(swc_[A-Za-z0-9_-]{43})`?(\\n)?"')
  if ($offers.Count -gt 0) {
    if ($token -and -not (Test-Path -LiteralPath (Join-Path $dir 'stopped'))) { Deliver-Text $alreadyConnectedText }
    $offered = $offers[$offers.Count - 1].Groups[1].Value
    $transcript = ''
    try { $transcript = "$(($stopText | ConvertFrom-Json).transcript_path)" } catch { $transcript = '' }
    if (-not (Test-IssuedHere $transcript $offered)) { Deliver-Text $foreignCodeText }
    $pluginUrl = ''
    try {
      $servers = (Get-Content -LiteralPath (Join-Path $pluginRoot '.mcp.json') -Raw -Encoding UTF8 | ConvertFrom-Json).mcpServers
      $pluginUrl = "$($servers.'agent-chat'.url)".TrimEnd('/')
    } catch {
      $pluginUrl = ''
    }
    if ($pluginUrl.EndsWith('/mcp')) { $pluginUrl = $pluginUrl.Substring(0, $pluginUrl.Length - 4) }
    if (-not $pluginUrl) { Deliver-Text $addressMissingText }
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $url = $pluginUrl
    $code = $offered
    Save-Setting 'AGENT_CHAT_WAKE_URL' $url
    Save-Setting 'AGENT_CHAT_WAKE_TOKEN' ''
    Save-Setting 'AGENT_CHAT_WAKE_CODE' $code
    $script:claimStatus = $null
    if (Invoke-Claim) { Deliver-Text $connectedText }
    Save-Setting 'AGENT_CHAT_WAKE_CODE' ''
    if ($script:claimStatus -eq 0) { Deliver-Text $unreachableText }
    Deliver-Text $codeRefusedText
  }
}

if (-not (Test-Path -LiteralPath $dir -PathType Container)) { exit 0 }
if (-not $url) { exit 0 }

if ($Action -eq 'claim') {
  if (-not (Invoke-Claim)) { exit 1 }
  [Console]::Out.WriteLine('Connected: this session now wakes on agent-chat notices.')
  exit 0
}

if (Test-Path -LiteralPath (Join-Path $dir 'stopped')) { exit 0 }
if (-not $token) {
  if (-not $code) { exit 0 }
  if (-not (Invoke-Claim)) { exit 0 }
}
$authorization = @{ Authorization = "Bearer $token" }
$cursorFile = Join-Path $dir 'cursor'
$pendingFile = Join-Path $dir 'pending'
$savedCursor = Read-Marked $cursorFile
$cursor = if ($savedCursor.State -eq 'mine') { $savedCursor.Number } elseif ($savedCursor.State -eq 'foreign') { $unknownCursor } else { '0' }

if ($Action -eq 'session-start') {
  if ((Read-Marked $pendingFile).State -ne 'mine') { exit 0 }
  $answer = Invoke-Wake 'GET' "$url/wake?after=$cursor&wait=0&format=session-start&redelivery=1" $authorization '' $margin
  if ($answer.Status -eq 200) { [Console]::Out.Write($answer.Body) }
  exit 0
}

$lock = Join-Path $dir 'wake.lock'
$lockPid = Join-Path $lock 'pid'
$ownsLock = $false
try {
  try {
    New-Item -ItemType Directory -Path $lock -ErrorAction Stop | Out-Null
  } catch {
    $holder = Read-Number $lockPid
    if ($holder) {
      if (Get-Process -Id ([int]$holder) -ErrorAction SilentlyContinue) { exit 0 }
    } elseif ((Get-Item -LiteralPath $lock).LastWriteTimeUtc -gt [DateTime]::UtcNow.AddMinutes(-1)) {
      exit 0
    }
    Remove-Item -LiteralPath $lock -Recurse -Force -ErrorAction SilentlyContinue
    try { New-Item -ItemType Directory -Path $lock -ErrorAction Stop | Out-Null } catch { exit 0 }
  }
  $ownsLock = $true
  Write-Number $lockPid $PID

  $savedPending = Read-Marked $pendingFile
  if ($savedPending.State -eq 'mine') {
    $cursor = $savedPending.Number
    Write-Marked $cursorFile $cursor
  }
  Remove-Item -LiteralPath $pendingFile -Force -ErrorAction SilentlyContinue

  $format = if ($Product -eq 'codex') { 'stop' } else { 'text' }
  $deadline = [DateTime]::UtcNow.AddSeconds($budget)
  $backoff = $retryMin
  while ($true) {
    $left = [int][Math]::Floor(($deadline - [DateTime]::UtcNow).TotalSeconds)
    $waitNow = $waitSeconds
    if ($waitNow + $margin -gt $left) { $waitNow = $left - $margin }
    if ($waitNow -lt 1) { break }
    if (-not (Test-ConnectedAsBefore)) { exit 0 }
    $answer = Invoke-Wake 'GET' "$url/wake?after=$cursor&wait=$waitNow&format=$format" $authorization '' ($waitNow + $margin)
    if (-not (Test-ConnectedAsBefore)) {
      if ($answer.Status -eq 200 -and $answer.Cursor -match '^\d+$') { Deliver-Body $answer.Body }
      exit 0
    }
    if ($answer.Status -eq 200 -and $answer.Cursor -match '^\d+$') {
      Write-Marked $pendingFile $answer.Cursor
      Deliver-Body $answer.Body
    }
    if ($answer.Status -eq 204) {
      if ($cursor -eq $unknownCursor -and $answer.Cursor -eq $unknownCursor) {
        $cursor = '0'
        Write-Marked $cursorFile $cursor
      } elseif ($answer.Cursor -match '^\d+$' -and $answer.Cursor -ne $cursor) {
        $cursor = $answer.Cursor
        Write-Marked $cursorFile $cursor
      }
      $backoff = $retryMin
      continue
    }
    if ($answer.Status -eq 401 -or $answer.Status -eq 403) {
      [System.IO.File]::WriteAllText((Join-Path $dir 'stopped'), '', $utf8)
      Deliver-Text $refusedText
    }
    $left = [int][Math]::Floor(($deadline - [DateTime]::UtcNow).TotalSeconds) - $margin
    if ($left -lt 1) { break }
    Start-Sleep -Seconds ([Math]::Min($backoff, $left))
    $backoff = [Math]::Min($backoff * 2, $retryMax)
  }
  Deliver-Text $idleText
} finally {
  if ($ownsLock) { Remove-Item -LiteralPath $lock -Recurse -Force -ErrorAction SilentlyContinue }
}
