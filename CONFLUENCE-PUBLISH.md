# Publishing to Confluence

Confluence-ready documentation generated from `README.md` (Quay Container Registry — Quadlet Deployment).

## Files

| File | Use |
|---|---|
| `confluence-quay-quadlet.wiki` | Confluence Wiki Markup — paste via **Insert → Markup** |
| `confluence-quay-quadlet.html` | Confluence Storage Format — import via REST API |

## Option A — Confluence Server / Data Center (Markup macro)

1. In Confluence, create a new page.
2. Click **Insert** → **Markup** (or type `/markup`).
3. Select **Confluence Wiki** as the markup type.
4. Paste the entire contents of `confluence-quay-quadlet.wiki`.
5. Click **Insert**, then **Publish**.

Suggested page title: **Quay Container Registry — Quadlet Deployment**

## Option B — Confluence Cloud (paste Markdown)

1. Create a new page.
2. Copy the contents of `README.md` from this directory.
3. Paste directly into the page body — Confluence Cloud converts headings, tables, and code blocks.
4. Review formatting, then publish.

## Option C — REST API (Storage Format)

Use `confluence-quay-quadlet.html` with the Confluence REST API:

```bash
SPACE_KEY="YOUR_SPACE"
CONFLUENCE_URL="https://your-company.atlassian.net/wiki"
USER="you@company.com"
TOKEN="your-api-token"

curl -u "${USER}:${TOKEN}" \
  -X POST "${CONFLUENCE_URL}/rest/api/content" \
  -H "Content-Type: application/json" \
  -d @- <<EOF
{
  "type": "page",
  "title": "Quay Container Registry — Quadlet Deployment",
  "space": {"key": "${SPACE_KEY}"},
  "body": {
    "storage": {
      "value": $(python3 -c 'import json; print(json.dumps(open("confluence-quay-quadlet.html").read()))'),
      "representation": "storage"
    }
  }
}
EOF
```

## Suggested Confluence labels

- `quay`
- `podman`
- `quadlet`
- `container-registry`
- `runbook`
