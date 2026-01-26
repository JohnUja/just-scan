#!/bin/bash

# Script to organize development documentation files
# Run this from the "Just Scan" project directory

# Create development docs folder on Desktop
DOCS_FOLDER="$HOME/Desktop/Just Scan - Development Docs"
mkdir -p "$DOCS_FOLDER"

# Move all development documentation files
cd "$(dirname "$0")"

# Move development/debug/test files
mv APP_DEVELOPMENT_JOURNEY.md "$DOCS_FOLDER/" 2>/dev/null
mv ARCHITECTURE_COMPARISON.md "$DOCS_FOLDER/" 2>/dev/null
mv BUG_ANALYSIS.md "$DOCS_FOLDER/" 2>/dev/null
mv CLEANUP_AND_APP_STORE_PREP.md "$DOCS_FOLDER/" 2>/dev/null
mv CURRENT_ISSUES_ANALYSIS.md "$DOCS_FOLDER/" 2>/dev/null
mv DEBUG_INSTRUCTIONS.md "$DOCS_FOLDER/" 2>/dev/null
mv DEBUG_PLAN.md "$DOCS_FOLDER/" 2>/dev/null
mv DEBUG_PROBLEMS.md "$DOCS_FOLDER/" 2>/dev/null
mv DEBUG_QUICK_START.md "$DOCS_FOLDER/" 2>/dev/null
mv DEBUG_SETUP_COMPLETE.md "$DOCS_FOLDER/" 2>/dev/null
mv DEPRECATED_CODE_REMOVED.md "$DOCS_FOLDER/" 2>/dev/null
mv DOCUMENT_REVIEW_CLEANUP.md "$DOCS_FOLDER/" 2>/dev/null
mv DOCUMENT_REVIEW_VIEW_ANALYSIS.md "$DOCS_FOLDER/" 2>/dev/null
mv FAST_BUILD_FIX.md "$DOCS_FOLDER/" 2>/dev/null
mv FILES_NEEDING_FIXES.md "$DOCS_FOLDER/" 2>/dev/null
mv JITTER_AND_COLOR_TEST_PLAN.md "$DOCS_FOLDER/" 2>/dev/null
mv LOG_ANALYSIS.md "$DOCS_FOLDER/" 2>/dev/null
mv PAYWALL_AND_SUBMISSION_GUIDE.md "$DOCS_FOLDER/" 2>/dev/null
mv RELEASE_CHECKLIST.md "$DOCS_FOLDER/" 2>/dev/null
mv SELECTION_ANALYSIS.md "$DOCS_FOLDER/" 2>/dev/null
mv SELECTION_ANALYSIS_REFACTOR.md "$DOCS_FOLDER/" 2>/dev/null
mv TEST_DEBUG_LOGGING.md "$DOCS_FOLDER/" 2>/dev/null
mv TEST_PLAN.md "$DOCS_FOLDER/" 2>/dev/null

# Move Python debug scripts if they exist
mv debug_server.py "$DOCS_FOLDER/" 2>/dev/null
mv monitor_debug_logs.py "$DOCS_FOLDER/" 2>/dev/null

echo "✅ Development docs moved to: $DOCS_FOLDER"
echo ""
echo "Files kept in project:"
echo "  - README.md (project overview)"
echo "  - APP_STORE_SUBMISSION_CHECKLIST.md (submission reference)"
echo ""
echo "All development notes archived to Desktop folder."

