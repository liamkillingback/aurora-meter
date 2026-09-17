# A fixture for AuroraMeter.HouseStyleTest's markdown scanner

Not a guide, and deliberately outside every path the scanner selects. It carries
one dash of every kind so that "the sweep found nothing" can be told apart from
"the scanner looks at nothing", which is the failure `open-findings.md` X325 and
X350 record three times in one week.

Each line below is named. The test asserts the scanner reports exactly the two
REPORT lines and none of the SILENT ones.

REPORT-prose: an em dash in ordinary prose — this one must be reported.

REPORT-en: an en dash in ordinary prose – this one must be reported too.

SILENT-span: a dash inside an inline code span, `a — b`, is a sample and is not
prose.

SILENT-url: a dash inside a URL, <https://example.com/a—b>, is an address.

```elixir
# SILENT-fence: a dash inside a fenced block — a code sample is not prose
:ok
```
