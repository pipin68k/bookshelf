<#
.SYNOPSIS
  data/isbn13.txt を元に、国立国会図書館サーチ(NDL Search)のSRU APIへ
  ISBNを1件ずつ問い合わせて書誌情報とNDC分類を取得し、
  data/books.json を生成・更新する。

.DESCRIPTION
  入力ファイルの空行を除く各ISBNについて:
    - 出力ファイルに既にNDC分類まで取得済みのエントリがあれば、
      -Force を指定しない限りリクエストをスキップする(APIへ毎回
      問い合わせない)。これはNDL Searchを配慮して使うため。
      タイトルは取れたがNDCが不明なエントリ(NDL側にそもそもNDCが
      登録されていない、主に古いタイトルに多い)は、後日の再目録化で
      NDCが付与される可能性があるため毎回再試行する。
    - スキップしない場合は https://ndlsearch.ndl.go.jp/api/sru
      (recordSchema=dcndl)へ問い合わせ、-IntervalSeconds 待ってから
      レスポンスを解析する。
    - 1つのISBNに複数の候補レコードがある場合(NDL Searchは各participating
      library=参加図書館のレコードを集約して返す)、NDL自身の書誌
      (リポジトリR100000002)を優先する。これが最も情報が揃っている
      ことが多いため。なければ最初のレコードを使う。
    - NDLにデータがないISBNは、削除せずにスタブ(title/author等をnullの
      まま)として記録する。アプリ側の「(タイトル未設定)」表示に対応する。
  既存のbooks.jsonのうち、ISBN起点でないエントリ(手動追加した電子書籍等)
  はそのまま変更しない。

.PARAMETER IntervalSeconds
  NDL Searchへの実際のリクエスト間の最小待機秒数。既定2秒。
  NDL Searchから急なリクエストを避けるよう求められているため。

.PARAMETER Force
  NDC分類を取得済みのエントリも含め、全ISBNを再取得する。

.PARAMETER Limit
  実際にリクエストが必要なISBNのうち、先頭N件だけ処理する(0で無制限)。
  全件実行する前にお試しで動かす用途。

.EXAMPLE
  .\scripts\ConvertTo-BooksJson.ps1
.EXAMPLE
  .\scripts\ConvertTo-BooksJson.ps1 -IntervalSeconds 3 -Limit 10
#>
param(
    [string]$IsbnFile = (Join-Path $PSScriptRoot "..\data\isbn13.txt"),
    [string]$OutFile = (Join-Path $PSScriptRoot "..\data\books.json"),
    [double]$IntervalSeconds = 2,
    [switch]$Force,
    [int]$Limit = 0
)

$ErrorActionPreference = "Stop"

$SruEndpoint = "https://ndlsearch.ndl.go.jp/api/sru"
$UserAgent = "private-bookshelf-build-script/1.0 (personal, non-commercial use)"
$PreferredRepository = "R100000002" # NDL自身の書誌(全国書誌) - 揃っていることが多い

$Ns = @{
    srw     = "http://www.loc.gov/zing/srw/"
    rdf     = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    rdfs    = "http://www.w3.org/2000/01/rdf-schema#"
    dc      = "http://purl.org/dc/elements/1.1/"
    dcterms = "http://purl.org/dc/terms/"
    dcndl   = "http://ndl.go.jp/dcndl/terms/"
    foaf    = "http://xmlns.com/foaf/0.1/"
}

# --- 決定論的なUUID v5(SHA-1のname-based)。同じISBNを再実行しても
#     同じidになるようにするため。 ---
# ISBNはURLでもDNS名でもOIDでもX.500 DNでもないので、RFC 4122が
# 定義済みの名前空間はどれも当てはまらない。RFC 4122 §4.3の通り、
# アプリケーション独自の名前空間UUIDを新たに割り当てるのが本来の使い方。
# これはこのアプリ用に一度だけ生成したもの([guid]::NewGuid())で、
# 実行のたびにidがぶれないよう固定しておく必要がある。
$Uuid5Namespace = [guid]"57d2ddca-2596-430c-94c3-306625710373" # bookshelf独自の名前空間

