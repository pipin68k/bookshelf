<#
.SYNOPSIS
  Builds/updates data/books.json from data/isbn13.txt by querying the
  National Diet Library Search (NDL Search) SRU API for bibliographic data
  and NDC classification, one ISBN at a time.

.DESCRIPTION
  For each non-blank ISBN in the input file:
    - If it already has an NDC classification in the output file, it is
      skipped (no request made) unless -Force is given. This avoids
      re-querying the API on every run, per NDL Search's request to use the
      API considerately. Entries that have a title but no NDC (NDL simply
      has no NDC on file for some, mostly older, titles) are retried on
      every run, since re-cataloging can add it later.
    - Otherwise the script queries https://ndlsearch.ndl.go.jp/api/sru
      (recordSchema=dcndl), waits -IntervalSeconds, and parses the response.
    - When an ISBN matches multiple source records (NDL Search aggregates
      records from many participating libraries), the script prefers the
      record from NDL's own catalog (repository R100000002) since it is
      consistently the most complete; otherwise it falls back to the first
      returned record.
    - An ISBN NDL has no data for gets a stub entry (title/author/etc. left
      null) rather than being dropped, matching the app's existing
      "(タイトル未設定)" fallback display.
  Entries in the existing books.json that are not ISBN-driven (e.g.
  manually added ebooks) are left untouched.

.PARAMETER IntervalSeconds
  Minimum delay between actual NDL Search API requests. Default 2 seconds,
  per NDL Search's request not to send requests in rapid succession.

.PARAMETER Force
  Re-query every ISBN, including ones that already have an NDC classification.

.PARAMETER Limit
  Only process the first N ISBNs that actually need a request (0 = no
  limit). Useful for trying the script out before running it on the full list.

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
$PreferredRepository = "R100000002" # NDL's own catalog (全国書誌) - most complete when present

$Ns = @{
    srw     = "http://www.loc.gov/zing/srw/"
    rdf     = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    rdfs    = "http://www.w3.org/2000/01/rdf-schema#"
    dc      = "http://purl.org/dc/elements/1.1/"
    dcterms = "http://purl.org/dc/terms/"
    dcndl   = "http://ndl.go.jp/dcndl/terms/"
    foaf    = "http://xmlns.com/foaf/0.1/"
}

# --- deterministic UUID v5 (SHA-1 name-based), used so re-running the
#     script on an already-fetched ISBN reuses the same id. ---
$Uuid5Namespace = [guid]"6ba7b811-9dad-11d1-80b4-00c04fd430c8" # standard "URL" namespace

function New-Uuid5 {
    param([string]$Name)
    $nsBytes = $Uuid5Namespace.ToByteArray()
    # .NET Guid byte order for the first 3 fields is little-endian; swap to
    # the RFC 4122 network byte order before hashing.
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

# NOTE: XmlNamespaceManager implements IEnumerable, so a plain `return`
# would have PowerShell silently unroll it into its enumerated namespace
# prefixes instead of returning the object itself. Write-Output -NoEnumerate
# prevents that.
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
    # Strip trailing NDL cataloging role words (repeated, e.g. "著" then a
    # leftover separator), e.g. "柳田邦男 著" -> "柳田邦男".
    $rolePattern = '\s*[;；,、]?\s*(編著|共著|編集|編訳|編|著者|著|訳者|訳|監修|画|作|原作)+\s*$'
    while ($s -match $rolePattern) {
        $s = $s -replace $rolePattern, ''
    }
    $s = $s.Trim()
    if ($s -eq "") { return $null }
    return $s
}

# Fetch and parse all candidate bibliographic records NDL Search returns for
# one ISBN, each as a hashtable of extracted fields (or $null fields).
function Get-NdlCandidates {
    param([string]$Isbn13)

    $query = "isbn%3D$Isbn13"
    $uri = "$($SruEndpoint)?operation=searchRetrieve&version=1.2&query=$query&recordSchema=dcndl&recordPacking=xml&maximumRecords=3"

    $resp = Invoke-WebRequest -Uri $uri -UseBasicParsing -Headers @{ "User-Agent" = $UserAgent }
    [xml]$xml = $resp.Content
    $nsmgr = New-XmlNamespaceManager -Xml $xml

    $candidates = @()
    foreach ($record in $xml.SelectNodes("/srw:searchRetrieveResponse/srw:records/srw:record", $nsmgr)) {
        # A record can contain several dcndl:BibResource elements sharing the
        # same rdf:about (one carries the metadata, others just link to
        # holdings). The one with a dcterms:title is the metadata one.
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

        # Prefer the first creator's NDL authority name (handles Western name
        # order correctly, e.g. "Anthony, Piers, 1934-", and naturally
        # excludes translators/editors listed as later dcterms:creator
        # entries); fall back to the free-text dc:creator field, stripped of
        # trailing role words (e.g. "柳田邦男 著" -> "柳田邦男"), when no
        # authority-controlled name is available.
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

# --- load input ISBNs ---

if (-not (Test-Path $IsbnFile)) { throw "ISBN file not found: $IsbnFile" }
$isbns = Get-Content $IsbnFile | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" } | Select-Object -Unique

# --- load existing books.json (preserved as-is except for entries we refresh) ---

$existing = @{}       # isbn13 -> entry (ordered hashtable), for ones we might update
$otherEntries = @()   # entries with no isbn13, or not touched by this run

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
$results = @{}  # isbn13 -> final entry, seeded from $existing then overwritten as processed
foreach ($k in $existing.Keys) { $results[$k] = $existing[$k] }

$requestCount = 0
$processedCount = 0

foreach ($isbn in $isbns) {
    $needsFetch = $Force -or -not $existing.ContainsKey($isbn) -or -not (Test-HasNdc $existing[$isbn])
    if (-not $needsFetch) { continue }

    if ($Limit -gt 0 -and $processedCount -ge $Limit) {
        Write-Output "Limit of $Limit reached, stopping (remaining ISBNs left untouched)."
        break
    }
    $processedCount++

    if ($requestCount -gt 0) {
        Start-Sleep -Seconds $IntervalSeconds
    }

    Write-Output "[$processedCount] querying NDL Search for $isbn ..."
    $best = $null
    try {
        $candidates = Get-NdlCandidates -Isbn13 $isbn
        $requestCount++
        $best = Select-BestCandidate -Candidates $candidates
    } catch {
        Write-Warning "Request failed for $isbn`: $($_.Exception.Message)"
        $requestCount++
    }

    $id = if ($existing.ContainsKey($isbn)) { $existing[$isbn].id } else { New-Uuid5 "isbn:$isbn" }
    $createdAt = if ($existing.ContainsKey($isbn)) { $existing[$isbn].createdat } else { $nowIso }

    if ($best) {
        Write-Output "    -> $($best.Title)"
    } else {
        Write-Output "    -> no NDL record found"
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
$allEntries = $allEntries | Sort-Object { $_.id }

$json = $allEntries | ConvertTo-Json -Depth 5
# ConvertTo-Json escapes all non-ASCII characters as \uXXXX; decode them back
# to literal UTF-8 so books.json stays human-readable (matches the existing file).
$json = [regex]::Replace($json, '\\u([0-9a-fA-F]{4})', { param($m) [string][char][convert]::ToInt32($m.Groups[1].Value, 16) })

Set-Content -Path $OutFile -Value $json -Encoding utf8NoBOM

Write-Output ""
Write-Output "Done. $requestCount NDL Search request(s) made, $($allEntries.Count) total entries written to $OutFile"
