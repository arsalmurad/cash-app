# Offline title fonts

Exact upstream files from Google Fonts revision
`9710da1eacb3be272583c3224dcb70f9da6eadbb`, not dynamically fetched font CSS.
The accompanying upstream OFL notices are retained with the assets.

| Asset | Upstream path | Git blob | SHA-256 |
| --- | --- | --- | --- |
| NotoSansArabic.ttf | ofl/notosansarabic/NotoSansArabic[wdth,wght].ttf | f1d01edce4ebaedcbe9a06fc75fec07b304ec3df | 63111b5b2e074dd48cc67692e0a2726d86ee94c1c37fe8598257b7b4e87e869e |
| NotoEmoji.ttf | ofl/notoemoji/NotoEmoji[wght].ttf | c2c26ab612a88a8610ff9cfbb89299bf2aea6c7a | de6c18832938afc99caf132b39d6a30a19bac7f2e812e28db2535b4608d27551 |

The default Material font remains primary. Arabic/Urdu and monochrome emoji
fallbacks cover mixed-script transaction titles and CSV review without a
third-party font request. These are not a promise to cover every Unicode script
or every future emoji. Further script coverage requires additional bundled
assets; unsupported font fallback is restricted to the app's own origin.

The pinned web renderer emits its missing-character warning while reviewing
CRLF CSV text, but not the otherwise identical LF fixture. Do not normalize
quoted carriage returns to hide this warning: imported/exported fields must
remain exact. The browser acceptance keeps CRLF data preservation and LF
offline glyph coverage as separate cases.

Source: [Google Fonts at the pinned revision](https://github.com/google/fonts/tree/9710da1eacb3be272583c3224dcb70f9da6eadbb/ofl).