function New-Uuid5 {
    param([string]$Name)
    $nsBytes = $Uuid5Namespace.ToByteArray()
    # .NET のGuidは先頭3フィールドがリトルエンディアンなので、
    # ハッシュ計算の前にRFC 4122のネットワークバイト順に並び替える。
    $swapped = @(
        $nsBytes[3], $nsBytes[2], $nsBytes[1], $nsBytes[0],
        $nsBytes[5], $nsBytes[4],
        $nsBytes[7], $nsBytes[6],
        $nsBytes[8], $nsBytes[9], $nsBytes[10], $nsBytes[11], $nsBytes[12], $nsBytes[13], $nsBytes[14], $nsBytes[15]
    )
    $nameBytes = [System.Text.Encoding]::UTF8.GetBytes($Name)
    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    $hash = $sha1.ComputeHash($swapped + $nameBytes)
    $hash[6] = ($hash[6] -band 0x0F) -bor 0x50 # version 5
    $hash[8] = ($hash[8] -band 0x3F) -bor 0x80 # variant RFC4122
    $b = $hash[0..15]
    $swappedBack = [byte[]](@($b[3], $b[2], $b[1], $b[0], $b[5], $b[4], $b[7], $b[6]) + $b[8..15])
    return [guid]::new($swappedBack).ToString()
}

# 注: XmlNamespaceManagerはIEnumerableを実装しているため、素の`return`だと
# PowerShellがオブジェクト自体ではなく列挙された名前空間プレフィックスの方を
# 黙って展開して返してしまう。Write-Output -NoEnumerate でそれを防ぐ。
function New-XmlNamespaceManager {
    param([xml]$Xml)
    $nsmgr = New-Object System.Xml.XmlNamespaceManager($Xml.NameTable)
    foreach ($p in $Ns.Keys) { $nsmgr.AddNamespace($p, $Ns[$p]) }
    Write-Output -NoEnumerate $nsmgr
}

function Get-NodeText {
    param($Node, [string]$XPath, $NsMgr)
    $n = $Node.SelectSingleNode($XPath, $NsMgr)
    if ($null -eq $n) { return $null }
    $text = $n.InnerText.Trim()
    if ($text -eq "") { return $null }
    return $text
}

function ConvertTo-CleanAuthor {
    param([string]$Raw)
    if (-not $Raw) { return $null }
    $s = $Raw
    # NDLの目録での役割語(末尾に繰り返し付くことがある。例えば「著」の後に
    # 区切り文字が残るケースなど)を取り除く。例: "柳田邦男 著" -> "柳田邦男"
    $rolePattern = '\s*[;；,、]?\s*(編著|共著|編集|編訳|編|著者|著|訳者|訳|監修|画|作|原作)+\s*$'
    while ($s -match $rolePattern) {
        $s = $s -replace $rolePattern, ''
    }
    $s = $s.Trim()
    if ($s -eq "") { return $null }
    return $s
}

