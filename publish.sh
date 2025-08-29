#!/bin/bash

# Publish script for node-mac-recorder
# Usage: ./publish.sh <patch|minor|major> "commit message"

# Check if correct number of arguments provided
if [ $# -ne 2 ]; then
    echo "❌ Usage: $0 <patch|minor|major> \"commit message\""
    echo "   Example: $0 patch \"Fix multi-display coordinate issues\""
    exit 1
fi

VERSION_TYPE=$1
COMMIT_MESSAGE=$2

# Validate version type
if [[ "$VERSION_TYPE" != "patch" && "$VERSION_TYPE" != "minor" && "$VERSION_TYPE" != "major" ]]; then
    echo "❌ Invalid version type: $VERSION_TYPE"
    echo "   Must be one of: patch, minor, major"
    exit 1
fi

# Check if we're in a git repository
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo "❌ Not in a git repository"
    exit 1
fi

# Check if there are uncommitted changes
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "📁 Adding all changes to git..."
    git add .
    
    if [ $? -ne 0 ]; then
        echo "❌ Failed to add files to git"
        exit 1
    fi
    
    echo "📝 Committing changes..."
    git commit -m "$COMMIT_MESSAGE"
    
    if [ $? -ne 0 ]; then
        echo "❌ Failed to commit changes"
        exit 1
    fi
    
    echo "✅ Changes committed successfully"
else
    echo "ℹ️  No uncommitted changes found"
fi

# Bump version
echo "📦 Bumping $VERSION_TYPE version..."
npm version $VERSION_TYPE

if [ $? -ne 0 ]; then
    echo "❌ Failed to bump version"
    exit 1
fi

NEW_VERSION=$(node -p "require('./package.json').version")
echo "✅ Version bumped to: $NEW_VERSION"

# Push to git
echo "🚀 Pushing to git..."
git push origin HEAD

if [ $? -ne 0 ]; then
    echo "❌ Failed to push to git"
    exit 1
fi

echo "✅ Pushed to git successfully"

# Publish to npm
echo "📤 Publishing to npm..."
npm publish

if [ $? -ne 0 ]; then
    echo "❌ Failed to publish to npm"
    exit 1
fi

echo "🎉 Successfully published version $NEW_VERSION to npm!"
echo ""
echo "📋 Summary:"
echo "   • Committed: '$COMMIT_MESSAGE'"
echo "   • Version: $NEW_VERSION ($VERSION_TYPE bump)"
echo "   • Git: Pushed to remote"
echo "   • NPM: Published successfully"