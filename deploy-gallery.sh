#!/bin/bash
set -e
cd "/Users/ameen.ahsan/Downloads/CoWork/GSMP"

echo "STEP 1/3 — Loading SQL to clipboard + opening Supabase SQL Editor"
cat gallery-setup.sql | pbcopy
open "https://supabase.com/dashboard/project/jeumykmrcbyugfdsttxf/sql/new"
echo ""
echo "   The SQL is in your clipboard. In the browser:"
echo "   1. Paste (Cmd+V)"
echo "   2. Click Run"
echo "   3. Confirm no errors"
echo ""
read -p "Press ENTER after the SQL has run successfully (or Ctrl+C to abort)..."

echo ""
echo "STEP 2/3 — Reviewing files to commit"
git add -A
git status --short
echo ""
read -p "Look right? Press ENTER to commit + push (or Ctrl+C to abort)..."

echo ""
echo "STEP 3/3 — Pushing to GitHub"
git commit -m "Add gallery feature (albums, photos, public page, admin tabs)"
git push origin main

echo ""
echo "Done. GitHub Pages will redeploy in ~2 min."
echo "Verify: https://gsmp.org/pages/gallery"
