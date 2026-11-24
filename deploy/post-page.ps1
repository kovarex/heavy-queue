# Posts a page or a JSON document to a running board, with the posting password (the board's address and
# password are publish.txt's first two lines: the data folder's, or -PublishFile):
#   post-page.ps1                          the main page as board\src\BoardPage.kpp has it, so a board shows
#                                          a new page without a new program (deploy\upload.cmd drops it again)
#   post-page.ps1 -Name NAME -File F       another page (HTML), linked from the main page as NAME
#   post-page.ps1 -Document NAME -File F   a JSON document, which such a page's script reads with ?doc=NAME
param([string]$Name = '', [string]$Document = '', [string]$File = '', [string]$PublishFile = '')
$ErrorActionPreference = 'Stop'
$clone = Split-Path $PSScriptRoot
if (-not $PublishFile) { . (Join-Path $clone 'lock\config.ps1'); $PublishFile = Join-Path $root 'publish.txt' }
$lines = @(Get-Content $PublishFile -TotalCount 2)
if ($lines.Count -lt 2) { throw "$PublishFile has no address and password" }
$address = $lines[0].Trim()
$secret = $lines[1].Trim()
if ($Name -and $Document) { throw 'a page or a document, not both' }
if (($Name -or $Document) -and -not $File) { throw '-File names what to post' }
if ($Document) { $query = "doc=$Document"; $type = 'application/json' } elseif ($Name) { $query = "page=$Name"; $type = 'text/html; charset=utf-8' } else { $query = 'page'; $type = 'text/html; charset=utf-8' }
if ($File) { $text = [IO.File]::ReadAllText((Resolve-Path $File)) }
else
{
  # The built-in page: BoardPage.kpp's raw string, from R"( to the first )" as the compiler reads it.
  $source = [IO.File]::ReadAllText((Join-Path $clone 'board\src\BoardPage.kpp'))
  $start = $source.IndexOf('R"(')
  $end = $source.IndexOf(')"', $start + 3)
  if ($start -lt 0 -or $end -lt 0) { throw 'BoardPage.kpp has no R"(...)" page' }
  $text = $source.Substring($start + 3, $end - $start - 3)
}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$answer = Invoke-WebRequest -UseBasicParsing -Method Post -Uri "$address`?$query" -Headers @{ 'X-Heavy-Password' = $secret } -ContentType $type -Body ([Text.Encoding]::UTF8.GetBytes($text)) -TimeoutSec 60
"posted ?$query ($($text.Length) characters): $($answer.StatusCode)"
