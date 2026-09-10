# ============================================================
#  聊天工坊 - 双人聊天 & 小游戏服务器
#  用法：右键“使用 PowerShell 运行”，或执行：
#    powershell -ExecutionPolicy Bypass -File server.ps1
#  手机使用：手机连同一 WiFi，浏览器访问 http://电脑IP:8765
# ============================================================
$port = 8765
$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }
$dataFile = Join-Path $root 'data.json'

# ---------- 全局状态（单线程处理，无需加锁） ----------
$state = @{
    seq    = 1
    users  = @{}   # username -> @{pwd;nick;chips;lastSeen}
    convs  = @{}   # convKey  -> ArrayList of msg
    games  = @{}   # gameId   -> hashtable
    tokens = @{}   # token    -> username
}

# ---------- 工具函数 ----------
function Now { [long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) }

function Hash-Pwd($pwd) {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($pwd + '_chat_salt_2026')
    $sha = [System.Security.Cryptography.SHA256]::Create()
    return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
}

function New-Token {
    $b = New-Object byte[] 24
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
    return (($b | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Conv-Key($a, $b) {
    $arr = @($a, $b) | Sort-Object
    return ($arr -join '__')
}

function Add-Msg($sender, $receiver, $type, $content, $gameId) {
    $key = Conv-Key $sender $receiver
    if (-not $state.convs.ContainsKey($key)) { $state.convs[$key] = New-Object System.Collections.ArrayList }
    $msg = [pscustomobject]@{
        id       = 'm' + $state.seq + '_' + (Get-Random -Maximum 999999)
        sender   = $sender
        receiver = $receiver
        type     = $type
        content  = $content
        gameId   = $gameId
        ts       = (Now)
        recalled = $false
    }
    [void]$state.convs[$key].Add($msg)
    $state.seq++
    return $msg
}

function Save-State {
    try {
        $convs = @{}
        foreach ($k in $state.convs.Keys) { $convs[$k] = @($state.convs[$k]) }
        $obj = @{ seq = $state.seq; users = $state.users; convs = $convs }
        $json = $obj | ConvertTo-Json -Depth 30 -Compress
        [System.IO.File]::WriteAllText($dataFile, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch { Write-Host "保存失败: $_" }
}

function Load-State {
    if (-not (Test-Path $dataFile)) { return }
    try {
        $data = (Get-Content $dataFile -Raw -Encoding UTF8) | ConvertFrom-Json
        if ($data.seq) { $state.seq = [int]$data.seq }
        if ($data.users) {
            foreach ($p in $data.users.PSObject.Properties) {
                $u = $p.Value
                $state.users[$p.Name] = @{ pwd = $u.pwd; nick = $u.nick; chips = [int]$u.chips; lastSeen = [long]0 }
            }
        }
        if ($data.convs) {
            foreach ($p in $data.convs.PSObject.Properties) {
                $list = New-Object System.Collections.ArrayList
                foreach ($m in $p.Value) { [void]$list.Add($m) }
                $state.convs[$p.Name] = $list
            }
        }
        Write-Host "已加载历史数据（用户 $($state.users.Count) 个）"
    } catch { Write-Host "数据加载失败: $_" }
}

function Get-Me($token) {
    if (-not $token) { return $null }
    if ($state.tokens.ContainsKey($token)) {
        $name = $state.tokens[$token]
        if ($state.users.ContainsKey($name)) { return $name }
    }
    return $null
}

# ---------- 扑克牌 ----------
function New-Deck {
    $suits = @('♠', '♥', '♦', '♣')
    $ranks = @('A','2','3','4','5','6','7','8','9','10','J','Q','K')
    $deck = @()
    for ($si = 0; $si -lt 4; $si++) {
        for ($i = 0; $i -lt 13; $i++) {
            $deck += @{ s = $suits[$si]; r = $ranks[$i]; v = ($i + 1); nv = ($(if ($i -ge 10) { 10 } else { $i + 1 })) }
        }
    }
    for ($i = $deck.Count - 1; $i -gt 0; $i--) {
        $j = Get-Random -Maximum ($i + 1)
        $t = $deck[$i]; $deck[$i] = $deck[$j]; $deck[$j] = $t
    }
    return $deck
}

# 检查特殊牌型（五花牛/炸弹/五小牛），返回名称或 $null
function Check-Special($cards) {
    $vals = @($cards | ForEach-Object { [int]$_.nv })
    $bigCount = @($cards | Where-Object { [int]$_.v -gt 5 }).Count
    $allSmall = ($bigCount -eq 0) -and (($vals | Measure-Object -Sum).Sum -le 10)
    if ($allSmall) { return @{ name = '五小牛'; score = 1000 } }
    if (@($cards | Where-Object { [int]$_.v -lt 11 }).Count -eq 0) { return @{ name = '五花牛'; score = 900 } }
    foreach ($i in 1..13) {
        if (@($cards | Where-Object { [int]$_.v -eq $i }).Count -ge 4) { return @{ name = '炸弹'; score = 800 } }
    }
    return $null
}

# 验证玩家手动选的3张牌是否凑成牛，返回结果或 $null
function Eval-ManualNiu($cards, $selIdx) {
    $vals = @($cards | ForEach-Object { [int]$_.nv })
    $sum3 = 0
    foreach ($i in $selIdx) { $sum3 += $vals[[int]$i] }
    if (($sum3 % 10) -ne 0) { return $null }
    $rest = @(0..4 | Where-Object { $_ -notin $selIdx })
    $niu = ($vals[$rest[0]] + $vals[$rest[1]]) % 10
    if ($niu -eq 0) { return @{ name = '牛牛'; score = 700; selIdx = $selIdx } }
    return @{ name = "牛$niu"; score = (100 + $niu * 10); selIdx = $selIdx }
}

# 自动找最佳牛组合（用于"无牛"时检查是否真的无牛，或自动模式）
function Eval-NiuNiu($cards) {
    $special = Check-Special $cards
    if ($special) { return $special }
    $vals = @($cards | ForEach-Object { [int]$_.nv })
    $best = -1
    for ($a = 0; $a -lt 5; $a++) {
        for ($b = $a + 1; $b -lt 5; $b++) {
            for ($c = $b + 1; $c -lt 5; $c++) {
                if ((($vals[$a] + $vals[$b] + $vals[$c]) % 10) -eq 0) {
                    $rest = @(0..4 | Where-Object { $_ -ne $a -and $_ -ne $b -and $_ -ne $c })
                    $niu = (($vals[$rest[0]] + $vals[$rest[1]]) % 10)
                    if ($niu -gt $best) { $best = $niu }
                }
            }
        }
    }
    if ($best -ge 0) {
        if ($best -eq 0) { return @{ name = '牛牛'; score = 700 } }
        return @{ name = "牛$best"; score = (100 + $best * 10) }
    }
    return @{ name = '没牛'; score = 0 }
}

function Eval-Zjh($cards) {
    $sorted = @($cards | Sort-Object { -[int]$_.v })
    $vals = @($sorted | ForEach-Object { [int]$_.v })
    $suits = @($sorted | ForEach-Object { $_.s })
    $isFlush = ($suits[0] -eq $suits[1] -and $suits[1] -eq $suits[2])
    $isTriple = ($vals[0] -eq $vals[1] -and $vals[1] -eq $vals[2])
    $isPair = ($vals[0] -eq $vals[1] -or $vals[1] -eq $vals[2])
    $isStraight = (($vals[0] - $vals[1] -eq 1) -and ($vals[1] - $vals[2] -eq 1)) -or
                  ($vals[0] -eq 13 -and $vals[1] -eq 12 -and $vals[2] -eq 1)
    if ($isTriple) { return @{ name = '豹子'; score = (600 + $vals[0] * 10) } }
    if ($isFlush -and $isStraight) {
        $high = $(if ($vals[0] -eq 13 -and $vals[2] -eq 1) { 14 } else { $vals[0] })
        return @{ name = '顺金'; score = (500 + $high * 10) }
    }
    if ($isFlush) { return @{ name = '金花'; score = (400 + $vals[0] * 100 + $vals[1] * 10 + $vals[2]) } }
    if ($isStraight) {
        $high = $(if ($vals[0] -eq 13 -and $vals[2] -eq 1) { 14 } else { $vals[0] })
        return @{ name = '顺子'; score = (300 + $high * 10) }
    }
    if ($isPair) {
        $pairVal = $(if ($vals[0] -eq $vals[1]) { $vals[0] } else { $vals[1] })
        $singleVal = $(if ($vals[0] -eq $vals[1]) { $vals[2] } else { $vals[0] })
        return @{ name = '对子'; score = (200 + $pairVal * 10 + $singleVal) }
    }
    return @{ name = '单张'; score = (100 + $vals[0] * 10 + $vals[1] + $vals[2] * 0.1) }
}

# ========== 港式五张（梭哈）比牌 ==========
function Eval-Showhand($cards) {
    $vals = @($cards | ForEach-Object { $vv = [int]$_.v; if ($vv -eq 1) { 14 } else { $vv } })
    $suits = @($cards | ForEach-Object { "$($_.s)" })
    $desc = @($vals | Sort-Object -Descending)
    $cnt = @{}
    foreach ($v in $vals) { if ($cnt.ContainsKey($v)) { $cnt[$v]++ } else { $cnt[$v] = 1 } }
    $fours = @($cnt.Keys | Where-Object { $cnt[$_] -eq 4 } | ForEach-Object { [int]$_ })
    $trips = @($cnt.Keys | Where-Object { $cnt[$_] -eq 3 } | ForEach-Object { [int]$_ })
    $pairs = @($cnt.Keys | Where-Object { $cnt[$_] -eq 2 } | ForEach-Object { [int]$_ } | Sort-Object -Descending)
    $uniq = @($vals | Sort-Object -Unique)
    $isFlush = (@($suits | Select-Object -Unique).Count -eq 1)
    $isStraight = $false; $straightHigh = 0
    if ($uniq.Count -eq 5) {
        if (($desc[0] - $desc[4]) -eq 4) { $isStraight = $true; $straightHigh = $desc[0] }
        $s5 = ($uniq | Sort-Object) -join ','
        if ($s5 -eq '2,3,4,5,14') { $isStraight = $true; $straightHigh = 5 }
    }
    # 编码签名为大整数
    $suitRank = @{ '♠' = 4; '♥' = 3; '♣' = 2; '♦' = 1 }
    function Encode-Sig($ranks) {
        $code = 0
        foreach ($r in $ranks) { $code = $code * 15 + [int]$r }
        return $code
    }
    $cat = 0; $name = '散牌'; $sig = $desc
    if ($isStraight -and $isFlush) {
        $cat = 8; $name = '同花顺'; $sig = @($straightHigh)
    } elseif ($fours.Count -eq 1) {
        $kicker = @($vals | Where-Object { $_ -ne $fours[0] })
        $cat = 7; $name = '四条'; $sig = @($fours[0]) + $kicker
    } elseif ($trips.Count -eq 1 -and $pairs.Count -eq 1) {
        $cat = 6; $name = '葫芦'; $sig = @($trips[0], $pairs[0])
    } elseif ($isFlush) {
        $cat = 5; $name = '同花'; $sig = $desc
    } elseif ($isStraight) {
        $cat = 4; $name = '顺子'; $sig = @($straightHigh)
    } elseif ($trips.Count -eq 1) {
        $kickers = @($vals | Where-Object { $_ -ne $trips[0] } | Sort-Object -Descending)
        $cat = 3; $name = '三条'; $sig = @($trips[0]) + $kickers
    } elseif ($pairs.Count -eq 2) {
        $kicker = @($vals | Where-Object { $_ -ne $pairs[0] -and $_ -ne $pairs[1] })
        $cat = 2; $name = '两对'; $sig = @($pairs[0], $pairs[1]) + $kicker
    } elseif ($pairs.Count -eq 1) {
        $kickers = @($vals | Where-Object { $_ -ne $pairs[0] } | Sort-Object -Descending)
        $cat = 1; $name = '对子'; $sig = @($pairs[0]) + $kickers
    }
    $score = $cat * 1000000 + (Encode-Sig $sig)
    # 找最大牌的花色用于完全同分决胜
    $maxV = $desc[0]
    $topSuit2 = 0
    for ($i = 0; $i -lt 5; $i++) { if ([int]$vals[$i] -eq $maxV -and $suitRank[$suits[$i]] -gt $topSuit2) { $topSuit2 = $suitRank[$suits[$i]] } }
    return @{ name = $name; score = $score; suitTop = $topSuit2 }
}

function End-Showhand($g) {
    $hCards = @($g.hostHole) + @($g.hostUp)
    $gCards = @($g.guestHole) + @($g.guestUp)
    $h = Eval-Showhand $hCards
    $gu = Eval-Showhand $gCards
    $g.status = 'ended'
    $hn = Nick-Of $g.host; $gn = Nick-Of $g.guest
    if ($h.score -eq $gu.score) {
        if ($h.suitTop -eq $gu.suitTop) {
            Award-Pot $g $null
            $g.result = "平局：双方都是 $($h.name)，奖池平分"
        } elseif ($h.suitTop -gt $gu.suitTop) {
            Award-Pot $g $g.host
            $g.result = "$hn 的【$($h.name)】以花色胜出 $gn 的【$($gu.name)】"
        } else {
            Award-Pot $g $g.guest
            $g.result = "$gn 的【$($gu.name)】以花色胜出 $hn 的【$($h.name)】"
        }
    } elseif ($h.score -gt $gu.score) {
        Award-Pot $g $g.host
        $g.result = "$hn 的【$($h.name)】战胜 $gn 的【$($gu.name)】"
    } else {
        Award-Pot $g $g.guest
        $g.result = "$gn 的【$($gu.name)】战胜 $hn 的【$($h.name)】"
    }
    $g.lastAction = $g.result
    [void](Add-Msg $g.host $g.guest 'system' ("🎴 梭哈结束：" + $g.result + "，奖池 $($g.pot) 筹码") $g.id)
}

# 梭哈：谁的明牌牌面大谁先行动（平局庄家先）
function Showhand-First($g) {
    $hv = @($g.hostUp | ForEach-Object { $vv = [int]$_.v; if ($vv -eq 1) { 14 } else { $vv } })
    $gv = @($g.guestUp | ForEach-Object { $vv = [int]$_.v; if ($vv -eq 1) { 14 } else { $vv } })
    $hm = ($hv | Measure-Object -Maximum).Maximum
    $gm = ($gv | Measure-Object -Maximum).Maximum
    if ($gm -gt $hm) { return $g.guest }
    return $g.host
}

# 梭哈：一轮下注结束 → 重置并发出下一张明牌（满4张则摊牌）
function Advance-Showhand($g) {
    $g.hostStreet = 0; $g.guestStreet = 0
    $g.hostActed = $false; $g.guestActed = $false
    $g.currentBet = 0
    if (@($g.hostUp).Count -ge 4) {
        End-Showhand $g
        return
    }
    $n = @($g.hostUp).Count
    $g.hostUp = @($g.hostUp) + @($g.deck[2 + 2 * $n])
    $g.guestUp = @($g.guestUp) + @($g.deck[3 + 2 * $n])
    $g.street = [int]$g.street + 1
    $g.turn = Showhand-First $g
    $g.lastAction = "第 $($g.street) 张明牌发出，轮到 $(Nick-Of $g.turn) 说话"
}

function Nick-Of($name) {
    if ($state.users.ContainsKey($name)) { return $state.users[$name].nick }
    return $name
}

# 游戏结算：把奖池给赢家
function Award-Pot($g, $winnerName) {
    if ($winnerName) {
        $state.users[$winnerName].chips = [int]$state.users[$winnerName].chips + [int]$g.pot
        $g.winner = $winnerName
    } else {
        # 平局平分
        $half = [math]::Floor([int]$g.pot / 2)
        $state.users[$g.host].chips = [int]$state.users[$g.host].chips + $half
        $state.users[$g.guest].chips = [int]$state.users[$g.guest].chips + ($g.pot - $half)
        $g.winner = ''
    }
}

function End-NiuNiu($g) {
    # 使用双方提交的结果（hostResult / guestResult）
    if ($g.hostResult) { $h = $g.hostResult } else { $h = Eval-NiuNiu $g.hostCards }
    if ($g.guestResult) { $gu = $g.guestResult } else { $gu = Eval-NiuNiu $g.guestCards }
    $g.status = 'ended'
    $hn = Nick-Of $g.host; $gn = Nick-Of $g.guest
    if ($h.score -eq $gu.score) {
        Award-Pot $g $null
        $g.result = "平局：双方都是 $($h.name)，奖池平分"
    } elseif ($h.score -gt $gu.score) {
        Award-Pot $g $g.host
        $g.result = "$hn 的【$($h.name)】战胜 $gn 的【$($gu.name)】"
    } else {
        Award-Pot $g $g.guest
        $g.result = "$gn 的【$($gu.name)】战胜 $hn 的【$($h.name)】"
    }
    $g.lastAction = $g.result
    [void](Add-Msg $g.host $g.guest 'system' ("🎮 牛牛结束：" + $g.result + "，奖池 $($g.pot) 筹码") $g.id)
}

function End-Zjh($g, $reason) {
    $h = Eval-Zjh $g.hostCards
    $gu = Eval-Zjh $g.guestCards
    $g.status = 'ended'
    $hn = Nick-Of $g.host; $gn = Nick-Of $g.guest
    if ($reason -eq 'fold') {
        # 弃牌者在调用处处理奖池
    } elseif ($h.score -eq $gu.score) {
        Award-Pot $g $null
        $g.result = "平局：双方都是 $($h.name)，奖池平分"
    } elseif ($h.score -gt $gu.score) {
        Award-Pot $g $g.host
        $g.result = "$hn 的【$($h.name)】战胜 $gn 的【$($gu.name)】"
    } else {
        Award-Pot $g $g.guest
        $g.result = "$gn 的【$($gu.name)】战胜 $hn 的【$($h.name)】"
    }
    $g.lastAction = $g.result
    [void](Add-Msg $g.host $g.guest 'system' ("🎮 炸金花结束：" + $g.result + "，奖池 $($g.pot) 筹码") $g.id)
}

# 构造发给某个玩家的游戏视图（隐藏对手的牌）
function Build-GameView($g, $me) {
    $iAmHost = ($g.host -eq $me)
    $myCards = $(if ($iAmHost) { $g.hostCards } else { $g.guestCards })
    $oppName = $(if ($iAmHost) { $g.guest } else { $g.host })
    $oppSeen = $false
    $oppCards = $null
    if ($g.status -eq 'ended') {
        $oppCards = $(if ($iAmHost) { $g.guestCards } else { $g.hostCards })
        $oppSeen = $true
    }
    $myLooked = $(if ($iAmHost) { $g.hostLooked } else { $g.guestLooked })
    $myFolded = $(if ($iAmHost) { $g.hostFolded } else { $g.guestFolded })
    $myOpened = $(if ($iAmHost) { $g.hostOpened } else { $g.guestOpened })
    $oppLooked = $(if ($iAmHost) { $g.guestLooked } else { $g.hostLooked })
    $oppFolded = $(if ($iAmHost) { $g.guestFolded } else { $g.hostFolded })
    $oppOpened = $(if ($iAmHost) { $g.guestOpened } else { $g.hostOpened })
    # 炸金花：自己没看牌前，自己的牌也是背面
    $showMyCards = $true
    if ($g.type -eq 'zhajinhua' -and -not $myLooked -and $g.status -ne 'ended') { $showMyCards = $false }
    # 牛牛选牌阶段：自己的牌始终可见（要选牌）
    $mySelection = $(if ($iAmHost) { $g.hostSelection } else { $g.guestSelection })
    $myResult = $(if ($iAmHost) { $g.hostResult } else { $g.guestResult })
    $mySubmitted = [bool]$(if ($iAmHost) { $g.hostSubmitted } else { $g.guestSubmitted })
    $oppSubmitted = [bool]$(if ($iAmHost) { $g.guestSubmitted } else { $g.hostSubmitted })
    # 牛牛：结束后也显示对手的选牌
    $oppSelection = $null
    if ($g.status -eq 'ended' -and $g.type -eq 'niuniu') {
        $oppSelection = $(if ($iAmHost) { $g.guestSelection } else { $g.hostSelection })
    }
    # 梭哈：自己的底牌+明牌；对方明牌始终可见，底牌仅摊牌后可见
    $myHole = $null; $myUp = @(); $oppHole = $null; $oppUp = @()
    if ($g.type -eq 'showhand') {
        if ($iAmHost) {
            $myHole = $g.hostHole; $myUp = @($g.hostUp)
            $oppUp = @($g.guestUp)
            if ($g.status -eq 'ended') { $oppHole = $g.guestHole }
        } else {
            $myHole = $g.guestHole; $myUp = @($g.guestUp)
            $oppUp = @($g.hostUp)
            if ($g.status -eq 'ended') { $oppHole = $g.hostHole }
        }
    }
    return [pscustomobject]@{
        id = $g.id; type = $g.type; status = $g.status
        host = $g.host; guest = $g.guest
        hostNick = (Nick-Of $g.host); guestNick = (Nick-Of $g.guest)
        bet = [int]$g.bet; pot = [int]$g.pot; currentBet = [int]$g.currentBet; round = [int]$g.round
        turn = $g.turn; winner = $g.winner; result = $g.result; lastAction = $g.lastAction
        iAmHost = $iAmHost; myName = $me; oppName = $oppName
        myNick = (Nick-Of $me); oppNick = (Nick-Of $oppName)
        myCards = @($myCards); showMyCards = $showMyCards
        myLooked = [bool]$myLooked; myFolded = [bool]$myFolded; myOpened = [bool]$myOpened
        oppCards = $(if ($oppCards) { @($oppCards) } else { $null }); oppSeen = $oppSeen
        oppLooked = [bool]$oppLooked; oppFolded = [bool]$oppFolded; oppOpened = [bool]$oppOpened
        mySelection = $(if ($mySelection) { @($mySelection) } else { $null })
        myResult = $myResult; mySubmitted = $mySubmitted; oppSubmitted = $oppSubmitted
        oppSelection = $(if ($oppSelection) { @($oppSelection) } else { $null })
        myHole = $myHole; myUp = @($myUp); oppHole = $oppHole; oppUp = @($oppUp)
        street = [int]$g.street
        myStreetPaid = [int]$(if ($iAmHost) { $g.hostStreet } else { $g.guestStreet })
        oppStreetPaid = [int]$(if ($iAmHost) { $g.guestStreet } else { $g.hostStreet })
    }
}

# ---------- HTTP 响应 ----------
function Write-Response($client, $code, $text, $contentType, $bodyBytes) {
    try {
        $stream = $client.GetStream()
        $head = "HTTP/1.1 $code $text`r`n" +
                "Content-Type: $contentType`r`n" +
                "Content-Length: $($bodyBytes.Length)`r`n" +
                "Access-Control-Allow-Origin: *`r`n" +
                "Access-Control-Allow-Headers: Content-Type`r`n" +
                "Access-Control-Allow-Methods: GET,POST,OPTIONS`r`n" +
                "Connection: close`r`n`r`n"
        $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
        $stream.Write($hb, 0, $hb.Length)
        $stream.Write($bodyBytes, 0, $bodyBytes.Length)
        $stream.Flush()
    } catch {}
}

function Send-Json($client, $obj, $code = 200, $text = 'OK') {
    $json = ($obj | ConvertTo-Json -Depth 30 -Compress)
    if (-not $json) { $json = '{}' }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    Write-Response $client $code $text 'application/json; charset=utf-8' $bytes
}

function Send-Err($client, $msg, $code = 400) {
    Send-Json $client ([pscustomobject]@{ ok = $false; error = $msg }) $code
}

# ---------- 路由处理 ----------
function Handle-Api($client, $path, $query, $req) {
    # --- 注册 ---
    if ($path -eq '/api/register' -and $req) {
        $u = ("$($req.username)").Trim()
        $p = "$($req.password)"
        $nick = "$($req.nickname)"
        if ($u.Length -lt 3 -or $u.Length -gt 20) { Send-Err $client '用户名需 3-20 位字符'; return }
        if ($p.Length -lt 6) { Send-Err $client '密码至少 6 位'; return }
        if ($state.users.ContainsKey($u)) { Send-Err $client '用户名已存在'; return }
        if (-not $nick) { $nick = $u }
        $state.users[$u] = @{ pwd = (Hash-Pwd $p); nick = $nick; chips = 1000; lastSeen = (Now) }
        $token = New-Token
        $state.tokens[$token] = $u
        $state.seq++; Save-State
        Send-Json $client ([pscustomobject]@{ ok = $true; token = $token; username = $u; nickname = $nick; chips = 1000 })
        return
    }
    # --- 登录 ---
    if ($path -eq '/api/login' -and $req) {
        $u = ("$($req.username)").Trim()
        $p = "$($req.password)"
        if (-not $state.users.ContainsKey($u)) { Send-Err $client '用户不存在'; return }
        if ($state.users[$u].pwd -ne (Hash-Pwd $p)) { Send-Err $client '密码错误'; return }
        $state.users[$u].lastSeen = (Now)
        $token = New-Token
        $state.tokens[$token] = $u
        Save-State
        Send-Json $client ([pscustomobject]@{ ok = $true; token = $token; username = $u; nickname = $state.users[$u].nick; chips = [int]$state.users[$u].chips })
        return
    }
    # --- 轮询同步 ---
    if ($path -eq '/api/poll') {
        $ptoken = $query.token
        if (-not $ptoken -and $req -and $req.token) { $ptoken = $req.token }
        $me = Get-Me $ptoken
        if (-not $me) { Send-Err $client '未登录' 401; return }
        $state.users[$me].lastSeen = (Now)
        $now = Now
        $users = @()
        foreach ($k in $state.users.Keys) {
            $uu = $state.users[$k]
            $users += [pscustomobject]@{
                username = $k; nickname = $uu.nick; chips = [int]$uu.chips
                online = (($now - [long]$uu.lastSeen) -lt 9000)
            }
        }
        $convs = @{}
        foreach ($key in $state.convs.Keys) {
            $parts = $key -split '__'
            if ($parts -contains $me) { $convs[$key] = @($state.convs[$key]) }
        }
        $games = @()
        foreach ($g in $state.games.Values) {
            if ($g.host -eq $me -or $g.guest -eq $me) { $games += (Build-GameView $g $me) }
        }
        Send-Json $client ([pscustomobject]@{
            ok = $true; seq = $state.seq; now = $now
            me = [pscustomobject]@{ username = $me; nickname = $state.users[$me].nick; chips = [int]$state.users[$me].chips }
            users = $users; convs = $convs; games = $games
        })
        return
    }
    # --- 改昵称 ---
    if ($path -eq '/api/nickname' -and $req) {
        $me = Get-Me $req.token
        if (-not $me) { Send-Err $client '未登录' 401; return }
        $nick = ("$($req.nickname)").Trim()
        if ($nick.Length -lt 1 -or $nick.Length -gt 20) { Send-Err $client '昵称需 1-20 字'; return }
        $state.users[$me].nick = $nick
        $state.seq++; Save-State
        Send-Json $client ([pscustomobject]@{ ok = $true; nickname = $nick })
        return
    }
    # --- 发消息 ---
    if ($path -eq '/api/messages' -and $req) {
        $me = Get-Me $req.token
        if (-not $me) { Send-Err $client '未登录' 401; return }
        $peer = "$($req.peer)"
        if (-not $state.users.ContainsKey($peer)) { Send-Err $client '用户不存在'; return }
        $type = "$($req.type)"; if (-not $type) { $type = 'text' }
        $content = "$($req.content)"
        if ($type -eq 'text' -and -not $content.Trim()) { Send-Err $client '内容为空'; return }
        $msg = Add-Msg $me $peer $type $content "$($req.gameId)"
        Save-State
        Send-Json $client ([pscustomobject]@{ ok = $true; msg = $msg })
        return
    }
    # --- 撤回 ---
    if ($path -eq '/api/messages/recall' -and $req) {
        $me = Get-Me $req.token
        if (-not $me) { Send-Err $client '未登录' 401; return }
        foreach ($key in $state.convs.Keys) {
            foreach ($m in $state.convs[$key]) {
                if ($m.id -eq "$($req.msgId)" -and $m.sender -eq $me) {
                    if ((Now) - $m.ts -lt 120000) {
                        $m.recalled = $true; $state.seq++; Save-State
                        Send-Json $client ([pscustomobject]@{ ok = $true }); return
                    } else {
                        Send-Err $client '超过 2 分钟不可撤回'; return
                    }
                }
            }
        }
        Send-Err $client '消息不存在'; return
    }
    # --- 清空聊天记录 ---
    if ($path -eq '/api/messages/clear' -and $req) {
        $me = Get-Me $req.token
        if (-not $me) { Send-Err $client '未登录' 401; return }
        $peer = "$($req.peer)"
        $key = Conv-Key $me $peer
        if ($state.convs.ContainsKey($key)) { $state.convs.Remove($key) }
        $state.seq++; Save-State
        Send-Json $client ([pscustomobject]@{ ok = $true })
        return
    }
    # --- 筹码充值 ---
    if ($path -eq '/api/chips/recharge' -and $req) {
        $me = Get-Me $req.token
        if (-not $me) { Send-Err $client '未登录' 401; return }
        if ("$($req.pwd)" -ne '123321') { Send-Err $client '充值密码错误'; return }
        $amount = [int]$req.amount
        if ($amount -lt 1) { $amount = 1000 }
        $state.users[$me].chips = [int]$state.users[$me].chips + $amount
        $state.seq++; Save-State
        Send-Json $client ([pscustomobject]@{ ok = $true; chips = [int]$state.users[$me].chips })
        return
    }
    # --- 创建游戏（发出邀请） ---
    if ($path -eq '/api/game/create' -and $req) {
        $me = Get-Me $req.token
        if (-not $me) { Send-Err $client '未登录' 401; return }
        $peer = "$($req.peer)"
        $type = "$($req.type)"
        if ($type -ne 'niuniu' -and $type -ne 'zhajinhua' -and $type -ne 'showhand') { Send-Err $client '未知游戏'; return }
        if (-not $state.users.ContainsKey($peer)) { Send-Err $client '用户不存在'; return }
        $bet = [int]$req.bet
        if ($bet -lt 10) { $bet = 50 }
        $id = 'g' + $state.seq
        $g = @{
            id = $id; type = $type; host = $me; guest = $peer
            status = 'waiting'; bet = $bet; pot = 0; currentBet = $bet; round = 0
            turn = $null; winner = $null; result = ''
            lastAction = '等待对方接受邀请'
            hostCards = @(); guestCards = @()
            hostLooked = $false; guestLooked = $false
            hostFolded = $false; guestFolded = $false
            hostOpened = $false; guestOpened = $false
            hostSelection = $null; guestSelection = $null
            hostResult = $null; guestResult = $null
            hostSubmitted = $false; guestSubmitted = $false
            deck = @(); street = 0
            hostHole = $null; guestHole = $null
            hostUp = @(); guestUp = @()
            hostStreet = 0; guestStreet = 0
            hostActed = $false; guestActed = $false
            ts = (Now)
        }
        $state.games[$id] = $g
        $typeName = $(if ($type -eq 'niuniu') { '牛牛' } elseif ($type -eq 'showhand') { '梭哈' } else { '炸金花' })
        [void](Add-Msg $me $peer 'game_invite' $typeName $id)
        $state.seq++; Save-State
        Send-Json $client ([pscustomobject]@{ ok = $true; gameId = $id })
        return
    }
    # --- 游戏动作 ---
    if ($path -eq '/api/game/action' -and $req) {
        $me = Get-Me $req.token
        if (-not $me) { Send-Err $client '未登录' 401; return }
        $gid = "$($req.gameId)"
        $g = $null
        foreach ($x in $state.games.Values) { if ($x.id -eq $gid) { $g = $x; break } }
        if (-not $g) { Send-Err $client '游戏不存在'; return }
        if ($g.host -ne $me -and $g.guest -ne $me) { Send-Err $client '你不在这局游戏中'; return }
        $act = "$($req.act)"
        $iAmHost = ($g.host -eq $me)
        $other = $(if ($iAmHost) { $g.guest } else { $g.host })

        # 接受邀请
        if ($act -eq 'join') {
            if ($g.status -ne 'waiting') { Send-Json $client ([pscustomobject]@{ ok = $true }); return }
            if ([int]$state.users[$g.host].chips -lt $g.bet -or [int]$state.users[$g.guest].chips -lt $g.bet) {
                Send-Err $client '有玩家筹码不足，无法开始'; return
            }
            $state.users[$g.host].chips = [int]$state.users[$g.host].chips - [int]$g.bet
            $state.users[$g.guest].chips = [int]$state.users[$g.guest].chips - [int]$g.bet
            $deck = New-Deck
            if ($g.type -eq 'niuniu') {
                $g.hostCards = @($deck[0..4]); $g.guestCards = @($deck[5..9])
            } elseif ($g.type -eq 'showhand') {
                $g.deck = $deck
                $g.hostHole = $deck[0]; $g.guestHole = $deck[1]
                $g.hostUp = @($deck[2]); $g.guestUp = @($deck[3])
                $g.street = 1
            } else {
                $g.hostCards = @($deck[0..2]); $g.guestCards = @($deck[3..5])
            }
            $g.pot = [int]$g.bet * 2
            if ($g.type -eq 'niuniu') {
                $g.status = 'selecting'
                $g.lastAction = '发牌完成！请选择3张牌凑牛'
            } elseif ($g.type -eq 'showhand') {
                $g.status = 'playing'
                $g.currentBet = 0
                $g.turn = Showhand-First $g
                $g.lastAction = "梭哈开始！底牌+第1张明牌已发，$(Nick-Of $g.turn) 先说话"
            } else {
                $g.status = 'playing'
                $g.lastAction = '游戏开始！双方已下底注'
                $g.turn = $g.host
            }
            $state.seq++; Save-State
            Send-Json $client ([pscustomobject]@{ ok = $true }); return
        }

        # 拒绝邀请
        if ($act -eq 'decline' -and $g.status -eq 'waiting') {
            if ($me -ne $g.guest) { Send-Err $client '只有被邀请人可以拒绝'; return }
            $g.status = 'ended'
            $g.result = '对方拒绝了游戏邀请'
            $g.lastAction = $g.result
            $state.seq++; Save-State
            Send-Json $client ([pscustomobject]@{ ok = $true }); return
        }

        # 牛牛：手动选牌阶段
        if ($g.type -eq 'niuniu') {
            if ($g.status -ne 'selecting') { Send-Err $client '当前不可选牌'; return }
            $mySubmitted = $(if ($iAmHost) { $g.hostSubmitted } else { $g.guestSubmitted })
            if ($mySubmitted) { Send-Err $client '你已确认过牌型'; return }

            # 确认特殊牌型（五花牛/炸弹/五小牛）— 直接提交
            if ($act -eq 'confirmspecial') {
                $myCards = $(if ($iAmHost) { $g.hostCards } else { $g.guestCards })
                $sp = Check-Special $myCards
                if (-not $sp) { Send-Err $client '你没有特殊牌型'; return }
                if ($iAmHost) { $g.hostResult = $sp; $g.hostSubmitted = $true } else { $g.guestResult = $sp; $g.guestSubmitted = $true }
                $g.lastAction = "$(Nick-Of $me) 确认牌型：$($sp.name)"
                if ($g.hostSubmitted -and $g.guestSubmitted) { End-NiuNiu $g }
                $state.seq++; Save-State
                Send-Json $client ([pscustomobject]@{ ok = $true }); return
            }

            # 无牛
            if ($act -eq 'noniu') {
                if ($iAmHost) { $g.hostResult = @{ name = '没牛'; score = 0 }; $g.hostSubmitted = $true } else { $g.guestResult = @{ name = '没牛'; score = 0 }; $g.guestSubmitted = $true }
                $g.lastAction = "$(Nick-Of $me) 确认：没牛"
                if ($g.hostSubmitted -and $g.guestSubmitted) { End-NiuNiu $g }
                $state.seq++; Save-State
                Send-Json $client ([pscustomobject]@{ ok = $true }); return
            }

            # 选牌确认
            if ($act -eq 'select') {
                $selRaw = $req.selIdx
                if (-not $selRaw) { Send-Err $client '请选择3张牌'; return }
                $sel = @($selRaw | ForEach-Object { [int]$_ })
                if ($sel.Count -ne 3) { Send-Err $client '需要选3张牌'; return }
                # 去重检查
                $unique = @($sel | Sort-Object -Unique)
                if ($unique.Count -ne 3) { Send-Err $client '不能选同一张牌'; return }
                foreach ($x in $sel) { if ($x -lt 0 -or $x -gt 4) { Send-Err $client '牌索引越界'; return } }
                $myCards = $(if ($iAmHost) { $g.hostCards } else { $g.guestCards })
                $result = Eval-ManualNiu $myCards $sel
                if (-not $result) { Send-Err $client '这3张牌之和不是10的倍数，凑不成牛！请重新选或选「没牛」'; return }
                if ($iAmHost) { $g.hostSelection = $sel; $g.hostResult = $result; $g.hostSubmitted = $true } else { $g.guestSelection = $sel; $g.guestResult = $result; $g.guestSubmitted = $true }
                $g.lastAction = "$(Nick-Of $me) 确认牌型：$($result.name)"
                if ($g.hostSubmitted -and $g.guestSubmitted) { End-NiuNiu $g }
                $state.seq++; Save-State
                Send-Json $client ([pscustomobject]@{ ok = $true }); return
            }
            Send-Err $client '未知动作'; return
        }

        # 梭哈动作
        if ($g.type -eq 'showhand') {
            if ($g.status -ne 'playing') { Send-Err $client '游戏未在进行'; return }
            $nn = Nick-Of $me
            # 弃牌
            if ($act -eq 'fold') {
                if ($g.turn -ne $me) { Send-Err $client '还没轮到你操作'; return }
                if ($iAmHost) { $g.hostFolded = $true } else { $g.guestFolded = $true }
                $g.status = 'ended'
                Award-Pot $g $other
                $g.result = "$nn 弃牌，$(Nick-Of $other) 赢得奖池 $($g.pot) 筹码"
                $g.lastAction = $g.result
                [void](Add-Msg $g.host $g.guest 'system' ("🎴 梭哈：" + $g.result) $g.id)
                $state.seq++; Save-State
                Send-Json $client ([pscustomobject]@{ ok = $true }); return
            }
            if ($g.turn -ne $me) { Send-Err $client '还没轮到你操作'; return }
            $myPaid = $(if ($iAmHost) { [int]$g.hostStreet } else { [int]$g.guestStreet })
            if ($act -eq 'call') {
                $cost = [int]$g.currentBet - $myPaid
                if ($cost -lt 0) { $cost = 0 }
                if ([int]$state.users[$me].chips -lt $cost) { Send-Err $client '筹码不足，请点击 ＋ 补充'; return }
                $state.users[$me].chips = [int]$state.users[$me].chips - $cost
                $g.pot = [int]$g.pot + $cost
                if ($iAmHost) { $g.hostStreet = [int]$g.currentBet; $g.hostActed = $true } else { $g.guestStreet = [int]$g.currentBet; $g.guestActed = $true }
                if ($cost -eq 0) { $g.lastAction = "$nn 过牌" } else { $g.lastAction = "$nn 跟注 $cost" }
                # 判断本轮是否结束：对方已行动且双方投入相等
                $otherActed = $(if ($iAmHost) { $g.guestActed } else { $g.hostActed })
                $otherPaid = $(if ($iAmHost) { [int]$g.guestStreet } else { [int]$g.hostStreet })
                if ($otherActed -and $otherPaid -eq [int]$g.currentBet) {
                    Advance-Showhand $g
                } else {
                    $g.turn = $other
                }
                $state.seq++; Save-State
                Send-Json $client ([pscustomobject]@{ ok = $true }); return
            }
            if ($act -eq 'raise') {
                $newBet = $(if ([int]$g.currentBet -eq 0) { [int]$g.bet } else { [int]$g.currentBet * 2 })
                $cost = $newBet - $myPaid
                if ([int]$state.users[$me].chips -lt $cost) { Send-Err $client '筹码不足，请点击 ＋ 补充'; return }
                $state.users[$me].chips = [int]$state.users[$me].chips - $cost
                $g.pot = [int]$g.pot + $cost
                $g.currentBet = $newBet
                if ($iAmHost) {
                    $g.hostStreet = $newBet; $g.hostActed = $true; $g.guestActed = $false
                } else {
                    $g.guestStreet = $newBet; $g.guestActed = $true; $g.hostActed = $false
                }
                $g.turn = $other
                $g.lastAction = "$nn 加注，本轮需跟 $newBet（本次投入 $cost）"
                $state.seq++; Save-State
                Send-Json $client ([pscustomobject]@{ ok = $true }); return
            }
            Send-Err $client '未知动作'; return
        }

        # 炸金花动作
        if ($g.type -eq 'zhajinhua') {
            if ($g.status -ne 'playing') { Send-Err $client '游戏未在进行'; return }
            $myLooked = $(if ($iAmHost) { $g.hostLooked } else { $g.guestLooked })
            if ($act -eq 'look') {
                if ($iAmHost) { $g.hostLooked = $true } else { $g.guestLooked = $true }
                $g.lastAction = "$(Nick-Of $me) 看了牌"
                $state.seq++; Save-State
                Send-Json $client ([pscustomobject]@{ ok = $true }); return
            }
            if ($g.turn -ne $me) { Send-Err $client '还没轮到你操作'; return }
            $nn = Nick-Of $me
            switch ($act) {
                'call' {
                    $cost = $(if ($myLooked) { [int]$g.currentBet * 2 } else { [int]$g.currentBet })
                    if ([int]$state.users[$me].chips -lt $cost) { Send-Err $client '筹码不足，请点击 ＋ 补充'; return }
                    $state.users[$me].chips = [int]$state.users[$me].chips - $cost
                    $g.pot = [int]$g.pot + $cost
                    $g.round = [int]$g.round + 1
                    $g.turn = $other
                    $g.lastAction = "$nn 跟注 $cost"
                }
                'raise' {
                    $cost = $(if ($myLooked) { [int]$g.currentBet * 4 } else { [int]$g.currentBet * 2 })
                    if ([int]$state.users[$me].chips -lt $cost) { Send-Err $client '筹码不足，请点击 ＋ 补充'; return }
                    $state.users[$me].chips = [int]$state.users[$me].chips - $cost
                    $g.pot = [int]$g.pot + $cost
                    if ($myLooked) { $g.currentBet = [int]$g.currentBet * 2 }
                    $g.round = [int]$g.round + 1
                    $g.turn = $other
                    $g.lastAction = "$nn 加注 $cost，当前注 $($g.currentBet)"
                }
                'fold' {
                    if ($iAmHost) { $g.hostFolded = $true } else { $g.guestFolded = $true }
                    $g.status = 'ended'
                    Award-Pot $g $other
                    $g.result = "$nn 弃牌，$(Nick-Of $other) 赢得奖池 $($g.pot) 筹码"
                    $g.lastAction = $g.result
                    [void](Add-Msg $g.host $g.guest 'system' ("🎮 炸金花：" + $g.result) $g.id)
                    $state.seq++; Save-State
                    Send-Json $client ([pscustomobject]@{ ok = $true }); return
                }
                'compare' {
                    if (-not $myLooked) { Send-Err $client '请先看牌再比牌'; return }
                    $cost = [int]$g.currentBet * 2
                    if ([int]$state.users[$me].chips -lt $cost) { Send-Err $client '筹码不足，请点击 ＋ 补充'; return }
                    $state.users[$me].chips = [int]$state.users[$me].chips - $cost
                    $g.pot = [int]$g.pot + $cost
                    End-Zjh $g 'compare'
                    $state.seq++; Save-State
                    Send-Json $client ([pscustomobject]@{ ok = $true }); return
                }
                default { Send-Err $client '未知动作'; return }
            }
            # 轮数过多自动比牌
            if ([int]$g.round -ge 12) {
                if (-not $g.hostLooked) { $g.hostLooked = $true }
                if (-not $g.guestLooked) { $g.guestLooked = $true }
                End-Zjh $g 'autocompare'
            }
            $state.seq++; Save-State
            Send-Json $client ([pscustomobject]@{ ok = $true }); return
        }
        Send-Err $client '未知动作'; return
    }
    Send-Err $client '未知接口' 404
}

# ---------- 启动服务器 ----------
Load-State
$listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Any, $port)
try {
    $listener.Start()
} catch {
    Write-Host "端口 $port 被占用，请先关闭之前的服务器窗口" -ForegroundColor Red
    Read-Host '按回车退出'; exit
}

# 打印局域网地址
$ips = @()
try {
    $ips = [System.Net.Dns]::GetHostEntry([System.Net.Dns]::GetHostName()).AddressList |
        Where-Object { $_.AddressFamily -eq 'InterNetwork' -and -not $_.IPAddressToString.StartsWith('169.254') } |
        ForEach-Object { $_.IPAddressToString }
} catch {}

Write-Host ''
Write-Host '==============================================' -ForegroundColor Cyan
Write-Host '  聊天工坊服务器已启动！' -ForegroundColor Green
Write-Host '==============================================' -ForegroundColor Cyan
Write-Host "  本机访问： http://localhost:$port"
foreach ($ip in $ips) { Write-Host "  手机访问： http://${ip}:$port   （手机需连同一 WiFi）" -ForegroundColor Yellow }
Write-Host '==============================================' -ForegroundColor Cyan
Write-Host '  按 Ctrl+C 停止服务器'
Write-Host ''

$htmlPath = Join-Path $root 'index.html'

while ($true) {
    $client = $null
    try {
        $client = $listener.AcceptTcpClient()
    } catch { continue }
    try {
        $client.ReceiveTimeout = 8000
        $client.SendTimeout = 8000
        $stream = $client.GetStream()
        $ms = New-Object System.IO.MemoryStream
        $buf = New-Object byte[] 16384
        $headerEnd = -1
        $headerText = ''
        # 读到请求头结束
        for ($tries = 0; $tries -lt 50; $tries++) {
            $n = $stream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $ms.Write($buf, 0, $n)
            $headerText = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
            $idx = $headerText.IndexOf("`r`n`r`n")
            if ($idx -ge 0) { $headerEnd = $idx + 4; break }
        }
        if ($headerEnd -lt 0) { try { $client.Close() } catch {}; continue }

        # 解析请求行
        $lines = $headerText.Substring(0, $headerEnd - 4) -split "`r`n"
        $reqLine = $lines[0]
        $parts = $reqLine -split ' '
        if ($parts.Count -lt 2) { try { $client.Close() } catch {}; continue }
        $method = $parts[0]
        $urlPath = $parts[1]

        # Content-Length
        $contentLength = 0
        foreach ($line in $lines) {
            if ($line -match '^Content-Length:\s*(\d+)' -or $line -match '^content-length:\s*(\d+)') {
                $contentLength = [int]$Matches[1]
            }
        }
        # 读完 body
        while ($ms.Length -lt ($headerEnd + $contentLength)) {
            $n = $stream.Read($buf, 0, [math]::Min($buf.Length, ($headerEnd + $contentLength - $ms.Length)))
            if ($n -le 0) { break }
            $ms.Write($buf, 0, $n)
        }
        $all = $ms.ToArray()
        $bodyStr = ''
        if ($contentLength -gt 0) {
            $bodyStr = [System.Text.Encoding]::UTF8.GetString($all, $headerEnd, [math]::Min($contentLength, $all.Length - $headerEnd))
        }

        # 解析 path / query
        $pathOnly = $urlPath
        $query = @{}
        $qIdx = $urlPath.IndexOf('?')
        if ($qIdx -ge 0) {
            $pathOnly = $urlPath.Substring(0, $qIdx)
            $qstr = $urlPath.Substring($qIdx + 1)
            foreach ($pair in $qstr -split '&') {
                $kv = $pair -split '=', 2
                if ($kv.Count -eq 2) { $query[[uri]::UnescapeDataString($kv[0])] = [uri]::UnescapeDataString($kv[1]) }
            }
        }

        # OPTIONS 预检
        if ($method -eq 'OPTIONS') {
            Write-Response $client 204 'No Content' 'text/plain' ([byte[]]@())
            try { $client.Close() } catch {}
            continue
        }

        # 静态文件
        if ($method -eq 'GET' -and ($pathOnly -eq '/' -or $pathOnly -eq '/index.html')) {
            if (Test-Path $htmlPath) {
                $bytes = [System.IO.File]::ReadAllBytes($htmlPath)
                Write-Response $client 200 'OK' 'text/html; charset=utf-8' $bytes
            } else {
                $eb = [System.Text.Encoding]::UTF8.GetBytes('index.html not found')
                Write-Response $client 404 'Not Found' 'text/plain' $eb
            }
            try { $client.Close() } catch {}
            continue
        }

        # API
        if ($pathOnly -like '/api/*') {
            $reqBody = $null
            if ($bodyStr) {
                try { $reqBody = $bodyStr | ConvertFrom-Json } catch { $reqBody = $null }
            }
            # body 之外允许 query 带 token
            if ($reqBody -and -not $reqBody.token -and $query.token) {
                $reqBody | Add-Member -NotePropertyName token -NotePropertyValue $query.token -Force
            }
            try {
                Handle-Api $client $pathOnly $query $reqBody
            } catch {
                Write-Host "API错误 $pathOnly : $_" -ForegroundColor Red
                try { Send-Err $client '服务器内部错误' 500 } catch {}
            }
            try { $client.Close() } catch {}
            continue
        }

        $nb = [System.Text.Encoding]::UTF8.GetBytes('Not Found')
        Write-Response $client 404 'Not Found' 'text/plain' $nb
        try { $client.Close() } catch {}
    } catch {
        # 单连接失败不影响服务器
    } finally {
        try { $client.Close() } catch {}
    }
}
