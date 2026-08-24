# Elementor publishing assets

Generated from the repository `README.md` by
`~/.claude/skills/marcs-vibe-coding/scripts/readme_forge.py`. Regenerate after
any README change: these are build output, not sources.

| File | Where it goes |
|---|---|
| `Boffin.html` | Paste into an Elementor **HTML** widget on marcdeller.com |
| `elementor-widget-markdown.css` | Paste into that widget's **Advanced → Custom CSS** box. It uses Elementor's `selector` token, so it only resolves there: it will not work as a global stylesheet or in a plain browser |
| `Boffin.preview.html` | Open locally to check the styled result before publishing. Not for upload |

```bash
cp README.md /tmp/Boffin.md
python3 ~/.claude/skills/marcs-vibe-coding/scripts/readme_forge.py /tmp/Boffin.md
```