# 1つのISBNについて、NDL Searchが返す候補書誌レコードをすべて取得・解析する。
# 各候補は抽出したフィールドを持つオブジェクト(値がnullの場合もある)。
function Get-NdlCandidates {
    param([string]$Isbn13)

    $query = "isbn%3D$Isbn13"
    $uri = "$($SruEndpoint)?operation=searchRetrieve&version=1.2&query=$query&recordSchema=dcndl&recordPacking=xml&maximumRecords=3"

    $resp = Invoke-WebRequest -Uri $uri -UseBasicParsing -Headers @{ "User-Agent" = $UserAgent }
    [xml]$xml = $resp.Content
    $nsmgr = New-XmlNamespaceManager -Xml $xml

    $candidates = @()
    foreach ($record in $xml.SelectNodes("/srw:searchRetrieveResponse/srw:records/srw:record", $nsmgr)) {
        # 1レコードの中に同じrdf:aboutを持つdcndl:BibResourceが複数含まれる
        # ことがある(1つが書誌本体、他は所蔵情報へのリンクのみ)。
        # dcterms:titleを持つ方が書誌本体。
        $bibNode = $record.SelectSingleNode(".//dcndl:BibResource[dcterms:title]", $nsmgr)
        if ($null -eq $bibNode) { continue }

        $about = $bibNode.GetAttribute("about", $Ns.rdf)
        $title = Get-NodeText $bibNode "dcterms:title" $nsmgr
        if (-not $title) { continue }

        $baseTitle = Get-NodeText $bibNode "dc:title/rdf:Description/rdf:value" $nsmgr
        $series = $null
        if ($baseTitle -and $baseTitle -ne $title) { $series = $baseTitle }

        $label = Get-NodeText $bibNode "dcndl:seriesTitle/rdf:Description/rdf:value" $nsmgr
        $vol = Get-NodeText $bibNode "dcndl:volume/rdf:Description/rdf:value" $nsmgr

        # 最初のdcterms:creatorのNDL典拠形の名前を優先する(西欧人名の
        # 順序も正しく扱え、例えば"Anthony, Piers, 1934-"のようになる。
        # また後続のdcterms:creatorに載る訳者・編者は自然に除外される)。
        # 典拠形の名前がない場合のみ、自由記述のdc:creatorから末尾の
        # 役割語(例:「柳田邦男 著」->「柳田邦男」)を取り除いて使う。
        $author = Get-NodeText $bibNode "dcterms:creator/foaf:Agent/foaf:name" $nsmgr
        if (-not $author) {
            $authorRaw = Get-NodeText $bibNode "dc:creator" $nsmgr
            $author = ConvertTo-CleanAuthor $authorRaw
        }

        $publisher = Get-NodeText $bibNode "dcterms:publisher/foaf:Agent/foaf:name" $nsmgr

        $pubyear = Get-NodeText $bibNode "dcterms:issued" $nsmgr
        if (-not $pubyear) {
            $dateText = Get-NodeText $bibNode "dcterms:date" $nsmgr
            if ($dateText -match '(\d{4})') { $pubyear = $Matches[1] }
        }

        $ndc = $null
        foreach ($edition in @("ndc10", "ndc9", "ndc8")) {
            $subj = $bibNode.SelectSingleNode("dcterms:subject[contains(@rdf:resource,'/class/$edition/')]", $nsmgr)
            if ($subj) {
                $resource = $subj.GetAttribute("resource", $Ns.rdf)
                $ndc = $resource -replace '^.*/class/[^/]+/', ''
                break
            }
        }

        $candidates += [pscustomobject]@{
            Repository = if ($about -match "/(R\d+)-") { $Matches[1] } else { "" }
            Title      = $title
            Series     = $series
            Label      = $label
            Vol        = $vol
            Author     = $author
            Publisher  = $publisher
            PubYear    = $pubyear
            Ndc        = $ndc
        }
    }
    return $candidates
}

function Select-BestCandidate {
    param([array]$Candidates)
    if (-not $Candidates -or $Candidates.Count -eq 0) { return $null }
    $preferred = $Candidates | Where-Object { $_.Repository -eq $PreferredRepository } | Select-Object -First 1
    if ($preferred) {
        if (-not $preferred.Ndc) {
            $withNdc = $Candidates | Where-Object { $_.Ndc } | Select-Object -First 1
            if ($withNdc) { $preferred.Ndc = $withNdc.Ndc }
        }
        return $preferred
    }
    return $Candidates | Select-Object -First 1
}

function Test-HasNdc {
    param($Entry)
    return [bool]$Entry.ndc
}

# --- 入力ISBNの読み込み ---

if (-not (Test-Path $IsbnFile)) { throw "ISBN file not found: $IsbnFile" }
$isbns = Get-Content $IsbnFile | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" } | Select-Object -Unique

# --- 既存のbooks.jsonの読み込み(更新対象以外はそのまま保持する) ---

$existing = @{}       # isbn13 -> エントリ(更新対象になりうるもの)
$otherEntries = @()   # isbn13を持たない、今回の実行で触らないエントリ

if (Test-Path $OutFile) {
    $raw = Get-Content $OutFile -Raw | ConvertFrom-Json
    foreach ($e in $raw) {
        if ($e.isbn13) {
            $existing[$e.isbn13] = $e
        } else {
            $otherEntries += $e
        }
    }
}

$nowIso = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
$results = @{}  # isbn13 -> 最終的なエントリ。$existingから引き継ぎ、処理したものだけ上書きする
foreach ($k in $existing.Keys) { $results[$k] = $existing[$k] }

$requestCount = 0
$processedCount = 0

foreach ($isbn in $isbns) {
    $needsFetch = $Force -or -not $existing.ContainsKey($isbn) -or -not (Test-HasNdc $existing[$isbn])
    if (-not $needsFetch) { continue }

    if ($Limit -gt 0 -and $processedCount -ge $Limit) {
        Write-Output "上限の $Limit 件に達したため停止します(残りのISBNは変更していません)。"
        break
    }
    $processedCount++

    if ($requestCount -gt 0) {
        Start-Sleep -Seconds $IntervalSeconds
    }

    Write-Output "[$processedCount] $isbn をNDL Searchに問い合わせ中 ..."
    $best = $null
    try {
        $candidates = Get-NdlCandidates -Isbn13 $isbn
        $requestCount++
        $best = Select-BestCandidate -Candidates $candidates
    } catch {
        Write-Warning "$isbn の取得に失敗しました: $($_.Exception.Message)"
        $requestCount++
    }

    $id = if ($existing.ContainsKey($isbn)) { $existing[$isbn].id } else { New-Uuid5 "isbn:$isbn" }
    $createdAt = if ($existing.ContainsKey($isbn)) { $existing[$isbn].createdat } else { $nowIso }

    if ($best) {
        Write-Output "    -> $($best.Title)"
    } else {
        Write-Output "    -> NDLにレコードが見つかりませんでした"
    }

    $results[$isbn] = [ordered]@{
        id        = $id
        isbn13    = $isbn
        title     = $best.Title
        author    = $best.Author
        publisher = $best.Publisher
        pubyear   = $best.PubYear
        ndc       = $best.Ndc
        series    = $best.Series
        label     = $best.Label
        vol       = $best.Vol
        format    = "printed"
        createdat = $createdAt
        updatedat = $nowIso
    }
}

$allEntries = @($results.Values) + $otherEntries
# 再度@()で包む: Sort-Objectは(他の多くのコマンドレットと同様)結果が
# 1件だけのとき配列ではなく裸のオブジェクトに戻してしまうため。
$allEntries = @($allEntries | Sort-Object { $_.id })

# -AsArray を付けることで、$allEntriesがちょうど1件のときもbooks.jsonを
# JSON配列のまま保つ。付けないとConvertTo-Jsonがその場合だけ裸のオブジェクトを
# 出力してしまい、アプリ側のrawBooks.map(...)が壊れる。
$json = $allEntries | ConvertTo-Json -Depth 5 -AsArray
# ConvertTo-Jsonは非ASCII文字をすべて\uXXXXにエスケープしてしまうため、
# books.jsonが既存ファイルと同様に人間の読める状態を保つよう、
# 実際のUTF-8文字に戻す。
$json = [regex]::Replace($json, '\\u([0-9a-fA-F]{4})', { param($m) [string][char][convert]::ToInt32($m.Groups[1].Value, 16) })

Set-Content -Path $OutFile -Value $json -Encoding utf8NoBOM

Write-Output ""
Write-Output "完了しました。NDL Searchへのリクエスト $requestCount 件、合計 $($allEntries.Count) 件を $OutFile に書き込みました。"
